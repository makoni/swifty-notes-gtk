import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

struct RepositoryStateTests {
    @Test
    func `repository creates and loads notes sorted newest first`() async throws {
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
    func `repository supports duplicate import export and snapshots`() throws {
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
    func `repository imports note when source path contains spaces`() throws {
        // Regression test for https://github.com/makoni/swifty-notes-gtk/issues/2
        // A filename (or any path component) with spaces previously triggered
        // "file not found" because URL.path() percent-encodes — FileManager
        // APIs that take an atPath: String must receive the decoded path.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let spacedDirectory = temp.appendingPathComponent("source folder with spaces", isDirectory: true)
        let importURL = spacedDirectory.appendingPathComponent("note with spaces.md", isDirectory: false)
        let exportURL = temp.appendingPathComponent("exported copy.md", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: temp) }

        try FileManager.default.createDirectory(at: spacedDirectory, withIntermediateDirectories: true)
        try "# Imported with spaces".write(to: importURL, atomically: true, encoding: .utf8)

        let repository = NotesRepository(notesDirectory: temp.appendingPathComponent("notes", isDirectory: true))
        let imported = try repository.importNote(from: importURL)

        #expect(imported.content == "# Imported with spaces")

        try repository.export(note: imported, to: exportURL)
        let exported = try String(contentsOf: exportURL, encoding: .utf8)
        #expect(exported == "# Imported with spaces")
    }

    @Test
    func `external markdown document store loads file when path contains spaces`() throws {
        // Regression test for https://github.com/makoni/swifty-notes-gtk/issues/24
        // — "Open Markdown File…" and double-clicking a .md from Nautilus
        // both route through `ExternalMarkdownDocumentStore.load`, which
        // calls `FileManager.attributesOfItem(atPath: standardizedURL.path())`
        // for the modification-time + size snapshot. On Swift 6 `URL.path()`
        // is percent-encoded, FileManager wants the decoded native path,
        // so any file under "My Notes/" silently fails to open — same
        // class as #2/#3 that 1cb8e41 fixed elsewhere. The fix is the same
        // (`path(percentEncoded: false)`); this test pins it on
        // ExternalMarkdownDocumentStore specifically so that path stays
        // covered by CI from now on.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let spacedDirectory = temp.appendingPathComponent("My Notes", isDirectory: true)
        let fileURL = spacedDirectory.appendingPathComponent("note with spaces.md", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: temp) }

        try FileManager.default.createDirectory(at: spacedDirectory, withIntermediateDirectories: true)
        try "# Opened from a spaced path".write(to: fileURL, atomically: true, encoding: .utf8)

        let document = try ExternalMarkdownDocumentStore.load(from: fileURL)

        #expect(document.content == "# Opened from a spaced path")
        #expect(document.url.lastPathComponent == "note with spaces.md")
        #expect(document.snapshot.fileSize == UInt64("# Opened from a spaced path".utf8.count))
        #expect(document.snapshot.modifiedAt > 0)
    }

    @Test
    func `external markdown document store round-trips save+load through a spaced path`() throws {
        // Twin of the load-only test above, covering the save() path of
        // ExternalMarkdownDocumentStore — "Save As…" with a target file
        // whose parent directory contains a space (or the user typed a
        // spaced filename) would hit the same FileManager call chain
        // and the same `URL.path()` regression if save loses the fix.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let spacedDirectory = temp.appendingPathComponent("Output Folder", isDirectory: true)
        let fileURL = spacedDirectory.appendingPathComponent("saved note.md", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: temp) }

        let saved = try ExternalMarkdownDocumentStore.save(content: "# Persisted via save", to: fileURL)
        #expect(saved.content == "# Persisted via save")
        #expect(saved.snapshot.fileSize > 0)

        let reloaded = try ExternalMarkdownDocumentStore.load(from: fileURL)
        #expect(reloaded.content == "# Persisted via save")
    }

    @Test
    func `repository operates when notes directory path contains spaces`() throws {
        // Regression test for https://github.com/makoni/swifty-notes-gtk/issues/2
        // If the user points the notes library at e.g. ~/My Notes, every
        // FileManager call that reads a URL via .path() would fail because
        // the path comes back percent-encoded.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let spacedNotesDirectory = temp.appendingPathComponent("My Notes Library", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: spacedNotesDirectory)
        let created = try repository.createNote(initialContent: "# Hello from a spaced folder")

        let loaded = try repository.loadNotes()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == created.id)
        #expect(loaded.first?.content == "# Hello from a spaced folder")

        let snapshot = try repository.directorySnapshot()
        #expect(snapshot.entries.count == 1)

        try repository.delete(note: created)
        #expect(try repository.loadNotes().isEmpty)
    }

    @Test
    func `has exportable assets returns true only when asset directory contains files`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let empty = try repository.createNote(initialContent: "Empty")
        #expect(!repository.hasExportableAssets(note: empty))

        let withAssets = try repository.createNote(initialContent: "With assets")
        let assetsDirectory = repository.noteAssetsDirectoryURL(for: withAssets)
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        try Data("png-bytes".utf8).write(
            to: assetsDirectory.appendingPathComponent("pic.png", isDirectory: false),
            options: .atomic,
        )
        #expect(repository.hasExportableAssets(note: withAssets))
    }

    @Test
    func `export returns outcome without assets for note without images`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp.appendingPathComponent("notes", isDirectory: true))
        let note = try repository.createNote(initialContent: "# Plain text")
        let destinationURL = temp.appendingPathComponent("export/plain.md")

        let outcome = try repository.export(note: note, to: destinationURL)

        #expect(outcome.markdownURL == destinationURL)
        #expect(outcome.assetsDestinationURL == nil)
        #expect(outcome.assetsCopied == 0)
        #expect(try String(contentsOf: destinationURL, encoding: .utf8) == "# Plain text")
    }

    @Test
    func `export copies assets folder alongside markdown`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp.appendingPathComponent("notes", isDirectory: true))
        let note = try repository.createNote(initialContent: "# With image\n\n![pic](assets/pic.png)")
        let assetsDirectory = repository.noteAssetsDirectoryURL(for: note)
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        try Data("png-bytes".utf8).write(
            to: assetsDirectory.appendingPathComponent("pic.png", isDirectory: false),
            options: .atomic,
        )
        try Data("cover-bytes".utf8).write(
            to: assetsDirectory.appendingPathComponent("cover.jpg", isDirectory: false),
            options: .atomic,
        )

        let exportDirectory = temp.appendingPathComponent("export", isDirectory: true)
        let destinationURL = exportDirectory.appendingPathComponent("my-post.md", isDirectory: false)

        let outcome = try repository.export(note: note, to: destinationURL, assetsCollision: .fail)

        let expectedAssetsURL = exportDirectory.appendingPathComponent("assets", isDirectory: true)
        #expect(outcome.markdownURL == destinationURL)
        #expect(outcome.assetsDestinationURL == expectedAssetsURL)
        #expect(outcome.assetsCopied == 2)
        #expect(try Data(contentsOf: expectedAssetsURL.appendingPathComponent("pic.png")) == Data("png-bytes".utf8))
        #expect(try Data(contentsOf: expectedAssetsURL.appendingPathComponent("cover.jpg")) == Data("cover-bytes".utf8))
    }

    @Test
    func `export fails when assets destination already exists`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp.appendingPathComponent("notes", isDirectory: true))
        let note = try repository.createNote(initialContent: "# With image")
        let assetsDirectory = repository.noteAssetsDirectoryURL(for: note)
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        try Data("new".utf8).write(
            to: assetsDirectory.appendingPathComponent("pic.png", isDirectory: false),
            options: .atomic,
        )

        let exportDirectory = temp.appendingPathComponent("export", isDirectory: true)
        let existingAssetsURL = exportDirectory.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: existingAssetsURL, withIntermediateDirectories: true)
        try Data("keep".utf8).write(
            to: existingAssetsURL.appendingPathComponent("existing.png", isDirectory: false),
            options: .atomic,
        )

        let destinationURL = exportDirectory.appendingPathComponent("my-post.md", isDirectory: false)

        do {
            _ = try repository.export(note: note, to: destinationURL, assetsCollision: .fail)
            Issue.record("Expected assetsDestinationExists error")
        } catch let error as NoteExportError {
            guard case let .assetsDestinationExists(url) = error else {
                Issue.record("Unexpected error case: \(error)")
                return
            }
            #expect(url == existingAssetsURL)
        }

        // Существующая папка не должна быть тронута при .fail.
        #expect(try Data(contentsOf: existingAssetsURL.appendingPathComponent("existing.png")) == Data("keep".utf8))
        #expect(!FileManager.default.fileExists(atPath: existingAssetsURL.appendingPathComponent("pic.png").path(percentEncoded: false)))
    }

    @Test
    func `export merges assets into existing destination when requested`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp.appendingPathComponent("notes", isDirectory: true))
        let note = try repository.createNote(initialContent: "# With image")
        let assetsDirectory = repository.noteAssetsDirectoryURL(for: note)
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        try Data("new".utf8).write(
            to: assetsDirectory.appendingPathComponent("pic.png", isDirectory: false),
            options: .atomic,
        )
        try Data("fresh".utf8).write(
            to: assetsDirectory.appendingPathComponent("cover.jpg", isDirectory: false),
            options: .atomic,
        )

        let exportDirectory = temp.appendingPathComponent("export", isDirectory: true)
        let existingAssetsURL = exportDirectory.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: existingAssetsURL, withIntermediateDirectories: true)
        try Data("old-to-replace".utf8).write(
            to: existingAssetsURL.appendingPathComponent("pic.png", isDirectory: false),
            options: .atomic,
        )
        try Data("keep-me".utf8).write(
            to: existingAssetsURL.appendingPathComponent("other.png", isDirectory: false),
            options: .atomic,
        )

        let destinationURL = exportDirectory.appendingPathComponent("my-post.md", isDirectory: false)

        let outcome = try repository.export(note: note, to: destinationURL, assetsCollision: .merge)

        #expect(outcome.assetsDestinationURL == existingAssetsURL)
        #expect(outcome.assetsCopied == 2)
        #expect(try Data(contentsOf: existingAssetsURL.appendingPathComponent("pic.png")) == Data("new".utf8))
        #expect(try Data(contentsOf: existingAssetsURL.appendingPathComponent("cover.jpg")) == Data("fresh".utf8))
        #expect(try Data(contentsOf: existingAssetsURL.appendingPathComponent("other.png")) == Data("keep-me".utf8))
    }

    @Test
    func `repository seeds default notes only for empty storage`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let seeded = try repository.seedDefaultNotesIfNeeded(createdAt: Date(timeIntervalSince1970: 100))
        let notesAfterSeed = try repository.loadNotes()

        #expect(seeded.count == 3)
        #expect(notesAfterSeed.count == 3)
        #expect(notesAfterSeed.map(\.title) == ["Markdown Showcase", "About Swifty Notes", "Using Swifty Notes CLI"])
        #expect(notesAfterSeed[0].content == MarkdownShowcaseSeed.content)
        #expect(notesAfterSeed[1].content == SwiftyNotesOverviewSeed.content)
        #expect(notesAfterSeed[2].content == SwiftyNotesCLISeed.content)
        #expect(notesAfterSeed[0].filename.hasSuffix("/note.md"))
        #expect(notesAfterSeed[1].filename.hasSuffix("/note.md"))
        #expect(notesAfterSeed[2].filename.hasSuffix("/note.md"))
        // Showcase stays at root; the explanatory guides land in the
        // "Guides" sub-folder so first-launch users discover folders
        // as a feature rather than a hidden setting.
        #expect(notesAfterSeed[0].folderPath == "")
        #expect(notesAfterSeed[1].folderPath == NotesRepository.defaultSeedGuidesFolder)
        #expect(notesAfterSeed[2].folderPath == NotesRepository.defaultSeedGuidesFolder)
        #expect(try repository.listFolders() == [NotesRepository.defaultSeedGuidesFolder])
        let imageURL = repository
            .noteAssetsDirectoryURL(for: notesAfterSeed[0])
            .appendingPathComponent(MarkdownShowcaseSeed.imageFilename, isDirectory: false)
        #expect(FileManager.default.fileExists(atPath: imageURL.path()))
        #expect(try Data(contentsOf: imageURL) == MarkdownShowcaseSeed.imageData())

        let secondSeed = try repository.seedDefaultNotesIfNeeded(createdAt: Date(timeIntervalSince1970: 200))
        let notesAfterSecondSeed = try repository.loadNotes()
        #expect(secondSeed.isEmpty)
        #expect(notesAfterSecondSeed.count == 3)
    }

    @Test
    func `repository skips seeding when notes are empty but trash has entries`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let userNote = try repository.createNote(initialContent: "# User content")
        try repository.moveToTrash(note: userNote)

        // Live notes are empty, but trash holds the user's deleted
        // note — they've already engaged with the app and shouldn't
        // be greeted with the onboarding seed again on next launch.
        #expect(try repository.loadNotes().isEmpty)
        let seeded = try repository.seedDefaultNotesIfNeeded()
        #expect(seeded.isEmpty)
        #expect(try repository.loadNotes().isEmpty)

        // Emptying the trash signals "fresh start" — the seed is
        // allowed to fire again so default content reappears.
        try repository.emptyTrash()
        let reSeeded = try repository.seedDefaultNotesIfNeeded()
        #expect(reSeeded.count == 3)
    }

    @Test
    func `repository migrates legacy flat notes into per note directories`() throws {
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
                .path(),
        ))
        #expect(!FileManager.default.fileExists(atPath: legacyNoteURL.path()))
        #expect(!FileManager.default.fileExists(atPath: legacyImageURL.path()))
    }

    @Test
    func `repository repairs missing bundled showcase asset for directory backed note`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let noteID = UUID()
        let noteDirectory = temp.appendingPathComponent(noteID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: noteDirectory, withIntermediateDirectories: true)
        try MarkdownShowcaseSeed.content.write(
            to: noteDirectory.appendingPathComponent("note.md", isDirectory: false),
            atomically: true,
            encoding: .utf8,
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
            encoding: .utf8,
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

    // The two legacy-prefix migration tests below assert that the *old*
    // identifier path no longer exists after migration. They can't run on
    // macOS APFS (default case-insensitive): the legacy and current
    // identifiers (`me.spaceinbox.SwiftyNotes` vs `me.spaceinbox.swiftynotes`)
    // collapse to the same directory, so the migration appears to be a
    // no-op and the assertion always fails. Migration logic itself is
    // platform-neutral and exercised on Linux CI; macOS users never had a
    // legacy install path to migrate from anyway.
    #if !os(macOS)
    @Test
    func `repository migrates legacy default storage prefix`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let legacyNotesDirectory = temp
            .appendingPathComponent(AppIdentity.legacyIdentifier, isDirectory: true)
            .appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyNotesDirectory, withIntermediateDirectories: true)
        try "# Legacy".write(
            to: legacyNotesDirectory.appendingPathComponent("legacy.md", isDirectory: false),
            atomically: true,
            encoding: .utf8,
        )

        let migratedRepository = NotesRepository(
            notesDirectory: temp
                .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
                .appendingPathComponent("notes", isDirectory: true),
        )

        let notes = try migratedRepository.loadNotes()
        #expect(notes.count == 1)
        #expect(notes.first?.content == "# Legacy")
        #expect(FileManager.default.fileExists(
            atPath: temp
                .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
                .appendingPathComponent("notes", isDirectory: true)
                .path(),
        ))
        #expect(!FileManager.default.fileExists(
            atPath: temp.appendingPathComponent(AppIdentity.legacyIdentifier, isDirectory: true).path(),
        ))
    }

    @Test
    func `repository migrates oldest legacy default storage prefix`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let legacyNotesDirectory = temp
            .appendingPathComponent(AppIdentity.oldestLegacyIdentifier, isDirectory: true)
            .appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyNotesDirectory, withIntermediateDirectories: true)
        try "# Oldest Legacy".write(
            to: legacyNotesDirectory.appendingPathComponent("legacy.md", isDirectory: false),
            atomically: true,
            encoding: .utf8,
        )

        let migratedRepository = NotesRepository(
            notesDirectory: temp
                .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
                .appendingPathComponent("notes", isDirectory: true),
        )

        let notes = try migratedRepository.loadNotes()
        #expect(notes.count == 1)
        #expect(notes.first?.content == "# Oldest Legacy")
        #expect(FileManager.default.fileExists(
            atPath: temp
                .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
                .appendingPathComponent("notes", isDirectory: true)
                .path(),
        ))
        #expect(!FileManager.default.fileExists(
            atPath: temp.appendingPathComponent(AppIdentity.oldestLegacyIdentifier, isDirectory: true).path(),
        ))
    }

    @Test
    func `workspace state store migrates legacy default state prefix`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let legacyStateDirectory = temp.appendingPathComponent(AppIdentity.legacyIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: legacyStateDirectory, withIntermediateDirectories: true)
        let legacyStateStore = WorkspaceStateStore(
            stateFileURL: legacyStateDirectory.appendingPathComponent("workspace.json", isDirectory: false),
        )
        let storedState = WorkspaceState(
            selectedNoteID: UUID(),
            isSidebarVisible: false,
            isPreviewVisible: false,
            searchQuery: "legacy",
            sortMode: .title,
            windowWidth: 1111,
            windowHeight: 777,
            previewWidth: 515,
        )
        try legacyStateStore.save(storedState)

        let migratedStateStore = WorkspaceStateStore(
            stateFileURL: temp
                .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
                .appendingPathComponent("workspace.json", isDirectory: false),
        )
        let loadedState = try migratedStateStore.load()

        #expect(loadedState == storedState)
        #expect(FileManager.default.fileExists(
            atPath: temp
                .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
                .appendingPathComponent("workspace.json", isDirectory: false)
                .path(),
        ))
        #expect(!FileManager.default.fileExists(
            atPath: temp
                .appendingPathComponent(AppIdentity.legacyIdentifier, isDirectory: true)
                .appendingPathComponent("workspace.json", isDirectory: false)
                .path(),
        ))
    }
    #endif

    @Test
    func `duplicate notes keep distinct stable I ds and delete independently`() throws {
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
    func `duplicate notes copy note local assets`() throws {
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
    func `repository imports image assets into note local directory with unique names`() throws {
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
    func `repository imports image asset from raw data with unique filename`() throws {
        // Clipboard paste decodes the image into bytes, not into a
        // source URL. The `data:` overload owns the same uniqueness +
        // sanitization logic as the URL one so paste-into-editor can
        // hand the bytes off without staging a temp file first.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let note = try repository.createNote(initialContent: "# Pasted")

        let firstBytes = Data("first-paste".utf8)
        let secondBytes = Data("second-paste".utf8)

        let firstRelativePath = try repository.importImageAsset(
            data: firstBytes,
            baseName: "pasted",
            fileExtension: "png",
            for: note,
        )
        let secondRelativePath = try repository.importImageAsset(
            data: secondBytes,
            baseName: "pasted",
            fileExtension: "png",
            for: note,
        )

        #expect(firstRelativePath == "assets/pasted.png")
        #expect(secondRelativePath == "assets/pasted-2.png")

        let assetsDir = repository.noteAssetsDirectoryURL(for: note)
        #expect(try Data(contentsOf: assetsDir.appendingPathComponent("pasted.png")) == firstBytes)
        #expect(try Data(contentsOf: assetsDir.appendingPathComponent("pasted-2.png")) == secondBytes)
    }

    @Test
    func `repository rejects raw image data with unsupported extension`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let note = try repository.createNote(initialContent: "# Pasted")

        #expect {
            try repository.importImageAsset(
                data: Data("nope".utf8),
                baseName: "pasted",
                fileExtension: "xyz",
                for: note,
            )
        } throws: { error in
            (error as? NotesRepositoryAssetImportError) == .unsupportedImageType("pasted.xyz")
        }
    }

    @Test
    func `repository sanitizes baseName when importing raw image data`() throws {
        // Anything the caller hands us is run through the same
        // filename-stem sanitizer as the URL-based path so a whitespaced
        // or mixed-case label still produces a kebab-case file on disk.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let note = try repository.createNote(initialContent: "# Pasted")

        let relativePath = try repository.importImageAsset(
            data: Data("snip".utf8),
            baseName: "Pasted Image",
            fileExtension: "PNG",
            for: note,
        )

        #expect(relativePath == "assets/pasted-image.png")
        let assetURL = repository.noteAssetsDirectoryURL(for: note).appendingPathComponent("pasted-image.png", isDirectory: false)
        #expect(FileManager.default.fileExists(atPath: assetURL.path()))
    }

    @Test
    func `repository stages unreferenced assets until next session then prunes them`() throws {
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
    func `repository keeps staged asset when reference returns before next session`() throws {
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
    func `directory snapshot changes when content changes without size change`() throws {
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
    func `directory snapshot changes when asset changes without size change`() throws {
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
    func `directory monitor snapshot changes when content changes without size change`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let original = try repository.createNote(initialContent: "abcde")
        let before = try repository.directoryMonitorSnapshot()

        var updated = original
        updated.content = "vwxyz"
        _ = try repository.save(note: updated)

        let after = try repository.directoryMonitorSnapshot()
        #expect(before != after)
        #expect(before.entries.count == 1)
        #expect(after.entries.count == 1)
        #expect(before.entries[0].fileSize == after.entries[0].fileSize)
        #expect(before.entries[0].contentFingerprint == 0)
        #expect(after.entries[0].contentFingerprint == 0)
    }

    @Test
    func `directory monitor snapshot surfaces legacy flat markdown files without migrating them`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let legacyURL = temp.appendingPathComponent("legacy-note.md", isDirectory: false)
        try "# Legacy\n\ncontent".write(to: legacyURL, atomically: true, encoding: .utf8)

        let repository = NotesRepository(notesDirectory: temp)
        let snapshot = try repository.directoryMonitorSnapshot()

        #expect(snapshot.entries.count == 1)
        #expect(snapshot.entries[0].filename == "__legacy_flat__/legacy-note.md")
        #expect(snapshot.entries[0].contentFingerprint == 0)
        #expect(FileManager.default.fileExists(atPath: legacyURL.path()))
    }

    @Test
    func `workspace state store round trips state`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = WorkspaceStateStore(
            stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
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
            previewWidth: 520,
        )
        try store.save(expected)

        let loaded = try store.load()
        #expect(loaded == expected)
    }

    @Test
    func `workspace state store round trips preview only mode`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = WorkspaceStateStore(
            stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
        )
        defer { try? FileManager.default.removeItem(at: temp) }

        let expected = WorkspaceState(
            selectedNoteID: UUID(),
            isSidebarVisible: true,
            viewMode: .preview,
            searchQuery: "preview",
            sortMode: .newestFirst,
            windowWidth: 1100,
            windowHeight: 760,
            previewWidth: 600,
        )
        try store.save(expected)

        let loaded = try store.load()
        #expect(loaded == expected)
        #expect(loaded.isPreviewVisible)
    }

    @Test
    func `workspace state round trips expanded folders and dedupes them`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = WorkspaceStateStore(
            stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
        )
        defer { try? FileManager.default.removeItem(at: temp) }

        let saved = WorkspaceState(
            expandedFolders: ["Work", "Work/Drafts", "Work", "  ", "Personal"],
        )
        try store.save(saved)

        let loaded = try store.load()
        #expect(loaded.expandedFolders == ["Work", "Work/Drafts", "Personal"])
    }

    @Test
    func `workspace state decodes older payload without expanded folders field`() throws {
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
        #expect(decoded.expandedFolders.isEmpty)
        // Legacy payloads predate the persisted Trash-expanded
        // sidebar state and should default to collapsed.
        #expect(decoded.isTrashExpanded == false)
    }

    @Test
    func `workspace state round trips isTrashExpanded`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = WorkspaceStateStore(
            stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
        )
        defer { try? FileManager.default.removeItem(at: temp) }

        try store.save(WorkspaceState(isTrashExpanded: true))
        #expect(try store.load().isTrashExpanded == true)

        try store.save(WorkspaceState(isTrashExpanded: false))
        #expect(try store.load().isTrashExpanded == false)
    }

    @Test
    func `workspace state decodes older payload without preview width`() throws {
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
        #expect(decoded.viewMode == .split)
    }

    @Test @MainActor
    func `preview width resolution expands legacy default but preserves custom widths`() {
        #expect(MainWindow.resolvedPreviewWidth(storedWidth: WorkspaceState.legacyDefaultPreviewWidth, availableWidth: 1600) == 560)
        #expect(MainWindow.resolvedPreviewWidth(storedWidth: 720, availableWidth: 1600) == 720)
        #expect(MainWindow.resolvedPreviewWidth(storedWidth: 720, availableWidth: 900) == 540)
    }

    // MARK: - Trash auto-prune (pure)

    @Test
    func `moveToTrash relocates the note directory under dot-trash and stamps deletedAt plus originalFolderPath in meta`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        try repository.createFolder(at: "Projects")
        var note = try repository.createNote(initialContent: "# Doomed", in: "Projects")

        let directoryBeforeTrash = repository.noteDirectoryURL(for: note)
        #expect(FileManager.default.fileExists(atPath: directoryBeforeTrash.path()))

        try repository.moveToTrash(note: note)

        // Original directory is gone …
        #expect(!FileManager.default.fileExists(atPath: directoryBeforeTrash.path()))

        // … and the note is now under `.trash/<uuid>/` with the
        // metadata extended.
        let trashedDirectory = temp
            .appendingPathComponent(".trash", isDirectory: true)
            .appendingPathComponent(note.id.uuidString.lowercased(), isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: trashedDirectory.path()))

        let trashed = try repository.trashedNotes()
        #expect(trashed.count == 1)
        guard let restored = trashed.first else { return }
        #expect(restored.id == note.id)
        #expect(restored.originalFolderPath == "Projects")
        #expect(restored.deletedAt != nil)
        #expect(restored.content == "# Doomed")
        _ = note
    }

    @Test
    func `loadNotes excludes notes that live under dot-trash so the sidebar list stays clean`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let keep = try repository.createNote(initialContent: "# Keep")
        let toss = try repository.createNote(initialContent: "# Toss")
        try repository.moveToTrash(note: toss)

        let surfaced = try repository.loadNotes().map(\.id)
        #expect(surfaced.contains(keep.id))
        #expect(!surfaced.contains(toss.id))
    }

    @Test
    func `restore moves a trashed note back to its original folder, recreating the folder if it disappeared in the meantime`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        try repository.createFolder(at: "Projects/Inbox")
        let note = try repository.createNote(initialContent: "# Body", in: "Projects/Inbox")
        try repository.moveToTrash(note: note)

        // User scrubbed the folder while the note was in the trash —
        // restore must rebuild the path rather than leaving the note
        // stranded in the bin.
        try repository.deleteFolderRecursively(at: "Projects/Inbox")

        try repository.restore(noteWithID: note.id)

        let surfaced = try repository.loadNotes().first { $0.id == note.id }
        #expect(surfaced?.folderPath == "Projects/Inbox")
        #expect(surfaced?.content == "# Body")
        #expect(try repository.trashedNotes().isEmpty)
    }

    @Test
    func `permanentlyDelete erases a single trashed note from disk and emptyTrash wipes the rest`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let alpha = try repository.createNote(initialContent: "# Alpha")
        let beta = try repository.createNote(initialContent: "# Beta")
        let gamma = try repository.createNote(initialContent: "# Gamma")

        try repository.moveToTrash(note: alpha)
        try repository.moveToTrash(note: beta)
        try repository.moveToTrash(note: gamma)

        try repository.permanentlyDelete(noteWithID: beta.id)
        let afterPermanent = try repository.trashedNotes().map(\.id).sorted { $0.uuidString < $1.uuidString }
        #expect(afterPermanent == [alpha.id, gamma.id].sorted { $0.uuidString < $1.uuidString })

        try repository.emptyTrash()
        #expect(try repository.trashedNotes().isEmpty)

        let trashRoot = temp.appendingPathComponent(".trash", isDirectory: true)
        if FileManager.default.fileExists(atPath: trashRoot.path()) {
            let leftovers = try FileManager.default.contentsOfDirectory(at: trashRoot, includingPropertiesForKeys: nil)
            #expect(leftovers.isEmpty)
        }
    }

    @Test
    func `pruneTrashIfNeeded permanently deletes only entries older than the retention window`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let young = try repository.createNote(initialContent: "# Young")
        let stale = try repository.createNote(initialContent: "# Stale")

        try repository.moveToTrash(note: young)
        try repository.moveToTrash(note: stale)

        // Backdate `stale` to 60 days ago by rewriting its meta.json
        // directly. `young` keeps its just-trashed timestamp.
        let staleDir = temp
            .appendingPathComponent(".trash", isDirectory: true)
            .appendingPathComponent(stale.id.uuidString.lowercased(), isDirectory: true)
        let staleMeta = staleDir.appendingPathComponent("meta.json", isDirectory: false)
        var raw = try Data(contentsOf: staleMeta)
        if var dict = try JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            dict["deletedAt"] = formatter.string(from: Date().addingTimeInterval(-60 * 24 * 3600))
            raw = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try raw.write(to: staleMeta, options: .atomic)
        }

        try repository.pruneTrashIfNeeded(retention: .days(30), now: Date())

        let remaining = try repository.trashedNotes().map(\.id)
        #expect(remaining == [young.id])
    }

    @Test
    func `trash prune leaves every entry alone when retention is never`() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let entries: [TrashEntry] = [
            .init(id: UUID(), deletedAt: now.addingTimeInterval(-100_000_000)),
            .init(id: UUID(), deletedAt: now.addingTimeInterval(-1)),
        ]
        #expect(NotesRepository.entriesEligibleForPrune(in: entries, retention: .never, now: now) == [])
    }

    @Test
    func `trash prune returns only entries whose deletedAt is older than the retention window`() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let day: TimeInterval = 24 * 3600
        let young = TrashEntry(id: UUID(), deletedAt: now.addingTimeInterval(-29 * day))
        let onTheEdge = TrashEntry(id: UUID(), deletedAt: now.addingTimeInterval(-30 * day + 1))
        let stale = TrashEntry(id: UUID(), deletedAt: now.addingTimeInterval(-31 * day))
        let ancient = TrashEntry(id: UUID(), deletedAt: now.addingTimeInterval(-365 * day))

        let due = NotesRepository.entriesEligibleForPrune(
            in: [young, onTheEdge, stale, ancient],
            retention: .days(30),
            now: now,
        )
        #expect(due.map(\.id) == [stale.id, ancient.id])
    }

    @Test
    func `trash prune skips legacy entries with no deletedAt timestamp so they don't get auto-deleted before they have an age`() {
        // Notes that landed in the trash before this feature shipped
        // have no `deletedAt` to compare against. The repository
        // stamps them on first encounter so the next scan will see a
        // real timestamp; until then the safe default is "leave it
        // alone" rather than risk wiping notes whose age we don't
        // know.
        let now = Date()
        let legacy = TrashEntry(id: UUID(), deletedAt: nil)
        let due = NotesRepository.entriesEligibleForPrune(
            in: [legacy],
            retention: .days(7),
            now: now,
        )
        #expect(due.isEmpty)
    }

    @Test
    func `trash prune ignores entries with deletedAt in the future so a backwards clock jump does not nuke recent notes`() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let fromTheFuture = TrashEntry(id: UUID(), deletedAt: now.addingTimeInterval(60))
        let due = NotesRepository.entriesEligibleForPrune(
            in: [fromTheFuture],
            retention: .days(1),
            now: now,
        )
        #expect(due.isEmpty)
    }
}
