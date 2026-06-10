#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

struct MainWindowSearchTests {
    @MainActor
    private static func makeWindow(appID: String) throws -> MainWindow {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = Application(id: appID)
        try app.register()
        return MainWindow(
            application: app,
            state: AppState(persistedState: WorkspaceState(isOutlineVisible: true)),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )
    }

    @Test("openFindBar in find mode reveals the bar and builds the controller lazily") @MainActor
    func openFindBarInFindModeRevealsTheBarAndBuildsTheControllerLazily() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.search.openfind")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("alpha beta alpha gamma")
        #expect(window.editorSearchController == nil)
        #expect(window.findReplaceBar.isVisible == false)

        window.openFindBar(mode: .find)

        #expect(window.findReplaceBar.isVisible == true)
        #expect(window.findReplaceBar.mode == .find)
        #expect(window.editorSearchController != nil)
    }

    @Test("openFindBar in replace mode reveals the bar with the replace row") @MainActor
    func openFindBarInReplaceModeRevealsTheBarWithTheReplaceRow() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.search.openreplace")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("foo bar foo")
        window.openFindBar(mode: .replace)
        #expect(window.findReplaceBar.mode == .replace)
        #expect(window.findReplaceBar.isVisible == true)
    }

    @Test("openFindBar pre-fills the query from a single-line selection") @MainActor
    func openFindBarPreFillsTheQueryFromASingleLineSelection() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.search.prefill")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("the quick brown fox")
        // Select "quick" (offset 4..<9).
        window.editor.buffer.select(range: 4..<9)
        window.openFindBar(mode: .find)
        #expect(window.findReplaceBar.query == "quick")
        // Pre-fill should have triggered a search so the match
        // count is populated immediately on open.
        #expect(window.editorSearchController?.debugMatchCount == 1)
    }

    @Test("openFindBar skips pre-fill for multi-line selections") @MainActor
    func openFindBarSkipsPreFillForMultiLineSelections() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.search.multiline")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("line one\nline two\nline three")
        // Select across the newline.
        window.editor.buffer.select(range: 4..<13)
        window.openFindBar(mode: .find)
        // The selection contained "\n", so it shouldn't have been
        // adopted into the find entry.
        #expect(window.findReplaceBar.query.isEmpty)
    }

    @Test("Reopening the bar without a selection restores the previous query") @MainActor
    func reopeningTheBarWithoutASelectionRestoresThePreviousQuery() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.search.memory")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("alpha beta gamma")
        // First open: type "beta" — should remember it across close.
        window.openFindBar(mode: .find)
        window.findReplaceBar.debugTypeQuery("beta")
        window.findReplaceBar.setVisible(false)
        // Second open: no selection in editor, no query yet — the
        // bar should pre-fill with the remembered "beta".
        window.editor.buffer.placeCursor(at: 0)
        window.openFindBar(mode: .find)
        #expect(window.findReplaceBar.query == "beta")
    }

    @Test("Selection wins over remembered query when both are available") @MainActor
    func selectionWinsOverRememberedQueryWhenBothAreAvailable() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.search.selwins")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("the quick brown fox")
        // Remember "brown" from a prior open.
        window.openFindBar(mode: .find)
        window.findReplaceBar.debugTypeQuery("brown")
        window.findReplaceBar.setVisible(false)
        // Now select "quick" and open again — selection takes
        // priority over the remembered query (GNOME convention).
        window.editor.buffer.select(range: 4..<9)
        window.openFindBar(mode: .find)
        #expect(window.findReplaceBar.query == "quick")
    }

    @Test("lastFocusedPane controls which bar Ctrl+F opens in split mode") @MainActor
    func lastFocusedPaneControlsWhichBarCtrlFOpensInSplitMode() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.search.focuspane")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("alpha beta gamma")

        // Default: editor pane. Ctrl+F opens the editor bar.
        window.openFindBar(mode: .find)
        #expect(window.findReplaceBar.isVisible == true)
        #expect(window.previewFindReplaceBar.isVisible == false)
        window.findReplaceBar.setVisible(false)

        // Flip the tracking to preview — the next Ctrl+F should
        // open the preview's bar instead.
        window.lastFocusedPane = .preview
        window.openFindBar(mode: .find)
        #expect(window.previewFindReplaceBar.isVisible == true)
        #expect(window.findReplaceBar.isVisible == false)
        window.previewFindReplaceBar.setVisible(false)

        // .replace always lands in the editor pane regardless of
        // focus — the preview bar is read-only.
        window.lastFocusedPane = .preview
        window.openFindBar(mode: .replace)
        #expect(window.findReplaceBar.isVisible == true)
        #expect(window.findReplaceBar.mode == .replace)
        #expect(window.previewFindReplaceBar.isVisible == false)
    }

    @Test("Replace-all completion shows a toast through the window") @MainActor
    func replaceAllCompletionShowsAToastThroughTheWindow() throws {
        // We can't introspect ToastOverlay's queue from headless
        // tests, but we can confirm the callback wiring runs — by
        // calling the controller path the bar would trigger and
        // letting it route through `onReplaceAllCompleted`. The
        // toast presentation itself is a one-liner against
        // ToastOverlay so the risk surface is in the wiring.
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.search.toast")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("foo foo foo")
        window.openFindBar(mode: .replace)
        window.findReplaceBar.debugTypeQuery("foo")
        window.findReplaceBar.replacement = "X"
        // Sanity: matches were found and ready to replace.
        #expect(window.editorSearchController?.debugMatchCount == 3)
        window.findReplaceBar.debugClickReplaceAll()
        // After replace-all the editor buffer reflects the
        // replacement, and the controller's match cache reset.
        #expect(window.editor.buffer.text == "X X X")
        #expect(window.editorSearchController?.debugMatchCount == 0)
    }
}
#endif
