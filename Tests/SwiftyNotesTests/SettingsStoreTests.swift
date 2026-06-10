import Foundation
@testable import SwiftyNotes
import Testing

struct SettingsStoreTests {
    @Test("App settings store round trips custom notes directory and preferences")
    func appSettingsStoreRoundTripsCustomNotesDirectoryAndPreferences() throws {
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

    @Test("App settings decode older payload with new preference defaults")
    func appSettingsDecodeOlderPayloadWithNewPreferenceDefaults() throws {
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
        // Legacy settings without `trashRetention` fall back to the
        // 30-day default — the same as a fresh install.
        #expect(settings.trashRetention == .days(30))
        // Outline tweaks fall back to the design's default ("comfortable
        // density, tree lines on, drag handles on hover, breadcrumb
        // visible") so the panel looks the same as a fresh install.
        #expect(settings.outlineDensity == .comfortable)
        #expect(settings.outlineTreeLines == true)
        #expect(settings.outlineDragHandles == true)
        #expect(settings.outlineBreadcrumbVisible == true)
        // Emoji-shortcode rendering defaults on for legacy payloads too.
        #expect(settings.renderEmojiShortcodes == true)
    }

    @Test("App settings store round trips outline tweaks")
    func appSettingsStoreRoundTripsOutlineTweaks() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = AppSettingsStore(
            settingsFileURL: temp.appendingPathComponent("settings.json", isDirectory: false),
        )

        let saved = AppSettings(
            outlineDensity: .compact,
            outlineTreeLines: false,
            outlineDragHandles: false,
            outlineBreadcrumbVisible: false,
            renderEmojiShortcodes: false,
        )
        try store.save(saved)
        let loaded = try store.load()
        #expect(loaded.outlineDensity == .compact)
        #expect(loaded.outlineTreeLines == false)
        #expect(loaded.outlineDragHandles == false)
        #expect(loaded.outlineBreadcrumbVisible == false)
        #expect(loaded.renderEmojiShortcodes == false)
    }

    @Test("App settings store round trips trash retention")
    func appSettingsStoreRoundTripsTrashRetention() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let settingsFileURL = temp
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        let store = AppSettingsStore(settingsFileURL: settingsFileURL)

        try store.save(AppSettings(trashRetention: .never))
        #expect(try store.load().trashRetention == .never)

        try store.save(AppSettings(trashRetention: .days(7)))
        #expect(try store.load().trashRetention == .days(7))

        try store.save(AppSettings(trashRetention: .days(365)))
        #expect(try store.load().trashRetention == .days(365))
    }

    @Test("App settings store migrates oldest legacy default settings prefix")
    func appSettingsStoreMigratesOldestLegacyDefaultSettingsPrefix() throws {
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

    @Test("Notes directory relocator moves notes into existing empty folder and removes old path")
    func notesDirectoryRelocatorMovesNotesIntoExistingEmptyFolderAndRemovesOld() throws {
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

    @Test("Notes directory relocator rejects non empty destination")
    func notesDirectoryRelocatorRejectsNonEmptyDestination() throws {
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

    @Test("Notes directory relocator rolls partial moves back when a later move fails")
    func notesDirectoryRelocatorRollsPartialMovesBackWhenALaterMoveFails() throws {
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

    @Test("Normalize against filesystem keeps custom notes directory when the folder exists")
    func normalizeAgainstFilesystemKeepsCustomNotesDirectoryWhenTheFolderExists() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let settings = AppSettings(customNotesDirectoryPath: temp.path(percentEncoded: false))
        let normalized = settings.normalizedAgainstFilesystem()

        #expect(normalized.customNotesDirectoryPath == temp.path(percentEncoded: false))
    }

    @Test("Normalize against filesystem clears stale custom notes directory pointing at a missing folder")
    func normalizeAgainstFilesystemClearsStaleCustomNotesDirectoryPointingAtAMissing() {
        let missingPath = "/tmp/swifty-notes-test-\(UUID().uuidString)/notes"
        let settings = AppSettings(customNotesDirectoryPath: missingPath, editorFontSize: 18)

        let normalized = settings.normalizedAgainstFilesystem()

        #expect(normalized.customNotesDirectoryPath == nil)
        #expect(normalized.editorFontSize == 18)
    }

    @Test("Normalize against filesystem clears custom notes directory that points at a regular file instead of a folder")
    func normalizeAgainstFilesystemClearsCustomNotesDirectoryThatPointsAtARegular() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try "x".write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }

        let settings = AppSettings(customNotesDirectoryPath: temp.path(percentEncoded: false))
        let normalized = settings.normalizedAgainstFilesystem()

        #expect(normalized.customNotesDirectoryPath == nil)
    }

    @Test("Normalize against filesystem is a no-op when no custom notes directory is configured")
    func normalizeAgainstFilesystemIsANoOpWhenNoCustomNotesDirectory() {
        let settings = AppSettings()

        let normalized = settings.normalizedAgainstFilesystem()

        #expect(normalized == settings)
    }

    @Test("Updating notes directory to the default clears the custom path but preserves every other preference")
    func updatingNotesDirectoryToDefaultPreservesPreferences() {
        let defaultDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swifty-default-\(UUID().uuidString)", isDirectory: true)
        let settings = AppSettings(
            customNotesDirectoryPath: "/tmp/some-custom-location",
            wrapsEditorLines: false,
            editorFontSize: 22,
            editorTabWidth: 8,
            editorIndentStyle: .tabs,
            autosaveDelaySeconds: 9,
            appearanceMode: .dark,
            spellCheckEnabled: false,
            spellCheckLanguage: "de_DE",
            trashRetention: .days(7),
            outlineDensity: .compact,
            outlineTreeLines: false,
            outlineDragHandles: false,
            outlineBreadcrumbVisible: false,
            renderEmojiShortcodes: false,
        )

        // The equality branch (directory == default) previously rebuilt
        // AppSettings without the four outline fields, silently resetting
        // them to their defaults — a settings data-loss regression.
        let updated = settings.updatingNotesDirectory(defaultDirectory, defaultDirectory: defaultDirectory)

        #expect(updated.customNotesDirectoryPath == nil)
        #expect(updated.wrapsEditorLines == false)
        #expect(updated.editorFontSize == 22)
        #expect(updated.editorTabWidth == 8)
        #expect(updated.editorIndentStyle == .tabs)
        #expect(updated.autosaveDelaySeconds == 9)
        #expect(updated.appearanceMode == .dark)
        #expect(updated.spellCheckEnabled == false)
        #expect(updated.spellCheckLanguage == "de_DE")
        #expect(updated.trashRetention == .days(7))
        #expect(updated.outlineDensity == .compact)
        #expect(updated.outlineTreeLines == false)
        #expect(updated.outlineDragHandles == false)
        #expect(updated.outlineBreadcrumbVisible == false)
        #expect(updated.renderEmojiShortcodes == false)
    }

    @Test("Updating notes directory to a custom location preserves every other preference")
    func updatingNotesDirectoryToCustomPreservesPreferences() {
        let defaultDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swifty-default-\(UUID().uuidString)", isDirectory: true)
        let custom = FileManager.default.temporaryDirectory
            .appendingPathComponent("swifty-custom-\(UUID().uuidString)", isDirectory: true)
        let settings = AppSettings(
            outlineDensity: .compact,
            outlineTreeLines: false,
            outlineDragHandles: false,
            outlineBreadcrumbVisible: false,
        )

        let updated = settings.updatingNotesDirectory(custom, defaultDirectory: defaultDirectory)

        #expect(updated.customNotesDirectoryPath == custom.path(percentEncoded: false))
        #expect(updated.outlineDensity == .compact)
        #expect(updated.outlineTreeLines == false)
        #expect(updated.outlineDragHandles == false)
        #expect(updated.outlineBreadcrumbVisible == false)
    }

    @Test("Notes directory error message rewrites cocoa file write codes into user-friendly text")
    func notesDirectoryErrorMessageRewritesCocoaFileWriteCodesIntoUserFriendly() {
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

    @Test("Notes directory error message keeps disk-full and read-only and relocation messages distinct")
    func notesDirectoryErrorMessageKeepsDiskFullAndReadOnlyAndRelocation() {
        let diskFullError = NSError(domain: NSCocoaErrorDomain, code: 640)
        let readOnlyVolumeError = NSError(domain: NSCocoaErrorDomain, code: 642)
        let relocationError = NotesDirectoryRelocator.RelocationError(message: "Choose an empty destination folder for your notes.")

        #expect(NotesDirectoryErrorMessage.userFriendly(for: diskFullError).contains("disk space"))
        #expect(NotesDirectoryErrorMessage.userFriendly(for: readOnlyVolumeError).lowercased().contains("read-only"))
        #expect(NotesDirectoryErrorMessage.userFriendly(for: relocationError) == "Choose an empty destination folder for your notes.")
    }

    @Test("Notes directory relocator removes the destination it created when rollback runs")
    func notesDirectoryRelocatorRemovesTheDestinationItCreatedWhenRollbackRuns() throws {
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

    // MARK: - Spaces-in-path regressions
    //
    // These tests pin the spaces-in-path behaviour of the three
    // FileManager-touching surfaces that weren't already covered by
    // `RepositoryStateTests`. Each one exercises a real save / load /
    // relocate cycle against a temp directory whose name contains a
    // space — if any `URL.path(percentEncoded: false)` call regresses
    // back to the bare `URL.path()` form the assertions fail loudly.

    @Test("App settings store round trips through a settings file URL whose path contains spaces")
    func appSettingsStoreRoundTripsThroughASettingsFileURLWhosePath() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let spacedConfigDir = temp.appendingPathComponent("My Config Folder", isDirectory: true)
        let settingsFileURL = spacedConfigDir.appendingPathComponent("settings.json", isDirectory: false)
        let customNotesDirectory = temp.appendingPathComponent("Notes With Spaces", isDirectory: true)
        let store = AppSettingsStore(settingsFileURL: settingsFileURL)

        try store.save(AppSettings(
            customNotesDirectoryPath: customNotesDirectory.path(percentEncoded: false),
            wrapsEditorLines: true,
            editorFontSize: 14,
            editorTabWidth: 4,
            editorIndentStyle: .spaces,
            autosaveDelaySeconds: 3,
            appearanceMode: .system,
        ))

        // The file actually landed at the spaced path (FileManager
        // resolves it correctly) AND `load` finds it again.
        #expect(FileManager.default.fileExists(atPath: settingsFileURL.path(percentEncoded: false)))
        let loaded = try store.load()
        #expect(loaded.customNotesDirectoryURL?.standardizedFileURL == customNotesDirectory.standardizedFileURL)
        #expect(loaded.editorFontSize == 14)
    }

    @Test("Workspace state store round trips through a state file URL whose path contains spaces")
    func workspaceStateStoreRoundTripsThroughAStateFileURLWhosePath() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let spacedStateDir = temp.appendingPathComponent("State With Spaces", isDirectory: true)
        let stateFileURL = spacedStateDir.appendingPathComponent("workspace.json", isDirectory: false)
        let store = WorkspaceStateStore(stateFileURL: stateFileURL)

        let stableID = UUID()
        let original = WorkspaceState(
            selectedNoteID: stableID,
            isSidebarVisible: false,
            isPreviewVisible: true,
            sortMode: .title,
            windowWidth: 1234,
            windowHeight: 567,
        )
        try store.save(original)

        #expect(FileManager.default.fileExists(atPath: stateFileURL.path(percentEncoded: false)))
        let loaded = try store.load()
        #expect(loaded.selectedNoteID == stableID)
        #expect(loaded.sortMode == .title)
        #expect(loaded.windowWidth == 1234)
    }

    @Test("Notes directory relocator moves contents when both source and destination paths contain spaces")
    func notesDirectoryRelocatorMovesContentsWhenBothSourceAndDestinationPathsContain() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let source = temp.appendingPathComponent("Source Notes", isDirectory: true)
        let destination = temp.appendingPathComponent("Destination Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "# Note one".write(
            to: source.appendingPathComponent("first note.md", isDirectory: false),
            atomically: true,
            encoding: .utf8,
        )
        try "# Note two".write(
            to: source.appendingPathComponent("second note.md", isDirectory: false),
            atomically: true,
            encoding: .utf8,
        )

        try NotesDirectoryRelocator.relocate(from: source, to: destination)

        #expect(!FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
        let moved = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .sorted()
        #expect(moved == ["first note.md", "second note.md"])
    }
}
