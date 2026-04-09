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

        let app = Application(id: "me.spaceinbox.swiftynotes.tests")
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

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.initialpreview")
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

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.editorpreferences")
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

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.create")
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

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.createpresented")
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

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.dropimage")
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
    func mainWindowCreateNoteRequestCreatesNoteAfterMainLoopDrain() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.signal")
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
        #expect(window.debugNotesCount == 1)

        window.debugRequestCreateNote()
        window.debugDrainMainContext()
        #expect(window.debugNotesCount == 2)
    }

    @Test @MainActor
    func mainWindowDeferredSelectionSwitchRunsAfterMainLoopDrain() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let first = Note(
            id: UUID(),
            filename: "first.md",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            content: "# First\n\nOne"
        )
        let second = Note(
            id: UUID(),
            filename: "second.md",
            createdAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 200),
            content: "# Second\n\nTwo"
        )
        let savedFirst = try repository.save(note: first)
        let savedSecond = try repository.save(note: second)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.deferredselection")
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
        window.debugLoadInitialNotes()

        #expect(window.debugSelectedNoteStableID() == savedSecond.stableID)

        window.debugRequestSelectDisplayedNote(at: 1)
        #expect(window.debugSelectedNoteStableID() == savedSecond.stableID)

        window.debugDrainMainContext()
        #expect(window.debugSelectedNoteStableID() == savedFirst.stableID)
        #expect(window.debugPreviewText.contains("First"))
        #expect(window.debugPreviewText.contains("One"))
    }

    @Test @MainActor
    func mainWindowToolbarButtonsExposeStandardTooltips() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.tooltips")
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
        #expect(window.debugToolbarTooltips["editorMode"] == "Editor only")
        #expect(window.debugToolbarTooltips["splitMode"] == "Split view")
        #expect(window.debugToolbarTooltips["previewMode"] == "Preview only")
        #expect(window.debugToolbarTooltips["formatHeading"] == "Turn the current line into a heading")
        #expect(window.debugToolbarTooltips["formatBold"] == "Wrap the selection in bold markdown")
        #expect(window.debugToolbarTooltips["formatItalic"] == "Wrap the selection in italic markdown")
        #expect(window.debugToolbarTooltips["formatCode"] == "Insert inline code or a fenced code block")
        #expect(window.debugToolbarTooltips["formatLink"] == "Insert a markdown link")
        #expect(window.debugToolbarTooltips["formatQuote"] == "Prefix the selected lines as a quote")
        #expect(window.debugToolbarTooltips["formatBullet"] == "Prefix the selected lines as a bulleted list")
        #expect(window.debugToolbarTooltips["formatNumbered"] == "Prefix the selected lines as a numbered list")
        #expect(window.debugToolbarTooltips["formatTask"] == "Prefix the selected lines as a task list")
    }

    @Test @MainActor
    func mainWindowUsesApplicationIconName() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.windowicon")
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

        #expect(window.debugWindowIconName == AppIdentity.identifier)
    }

    @Test @MainActor
    func mainWindowSidebarToggleHidesAndShowsSidebar() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.sidebartoggle")
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
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.search")
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
    func mainWindowViewModeSwitcherUpdatesLayout() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.previewpane")
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
        #expect(window.debugViewMode == .split)

        window.debugSelectViewMode(.editor)
        try await Task.sleep(for: .milliseconds(80))
        #expect(!window.debugIsPreviewPaneAttached)
        #expect(window.debugViewMode == .editor)

        window.debugSelectViewMode(.preview)
        try await Task.sleep(for: .milliseconds(80))
        #expect(!window.debugIsPreviewPaneAttached)
        #expect(window.debugViewMode == .preview)

        window.debugSelectViewMode(.split)
        #expect(window.debugIsPreviewPaneAttached)
        #expect(window.debugViewMode == .split)
    }

    @Test @MainActor
    func mainWindowFormattingToolbarAppliesBoldToSelectedEditorText() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.formatting")
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
        window.debugSetEditorText("Hello world")
        window.debugSelectEditorRange(6..<11)

        window.debugEmitEditorFormattingButtonClicked(.bold)

        #expect(window.debugEditorText == "Hello **world**")
        #expect(window.debugSelectedNoteContent == "Hello **world**")
        #expect(window.debugEditorSelectionRange == 6..<15)
    }

    @Test @MainActor
    func mainWindowFormattingToolbarTogglesBoldOffForFormattedSelection() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.formattingtoggle")
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
        window.debugSetEditorText("Hello **world**")
        window.debugSelectEditorRange(6..<15)

        window.debugEmitEditorFormattingButtonClicked(.bold)

        #expect(window.debugEditorText == "Hello world")
        #expect(window.debugSelectedNoteContent == "Hello world")
        #expect(window.debugEditorSelectionRange == 6..<11)
    }

    @Test @MainActor
    func mainWindowFormattingToolbarTogglesTaskListAtCursorAcrossWholeLine() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.tasktoggle")
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
        window.debugSetEditorText("- Ship it")
        window.debugSelectEditorRange(4..<4)

        window.debugEmitEditorFormattingButtonClicked(.taskList)
        #expect(window.debugEditorText == "- [ ] Ship it")
        #expect(window.debugEditorSelectionRange == 0..<13)

        window.debugEmitEditorFormattingButtonClicked(.taskList)
        #expect(window.debugEditorText == "Ship it")
        #expect(window.debugEditorSelectionRange == 0..<7)
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
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.restorestate")
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
        #expect(window.debugViewMode == .editor)
        #expect(window.debugSearchQuery == "a")
        #expect(window.debugSortMode == .title)
        #expect(window.debugDisplayedNoteTitles == ["Alpha", "Beta"])
    }

    @Test @MainActor
    func mainWindowSaveButtonPersistsCurrentEditorText() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.savebutton")
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
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.autosave")
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
        drainMainContext()
        let originalContent = try repository.loadNotes()[0].content

        window.debugSetEditorText("# First draft\n\nA")
        #expect(window.debugHeaderSubtitle.contains("Unsaved changes"))
        try await Task.sleep(for: .milliseconds(15))
        drainMainContext()
        #expect(try repository.loadNotes()[0].content == originalContent)

        window.debugSetEditorText("# Final draft\n\nB")
        #expect(window.debugHeaderSubtitle.contains("Unsaved changes"))
        try await Task.sleep(for: .milliseconds(20))
        drainMainContext()
        #expect(try repository.loadNotes()[0].content == originalContent)

        try await Task.sleep(for: .milliseconds(60))
        drainMainContext()
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

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.externalcreate")
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

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.externalupdate")
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
