import Foundation
import Testing
@testable import SwiftyNotes
import Adwaita
import CAdwaita

struct MainWindowCoreTests {
    @Test @MainActor
    func mainWindowCreatesInitialNoteAndUpdatesPreview() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests")
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
        #expect(window.debugPreviewText.contains("Bold"))
        #expect(window.debugPreviewText.contains("Code"))

        window.debugSetEditorText("# Title\n\nBody")
        #expect(window.debugSelectedNoteContent == "# Title\n\nBody")
        #expect(window.debugPreviewText.contains("Title"))
        #expect(window.debugPreviewText.contains("Body"))
    }

    @Test @MainActor
    func mainWindowPresentRendersPreviewForInitiallySelectedNote() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        _ = try repository.createNote(initialContent: "# Initial\n\nPreview body")

        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests.InitialPreview")
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

        window.present()
        try await Task.sleep(for: .milliseconds(40))

        #expect(window.debugSelectedNoteContent == "# Initial\n\nPreview body")
        #expect(window.debugPreviewText.contains("Initial"))
        #expect(window.debugPreviewText.contains("Preview body"))
    }

    @Test @MainActor
    func mainWindowAppliesConfiguredEditorAutosaveAndAppearancePreferencesAtStartup() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests.EditorPreferences")
        try app.register()

        let originalScheme = StyleManager.default.colorScheme
        defer { StyleManager.default.colorScheme = originalScheme }

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            appSettings: AppSettings(
                wrapsEditorLines: false,
                editorFontSize: 18,
                editorTabWidth: 2,
                editorIndentStyle: .tabs,
                autosaveDelaySeconds: 5,
                appearanceMode: .dark
            )
        )

        #expect(window.debugEditorWrapsLines == false)
        #expect(window.debugEditorFontSize == 18)
        #expect(window.debugEditorTabWidth == 2)
        #expect(window.debugEditorInsertsSpacesInsteadOfTabs == false)
        #expect(window.debugAutosaveDelaySeconds == 5)
        #expect(window.debugAppearanceMode == .dark)
        #expect(StyleManager.default.colorScheme == .forceDark)
    }

    @Test @MainActor
    func mainWindowCreateNoteAddsAnotherNote() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests.Create")
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
    func mainWindowCreateNoteAfterPresentKeepsSelectionStable() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests.CreatePresented")
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
        try await Task.sleep(for: .milliseconds(40))

        window.debugCreateNote()
        try await Task.sleep(for: .milliseconds(40))

        #expect(window.debugNotesCount == 2)
        #expect(window.debugSelectedNoteContent == "")
        #expect(window.debugHeaderSubtitle.contains("Saved"))
    }

    @Test @MainActor
    func mainWindowImportsDroppedImageIntoSelectedNoteAssetsAndMarkdown() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let existing = try repository.createNote(initialContent: "# Images\n\nBody")

        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests.DropImage")
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
        #expect(window.debugSelectedNoteStableID() == existing.stableID)

        let sourceImageURL = temp.appendingPathComponent("Dragged Diagram.PNG", isDirectory: false)
        try Data("dropped-image".utf8).write(to: sourceImageURL, options: .atomic)

        try window.importDroppedImages(from: [sourceImageURL])
        #expect(window.debugSelectedNoteContent?.contains("![Dragged Diagram](assets/dragged-diagram.png)") == true)

        window.saveSelectedNoteNow()
        let reloaded = try repository.loadNotes()
        #expect(reloaded[0].content.contains("![Dragged Diagram](assets/dragged-diagram.png)"))
        #expect(try Data(contentsOf: repository.noteAssetsDirectoryURL(for: reloaded[0]).appendingPathComponent("dragged-diagram.png")) == Data("dropped-image".utf8))
    }

    @Test @MainActor
    func mainWindowPlusButtonSignalCreatesNote() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests.Signal")
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

        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests.Tooltips")
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

        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests.SidebarToggle")
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
    func mainWindowSearchEntryFiltersDisplayedNotesAndPersistsQuery() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let stateFileURL = temp.appendingPathComponent("workspace.json", isDirectory: false)
        let repository = NotesRepository(notesDirectory: temp)
        _ = try repository.createNote(initialContent: "# Alpha\n\nFirst")
        try await Task.sleep(for: .milliseconds(20))
        _ = try repository.createNote(initialContent: "# Beta\n\nSecond")

        let stateStore = WorkspaceStateStore(stateFileURL: stateFileURL)
        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests.Search")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: stateStore,
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator()
        )

        window.debugLoadInitialNotes()
        #expect(window.debugDisplayedNoteTitles == ["Beta", "Alpha"])

        window.debugSetSearchQuery("alp")

        #expect(window.debugSearchQuery == "alp")
        #expect(window.debugDisplayedNotesCount == 1)
        #expect(window.debugDisplayedNoteTitles == ["Alpha"])
        #expect(try stateStore.load().searchQuery == "alp")
    }

    @Test @MainActor
    func mainWindowPreviewToggleDetachesAndRestoresPreviewPane() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests.PreviewPane")
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
    func mainWindowRestoresPersistedWorkspaceStateForFilteringAndVisibility() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let alpha = try repository.createNote(initialContent: "# Alpha\n\nFirst")
        _ = try repository.createNote(initialContent: "# Beta\n\nSecond")

        let persisted = WorkspaceState(
            selectedNoteID: alpha.id,
            isSidebarVisible: false,
            isPreviewVisible: false,
            searchQuery: "a",
            sortMode: .title,
            windowWidth: 980,
            windowHeight: 720,
            previewWidth: 620
        )
        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests.RestoreState")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(persistedState: persisted),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator()
        )

        window.debugLoadInitialNotes()

        #expect(!window.debugSidebarVisible)
        #expect(!window.debugIsPreviewPaneAttached)
        #expect(window.debugSearchQuery == "a")
        #expect(window.debugSortMode == .title)
        #expect(window.debugDisplayedNoteTitles == ["Alpha", "Beta"])
    }

    @Test @MainActor
    func mainWindowSaveButtonPersistsCurrentEditorText() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests.SaveButton")
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
        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests.Autosave")
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

        window.present()
        try await Task.sleep(for: .milliseconds(40))
        let originalContent = try repository.loadNotes()[0].content

        window.debugSetEditorText("# First draft\n\nA")
        #expect(window.debugHeaderSubtitle.contains("Unsaved changes"))
        try await Task.sleep(for: .milliseconds(15))
        #expect(try repository.loadNotes()[0].content == originalContent)

        window.debugSetEditorText("# Final draft\n\nB")
        #expect(window.debugHeaderSubtitle.contains("Unsaved changes"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(try repository.loadNotes()[0].content == originalContent)

        try await Task.sleep(for: .milliseconds(60))
        let autosaved = try repository.loadNotes()
        #expect(autosaved[0].content == "# Final draft\n\nB")
        #expect(autosaved[0].title == "Final draft")
        #expect(!window.debugEditorModified)
        #expect(window.debugHeaderSubtitle.contains("Saved"))
        #expect(!window.debugHeaderSubtitle.contains("Unsaved changes"))
    }

    @Test @MainActor
    func mainWindowReloadsExternalCreateAfterPoll() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let externalRepository = NotesRepository(notesDirectory: temp)

        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests.ExternalCreate")
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

        let app = Application(id: "me.spaceinbox.SwiftyNotes.Tests.ExternalUpdate")
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
}
