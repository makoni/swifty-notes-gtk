import Foundation
@testable import SwiftyNotes
import Testing

struct CLITests {
    @Test
    func `cli run if requested ignores non CLI arguments`() {
        #expect(NotesCLI.runIfRequested(arguments: ["list"]) == nil)
        #expect(NotesCLI.runIfRequested(arguments: []) == nil)
    }

    @Test
    func `cli run if requested tolerates a leading dash dash from swift run`() {
        // `swift run swiftynotes -- cli list` forwards "--" to the binary
        // in some SwiftPM versions; the dispatch should still route to the
        // CLI rather than fall through to the GUI launcher.
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let notesDirectory = temp.appendingPathComponent("notes", isDirectory: true)
        let result = NotesCLI.runIfRequested(arguments: [
            "--", "cli", "list", "--notes-dir", notesDirectory.path(),
        ])
        #expect(result?.exitCode == 0)
    }

    @Test
    func `cli supports stdin and content file sources`() throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let notesDirectory = temp.appendingPathComponent("notes", isDirectory: true)
        let contentFile = temp.appendingPathComponent("content.txt", isDirectory: false)
        try "# From File\n\nBody from file".write(to: contentFile, atomically: true, encoding: .utf8)

        let createFromStdin = NotesCLI.runIfRequested(
            arguments: ["cli", "create", "--notes-dir", notesDirectory.path(), "--stdin"],
            stdin: Data("# From Stdin\n\nBody from stdin".utf8),
        )
        #expect(createFromStdin?.exitCode == 0)
        let stdinDocument = try decodeDocument(from: createFromStdin?.stdout ?? "")
        #expect(stdinDocument.title == "From Stdin")
        #expect(stdinDocument.filename.hasSuffix("/note.md"))

        let createFromFile = NotesCLI.runIfRequested(
            arguments: ["cli", "create", "--notes-dir", notesDirectory.path(), "--content-file", contentFile.path()],
        )
        #expect(createFromFile?.exitCode == 0)
        let fileDocument = try decodeDocument(from: createFromFile?.stdout ?? "")
        #expect(fileDocument.title == "From File")
        #expect(fileDocument.filename.hasSuffix("/note.md"))

        let updateFromFile = NotesCLI.runIfRequested(
            arguments: ["cli", "update", "--notes-dir", notesDirectory.path(), stdinDocument.id, "--content-file", contentFile.path()],
        )
        #expect(updateFromFile?.exitCode == 0)
        let updatedFromFile = try decodeDocument(from: updateFromFile?.stdout ?? "")
        #expect(updatedFromFile.content == "# From File\n\nBody from file")

        let updateFromStdin = NotesCLI.runIfRequested(
            arguments: ["cli", "update", "--notes-dir", notesDirectory.path(), fileDocument.id, "--stdin"],
            stdin: Data("# Updated From Stdin\n\nReplacement".utf8),
        )
        #expect(updateFromStdin?.exitCode == 0)
        let updatedFromStdin = try decodeDocument(from: updateFromStdin?.stdout ?? "")
        #expect(updatedFromStdin.content == "# Updated From Stdin\n\nReplacement")

        let listResult = NotesCLI.runIfRequested(arguments: ["cli", "list", "--notes-dir", notesDirectory.path()])
        #expect(listResult?.exitCode == 0)
        let listed = try decodeSummaries(from: listResult?.stdout ?? "")
        #expect(listed.count == 2)
        #expect(Set(listed.map(\.id)) == Set([stdinDocument.id, fileDocument.id]))
        #expect(listed.allSatisfy { $0.filename.hasSuffix("/note.md") })
    }

    @Test
    func `cli reports usage and runtime errors`() {
        let unknownCommand = NotesCLI.runIfRequested(arguments: ["cli", "unknown"])
        #expect(unknownCommand?.exitCode == 2)
        #expect(unknownCommand?.stderr.contains("Unknown CLI command") == true)

        let conflictingSources = NotesCLI.runIfRequested(
            arguments: ["cli", "create", "--content", "inline", "--stdin"],
            stdin: Data("stdin".utf8),
        )
        #expect(conflictingSources?.exitCode == 2)
        #expect(conflictingSources?.stderr.contains("Use only one of --content, --content-file, or --stdin.") == true)

        let missingReplacement = NotesCLI.runIfRequested(
            arguments: ["cli", "update", UUID().uuidString.lowercased()],
        )
        #expect(missingReplacement?.exitCode == 2)
        #expect(missingReplacement?.stderr.contains("Replacement content is required.") == true)

        let missingNotesDirectoryValue = NotesCLI.runIfRequested(arguments: ["cli", "--notes-dir"])
        #expect(missingNotesDirectoryValue?.exitCode == 2)
        #expect(missingNotesDirectoryValue?.stderr.contains("Missing value for --notes-dir.") == true)

        let invalidUTF8Stdin = NotesCLI.runIfRequested(
            arguments: ["cli", "create", "--stdin"],
            stdin: Data([0xFF]),
        )
        #expect(invalidUTF8Stdin?.exitCode == 1)
        #expect(invalidUTF8Stdin?.stderr.contains("Could not read UTF-8 content from stdin") == true)
    }

    @Test
    func `cli create with folder auto creates the folder and places the note there`() throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let notesDirectory = temp.appendingPathComponent("notes", isDirectory: true)

        let result = NotesCLI.runIfRequested(
            arguments: [
                "cli", "create",
                "--notes-dir", notesDirectory.path(),
                "--folder", "Work/Projects",
                "--content", "# Hi",
            ],
        )
        #expect(result?.exitCode == 0)
        let document = try decodeDocument(from: result?.stdout ?? "")
        #expect(document.folder == "Work/Projects")

        let foldersResult = NotesCLI.runIfRequested(
            arguments: ["cli", "folders", "--notes-dir", notesDirectory.path()],
        )
        #expect(foldersResult?.exitCode == 0)
        let folders = try cliJSONDecoder().decode([String].self, from: Data((foldersResult?.stdout ?? "").utf8))
        #expect(folders.contains("Work"))
        #expect(folders.contains("Work/Projects"))
    }

    @Test
    func `cli list with folder scopes results to that folder and its descendants`() throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let notesDirectory = temp.appendingPathComponent("notes", isDirectory: true)

        _ = NotesCLI.runIfRequested(arguments: [
            "cli", "create", "--notes-dir", notesDirectory.path(), "--content", "root",
        ])
        _ = NotesCLI.runIfRequested(arguments: [
            "cli", "create", "--notes-dir", notesDirectory.path(),
            "--folder", "Work", "--content", "work",
        ])
        _ = NotesCLI.runIfRequested(arguments: [
            "cli", "create", "--notes-dir", notesDirectory.path(),
            "--folder", "Work/Drafts", "--content", "draft",
        ])
        _ = NotesCLI.runIfRequested(arguments: [
            "cli", "create", "--notes-dir", notesDirectory.path(),
            "--folder", "Personal", "--content", "personal",
        ])

        let scoped = NotesCLI.runIfRequested(arguments: [
            "cli", "list", "--notes-dir", notesDirectory.path(), "--folder", "Work",
        ])
        #expect(scoped?.exitCode == 0)
        let summaries = try decodeSummaries(from: scoped?.stdout ?? "")
        #expect(summaries.count == 2)
        #expect(Set(summaries.map(\.folder)) == Set(["Work", "Work/Drafts"]))
    }

    @Test
    func `cli move relocates a note and creates intermediate folders`() throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let notesDirectory = temp.appendingPathComponent("notes", isDirectory: true)

        let createResult = NotesCLI.runIfRequested(arguments: [
            "cli", "create", "--notes-dir", notesDirectory.path(), "--content", "hi",
        ])
        let created = try decodeDocument(from: createResult?.stdout ?? "")

        let moveResult = NotesCLI.runIfRequested(arguments: [
            "cli", "move", created.id,
            "--notes-dir", notesDirectory.path(),
            "--folder", "Work/Drafts",
        ])
        #expect(moveResult?.exitCode == 0)
        let moved = try decodeDocument(from: moveResult?.stdout ?? "")
        #expect(moved.id == created.id)
        #expect(moved.folder == "Work/Drafts")

        // Move back to root via --folder ""
        let backResult = NotesCLI.runIfRequested(arguments: [
            "cli", "move", created.id,
            "--notes-dir", notesDirectory.path(),
            "--folder", "",
        ])
        #expect(backResult?.exitCode == 0)
        let back = try decodeDocument(from: backResult?.stdout ?? "")
        #expect(back.folder == "")
    }

    @Test
    func `cli folders create makes a new folder and reflects it in folders output`() throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let notesDirectory = temp.appendingPathComponent("notes", isDirectory: true)

        let result = NotesCLI.runIfRequested(arguments: [
            "cli", "folders", "create", "Work/Drafts",
            "--notes-dir", notesDirectory.path(),
        ])
        #expect(result?.exitCode == 0)
        let foldersResult = NotesCLI.runIfRequested(arguments: [
            "cli", "folders", "--notes-dir", notesDirectory.path(),
        ])
        let folders = try cliJSONDecoder().decode([String].self, from: Data((foldersResult?.stdout ?? "").utf8))
        #expect(folders.contains("Work"))
        #expect(folders.contains("Work/Drafts"))
    }

    @Test
    func `cli folders rm refuses non empty folders without yes flag`() throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let notesDirectory = temp.appendingPathComponent("notes", isDirectory: true)

        _ = NotesCLI.runIfRequested(arguments: [
            "cli", "create", "--notes-dir", notesDirectory.path(),
            "--folder", "Work", "--content", "x",
        ])

        let refused = NotesCLI.runIfRequested(arguments: [
            "cli", "folders", "rm", "Work",
            "--notes-dir", notesDirectory.path(),
        ])
        #expect(refused?.exitCode == 2)
        #expect(refused?.stderr.contains("--yes") == true)

        let confirmed = NotesCLI.runIfRequested(arguments: [
            "cli", "folders", "rm", "Work", "--yes",
            "--notes-dir", notesDirectory.path(),
        ])
        #expect(confirmed?.exitCode == 0)

        let listAfter = NotesCLI.runIfRequested(arguments: [
            "cli", "list", "--notes-dir", notesDirectory.path(),
        ])
        let summaries = try decodeSummaries(from: listAfter?.stdout ?? "")
        #expect(summaries.isEmpty)
    }

    @Test
    func `cli folders rm allows deleting an empty folder without yes`() throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let notesDirectory = temp.appendingPathComponent("notes", isDirectory: true)

        _ = NotesCLI.runIfRequested(arguments: [
            "cli", "folders", "create", "Empty",
            "--notes-dir", notesDirectory.path(),
        ])
        let result = NotesCLI.runIfRequested(arguments: [
            "cli", "folders", "rm", "Empty",
            "--notes-dir", notesDirectory.path(),
        ])
        #expect(result?.exitCode == 0)
    }

    @Test
    func `cli folders rename moves the folder and notes follow`() throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let notesDirectory = temp.appendingPathComponent("notes", isDirectory: true)

        _ = NotesCLI.runIfRequested(arguments: [
            "cli", "create", "--notes-dir", notesDirectory.path(),
            "--folder", "Old", "--content", "x",
        ])
        let result = NotesCLI.runIfRequested(arguments: [
            "cli", "folders", "rename", "Old", "New",
            "--notes-dir", notesDirectory.path(),
        ])
        #expect(result?.exitCode == 0)

        let listed = NotesCLI.runIfRequested(arguments: [
            "cli", "list", "--notes-dir", notesDirectory.path(),
        ])
        let summaries = try decodeSummaries(from: listed?.stdout ?? "")
        #expect(summaries.first?.folder == "New")
    }

    @Test
    func `cli folders move relocates a folder under a new parent`() throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let notesDirectory = temp.appendingPathComponent("notes", isDirectory: true)

        _ = NotesCLI.runIfRequested(arguments: [
            "cli", "folders", "create", "Inbox",
            "--notes-dir", notesDirectory.path(),
        ])
        _ = NotesCLI.runIfRequested(arguments: [
            "cli", "folders", "create", "Archive",
            "--notes-dir", notesDirectory.path(),
        ])
        let result = NotesCLI.runIfRequested(arguments: [
            "cli", "folders", "move", "Inbox", "--to", "Archive",
            "--notes-dir", notesDirectory.path(),
        ])
        #expect(result?.exitCode == 0)

        let foldersResult = NotesCLI.runIfRequested(arguments: [
            "cli", "folders", "--notes-dir", notesDirectory.path(),
        ])
        let folders = try cliJSONDecoder().decode([String].self, from: Data((foldersResult?.stdout ?? "").utf8))
        #expect(folders.contains("Archive/Inbox"))
        #expect(!folders.contains("Inbox"))
    }

    @Test
    func `cli executable round trips notes across processes`() throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let notesDirectory = temp.appendingPathComponent("notes", isDirectory: true)
        let updateFile = temp.appendingPathComponent("updated.txt", isDirectory: false)
        try "# Updated Process Note\n\nFrom file".write(to: updateFile, atomically: true, encoding: .utf8)

        let createResult = try runCLIExecutable(
            arguments: ["cli", "--notes-dir", notesDirectory.path(), "create", "--stdin"],
            stdin: "# Process Note\n\nCreated via stdin",
        )
        #expect(createResult.exitCode == 0)
        #expect(createResult.stderr.isEmpty)
        let created = try decodeDocument(from: createResult.stdout)
        #expect(created.filename.hasSuffix("/note.md"))

        let listResult = try runCLIExecutable(arguments: ["cli", "list", "--notes-dir", notesDirectory.path()])
        #expect(listResult.exitCode == 0)
        let listed = try decodeSummaries(from: listResult.stdout)
        #expect(listed.count == 1)
        #expect(listed.first?.id == created.id)

        let rawGetResult = try runCLIExecutable(
            arguments: ["cli", "get", created.id, "--raw", "--notes-dir", notesDirectory.path()],
        )
        #expect(rawGetResult.exitCode == 0)
        #expect(rawGetResult.stdout == "# Process Note\n\nCreated via stdin\n")

        let updateResult = try runCLIExecutable(
            arguments: ["cli", "update", created.id, "--content-file", updateFile.path(), "--notes-dir", notesDirectory.path()],
        )
        #expect(updateResult.exitCode == 0)
        let updated = try decodeDocument(from: updateResult.stdout)
        #expect(updated.title == "Updated Process Note")
        #expect(updated.filename == created.filename)

        let persisted = try NotesRepository(notesDirectory: notesDirectory).loadNotes()
        #expect(persisted.count == 1)
        #expect(persisted.first?.content == "# Updated Process Note\n\nFrom file")
    }

    @Test
    func `cli executable uses default XDG notes directory`() throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let xdgDataHome = temp.appendingPathComponent("xdg-data", isDirectory: true)
        let xdgConfigHome = temp.appendingPathComponent("xdg-config", isDirectory: true)
        let environment = [
            "XDG_DATA_HOME": xdgDataHome.path(),
            "XDG_CONFIG_HOME": xdgConfigHome.path(),
        ]

        let createResult = try runCLIExecutable(
            arguments: ["cli", "create", "--content", "# Default Path\n\nBody"],
            environment: environment,
        )
        #expect(createResult.exitCode == 0)

        let defaultDirectory = xdgDataHome
            .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
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
    func `cli executable uses configured notes directory from settings`() throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let xdgDataHome = temp.appendingPathComponent("xdg-data", isDirectory: true)
        let xdgConfigHome = temp.appendingPathComponent("xdg-config", isDirectory: true)
        let customNotesDirectory = temp.appendingPathComponent("custom-notes", isDirectory: true)
        let settingsStore = AppSettingsStore(
            settingsFileURL: xdgConfigHome
                .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
                .appendingPathComponent("settings.json", isDirectory: false),
        )
        try settingsStore.save(AppSettings(customNotesDirectoryPath: customNotesDirectory.path()))

        let environment = [
            "XDG_DATA_HOME": xdgDataHome.path(),
            "XDG_CONFIG_HOME": xdgConfigHome.path(),
        ]

        let createResult = try runCLIExecutable(
            arguments: ["cli", "create", "--content", "# Configured Path\n\nBody"],
            environment: environment,
        )
        #expect(createResult.exitCode == 0)

        let notes = try NotesRepository(notesDirectory: customNotesDirectory).loadNotes()
        #expect(notes.count == 1)
        #expect(notes.first?.title == "Configured Path")

        let defaultDirectory = xdgDataHome
            .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
            .appendingPathComponent("notes", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: defaultDirectory.path()))
    }

    @Test
    func `cli executable falls back to flatpak default notes directory when host storage is empty`() throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let flatpakDataHome = temp
            .appendingPathComponent(".var", isDirectory: true)
            .appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
        let flatpakNotesDirectory = flatpakDataHome
            .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
            .appendingPathComponent("notes", isDirectory: true)
        let note = try NotesRepository(notesDirectory: flatpakNotesDirectory)
            .createNote(initialContent: "# Flatpak Default\n\nBody")

        let environment = [
            "HOME": temp.path(),
            "XDG_DATA_HOME": "",
            "XDG_CONFIG_HOME": "",
            "XDG_STATE_HOME": "",
        ]

        let getResult = try runCLIExecutable(
            arguments: ["cli", "get", note.stableID],
            environment: environment,
        )
        #expect(getResult.exitCode == 0)
        let fetched = try decodeDocument(from: getResult.stdout)
        #expect(fetched.id == note.stableID)
        #expect(fetched.title == "Flatpak Default")
    }

    @Test
    func `cli executable falls back to flatpak configured notes directory when host storage is empty`() throws {
        let temp = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let flatpakRoot = temp
            .appendingPathComponent(".var", isDirectory: true)
            .appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
        let flatpakConfigHome = flatpakRoot.appendingPathComponent("config", isDirectory: true)
        let customNotesDirectory = temp.appendingPathComponent("flatpak-custom-notes", isDirectory: true)
        let settingsStore = AppSettingsStore(
            settingsFileURL: flatpakConfigHome
                .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
                .appendingPathComponent("settings.json", isDirectory: false),
        )
        try settingsStore.save(AppSettings(customNotesDirectoryPath: customNotesDirectory.path()))
        let note = try NotesRepository(notesDirectory: customNotesDirectory)
            .createNote(initialContent: "# Flatpak Configured\n\nBody")

        let environment = [
            "HOME": temp.path(),
            "XDG_DATA_HOME": "",
            "XDG_CONFIG_HOME": "",
            "XDG_STATE_HOME": "",
        ]

        let getResult = try runCLIExecutable(
            arguments: ["cli", "get", note.stableID],
            environment: environment,
        )
        #expect(getResult.exitCode == 0)
        let fetched = try decodeDocument(from: getResult.stdout)
        #expect(fetched.id == note.stableID)
        #expect(fetched.title == "Flatpak Configured")
    }

    @Test
    func `cli executable surfaces help and exit codes`() throws {
        let helpResult = try runCLIExecutable(arguments: ["cli", "help", "create"])
        #expect(helpResult.exitCode == 0)
        #expect(helpResult.stdout.contains("swiftynotes cli create"))
        #expect(helpResult.stderr.isEmpty)

        let invalidIDResult = try runCLIExecutable(
            arguments: ["cli", "update", "not-a-uuid", "--content", "Hello"],
        )
        #expect(invalidIDResult.exitCode == 2)
        #expect(invalidIDResult.stdout.isEmpty)
        #expect(invalidIDResult.stderr.contains("Invalid note ID: not-a-uuid"))

        let notFoundResult = try runCLIExecutable(
            arguments: ["cli", "get", UUID().uuidString.lowercased(), "--notes-dir", temporaryDirectory().path()],
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
    let folder: String
    let createdAt: Date
    let updatedAt: Date
}

private struct CLIFileTestDocument: Decodable {
    let id: String
    let title: String
    let filename: String
    let folder: String
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
    environment: [String: String] = [:],
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
        stderr: String(decoding: stderrData, as: UTF8.self),
    )
}

private func swiftyNotesExecutableURL() -> URL {
    URL(fileURLWithPath: CommandLine.arguments[0], isDirectory: false)
        .deletingLastPathComponent()
        .appendingPathComponent("swiftynotes", isDirectory: false)
}
