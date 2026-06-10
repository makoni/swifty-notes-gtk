#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

/// Regression: Ctrl+F in preview-only view opened the EDITOR find bar
/// (because `lastFocusedPane` stays `.editor` — the rendered preview
/// labels aren't focusable, so switching to preview-only never flips it).
/// The editor searched its hidden buffer ("1 of 1") while the visible
/// preview got no highlight overlay. openFindBar now routes by view mode
/// in single-pane modes.
struct MainWindowPreviewSearchRoutingTests {
    @MainActor
    private static func makeWindow(appID: String) throws -> MainWindow {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
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

    @Test("Ctrl+F in preview-only mode opens the preview bar, not the editor bar") @MainActor
    func ctrlFInPreviewOnlyModeOpensThePreviewBarNotThe() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.search.previewonlyroute")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("# Why it stands out\n\nbody text")
        window.setViewMode(.preview, animated: false)
        window.openFindBar(mode: .find)
        #expect(window.previewFindReplaceBar.isVisible == true)
        #expect(window.findReplaceBar.isVisible == false)
        #expect(window.previewSearchController != nil)
    }

    @Test("Ctrl+F in editor-only mode opens the editor bar") @MainActor
    func ctrlFInEditorOnlyModeOpensTheEditorBar() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.search.editoronlyroute")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("# Why it stands out\n\nbody text")
        window.setViewMode(.editor, animated: false)
        window.openFindBar(mode: .find)
        #expect(window.findReplaceBar.isVisible == true)
        #expect(window.previewFindReplaceBar.isVisible == false)
    }

    @Test("Ctrl+H replace in preview-only mode still opens the editor bar") @MainActor
    func ctrlHReplaceInPreviewOnlyModeStillOpensTheEditorBar() throws {
        // The preview bar is read-only, so replace must always land in the
        // editor even when preview-only is on screen.
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.search.previewreplace")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("# Why it stands out\n\nbody text")
        window.setViewMode(.preview, animated: false)
        window.openFindBar(mode: .replace)
        #expect(window.findReplaceBar.isVisible == true)
        #expect(window.previewFindReplaceBar.isVisible == false)
    }

    @Test("Typing in the bar Ctrl+F opened paints highlights on the rendered preview label") @MainActor
    func typingInTheBarCtrlFOpenedPaintsHighlightsOnTheRendered() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.search.previewonlypaint")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("# Why it stands out\n\nbody text")
        _ = window.debugPreviewText
        window.setViewMode(.preview, animated: false)
        window.openFindBar(mode: .find)
        window.previewFindReplaceBar.debugTypeQuery("Why")
        // End-to-end: the visible preview label carries the highlight, and
        // the painted substring is the matched text.
        #expect(!window.preview.debugHighlightedLabelPointers.isEmpty)
        #expect(window.preview.debugAppliedHighlightTexts.contains("Why"))
    }
}
#endif
