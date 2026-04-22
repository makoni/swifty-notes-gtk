import Foundation
import Testing
@testable import SwiftyNotes
import Adwaita

struct CLICommandTests {
    @Test
    func cliCreateListGetAndUpdateNoteByID() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let createResult = NotesCLI.runIfRequested(
            arguments: ["cli", "create", "--notes-dir", temp.path(), "--content", "# CLI Title\n\nBody"]
        )
        #expect(createResult != nil)
        #expect(createResult?.exitCode == 0)

        let created = try JSONDecoder.swiftyNotesCLI.decode(
            CLITestDocument.self,
            from: Data((createResult?.stdout ?? "").utf8)
        )
        #expect(created.title == "CLI Title")
        #expect(created.filename.hasSuffix("/note.md"))

        let listResult = NotesCLI.runIfRequested(
            arguments: ["cli", "list", "--notes-dir", temp.path()]
        )
        #expect(listResult?.exitCode == 0)
        let listed = try JSONDecoder.swiftyNotesCLI.decode(
            [CLITestSummary].self,
            from: Data((listResult?.stdout ?? "").utf8)
        )
        #expect(listed.count == 1)
        #expect(listed.first?.id == created.id)
        #expect(listed.first?.filename.hasSuffix("/note.md") == true)

        let getResult = NotesCLI.runIfRequested(
            arguments: ["cli", "get", "--notes-dir", temp.path(), created.id]
        )
        #expect(getResult?.exitCode == 0)
        let fetched = try JSONDecoder.swiftyNotesCLI.decode(
            CLITestDocument.self,
            from: Data((getResult?.stdout ?? "").utf8)
        )
        #expect(fetched.content.contains("Body"))

        let updateResult = NotesCLI.runIfRequested(
            arguments: ["cli", "update", "--notes-dir", temp.path(), created.id, "--content", "# Updated\n\nReplaced"]
        )
        #expect(updateResult?.exitCode == 0)
        let updated = try JSONDecoder.swiftyNotesCLI.decode(
            CLITestDocument.self,
            from: Data((updateResult?.stdout ?? "").utf8)
        )
        #expect(updated.title == "Updated")
        #expect(updated.content == "# Updated\n\nReplaced")
        #expect(updated.filename == created.filename)

        let rawGetResult = NotesCLI.runIfRequested(
            arguments: ["cli", "get", "--notes-dir", temp.path(), created.id, "--raw"]
        )
        #expect(rawGetResult?.stdout == "# Updated\n\nReplaced\n")
    }

    @Test
    func cliRejectsUnknownID() {
        let result = NotesCLI.runIfRequested(
            arguments: ["cli", "get", UUID().uuidString.lowercased()]
        )
        #expect(result?.exitCode == 3)
        #expect(result?.stderr.contains("No note found") == true)
    }

    @Test
    func cliGeneralHelpIsAvailable() {
        let result = NotesCLI.runIfRequested(arguments: ["cli"])
        #expect(result?.exitCode == 0)
        #expect(result?.stdout.contains("SwiftyNotes CLI") == true)
        #expect(result?.stdout.contains("Commands:") == true)
        #expect(result?.stdout.contains("flatpak run me.spaceinbox.swiftynotes cli <command> [options]") == true)
        #expect(result?.stdout.contains("swiftynotes cli help <command>") == true)
    }

    @Test
    func cliCommandHelpIsAvailable() {
        let result = NotesCLI.runIfRequested(arguments: ["cli", "help", "update"])
        #expect(result?.exitCode == 0)
        #expect(result?.stdout.contains("swiftynotes cli update <note-id>") == true)
        #expect(result?.stdout.contains("Replace an existing note's markdown content by ID.") == true)
        #expect(result?.stdout.contains("--stdin") == true)
    }

    @Test
    func cliSubcommandHelpFlagIsAvailable() {
        let result = NotesCLI.runIfRequested(arguments: ["cli", "get", "--help"])
        #expect(result?.exitCode == 0)
        #expect(result?.stdout.contains("swiftynotes cli get <note-id>") == true)
        #expect(result?.stdout.contains("--raw") == true)
    }
}
