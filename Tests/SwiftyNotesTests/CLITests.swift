import Foundation
import Testing
@testable import SwiftyNotes

struct CLITests {
    @Test
    func cliRunIfRequestedIgnoresNonCLIArguments() {
        #expect(NotesCLI.runIfRequested(arguments: ["list"]) == nil)
        #expect(NotesCLI.runIfRequested(arguments: []) == nil)
    }

    @Test
    func cliSupportsStdinAndContentFileSources() throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let notesDirectory = temp.appendingPathComponent("notes", isDirectory: true)
        let contentFile = temp.appendingPathComponent("content.txt", isDirectory: false)
        try "# From File\n\nBody from file".write(to: contentFile, atomically: true, encoding: .utf8)

        let createFromStdin = NotesCLI.runIfRequested(
            arguments: ["cli", "create", "--notes-dir", notesDirectory.path(), "--stdin"],
            stdin: Data("# From Stdin\n\nBody from stdin".utf8)
        )
        #expect(createFromStdin?.exitCode == 0)
        let stdinDocument = try decodeDocument(from: createFromStdin?.stdout ?? "")
        #expect(stdinDocument.title == "From Stdin")

        let createFromFile = NotesCLI.runIfRequested(
            arguments: ["cli", "create", "--notes-dir", notesDirectory.path(), "--content-file", contentFile.path()]
        )
        #expect(createFromFile?.exitCode == 0)
        let fileDocument = try decodeDocument(from: createFromFile?.stdout ?? "")
        #expect(fileDocument.title == "From File")

        let updateFromFile = NotesCLI.runIfRequested(
            arguments: ["cli", "update", "--notes-dir", notesDirectory.path(), stdinDocument.id, "--content-file", contentFile.path()]
        )
        #expect(updateFromFile?.exitCode == 0)
        let updatedFromFile = try decodeDocument(from: updateFromFile?.stdout ?? "")
        #expect(updatedFromFile.content == "# From File\n\nBody from file")

        let updateFromStdin = NotesCLI.runIfRequested(
            arguments: ["cli", "update", "--notes-dir", notesDirectory.path(), fileDocument.id, "--stdin"],
            stdin: Data("# Updated From Stdin\n\nReplacement".utf8)
        )
        #expect(updateFromStdin?.exitCode == 0)
        let updatedFromStdin = try decodeDocument(from: updateFromStdin?.stdout ?? "")
        #expect(updatedFromStdin.content == "# Updated From Stdin\n\nReplacement")

        let listResult = NotesCLI.runIfRequested(arguments: ["cli", "list", "--notes-dir", notesDirectory.path()])
        #expect(listResult?.exitCode == 0)
        let listed = try decodeSummaries(from: listResult?.stdout ?? "")
        #expect(listed.count == 2)
        #expect(Set(listed.map(\.id)) == Set([stdinDocument.id, fileDocument.id]))
    }

    @Test
    func cliReportsUsageAndRuntimeErrors() {
        let unknownCommand = NotesCLI.runIfRequested(arguments: ["cli", "unknown"])
        #expect(unknownCommand?.exitCode == 2)
        #expect(unknownCommand?.stderr.contains("Unknown CLI command") == true)

        let conflictingSources = NotesCLI.runIfRequested(
            arguments: ["cli", "create", "--content", "inline", "--stdin"],
            stdin: Data("stdin".utf8)
        )
        #expect(conflictingSources?.exitCode == 2)
        #expect(conflictingSources?.stderr.contains("Use only one of --content, --content-file, or --stdin.") == true)

        let missingReplacement = NotesCLI.runIfRequested(
            arguments: ["cli", "update", UUID().uuidString.lowercased()]
        )
        #expect(missingReplacement?.exitCode == 2)
        #expect(missingReplacement?.stderr.contains("Replacement content is required.") == true)

        let missingNotesDirectoryValue = NotesCLI.runIfRequested(arguments: ["cli", "--notes-dir"])
        #expect(missingNotesDirectoryValue?.exitCode == 2)
        #expect(missingNotesDirectoryValue?.stderr.contains("Missing value for --notes-dir.") == true)

        let invalidUTF8Stdin = NotesCLI.runIfRequested(
            arguments: ["cli", "create", "--stdin"],
            stdin: Data([0xFF])
        )
        #expect(invalidUTF8Stdin?.exitCode == 1)
        #expect(invalidUTF8Stdin?.stderr.contains("Could not read UTF-8 content from stdin") == true)
    }

    @Test
    func cliExecutableRoundTripsNotesAcrossProcesses() throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let notesDirectory = temp.appendingPathComponent("notes", isDirectory: true)
        let updateFile = temp.appendingPathComponent("updated.txt", isDirectory: false)
        try "# Updated Process Note\n\nFrom file".write(to: updateFile, atomically: true, encoding: .utf8)

        let createResult = try runCLIExecutable(
            arguments: ["cli", "--notes-dir", notesDirectory.path(), "create", "--stdin"],
            stdin: "# Process Note\n\nCreated via stdin"
        )
        #expect(createResult.exitCode == 0)
        #expect(createResult.stderr.isEmpty)
        let created = try decodeDocument(from: createResult.stdout)

        let listResult = try runCLIExecutable(arguments: ["cli", "list", "--notes-dir", notesDirectory.path()])
        #expect(listResult.exitCode == 0)
        let listed = try decodeSummaries(from: listResult.stdout)
        #expect(listed.count == 1)
        #expect(listed.first?.id == created.id)

        let rawGetResult = try runCLIExecutable(
            arguments: ["cli", "get", created.id, "--raw", "--notes-dir", notesDirectory.path()]
        )
        #expect(rawGetResult.exitCode == 0)
        #expect(rawGetResult.stdout == "# Process Note\n\nCreated via stdin\n")

        let updateResult = try runCLIExecutable(
            arguments: ["cli", "update", created.id, "--content-file", updateFile.path(), "--notes-dir", notesDirectory.path()]
        )
        #expect(updateResult.exitCode == 0)
        let updated = try decodeDocument(from: updateResult.stdout)
        #expect(updated.title == "Updated Process Note")

        let persisted = try NotesRepository(notesDirectory: notesDirectory).loadNotes()
        #expect(persisted.count == 1)
        #expect(persisted.first?.content == "# Updated Process Note\n\nFrom file")
    }

    @Test
    func cliExecutableUsesDefaultXDGNotesDirectory() throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let xdgDataHome = temp.appendingPathComponent("xdg-data", isDirectory: true)
        let environment = ["XDG_DATA_HOME": xdgDataHome.path()]

        let createResult = try runCLIExecutable(
            arguments: ["cli", "create", "--content", "# Default Path\n\nBody"],
            environment: environment
        )
        #expect(createResult.exitCode == 0)

        let defaultDirectory = xdgDataHome
            .appendingPathComponent("io.github.makoni.SwiftyNotes", isDirectory: true)
            .appendingPathComponent("notes", isDirectory: true)
        let repository = NotesRepository(notesDirectory: defaultDirectory)
        let notes = try repository.loadNotes()
        #expect(notes.count == 1)
        #expect(notes.first?.title == "Default Path")

        let listResult = try runCLIExecutable(arguments: ["cli", "list"], environment: environment)
        #expect(listResult.exitCode == 0)
        let listed = try decodeSummaries(from: listResult.stdout)
        #expect(listed.count == 1)
        #expect(listed.first?.title == "Default Path")
    }

    @Test
    func cliExecutableSurfacesHelpAndExitCodes() throws {
        let helpResult = try runCLIExecutable(arguments: ["cli", "help", "create"])
        #expect(helpResult.exitCode == 0)
        #expect(helpResult.stdout.contains("SwiftyNotes cli create"))
        #expect(helpResult.stderr.isEmpty)

        let invalidIDResult = try runCLIExecutable(
            arguments: ["cli", "update", "not-a-uuid", "--content", "Hello"]
        )
        #expect(invalidIDResult.exitCode == 2)
        #expect(invalidIDResult.stdout.isEmpty)
        #expect(invalidIDResult.stderr.contains("Invalid note ID: not-a-uuid"))

        let notFoundResult = try runCLIExecutable(
            arguments: ["cli", "get", UUID().uuidString.lowercased(), "--notes-dir", temporaryDirectory().path()]
        )
        #expect(notFoundResult.exitCode == 3)
        #expect(notFoundResult.stderr.contains("No note found") == true)
    }
}

private struct CLIProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private struct CLIFileTestSummary: Decodable {
    let id: String
    let title: String
    let filename: String
    let createdAt: Date
    let updatedAt: Date
}

private struct CLIFileTestDocument: Decodable {
    let id: String
    let title: String
    let filename: String
    let createdAt: Date
    let updatedAt: Date
    let content: String
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func decodeSummaries(from json: String) throws -> [CLIFileTestSummary] {
    try cliJSONDecoder().decode([CLIFileTestSummary].self, from: Data(json.utf8))
}

private func decodeDocument(from json: String) throws -> CLIFileTestDocument {
    try cliJSONDecoder().decode(CLIFileTestDocument.self, from: Data(json.utf8))
}

private func cliJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

private func runCLIExecutable(
    arguments: [String],
    stdin: String? = nil,
    environment: [String: String] = [:]
) throws -> CLIProcessResult {
    let process = Process()
    process.executableURL = swiftyNotesExecutableURL()
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let stdinPipe: Pipe?
    if stdin != nil {
        let pipe = Pipe()
        process.standardInput = pipe
        stdinPipe = pipe
    } else {
        stdinPipe = nil
    }

    try process.run()

    if let stdin, let stdinPipe {
        stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
        stdinPipe.fileHandleForWriting.closeFile()
    }

    process.waitUntilExit()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    return CLIProcessResult(
        exitCode: process.terminationStatus,
        stdout: String(decoding: stdoutData, as: UTF8.self),
        stderr: String(decoding: stderrData, as: UTF8.self)
    )
}

private func swiftyNotesExecutableURL() -> URL {
    URL(fileURLWithPath: CommandLine.arguments[0], isDirectory: false)
        .deletingLastPathComponent()
        .appendingPathComponent("SwiftyNotes", isDirectory: false)
}
