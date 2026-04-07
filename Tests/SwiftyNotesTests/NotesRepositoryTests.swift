import Foundation
import Testing
@testable import SwiftyNotes
import Adwaita
import CAdwaita

actor SaveRecorder {
    private var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }

    func snapshot() -> [Int] {
        values
    }
}

actor URLRecorder {
    private var value: URL?

    func set(_ url: URL) {
        value = url
    }

    func snapshot() -> URL? {
        value
    }
}

struct NotesRepositoryTests {
    @Test
    func derivedTitleUsesFirstMeaningfulLine() {
        let title = Note.derivedTitle(from: "\n\n# Hello world\nBody")
        #expect(title == "Hello world")
    }

    @Test
    func derivedTitleFallsBackForEmptyNote() {
        #expect(Note.derivedTitle(from: " \n\n ") == "New Note")
    }

    @Test
    func noteRetitleReplacesFirstMeaningfulLine() {
        let note = Note(
            id: UUID(),
            filename: "note.md",
            createdAt: Date(),
            updatedAt: Date(),
            content: "Shopping list\n- eggs"
        )

        let renamed = note.retitled("Groceries")
        #expect(renamed.title == "Groceries")
        #expect(renamed.content.hasPrefix("Groceries"))
    }

    @Test
    func noteSearchAndExportFilenameUseReadableTitle() {
        let note = Note(
            id: UUID(),
            filename: "note.md",
            createdAt: Date(),
            updatedAt: Date(),
            content: "# Hello, Swift GTK!"
        )

        #expect(note.matches(searchQuery: "swift gtk"))
        #expect(note.suggestedExportFilename == "hello-swift-gtk.md")
        #expect(note.stableID == note.id.uuidString.lowercased())
    }

    @Test
    func rendererBuildsHeadingAndParagraphBlocks() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: "# Title\n\nParagraph", darkAppearance: false)
        #expect(blocks.count >= 2)
        #expect(blocks.first?.style == .heading(level: 1))
        #expect(blocks.first?.text == "Title")
    }

    @Test
    func rendererBuildsTaskListMarkers() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        - [x] Done
        - [ ] Todo
        """, darkAppearance: false)

        #expect(blocks.count == 2)
        #expect(blocks[0] == .listItem(text: .plain("Done"), depth: 0, marker: "[x]"))
        #expect(blocks[1] == .listItem(text: .plain("Todo"), depth: 0, marker: "[ ]"))
    }

    @Test
    func rendererUsesThemeAwareInlineCodeBackground() {
        let renderer = MarkdownRenderer()
        let lightBlocks = renderer.blocks(for: "Use `code` here", darkAppearance: false)
        let darkBlocks = renderer.blocks(for: "Use `code` here", darkAppearance: true)

        guard case let .paragraph(lightText) = lightBlocks.first,
              case let .paragraph(darkText) = darkBlocks.first else {
            Issue.record("Expected paragraph blocks")
            return
        }

        #expect(lightText.markup.contains("font_family=\"monospace\""))
        #expect(lightText.markup.contains("background=\"#f6f5f4\""))
        #expect(darkText.markup.contains("background=\"#3b3644\""))
        #expect(lightText.markup != darkText.markup)
    }

    @Test
    func autosaveCoordinatorRunsLatestTask() async {
        let autosave = AutosaveCoordinator()
        let recorder = SaveRecorder()

        await autosave.scheduleSave(after: .milliseconds(10)) {
            await recorder.append(1)
        }
        await autosave.scheduleSave(after: .milliseconds(10)) {
            await recorder.append(2)
        }

        try? await Task.sleep(for: .milliseconds(40))

        let result = await recorder.snapshot()
        #expect(result == [2])
    }

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
        #expect(result?.stdout.contains("SwiftyNotes cli help <command>") == true)
    }

    @Test
    func cliCommandHelpIsAvailable() {
        let result = NotesCLI.runIfRequested(arguments: ["cli", "help", "update"])
        #expect(result?.exitCode == 0)
        #expect(result?.stdout.contains("SwiftyNotes cli update <note-id>") == true)
        #expect(result?.stdout.contains("Replace an existing note's markdown content by ID.") == true)
        #expect(result?.stdout.contains("--stdin") == true)
    }

    @Test
    func cliSubcommandHelpFlagIsAvailable() {
        let result = NotesCLI.runIfRequested(arguments: ["cli", "get", "--help"])
        #expect(result?.exitCode == 0)
        #expect(result?.stdout.contains("SwiftyNotes cli get <note-id>") == true)
        #expect(result?.stdout.contains("--raw") == true)
    }

    @Test @MainActor
    func mainWindowCreatesInitialNoteAndUpdatesPreview() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "io.github.makoni.SwiftyNotes.Tests")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator()
        )

        window.debugLoadInitialNotes()
        #expect(window.debugNotesCount == 1)
        #expect(window.debugSelectedNoteContent == MarkdownShowcaseSeed.content)
        #expect(window.debugPreviewText.contains("Markdown Showcase"))
        #expect(window.debugPreviewText.contains("Welcome to the demo note"))

        window.debugSetEditorText("# Title\n\nBody")
        #expect(window.debugSelectedNoteContent == "# Title\n\nBody")
        #expect(window.debugPreviewText.contains("Title"))
        #expect(window.debugPreviewText.contains("Body"))
    }

    @Test @MainActor
    func mainWindowCreateNoteAddsAnotherNote() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "io.github.makoni.SwiftyNotes.Tests.Create")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator()
        )

        window.debugLoadInitialNotes()
        #expect(window.debugNotesCount == 1)

        window.debugCreateNote()
        #expect(window.debugNotesCount == 2)
    }

    @Test @MainActor
    func mainWindowPlusButtonSignalCreatesNote() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "io.github.makoni.SwiftyNotes.Tests.Signal")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator()
        )

        window.present()
        #expect(window.debugNotesCount == 1)

        window.debugEmitNewNoteClicked()
        #expect(window.debugNotesCount == 2)
    }

    @Test @MainActor
    func mainWindowToolbarButtonsExposeStandardTooltips() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "io.github.makoni.SwiftyNotes.Tests.Tooltips")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator()
        )

        window.debugLoadInitialNotes()
        #expect(window.debugToolbarTooltips["sidebar"] == "Hide Notes Sidebar")
        #expect(window.debugToolbarTooltips["new"] == "New Note")
        #expect(window.debugToolbarTooltips["save"] == "Save Note")
        #expect(window.debugToolbarTooltips["delete"] == "Delete Note")
        #expect(window.debugToolbarTooltips["menu"] == "Main Menu")
        #expect(window.debugToolbarTooltips["preview"] == "Hide Preview")

        window.debugEmitPreviewToggleClicked()
        #expect(window.debugToolbarTooltips["preview"] == "Show Preview")
        window.debugEmitPreviewToggleClicked()
        #expect(window.debugToolbarTooltips["preview"] == "Hide Preview")
    }

    @Test @MainActor
    func mainWindowSidebarToggleHidesAndShowsSidebar() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "io.github.makoni.SwiftyNotes.Tests.SidebarToggle")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator()
        )

        window.debugLoadInitialNotes()
        #expect(window.debugSidebarVisible)
        #expect(window.debugToolbarTooltips["sidebar"] == "Hide Notes Sidebar")

        window.debugEmitSidebarToggleClicked()
        #expect(!window.debugSidebarVisible)
        #expect(window.debugToolbarTooltips["sidebar"] == "Show Notes Sidebar")

        window.debugEmitSidebarToggleClicked()
        #expect(window.debugSidebarVisible)
        #expect(window.debugToolbarTooltips["sidebar"] == "Hide Notes Sidebar")
    }

    @Test @MainActor
    func mainWindowPreviewToggleDetachesAndRestoresPreviewPane() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "io.github.makoni.SwiftyNotes.Tests.PreviewPane")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator()
        )

        window.debugLoadInitialNotes()
        #expect(window.debugIsPreviewPaneAttached)

        window.debugEmitPreviewToggleClicked()
        try await Task.sleep(for: .milliseconds(280))
        #expect(!window.debugIsPreviewPaneAttached)
        #expect(window.debugToolbarTooltips["preview"] == "Show Preview")

        window.debugEmitPreviewToggleClicked()
        #expect(window.debugIsPreviewPaneAttached)
        #expect(window.debugToolbarTooltips["preview"] == "Hide Preview")
    }

    @Test @MainActor
    func mainWindowSaveButtonPersistsCurrentEditorText() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let app = Application(id: "io.github.makoni.SwiftyNotes.Tests.SaveButton")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            autosaveDelay: .seconds(2)
        )

        window.debugLoadInitialNotes()
        window.debugSetEditorText("# Saved Title\n\nSaved body")
        #expect(window.debugEditorModified)

        window.debugEmitSaveClicked()
        try await Task.sleep(for: .milliseconds(80))

        let saved = try repository.loadNotes()
        #expect(saved.count == 1)
        #expect(saved[0].content == "# Saved Title\n\nSaved body")
        #expect(saved[0].title == "Saved Title")
        #expect(!window.debugEditorModified)
        #expect(window.debugDisplayedNoteTitles.first == "Saved Title")
    }

    @Test @MainActor
    func mainWindowAutosaveWaitsForLastEditBeforeSaving() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let app = Application(id: "io.github.makoni.SwiftyNotes.Tests.Autosave")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            autosaveDelay: .milliseconds(40)
        )

        window.debugLoadInitialNotes()
        let originalContent = try repository.loadNotes()[0].content

        window.debugSetEditorText("# First draft\n\nA")
        try await Task.sleep(for: .milliseconds(15))
        #expect(try repository.loadNotes()[0].content == originalContent)

        window.debugSetEditorText("# Final draft\n\nB")
        try await Task.sleep(for: .milliseconds(20))
        #expect(try repository.loadNotes()[0].content == originalContent)

        try await Task.sleep(for: .milliseconds(60))
        let autosaved = try repository.loadNotes()
        #expect(autosaved[0].content == "# Final draft\n\nB")
        #expect(autosaved[0].title == "Final draft")
        #expect(!window.debugEditorModified)
    }

    @Test @MainActor
    func mainWindowReloadsExternalCreateAfterPoll() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let externalRepository = NotesRepository(notesDirectory: temp)

        let app = Application(id: "io.github.makoni.SwiftyNotes.Tests.ExternalCreate")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator()
        )

        window.debugLoadInitialNotes()
        #expect(window.debugNotesCount == 1)

        _ = try externalRepository.createNote(initialContent: "# External\n\nCreated from CLI")
        window.debugPollForExternalChanges()

        #expect(window.debugNotesCount == 2)
        #expect(window.debugDisplayedNotesCount == 2)
    }

    @Test @MainActor
    func mainWindowReloadsExternalUpdateAfterPoll() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let original = try repository.createNote(initialContent: "# Original\n\nBody")
        let externalRepository = NotesRepository(notesDirectory: temp)

        let app = Application(id: "io.github.makoni.SwiftyNotes.Tests.ExternalUpdate")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator()
        )

        window.debugLoadInitialNotes()
        #expect(window.debugNotesCount == 1)
        #expect(window.debugSelectedNoteContent == original.content)

        var externallyUpdated = try externalRepository.loadNotes().first
        #expect(externallyUpdated != nil)
        externallyUpdated?.content = "# Updated\n\nFresh text"
        _ = try externalRepository.save(note: externallyUpdated!)

        window.debugPollForExternalChanges()

        #expect(window.debugSelectedNoteContent == "# Updated\n\nFresh text")
        #expect(window.debugPreviewText.contains("Updated"))
        #expect(window.debugPreviewText.contains("Fresh text"))
    }

    @Test @MainActor
    func mainWindowContextMenuActionsExecuteForSelectedRowAfterSidebarRefresh() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "io.github.makoni.SwiftyNotes.Tests.ContextMenu")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator()
        )

        window.present()
        window.debugCreateNote()
        #expect(window.debugNotesCount == 2)
        #expect(window.debugOverflowMenuSectionTitles == ["Library"])

        window.debugOpenContextMenuForDisplayedNote(at: 1)
        #expect(window.debugHasContextMenu)
        #expect(window.debugNoteContextMenuLabels == [
            "Rename note…",
            "Duplicate note",
            "Export note…",
            "Copy note ID",
            "Delete…"
        ])

        let selectedStableID = window.debugSelectedNoteStableID()
        #expect(selectedStableID != nil)
        #expect(window.debugInvokeContextMenuAction(label: "Copy note ID"))
        #expect(!window.debugHasContextMenu)
        #expect(window.debugLastCopiedNoteID == selectedStableID)

        window.debugOpenContextMenuForDisplayedNote(at: 1)
        #expect(window.debugHasContextMenu)
        #expect(window.debugInvokeContextMenuAction(label: "Duplicate note"))
        #expect(!window.debugHasContextMenu)
        #expect(window.debugNotesCount == 3)
        #expect(Set(window.debugDisplayedNoteStableIDs).count == window.debugDisplayedNoteStableIDs.count)
    }

    @Test @MainActor
    func mainWindowOpenNotesFolderUsesInjectedDirectoryOpener() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "io.github.makoni.SwiftyNotes.Tests.OpenNotesFolder")
        try app.register()

        let openedURL = URLRecorder()
        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            directoryOpener: { url in
                await openedURL.set(url)
            }
        )

        window.debugLoadInitialNotes()
        await window.debugOpenNotesFolder()

        let recordedURL = await openedURL.snapshot()
        #expect(recordedURL?.standardizedFileURL == temp.standardizedFileURL)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: temp.path(), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test @MainActor
    func mainWindowSidebarSortControlReflectsAndChangesSortMode() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let alpha = Note(
            id: UUID(),
            filename: "alpha.md",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            content: "# Alpha\n"
        )
        let zeta = Note(
            id: UUID(),
            filename: "zeta.md",
            createdAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 200),
            content: "# Zeta\n"
        )
        _ = try repository.save(note: alpha)
        _ = try repository.save(note: zeta)

        let app = Application(id: "io.github.makoni.SwiftyNotes.Tests.SortControl")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator()
        )

        window.debugLoadInitialNotes()
        #expect(window.debugSortMode == .newestFirst)
        #expect(window.debugSidebarSortSelection == 0)
        #expect(window.debugDisplayedNoteTitles == ["Zeta", "Alpha"])

        window.debugEmitSortButtonClicked()
        #expect(window.debugSortMode == .oldestFirst)
        #expect(window.debugSidebarSortSelection == 1)
        #expect(window.debugDisplayedNoteTitles == ["Alpha", "Zeta"])

        window.debugSelectSidebarSort(at: 2)

        #expect(window.debugSortMode == .title)
        #expect(window.debugSidebarSortSelection == 2)
        #expect(window.debugDisplayedNoteTitles == ["Alpha", "Zeta"])
    }
}

private struct CLITestSummary: Decodable {
    let id: String
    let title: String
    let filename: String
    let createdAt: Date
    let updatedAt: Date
}

private struct CLITestDocument: Decodable {
    let id: String
    let title: String
    let filename: String
    let createdAt: Date
    let updatedAt: Date
    let content: String
}

private extension JSONDecoder {
    static var swiftyNotesCLI: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
