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
        #expect(created.filename.hasSuffix("/note.md"))
        #expect(duplicated.filename.hasSuffix("/note.md"))
        #expect(imported.filename.hasSuffix("/note.md"))
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
        #expect(notesAfterSeed[0].filename.hasSuffix("/note.md"))
        let imageURL = repository
            .noteAssetsDirectoryURL(for: notesAfterSeed[0])
            .appendingPathComponent(MarkdownShowcaseSeed.imageFilename, isDirectory: false)
        #expect(FileManager.default.fileExists(atPath: imageURL.path()))
        #expect(try Data(contentsOf: imageURL) == MarkdownShowcaseSeed.imageData())

        let secondSeed = try repository.seedMarkdownShowcaseIfNeeded(createdAt: Date(timeIntervalSince1970: 200))
        let notesAfterSecondSeed = try repository.loadNotes()
        #expect(secondSeed == nil)
        #expect(notesAfterSecondSeed.count == 1)
    }

    @Test
    func repositoryMigratesLegacyFlatNotesIntoPerNoteDirectories() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let legacyID = UUID()
        let legacyFilename = "2026-04-08T08-00-00Z--\(legacyID.uuidString.lowercased()).md"
        let legacyNoteURL = temp.appendingPathComponent(legacyFilename, isDirectory: false)
        try """
        # Markdown Showcase

        ![Swift and Adwaita showcase artwork](markdown-demo-image.png)
        """.write(to: legacyNoteURL, atomically: true, encoding: .utf8)
        let legacyImageURL = temp.appendingPathComponent(MarkdownShowcaseSeed.legacySharedImageFilename, isDirectory: false)
        try Data("legacy-image".utf8).write(to: legacyImageURL, options: .atomic)

        let repository = NotesRepository(notesDirectory: temp)
        let notes = try repository.loadNotes()

        #expect(notes.count == 1)
        #expect(notes[0].id == legacyID)
        #expect(notes[0].filename == "\(legacyID.uuidString.lowercased())/note.md")
        #expect(notes[0].content.contains(MarkdownShowcaseSeed.imageAssetPath))
        #expect(FileManager.default.fileExists(atPath: repository.noteURL(for: notes[0]).path()))
        #expect(FileManager.default.fileExists(
            atPath: repository
                .noteAssetsDirectoryURL(for: notes[0])
                .appendingPathComponent(MarkdownShowcaseSeed.imageFilename, isDirectory: false)
                .path()
        ))
        #expect(!FileManager.default.fileExists(atPath: legacyNoteURL.path()))
        #expect(!FileManager.default.fileExists(atPath: legacyImageURL.path()))
    }

    @Test
    func repositoryRepairsMissingBundledShowcaseAssetForDirectoryBackedNote() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let noteID = UUID()
        let noteDirectory = temp.appendingPathComponent(noteID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: noteDirectory, withIntermediateDirectories: true)
        try MarkdownShowcaseSeed.content.write(
            to: noteDirectory.appendingPathComponent("note.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let metadata = """
        {
          "createdAt" : "2026-04-08T08:49:57.000Z",
          "id" : "\(noteID.uuidString.uppercased())",
          "schemaVersion" : 1,
          "updatedAt" : "2026-04-08T09:02:30.000Z"
        }
        """
        try metadata.write(
            to: noteDirectory.appendingPathComponent("meta.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let notes = try repository.loadNotes()
        let repairedAssetURL = repository
            .noteAssetsDirectoryURL(for: notes[0])
            .appendingPathComponent(MarkdownShowcaseSeed.imageFilename, isDirectory: false)

        #expect(notes.count == 1)
        #expect(notes[0].title == "Markdown Showcase")
        #expect(FileManager.default.fileExists(atPath: repairedAssetURL.path()))
        #expect(try Data(contentsOf: repairedAssetURL) == MarkdownShowcaseSeed.imageData())
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
    func duplicateNotesCopyNoteLocalAssets() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        var original = try repository.createNote(initialContent: "# Original\n\n![Diagram](assets/diagram.png)")
        let originalAssetsDirectory = repository.noteAssetsDirectoryURL(for: original)
        try FileManager.default.createDirectory(at: originalAssetsDirectory, withIntermediateDirectories: true)
        let assetData = Data("asset-copy".utf8)
        let originalAssetURL = originalAssetsDirectory.appendingPathComponent("diagram.png", isDirectory: false)
        try assetData.write(to: originalAssetURL, options: .atomic)
        original = try repository.save(note: original)

        let duplicate = try repository.duplicate(note: original)
        let duplicatedAssetURL = repository
            .noteAssetsDirectoryURL(for: duplicate)
            .appendingPathComponent("diagram.png", isDirectory: false)

        #expect(FileManager.default.fileExists(atPath: duplicatedAssetURL.path()))
        #expect(try Data(contentsOf: duplicatedAssetURL) == assetData)
        #expect(duplicate.content == original.content)
    }

    @Test
    func repositoryImportsImageAssetsIntoNoteLocalDirectoryWithUniqueNames() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let note = try repository.createNote(initialContent: "# Images")

        let firstSourceDirectory = temp.appendingPathComponent("drop-a", isDirectory: true)
        let secondSourceDirectory = temp.appendingPathComponent("drop-b", isDirectory: true)
        try FileManager.default.createDirectory(at: firstSourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondSourceDirectory, withIntermediateDirectories: true)

        let firstSourceURL = firstSourceDirectory.appendingPathComponent("Diagram File.PNG", isDirectory: false)
        let secondSourceURL = secondSourceDirectory.appendingPathComponent("Diagram File.PNG", isDirectory: false)
        try Data("first-image".utf8).write(to: firstSourceURL, options: .atomic)
        try Data("second-image".utf8).write(to: secondSourceURL, options: .atomic)

        let firstRelativePath = try repository.importImageAsset(from: firstSourceURL, for: note)
        let secondRelativePath = try repository.importImageAsset(from: secondSourceURL, for: note)

        #expect(firstRelativePath == "assets/diagram-file.png")
        #expect(secondRelativePath == "assets/diagram-file-2.png")
        #expect(try Data(contentsOf: repository.noteAssetsDirectoryURL(for: note).appendingPathComponent("diagram-file.png")) == Data("first-image".utf8))
        #expect(try Data(contentsOf: repository.noteAssetsDirectoryURL(for: note).appendingPathComponent("diagram-file-2.png")) == Data("second-image".utf8))
    }

    @Test
    func repositoryStagesUnreferencedAssetsUntilNextSessionThenPrunesThem() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        var note = try repository.createNote(initialContent: "# Images\n\n![Alt](assets/image.png)")
        let assetURL = repository.noteAssetsDirectoryURL(for: note).appendingPathComponent("image.png", isDirectory: false)
        try FileManager.default.createDirectory(at: repository.noteAssetsDirectoryURL(for: note), withIntermediateDirectories: true)
        try Data("keep-until-next-session".utf8).write(to: assetURL, options: .atomic)

        note.content = "# Images\n\nNo image anymore"
        _ = try repository.save(note: note)

        #expect(FileManager.default.fileExists(atPath: assetURL.path()))

        let reopenedRepository = NotesRepository(notesDirectory: temp)
        _ = try reopenedRepository.loadNotes()

        #expect(!FileManager.default.fileExists(atPath: assetURL.path()))
    }

    @Test
    func repositoryKeepsStagedAssetWhenReferenceReturnsBeforeNextSession() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        var note = try repository.createNote(initialContent: "# Images\n\n![Alt](assets/image.png)")
        let assetURL = repository.noteAssetsDirectoryURL(for: note).appendingPathComponent("image.png", isDirectory: false)
        try FileManager.default.createDirectory(at: repository.noteAssetsDirectoryURL(for: note), withIntermediateDirectories: true)
        try Data("restored-before-prune".utf8).write(to: assetURL, options: .atomic)

        note.content = "# Images\n\nNo image anymore"
        note = try repository.save(note: note)
        note.content = "# Images\n\n![Alt](assets/image.png)"
        _ = try repository.save(note: note)

        let reopenedRepository = NotesRepository(notesDirectory: temp)
        let reopenedNotes = try reopenedRepository.loadNotes()

        #expect(FileManager.default.fileExists(atPath: assetURL.path()))
        #expect(reopenedNotes.first?.content.contains("assets/image.png") == true)
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
    func directorySnapshotChangesWhenAssetChangesWithoutSizeChange() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let note = try repository.createNote(initialContent: "# Asset note\n\n![Alt](assets/image.png)")
        let assetDirectory = repository.noteAssetsDirectoryURL(for: note)
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        let assetURL = assetDirectory.appendingPathComponent("image.png", isDirectory: false)
        try Data("abcde".utf8).write(to: assetURL, options: .atomic)
        let before = try repository.directorySnapshot()

        try Data("vwxyz".utf8).write(to: assetURL, options: .atomic)
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
