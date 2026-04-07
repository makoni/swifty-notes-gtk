import Foundation
import Testing
@testable import SwiftyNotes
import Adwaita
import CAdwaita

struct RepositoryStateTests {
    @Test
    func repositoryCreatesAndLoadsNotesSortedNewestFirst() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repository = NotesRepository(notesDirectory: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        let first = try repository.createNote(initialContent: "First")
        try? await Task.sleep(for: .milliseconds(20))
        let second = try repository.createNote(initialContent: "Second")

        let notes = try repository.loadNotes()
        #expect(notes.count == 2)
        #expect(notes.first?.id == second.id)
        #expect(notes.last?.id == first.id)
    }

    @Test
    func repositorySupportsDuplicateImportExportAndSnapshots() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let importURL = temp.appendingPathComponent("import.md")
        let exportURL = temp.appendingPathComponent("export.md")
        defer { try? FileManager.default.removeItem(at: temp) }

        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try "# Imported".write(to: importURL, atomically: true, encoding: .utf8)

        let repository = NotesRepository(notesDirectory: temp.appendingPathComponent("notes", isDirectory: true))
        let created = try repository.createNote(initialContent: "Original")
        let duplicated = try repository.duplicate(note: created)
        let imported = try repository.importNote(from: importURL)

        try repository.export(note: imported, to: exportURL)
        let exported = try String(contentsOf: exportURL, encoding: .utf8)
        let snapshot = try repository.directorySnapshot()

        #expect(duplicated.id != created.id)
        #expect(imported.content == "# Imported")
        #expect(exported == "# Imported")
        #expect(snapshot.entries.count == 3)
    }

    @Test
    func repositorySeedsMarkdownShowcaseOnlyForEmptyStorage() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let seeded = try repository.seedMarkdownShowcaseIfNeeded(createdAt: Date(timeIntervalSince1970: 100))
        let notesAfterSeed = try repository.loadNotes()

        #expect(seeded != nil)
        #expect(notesAfterSeed.count == 1)
        #expect(notesAfterSeed[0].title == "Markdown Showcase")
        #expect(notesAfterSeed[0].content == MarkdownShowcaseSeed.content)
        #expect(FileManager.default.fileExists(atPath: temp.appendingPathComponent(MarkdownShowcaseSeed.imageFilename).path()))

        let secondSeed = try repository.seedMarkdownShowcaseIfNeeded(createdAt: Date(timeIntervalSince1970: 200))
        let notesAfterSecondSeed = try repository.loadNotes()
        #expect(secondSeed == nil)
        #expect(notesAfterSecondSeed.count == 1)
    }

    @Test
    func repositoryMigratesLegacyDefaultStoragePrefix() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let legacyNotesDirectory = temp
            .appendingPathComponent(AppIdentity.legacyIdentifier, isDirectory: true)
            .appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyNotesDirectory, withIntermediateDirectories: true)
        try "# Legacy".write(
            to: legacyNotesDirectory.appendingPathComponent("legacy.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let migratedRepository = NotesRepository(
            notesDirectory: temp
                .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
                .appendingPathComponent("notes", isDirectory: true)
        )

        let notes = try migratedRepository.loadNotes()
        #expect(notes.count == 1)
        #expect(notes.first?.content == "# Legacy")
        #expect(FileManager.default.fileExists(
            atPath: temp
                .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
                .appendingPathComponent("notes", isDirectory: true)
                .path()
        ))
        #expect(!FileManager.default.fileExists(
            atPath: temp.appendingPathComponent(AppIdentity.legacyIdentifier, isDirectory: true).path()
        ))
    }

    @Test
    func workspaceStateStoreMigratesLegacyDefaultStatePrefix() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let legacyStateDirectory = temp.appendingPathComponent(AppIdentity.legacyIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: legacyStateDirectory, withIntermediateDirectories: true)
        let legacyStateStore = WorkspaceStateStore(
            stateFileURL: legacyStateDirectory.appendingPathComponent("workspace.json", isDirectory: false)
        )
        let storedState = WorkspaceState(
            selectedNoteID: UUID(),
            isSidebarVisible: false,
            isPreviewVisible: false,
            searchQuery: "legacy",
            sortMode: .title,
            windowWidth: 1111,
            windowHeight: 777,
            previewWidth: 515
        )
        try legacyStateStore.save(storedState)

        let migratedStateStore = WorkspaceStateStore(
            stateFileURL: temp
                .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
                .appendingPathComponent("workspace.json", isDirectory: false)
        )
        let loadedState = try migratedStateStore.load()

        #expect(loadedState == storedState)
        #expect(FileManager.default.fileExists(
            atPath: temp
                .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
                .appendingPathComponent("workspace.json", isDirectory: false)
                .path()
        ))
        #expect(!FileManager.default.fileExists(
            atPath: temp
                .appendingPathComponent(AppIdentity.legacyIdentifier, isDirectory: true)
                .appendingPathComponent("workspace.json", isDirectory: false)
                .path()
        ))
    }

    @Test
    func duplicateNotesKeepDistinctStableIDsAndDeleteIndependently() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let original = try repository.createNote(initialContent: "# Original\n\nBody")
        let duplicate = try repository.duplicate(note: original)

        #expect(duplicate.id != original.id)
        #expect(duplicate.stableID != original.stableID)
        #expect(duplicate.filename != original.filename)
        #expect(duplicate.content == original.content)

        try repository.delete(note: original)
        let afterDeletingOriginal = try repository.loadNotes()
        #expect(afterDeletingOriginal.count == 1)
        #expect(afterDeletingOriginal[0].id == duplicate.id)
        #expect(afterDeletingOriginal[0].stableID == duplicate.stableID)
        #expect(afterDeletingOriginal[0].content == original.content)

        try repository.delete(note: duplicate)
        let afterDeletingDuplicate = try repository.loadNotes()
        #expect(afterDeletingDuplicate.isEmpty)
    }

    @Test
    func directorySnapshotChangesWhenContentChangesWithoutSizeChange() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let original = try repository.createNote(initialContent: "abcde")
        let before = try repository.directorySnapshot()

        var updated = original
        updated.content = "vwxyz"
        _ = try repository.save(note: updated)

        let after = try repository.directorySnapshot()
        #expect(before != after)
        #expect(before.entries.count == 1)
        #expect(after.entries.count == 1)
        #expect(before.entries[0].fileSize == after.entries[0].fileSize)
        #expect(before.entries[0].contentFingerprint != after.entries[0].contentFingerprint)
    }

    @Test
    func workspaceStateStoreRoundTripsState() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = WorkspaceStateStore(
            stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
        )
        defer { try? FileManager.default.removeItem(at: temp) }

        let expected = WorkspaceState(
            selectedNoteID: UUID(),
            isSidebarVisible: false,
            isPreviewVisible: false,
            searchQuery: "swift",
            sortMode: .title,
            windowWidth: 900,
            windowHeight: 700,
            previewWidth: 520
        )
        try store.save(expected)

        let loaded = try store.load()
        #expect(loaded == expected)
    }

    @Test
    func workspaceStateDecodesOlderPayloadWithoutPreviewWidth() throws {
        let data = Data("""
        {
          "selectedNoteID": null,
          "isPreviewVisible": true,
          "searchQuery": "legacy",
          "sortMode": "newestFirst",
          "windowWidth": 1200,
          "windowHeight": 800
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: data)
        #expect(decoded.isSidebarVisible)
        #expect(decoded.previewWidth == WorkspaceState.defaultPreviewWidth)
        #expect(decoded.searchQuery == "legacy")
    }

    @Test @MainActor
    func previewWidthResolutionExpandsLegacyDefaultButPreservesCustomWidths() {
        #expect(MainWindow.resolvedPreviewWidth(storedWidth: WorkspaceState.legacyDefaultPreviewWidth, availableWidth: 1600) == 560)
        #expect(MainWindow.resolvedPreviewWidth(storedWidth: 720, availableWidth: 1600) == 720)
        #expect(MainWindow.resolvedPreviewWidth(storedWidth: 720, availableWidth: 900) == 480)
    }
}
