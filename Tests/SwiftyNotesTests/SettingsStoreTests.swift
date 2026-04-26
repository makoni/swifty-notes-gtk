import Foundation
@testable import SwiftyNotes
import Testing

struct SettingsStoreTests {
    @Test
    func `app settings store round trips custom notes directory and preferences`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let settingsFileURL = temp
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        let customNotesDirectory = temp.appendingPathComponent("custom-notes", isDirectory: true)
        let store = AppSettingsStore(settingsFileURL: settingsFileURL)

        try store.save(AppSettings(
            customNotesDirectoryPath: customNotesDirectory.path(),
            wrapsEditorLines: false,
            editorFontSize: 18,
            editorTabWidth: 2,
            editorIndentStyle: .tabs,
            autosaveDelaySeconds: 5,
            appearanceMode: .dark,
        ))

        let loaded = try store.load()
        #expect(loaded.customNotesDirectoryURL?.standardizedFileURL == customNotesDirectory.standardizedFileURL)
        #expect(!loaded.wrapsEditorLines)
        #expect(loaded.editorFontSize == 18)
        #expect(loaded.editorTabWidth == 2)
        #expect(loaded.editorIndentStyle == .tabs)
        #expect(loaded.autosaveDelaySeconds == 5)
        #expect(loaded.appearanceMode == .dark)
        #expect(
            loaded.resolvedNotesDirectory(
                defaultDirectory: temp.appendingPathComponent("default-notes", isDirectory: true),
            ).standardizedFileURL == customNotesDirectory.standardizedFileURL,
        )
    }

    @Test
    func `app settings decode older payload with new preference defaults`() throws {
        let payload = """
        {
          "customNotesDirectoryPath": "/tmp/notes"
        }
        """

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(payload.utf8))

        #expect(settings.customNotesDirectoryPath == "/tmp/notes")
        #expect(settings.wrapsEditorLines)
        #expect(settings.editorFontSize == 14)
        #expect(settings.editorTabWidth == 4)
        #expect(settings.editorIndentStyle == .spaces)
        #expect(settings.autosaveDelaySeconds == 2)
        #expect(settings.appearanceMode == .system)
    }

    @Test
    func `app settings store migrates oldest legacy default settings prefix`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let legacyDirectory = temp.appendingPathComponent(AppIdentity.oldestLegacyIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let customNotesDirectory = temp.appendingPathComponent("legacy-custom-notes", isDirectory: true)
        let legacyStore = AppSettingsStore(
            settingsFileURL: legacyDirectory.appendingPathComponent("settings.json", isDirectory: false),
        )
        try legacyStore.save(AppSettings(customNotesDirectoryPath: customNotesDirectory.path()))

        let migratedStore = AppSettingsStore(
            settingsFileURL: temp
                .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
                .appendingPathComponent("settings.json", isDirectory: false),
        )

        let loaded = try migratedStore.load()
        #expect(loaded.customNotesDirectoryURL?.standardizedFileURL == customNotesDirectory.standardizedFileURL)
        #expect(FileManager.default.fileExists(
            atPath: temp
                .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
                .appendingPathComponent("settings.json", isDirectory: false)
                .path(),
        ))
        #expect(!FileManager.default.fileExists(
            atPath: temp
                .appendingPathComponent(AppIdentity.oldestLegacyIdentifier, isDirectory: true)
                .appendingPathComponent("settings.json", isDirectory: false)
                .path(),
        ))
    }

    @Test
    func `notes directory relocator moves notes into existing empty folder and removes old path`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let source = temp.appendingPathComponent("source-notes", isDirectory: true)
        let destination = temp.appendingPathComponent("destination-notes", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "# Moved\n".write(
            to: source.appendingPathComponent("note.md", isDirectory: false),
            atomically: true,
            encoding: .utf8,
        )
        try Data([0x01, 0x02, 0x03]).write(
            to: source.appendingPathComponent("asset.bin", isDirectory: false),
        )

        try NotesDirectoryRelocator.relocate(from: source, to: destination)

        #expect(!FileManager.default.fileExists(atPath: source.path()))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("note.md").path()))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("asset.bin").path()))
    }

    @Test
    func `notes directory relocator rejects non empty destination`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let source = temp.appendingPathComponent("source-notes", isDirectory: true)
        let destination = temp.appendingPathComponent("destination-notes", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "# Source\n".write(
            to: source.appendingPathComponent("note.md", isDirectory: false),
            atomically: true,
            encoding: .utf8,
        )
        try "occupied".write(
            to: destination.appendingPathComponent("existing.txt", isDirectory: false),
            atomically: true,
            encoding: .utf8,
        )

        do {
            try NotesDirectoryRelocator.relocate(from: source, to: destination)
            Issue.record("Expected relocation to reject a non-empty destination folder")
        } catch {
            #expect(error.localizedDescription.contains("empty"))
        }
    }

    @Test
    func `notes directory relocator rolls partial moves back when a later move fails`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let source = temp.appendingPathComponent("source-notes", isDirectory: true)
        let destination = temp.appendingPathComponent("destination-notes", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for filename in ["a.md", "b.md", "c.md"] {
            try "# \(filename)\n".write(
                to: source.appendingPathComponent(filename, isDirectory: false),
                atomically: true,
                encoding: .utf8,
            )
        }

        do {
            try NotesDirectoryRelocator.relocateInternal(from: source, to: destination, debugFailMoveAtIndex: 1)
            Issue.record("Expected relocation to surface the simulated move failure")
        } catch {
            // Surface error is expected; we now want full rollback.
        }

        let restoredSourceContents = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).map(\.lastPathComponent).sorted()
        let destinationContents = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).map(\.lastPathComponent).sorted()
        #expect(restoredSourceContents == ["a.md", "b.md", "c.md"])
        #expect(destinationContents == [])
    }

    @Test
    func `normalize against filesystem keeps custom notes directory when the folder exists`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let settings = AppSettings(customNotesDirectoryPath: temp.path(percentEncoded: false))
        let normalized = settings.normalizedAgainstFilesystem()

        #expect(normalized.customNotesDirectoryPath == temp.path(percentEncoded: false))
    }

    @Test
    func `normalize against filesystem clears stale custom notes directory pointing at a missing folder`() {
        let missingPath = "/tmp/swifty-notes-test-\(UUID().uuidString)/notes"
        let settings = AppSettings(customNotesDirectoryPath: missingPath, editorFontSize: 18)

        let normalized = settings.normalizedAgainstFilesystem()

        #expect(normalized.customNotesDirectoryPath == nil)
        #expect(normalized.editorFontSize == 18)
    }

    @Test
    func `normalize against filesystem clears custom notes directory that points at a regular file instead of a folder`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try "x".write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }

        let settings = AppSettings(customNotesDirectoryPath: temp.path(percentEncoded: false))
        let normalized = settings.normalizedAgainstFilesystem()

        #expect(normalized.customNotesDirectoryPath == nil)
    }

    @Test
    func `normalize against filesystem is a no-op when no custom notes directory is configured`() {
        let settings = AppSettings()

        let normalized = settings.normalizedAgainstFilesystem()

        #expect(normalized == settings)
    }

    @Test
    func `notes directory error message rewrites cocoa file write codes into user-friendly text`() {
        let permissionError = NSError(domain: NSCocoaErrorDomain, code: 512)
        let writeNoPermissionError = NSError(domain: NSCocoaErrorDomain, code: 513)
        let readNoPermissionError = NSError(domain: NSCocoaErrorDomain, code: 257)

        let permissionText = NotesDirectoryErrorMessage.userFriendly(for: permissionError)
        let writeNoPermissionText = NotesDirectoryErrorMessage.userFriendly(for: writeNoPermissionError)
        let readNoPermissionText = NotesDirectoryErrorMessage.userFriendly(for: readNoPermissionError)

        #expect(permissionText.contains("permission"))
        #expect(writeNoPermissionText.contains("permission"))
        #expect(readNoPermissionText.contains("permission"))
        #expect(!permissionText.contains("NSCocoaErrorDomain"))
        #expect(!permissionText.contains("512"))
    }

    @Test
    func `notes directory error message keeps disk-full and read-only and relocation messages distinct`() {
        let diskFullError = NSError(domain: NSCocoaErrorDomain, code: 640)
        let readOnlyVolumeError = NSError(domain: NSCocoaErrorDomain, code: 642)
        let relocationError = NotesDirectoryRelocator.RelocationError(message: "Choose an empty destination folder for your notes.")

        #expect(NotesDirectoryErrorMessage.userFriendly(for: diskFullError).contains("disk space"))
        #expect(NotesDirectoryErrorMessage.userFriendly(for: readOnlyVolumeError).lowercased().contains("read-only"))
        #expect(NotesDirectoryErrorMessage.userFriendly(for: relocationError) == "Choose an empty destination folder for your notes.")
    }

    @Test
    func `notes directory relocator removes the destination it created when rollback runs`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let source = temp.appendingPathComponent("source-notes", isDirectory: true)
        let destination = temp.appendingPathComponent("destination-notes", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "# a\n".write(
            to: source.appendingPathComponent("a.md", isDirectory: false),
            atomically: true,
            encoding: .utf8,
        )
        try "# b\n".write(
            to: source.appendingPathComponent("b.md", isDirectory: false),
            atomically: true,
            encoding: .utf8,
        )

        do {
            try NotesDirectoryRelocator.relocateInternal(from: source, to: destination, debugFailMoveAtIndex: 1)
            Issue.record("Expected relocation to surface the simulated move failure")
        } catch {
            // Expected.
        }

        #expect(FileManager.default.fileExists(atPath: source.path()))
        #expect(!FileManager.default.fileExists(atPath: destination.path()))
        let restoredSourceContents = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).map(\.lastPathComponent).sorted()
        #expect(restoredSourceContents == ["a.md", "b.md"])
    }
}
