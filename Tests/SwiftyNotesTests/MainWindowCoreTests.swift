#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

struct MainWindowCoreTests {
    @Test("Main window creates initial note and updates preview") @MainActor
    func mainWindowCreatesInitialNoteAndUpdatesPreview() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        #expect(window.debugNotesCount == 3)
        #expect(window.debugSelectedNoteContent == MarkdownShowcaseSeed.content)
        #expect(window.debugPreviewText.contains("Markdown Showcase"))
        #expect(window.debugPreviewText.contains("screenshot-ready note"))
        #expect(window.debugPreviewText.contains("Feature Snapshot"))
        #expect(window.debugPreviewText.contains("Toolbar"))

        window.debugSetEditorText("# Title\n\nBody")
        #expect(window.debugSelectedNoteContent == "# Title\n\nBody")
        #expect(window.debugPreviewText.contains("Title"))
        #expect(window.debugPreviewText.contains("Body"))
    }

    @Test("Main window typing burst defers markdown rebuild until pending preview flush") @MainActor
    func mainWindowTypingBurstDefersMarkdownRebuildUntilPendingPreviewFlush() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.typingpreview")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        let baselineBuildCount = window.debugPreviewBlockBuildCount

        window.debugSetEditorText("# First draft\n\nA")
        window.debugSetEditorText("# Final draft\n\nB")

        #expect(window.debugPreviewBlockBuildCount == baselineBuildCount)
        #expect(window.debugPreviewText.contains("Final draft"))
        #expect(window.debugPreviewText.contains("B"))
        #expect(window.debugPreviewBlockBuildCount == baselineBuildCount + 1)
    }

    @Test("Main window body edits skip sidebar redraw when title and search state are unchanged") @MainActor
    func mainWindowBodyEditsSkipSidebarRedrawWhenTitleAndSearchState() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.typingsidebar")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        let baselineRenderCount = window.debugSidebarRenderCount

        window.debugAppendEditorText("\n\nUpdated body only")

        #expect(window.debugSidebarRenderCount == baselineRenderCount)
    }

    @Test("Main window selecting CLI seeded note updates preview") @MainActor
    func mainWindowSelectingCLISeededNoteUpdatesPreview() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.cliseedpreview")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        // The seeded onboarding layout puts the explanatory guides
        // inside an expanded "Guides" folder so they appear first in
        // the sidebar, with the root-level showcase below them.
        #expect(window.debugDisplayedNoteTitles == [
            "About Swifty Notes",
            "Using Swifty Notes CLI",
            "Markdown Showcase",
        ])

        window.debugSelectDisplayedNote(at: 1)

        #expect(window.debugSelectedNoteStableID() != nil)
        #expect(window.debugSelectedNoteContent == SwiftyNotesCLISeed.content)
        #expect(window.debugPreviewText.contains("Using Swifty Notes CLI"))
        #expect(window.debugPreviewText.contains("swiftynotes cli list"))
        #expect(window.debugPreviewText.contains("swiftynotes cli update"))
    }

    @Test("Main window present renders preview for initially selected note") @MainActor
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
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.present()
        try await Task.sleep(for: .milliseconds(40))

        #expect(window.debugSelectedNoteContent == "# Initial\n\nPreview body")
        #expect(window.debugPreviewText.contains("Initial"))
        #expect(window.debugPreviewText.contains("Preview body"))
    }

    @Test("Main window applies configured editor autosave and appearance preferences at startup") @MainActor
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
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
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
                appearanceMode: .dark,
            ),
        )

        #expect(window.debugEditorWrapsLines == false)
        #expect(window.debugEditorFontSize == 18)
        #expect(window.debugEditorTabWidth == 2)
        #expect(window.debugEditorInsertsSpacesInsteadOfTabs == false)
        #expect(window.debugAutosaveDelaySeconds == 5)
        #expect(window.debugAppearanceMode == .dark)
        #expect(StyleManager.default.colorScheme == .forceDark)
    }

    @Test("Main window create note adds another note") @MainActor
    func mainWindowCreateNoteAddsAnotherNote() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.create")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        #expect(window.debugNotesCount == 3)

        window.debugCreateNote()
        #expect(window.debugNotesCount == 4)
    }

    @Test("Main window create note after present keeps selection stable") @MainActor
    func mainWindowCreateNoteAfterPresentKeepsSelectionStable() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.createpresented")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.present()
        try await Task.sleep(for: .milliseconds(40))

        window.debugCreateNote()
        try await Task.sleep(for: .milliseconds(40))

        #expect(window.debugNotesCount == 4)
        #expect(window.debugSelectedNoteContent == "")
        #expect(window.debugHeaderSubtitle.contains("Saved"))
    }

    @Test("Main window imports dropped image into selected note assets and markdown") @MainActor
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
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
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

    @Test("Main window imports pasted image into selected note assets and markdown") @MainActor
    func mainWindowImportsPastedImageIntoSelectedNoteAssetsAndMarkdown() throws {
        // Clipboard paste mirrors the drop-target import: the bytes the
        // clipboard handed us land in the note's `assets/` folder under
        // a unique `pasted.png` / `pasted-2.png` filename, and a
        // `![](path)` reference is inserted at the cursor. No alt text —
        // the clipboard never gives us a filename to lift one from.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let existing = try repository.createNote(initialContent: "# Pasted\n\nBody")

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.paste-image")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        #expect(window.debugSelectedNoteStableID() == existing.stableID)

        let pngBytes = Data("pasted-image".utf8)
        try window.importPastedImage(pngData: pngBytes)
        #expect(window.debugSelectedNoteContent?.contains("![](assets/pasted.png)") == true)

        // A second paste collides on filename and gets the standard `-2`
        // suffix, same as the URL-based drop-import path.
        try window.importPastedImage(pngData: Data("second-paste".utf8))
        #expect(window.debugSelectedNoteContent?.contains("![](assets/pasted-2.png)") == true)

        window.saveSelectedNoteNow()
        let reloaded = try repository.loadNotes()
        #expect(reloaded[0].content.contains("![](assets/pasted.png)"))
        #expect(reloaded[0].content.contains("![](assets/pasted-2.png)"))
        let assetsDir = repository.noteAssetsDirectoryURL(for: reloaded[0])
        #expect(try Data(contentsOf: assetsDir.appendingPathComponent("pasted.png")) == pngBytes)
        #expect(try Data(contentsOf: assetsDir.appendingPathComponent("pasted-2.png")) == Data("second-paste".utf8))
    }

    @Test("Main window paste URL with no selection wraps it as a markdown link") @MainActor
    func mainWindowPasteURLWithNoSelectionWrapsItAsAMarkdown() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        _ = try repository.createNote(initialContent: "Cursor here: ")

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.paste-url-bare")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        window.debugSetEditorText("Cursor here: ")
        window.debugSelectEditorRange(13 ..< 13)

        window.handleClipboardTextPaste(
            clipboardText: "https://example.com",
            selectedText: "",
            textBefore: "Cursor here: ",
        )

        #expect(window.debugEditorText == "Cursor here: [https://example.com](https://example.com)")
    }

    @Test("Main window paste URL with selection wraps the selection as link text") @MainActor
    func mainWindowPasteURLWithSelectionWrapsTheSelectionAsLinkText() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        _ = try repository.createNote(initialContent: "click here please")

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.paste-url-selection")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        window.debugSetEditorText("click here please")
        window.debugSelectEditorRange(0 ..< 10) // "click here"

        window.handleClipboardTextPaste(
            clipboardText: "https://example.com",
            selectedText: "click here",
            textBefore: "",
        )

        #expect(window.debugEditorText == "[click here](https://example.com) please")
    }

    @Test("Main window paste plain text inserts text without wrapping") @MainActor
    func mainWindowPastePlainTextInsertsTextWithoutWrapping() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        _ = try repository.createNote(initialContent: "")

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.paste-plain")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        window.debugSetEditorText("Prefix: ")
        window.debugSelectEditorRange(8 ..< 8)

        window.handleClipboardTextPaste(
            clipboardText: "just some words",
            selectedText: "",
            textBefore: "Prefix: ",
        )

        #expect(window.debugEditorText == "Prefix: just some words")
    }

    @Test("Main window paste URL inside code block keeps URL raw") @MainActor
    func mainWindowPasteURLInsideCodeBlockKeepsURLRaw() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        _ = try repository.createNote(initialContent: "")

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.paste-url-codeblock")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        let prefix = "```\ncurl "
        window.debugSetEditorText(prefix)
        window.debugSelectEditorRange(prefix.count ..< prefix.count)

        window.handleClipboardTextPaste(
            clipboardText: "https://example.com",
            selectedText: "",
            textBefore: prefix,
        )

        #expect(window.debugEditorText == "```\ncurl https://example.com")
    }

    @Test("Main window paste image throws when no note is selected") @MainActor
    func mainWindowPasteImageThrowsWhenNoNoteIsSelected() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.paste-image-no-note")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        // Deliberately skip `debugLoadInitialNotes()` — no note selected.
        #expect {
            try window.importPastedImage(pngData: Data("any".utf8))
        } throws: { error in
            (error as? DroppedImageImportError) == .noSelectedNote
        }
    }

    @Test("Main window create note request creates note after main loop drain") @MainActor
    func mainWindowCreateNoteRequestCreatesNoteAfterMainLoopDrain() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let deferredScheduler = TestMainActorScheduler()

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.signal")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            deferredUIActionScheduler: deferredScheduler.schedule,
        )

        window.debugLoadInitialNotes()
        #expect(window.debugNotesCount == 3)

        window.debugRequestCreateNote()
        deferredScheduler.runPendingActions()
        #expect(window.debugNotesCount == 4)
    }

    @Test("Main window deferred selection switch runs after main loop drain") @MainActor
    func mainWindowDeferredSelectionSwitchRunsAfterMainLoopDrain() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let first = Note(
            id: UUID(),
            filename: "first.md",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            content: "# First\n\nOne",
        )
        let second = Note(
            id: UUID(),
            filename: "second.md",
            createdAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 200),
            content: "# Second\n\nTwo",
        )
        let savedFirst = try repository.save(note: first)
        let savedSecond = try repository.save(note: second)
        let deferredScheduler = TestMainActorScheduler()

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.deferredselection")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            deferredUIActionScheduler: deferredScheduler.schedule,
        )

        window.debugLoadInitialNotes()

        #expect(window.debugSelectedNoteStableID() == savedSecond.stableID)

        window.debugRequestSelectDisplayedNote(at: 1)
        #expect(window.debugSelectedNoteStableID() == savedSecond.stableID)

        deferredScheduler.runPendingActions()
        #expect(window.debugSelectedNoteStableID() == savedFirst.stableID)
        #expect(window.debugPreviewText.contains("First"))
        #expect(window.debugPreviewText.contains("One"))
    }

    @Test("Main window toolbar buttons expose standard tooltips") @MainActor
    func mainWindowToolbarButtonsExposeStandardTooltips() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.tooltips")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
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

    @Test("Main window formatting toolbar uses compact icon mode when editor narrows") @MainActor
    func mainWindowFormattingToolbarUsesCompactIconModeWhenEditorNarrows() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.toolbarcompact")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        let wideEnough = window.debugEditorFormattingToolbarCompactThreshold + 80
        let tooNarrow = window.debugEditorFormattingToolbarCompactThreshold - 1
        window.debugSetEditorFormattingToolbarWidth(wideEnough)

        let expandedLabels: [MarkdownFormattingAction: String?] = [
            .heading: "H1",
            .bold: "Bold",
            .italic: "Italic",
            .code: "</>",
            .link: "Link",
            .quote: "Quote",
            .bulletList: "Bullets",
            .numberedList: "1.",
            .taskList: "[ ]",
            .table: "Table",
        ]
        #expect(window.debugEditorFormattingToolbarSnapshot == .init(
            isCompact: false,
            usesTwoRows: false,
            labelsByAction: expandedLabels,
        ))

        window.debugSetEditorFormattingToolbarWidth(tooNarrow)

        let compactLabels: [MarkdownFormattingAction: String?] = [
            .heading: "H1",
            .bold: nil,
            .italic: nil,
            .code: "</>",
            .link: nil,
            .quote: nil,
            .bulletList: nil,
            .numberedList: nil,
            .taskList: "[ ]",
            .table: nil,
        ]
        #expect(window.debugEditorFormattingToolbarSnapshot == .init(
            isCompact: true,
            usesTwoRows: false,
            labelsByAction: compactLabels,
        ))
        #expect(window.debugToolbarTooltips["formatBold"] == "Wrap the selection in bold markdown")

        window.debugSetEditorFormattingToolbarWidth(wideEnough)

        #expect(window.debugEditorFormattingToolbarSnapshot == .init(
            isCompact: false,
            usesTwoRows: false,
            labelsByAction: expandedLabels,
        ))
    }

    @Test("Main window formatting toolbar wraps into two rows when compact row still does not fit") @MainActor
    func mainWindowFormattingToolbarWrapsIntoTwoRowsWhenCompactRowStill() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.toolbarwrap")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        window.debugSetEditorFormattingToolbarWidth(220)

        let compactLabels: [MarkdownFormattingAction: String?] = [
            .heading: "H1",
            .bold: nil,
            .italic: nil,
            .code: "</>",
            .link: nil,
            .quote: nil,
            .bulletList: nil,
            .numberedList: nil,
            .taskList: "[ ]",
            .table: nil,
        ]
        #expect(window.debugEditorFormattingToolbarSnapshot == .init(
            isCompact: true,
            usesTwoRows: true,
            labelsByAction: compactLabels,
        ))
        #expect(window.debugToolbarTooltips["formatNumbered"] == "Prefix the selected lines as a numbered list")

        window.debugSetEditorFormattingToolbarWidth(window.debugEditorFormattingToolbarCompactThreshold - 1)

        #expect(window.debugEditorFormattingToolbarSnapshot == .init(
            isCompact: true,
            usesTwoRows: false,
            labelsByAction: compactLabels,
        ))
    }

    @Test("Main window uses application icon name") @MainActor
    func mainWindowUsesApplicationIconName() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.windowicon")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        #expect(window.debugWindowIconName == AppIdentity.identifier)
    }

    @Test("Main window sidebar toggle hides and shows sidebar") @MainActor
    func mainWindowSidebarToggleHidesAndShowsSidebar() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.sidebartoggle")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
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

    @Test("Main window search entry filters displayed notes and persists query") @MainActor
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
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        #expect(window.debugDisplayedNoteTitles == ["Beta", "Alpha"])

        window.debugSetSearchQuery("alp")

        #expect(window.debugSearchQuery == "alp")
        #expect(window.debugDisplayedNotesCount == 1)
        #expect(window.debugDisplayedNoteTitles == ["Alpha"])
        #expect(try stateStore.load().searchQuery == "alp")
    }

    @Test("Main window view mode switcher updates layout") @MainActor
    func mainWindowViewModeSwitcherUpdatesLayout() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.previewpane")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
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

    @Test("Main window formatting toolbar applies bold to selected editor text") @MainActor
    func mainWindowFormattingToolbarAppliesBoldToSelectedEditorText() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.formatting")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        window.debugSetEditorText("Hello world")
        window.debugSelectEditorRange(6 ..< 11)

        window.debugEmitEditorFormattingButtonClicked(.bold)

        #expect(window.debugEditorText == "Hello **world**")
        #expect(window.debugSelectedNoteContent == "Hello **world**")
        #expect(window.debugEditorSelectionRange == 6 ..< 15)
    }

    @Test("Main window formatting toolbar remembers last chosen table size and alignments") @MainActor
    func mainWindowFormattingToolbarRemembersLastChosenTableSizeAndAlignments() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let stateURL = temp.appendingPathComponent("workspace.json", isDirectory: false)
        let store = WorkspaceStateStore(stateFileURL: stateURL)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.formattingremembertable")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: store,
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        window.debugSetEditorText("")
        window.debugSelectEditorRange(0 ..< 0)

        window.debugPickTableSize(rows: 3, cols: 2, alignments: [.right, .center])

        let persisted = try store.load()
        #expect(persisted.lastTableRows == 3)
        #expect(persisted.lastTableCols == 2)
        #expect(persisted.lastTableAlignments == [.right, .center])
        #expect(window.debugEditorText.contains("| Column 1 | Column 2 |"))
        #expect(window.debugEditorText.contains("| -------: | :------: |"))
    }

    @Test("Main window formatting toolbar insert table writes scaffold at the cursor and selects the first header cell") @MainActor
    func mainWindowFormattingToolbarInsertTableWritesScaffoldAtTheCursorAnd() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.formattinginsert-table")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        window.debugSetEditorText("")
        window.debugSelectEditorRange(0 ..< 0)

        window.debugPickTableSize(rows: 2, cols: 3)

        // Confirming the alignment phase writes explicit per-column markers.
        // Default alignment is left, so the post-header row picks up `:---`.
        let expected = """
        | Column 1 | Column 2 | Column 3 |
        | :------- | :------- | :------- |
        |          |          |          |
        |          |          |          |
        """ + "\n"
        #expect(window.debugEditorText == expected)
        #expect(window.debugSelectedNoteContent == expected)
        // "Column 1" is selected so the user can start typing straight away.
        let selection = window.debugEditorSelectionRange
        let headerStart = try expected.distance(
            from: expected.startIndex,
            to: #require(expected.range(of: "Column 1")?.lowerBound),
        )
        #expect(selection == headerStart ..< (headerStart + "Column 1".count))
    }

    @Test("Main window formatting toolbar toggles bold off for formatted selection") @MainActor
    func mainWindowFormattingToolbarTogglesBoldOffForFormattedSelection() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.formattingtoggle")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        window.debugSetEditorText("Hello **world**")
        window.debugSelectEditorRange(6 ..< 15)

        window.debugEmitEditorFormattingButtonClicked(.bold)

        #expect(window.debugEditorText == "Hello world")
        #expect(window.debugSelectedNoteContent == "Hello world")
        #expect(window.debugEditorSelectionRange == 6 ..< 11)
    }

    @Test("Main window formatting toolbar toggles task list at cursor across whole line") @MainActor
    func mainWindowFormattingToolbarTogglesTaskListAtCursorAcrossWholeLine() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.tasktoggle")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        window.debugSetEditorText("- Ship it")
        window.debugSelectEditorRange(4 ..< 4)

        window.debugEmitEditorFormattingButtonClicked(.taskList)
        #expect(window.debugEditorText == "- [ ] Ship it")
        #expect(window.debugEditorSelectionRange == 0 ..< 13)

        window.debugEmitEditorFormattingButtonClicked(.taskList)
        #expect(window.debugEditorText == "Ship it")
        #expect(window.debugEditorSelectionRange == 0 ..< 7)
    }

    @Test("Main window restores persisted workspace state for filtering and visibility") @MainActor
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
            previewWidth: 620,
        )
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.restorestate")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(persistedState: persisted),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()

        #expect(!window.debugSidebarVisible)
        #expect(!window.debugIsPreviewPaneAttached)
        #expect(window.debugViewMode == .editor)
        #expect(window.debugSearchQuery == "a")
        #expect(window.debugSortMode == .title)
        #expect(window.debugDisplayedNoteTitles == ["Alpha", "Beta"])
    }

    @Test("Main window save button persists current editor text") @MainActor
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
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            autosaveDelay: .seconds(2),
        )

        window.debugLoadInitialNotes()
        window.debugSetEditorText("# Saved Title\n\nSaved body")
        #expect(window.debugEditorModified)

        window.debugEmitSaveClicked()
        try await Task.sleep(for: .milliseconds(80))

        let saved = try repository.loadNotes()
        #expect(saved.count == 3)
        #expect(saved[0].content == "# Saved Title\n\nSaved body")
        #expect(saved[0].title == "Saved Title")
        #expect(!window.debugEditorModified)
        // The seeded "Guides" folder is expanded by default, so its
        // children (About / CLI guide) sort above root-level notes
        // in the sidebar; assert presence rather than first-position.
        #expect(window.debugDisplayedNoteTitles.contains("Saved Title"))
    }

    @Test("Main window autosave waits for last edit before saving") @MainActor
    func mainWindowAutosaveWaitsForLastEditBeforeSaving() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let autosaveScheduler = TestMainActorScheduler()
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.autosave")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(taskScheduler: autosaveScheduler.schedule(after:operation:)),
            autosaveDelay: .milliseconds(40),
        )

        window.debugLoadInitialNotes()
        let originalContent = try repository.loadNotes()[0].content

        window.debugSetEditorText("# First draft\n\nA")
        #expect(window.debugHeaderSubtitle.contains("Unsaved changes"))
        #expect(try repository.loadNotes()[0].content == originalContent)

        window.debugSetEditorText("# Final draft\n\nB")
        #expect(window.debugHeaderSubtitle.contains("Unsaved changes"))
        #expect(try repository.loadNotes()[0].content == originalContent)

        autosaveScheduler.runPendingActions()
        let autosaved = try repository.loadNotes()
        #expect(autosaved[0].content == "# Final draft\n\nB")
        #expect(autosaved[0].title == "Final draft")
        #expect(!window.debugEditorModified)
        #expect(window.debugHeaderSubtitle.contains("Saved"))
        #expect(!window.debugHeaderSubtitle.contains("Unsaved changes"))
    }

    @Test("Main window reloads external create after poll") @MainActor
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
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        #expect(window.debugNotesCount == 3)

        _ = try externalRepository.createNote(initialContent: "# External\n\nCreated from CLI")
        window.debugPollForExternalChanges()

        #expect(window.debugNotesCount == 4)
        #expect(window.debugDisplayedNotesCount == 4)
    }

    @Test("Main window reloads external update after poll") @MainActor
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
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        #expect(window.debugNotesCount == 1)
        #expect(window.debugSelectedNoteContent == original.content)

        var externallyUpdated = try externalRepository.loadNotes().first
        #expect(externallyUpdated != nil)
        externallyUpdated?.content = "# Updated\n\nFresh text"
        _ = try externalRepository.save(note: #require(externallyUpdated))

        window.debugPollForExternalChanges()

        #expect(window.debugSelectedNoteContent == "# Updated\n\nFresh text")
        #expect(window.debugPreviewText.contains("Updated"))
        #expect(window.debugPreviewText.contains("Fresh text"))
    }

    @Test("Main window reloads external same size update after poll") @MainActor
    func mainWindowReloadsExternalSameSizeUpdateAfterPoll() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let original = try repository.createNote(initialContent: "# Original\n\nabcde")
        let externalRepository = NotesRepository(notesDirectory: temp)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.externalsamesizeupdate")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        #expect(window.debugNotesCount == 1)
        #expect(window.debugSelectedNoteContent == original.content)

        var externallyUpdated = try externalRepository.loadNotes().first
        #expect(externallyUpdated != nil)
        externallyUpdated?.content = "# Original\n\nvwxyz"
        _ = try externalRepository.save(note: #require(externallyUpdated))

        window.debugPollForExternalChanges()

        #expect(window.debugSelectedNoteContent == "# Original\n\nvwxyz")
        #expect(window.debugPreviewText.contains("Original"))
        #expect(window.debugPreviewText.contains("vwxyz"))
    }
}
#endif
