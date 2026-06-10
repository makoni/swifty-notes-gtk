#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

struct MainWindowPreviewOnlyContentTests {
    @Test("Switching to preview-only mode installs the preview pane wrapper as split content") @MainActor
    func switchingToPreviewOnlyModeInstallsThePreviewPaneWrapperAsSplit() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.previewonly")
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

        // Visit split first so the preview pane is wrapped in
        // previewPaneContent, then ask for preview-only.
        window.setViewMode(.split, animated: false)
        window.setViewMode(.preview, animated: false)

        // In preview-only mode the split's content must BE the preview
        // pane wrapper (the Box holding the preview-side find bar +
        // rootScroll) — the same widget split mode attaches to the Paned —
        // not the editor/preview Paned itself. The regression set
        // `rootScroll` directly while it was still parented to the wrapper,
        // so GTK rejected the reparent and the editor stayed on screen.
        #expect(window.splitView.content?.opaquePointer == window.previewPaneContent.opaquePointer)
        #expect(window.splitView.content?.opaquePointer != window.editorPreviewPane.opaquePointer)
        // The preview's scroll stays nested inside that wrapper.
        #expect(window.preview.rootScroll.parent?.opaquePointer == window.previewPaneContent.opaquePointer)
    }

    @Test("Toggling split → preview → split keeps content consistent and emits no reparent error") @MainActor
    func togglingSplitPreviewSplitKeepsContentConsistentAndEmitsNoReparentError() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.previewonly.roundtrip")
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

        window.setViewMode(.split, animated: false)
        window.setViewMode(.preview, animated: false)
        #expect(window.splitView.content?.opaquePointer == window.previewPaneContent.opaquePointer)

        // Back to split: content returns to the Paned and the wrapper is
        // re-attached as its end child without a dangling parent.
        window.setViewMode(.split, animated: false)
        #expect(window.splitView.content?.opaquePointer == window.editorPreviewPane.opaquePointer)
        #expect(window.preview.rootScroll.parent?.opaquePointer == window.previewPaneContent.opaquePointer)

        // And preview-only again — the second reparent must still succeed.
        window.setViewMode(.preview, animated: false)
        #expect(window.splitView.content?.opaquePointer == window.previewPaneContent.opaquePointer)
    }
}
#endif
