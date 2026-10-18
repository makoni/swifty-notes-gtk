#if !os(macOS)
import Adwaita
import CAdwaita
import Foundation
@testable import SwiftyNotes
import Testing

/// Where the divider between the editor and the preview lands in Split mode.
@Suite(.serialized)
struct PreviewPaneLayoutTests {
    @Test("The split preview gets its width beside a shown outline, also after the sidebar changes in the editor") @MainActor
    func theSplitPreviewGetsItsWidthBesideAShownOutline() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.panelayout.main")
        try app.register()
        let window = MainWindow(
            application: app,
            state: AppState(persistedState: WorkspaceState(isOutlineVisible: true)),
            stateStore: WorkspaceStateStore(stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )
        window.debugLoadInitialNotes()
        // Wider than a headless test monitor would let it be by default.
        window.window.setSizeRequest(width: 1400, height: 900)
        window.present()
        window.setViewMode(.split, animated: false)
        Self.waitUntil(timeout: .seconds(2)) { window.editorPreviewPane.width > 0 && window.preview.rootScroll.width > 0 }
        MainContext.pump(for: .milliseconds(100))

        // The room is the pane's, the window less the sidebar and the
        // outline; counting the outline in pushed the divider right and left
        // the preview narrower than its content, clipping it. The editor
        // keeps at least its own minimum (its toolbar's).
        func expectedDivider() -> Int {
            let room = window.editorPreviewPane.width
            let previewWidth = MainWindow.resolvedPreviewWidth(storedWidth: WorkspaceState.defaultPreviewWidth, availableWidth: room)
            var editorMinimum: Int32 = 0
            gtk_widget_measure(window.editorContent.widgetPointer, GTK_ORIENTATION_HORIZONTAL, -1, &editorMinimum, nil, nil, nil)
            return max(room - previewWidth, Int(editorMinimum))
        }
        func expectPreviewWidth(_ step: String) {
            Self.waitUntil(timeout: .seconds(2)) { abs(window.editorPreviewPane.position - expectedDivider()) <= 12 }
            let room = window.editorPreviewPane.width
            #expect(abs(window.editorPreviewPane.position - expectedDivider()) <= 12, "\(step): divider at \(window.editorPreviewPane.position) of \(room), expected \(expectedDivider())")
            #expect(window.preview.rootScroll.width >= MainWindow.minimumPreviewWidth, "\(step)")
        }
        expectPreviewWidth("launch")

        // The pane widens while the preview is away; GtkPaned would move
        // the divider by that when the preview comes back.
        window.setViewMode(.editor, animated: false)
        MainContext.pump(for: .milliseconds(100))
        window.toggleSidebarVisibility()
        MainContext.pump(for: .milliseconds(500))
        window.setViewMode(.split, animated: false)
        expectPreviewWidth("sidebar hidden in the editor")

        window.setViewMode(.editor, animated: false)
        MainContext.pump(for: .milliseconds(100))
        window.toggleSidebarVisibility()
        MainContext.pump(for: .milliseconds(500))
        window.setViewMode(.split, animated: false)
        expectPreviewWidth("sidebar shown in the editor")

        // Back while the sidebar still slides out: laid out in the room it
        // leaves at first, the preview would keep that width.
        window.setViewMode(.editor, animated: false)
        MainContext.pump(for: .milliseconds(100))
        window.toggleSidebarVisibility()
        MainContext.pump(for: .milliseconds(20))
        window.setViewMode(.split, animated: false)
        expectPreviewWidth("split while the sidebar slides out")
    }

    @Test("An opened file's split preview gets its width beside a shown outline") @MainActor
    func anOpenedFilesSplitPreviewGetsItsWidthBesideAShownOutline() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let fileURL = temp.appendingPathComponent("Wide.md", isDirectory: false)
        try "# Wide\n\n## Section\n\nBody".write(to: fileURL, atomically: true, encoding: .utf8)
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.panelayout.external")
        try app.register()
        let window = try ExternalDocumentWindow(
            application: app, fileURL: fileURL, renderer: MarkdownRenderer(), autosave: AutosaveCoordinator()
        )
        // Wider than a headless test monitor would let it be by default.
        window.window.setSizeRequest(width: 1400, height: 900)
        window.present()
        Self.waitUntil(timeout: .seconds(2)) { window.editorPreviewPane.width > 0 }
        // Show the outline while the preview is away, then bring the
        // preview back beside it.
        window.debugSetViewMode(.editor)
        MainContext.pump(for: .milliseconds(100))
        window.toggleOutlineVisibility()
        MainContext.pump(for: .milliseconds(500))
        window.debugSetViewMode(.split)

        func previewWidthMiss() -> Int {
            let room = window.editorPreviewPane.width
            let expected = MainWindow.resolvedPreviewWidth(storedWidth: WorkspaceState.defaultPreviewWidth, availableWidth: room)
            return abs(room - window.editorPreviewPane.position - expected)
        }
        Self.waitUntil(timeout: .seconds(2)) { previewWidthMiss() <= 12 }
        #expect(previewWidthMiss() <= 12, "divider at \(window.editorPreviewPane.position) of \(window.editorPreviewPane.width)")
        #expect(window.preview.rootScroll.width >= MainWindow.minimumPreviewWidth)
    }

    @MainActor
    private static func waitUntil(
        timeout: Duration,
        step: Duration = .milliseconds(10),
        _ condition: @MainActor () -> Bool
    ) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            MainContext.pump(for: step)
        }
    }
}
#endif
