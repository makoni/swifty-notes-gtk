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
        defer { window.window.close() }
        window.setViewMode(.split, animated: false)
        Self.waitUntil(timeout: .seconds(2)) { window.editorPreviewPane.width > 0 && window.preview.rootScroll.width > 0 }
        MainContext.pump(for: .milliseconds(100))

        // The room is the pane's, the window less the sidebar and the
        // outline; counting the outline in pushed the divider right and left
        // the preview narrower than its content, clipping it. The editor
        // keeps at least its own minimum (its toolbar's).
        func expectedDivider() -> Int {
            let room = window.editorPreviewPane.width
            // The width the window remembers: a clamp by the editor's
            // minimum (a narrow room) is remembered like a drag.
            let previewWidth = PaneLayout.resolvedPreviewWidth(storedWidth: window.state.preferredPreviewWidth, availableWidth: room)
            var editorMinimum: Int32 = 0
            gtk_widget_measure(window.editorContent.widgetPointer, GTK_ORIENTATION_HORIZONTAL, -1, &editorMinimum, nil, nil, nil)
            return max(room - previewWidth, Int(editorMinimum))
        }
        func expectPreviewWidth(_ step: String) {
            Self.waitUntil(timeout: .seconds(2)) { abs(window.editorPreviewPane.position - expectedDivider()) <= 12 }
            // And still there once the layout has settled.
            MainContext.pump(for: .milliseconds(300))
            let room = window.editorPreviewPane.width
            #expect(abs(window.editorPreviewPane.position - expectedDivider()) <= 12, "\(step): divider at \(window.editorPreviewPane.position) of \(room), expected \(expectedDivider())")
            // What shows of the preview, not its allocation (never less than
            // its minimum; GtkPaned clips the rest).
            #expect(room - window.editorPreviewPane.position >= PaneLayout.minimumPreviewWidth, "\(step)")
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

        // The room grows while the divider settles: placed in the narrow
        // room first (the editor's minimum clamps the preview), it must
        // follow, not leave the preview at the clamped width — nor remember
        // that width as the user's.
        window.setViewMode(.editor, animated: false)
        MainContext.pump(for: .milliseconds(100))
        window.toggleSidebarVisibility()
        MainContext.pump(for: .milliseconds(500))
        window.state.setPreferredPreviewWidth(WorkspaceState.defaultPreviewWidth)
        window.setViewMode(.split, animated: false)
        MainContext.pump(for: .milliseconds(30))
        window.toggleSidebarVisibility()
        expectPreviewWidth("room grown while settling")
        #expect(window.state.preferredPreviewWidth == WorkspaceState.defaultPreviewWidth)
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
        defer { window.window.close() }
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
            let expected = PaneLayout.resolvedPreviewWidth(storedWidth: WorkspaceState.defaultPreviewWidth, availableWidth: room)
            return abs(room - window.editorPreviewPane.position - expected)
        }
        Self.waitUntil(timeout: .seconds(2)) { previewWidthMiss() <= 12 }
        MainContext.pump(for: .milliseconds(300))
        #expect(previewWidthMiss() <= 12, "divider at \(window.editorPreviewPane.position) of \(window.editorPreviewPane.width)")
        #expect(window.debugPreviewRoomWidth == window.editorPreviewPane.width)
        #expect(window.editorPreviewPane.width - window.editorPreviewPane.position >= PaneLayout.minimumPreviewWidth)

        // Showing the outline beside the preview keeps the width it
        // remembers: the room it measures excludes the outline.
        window.toggleOutlineVisibility()
        MainContext.pump(for: .milliseconds(500))
        window.toggleOutlineVisibility()
        MainContext.pump(for: .milliseconds(500))
        #expect(window.debugPreferredPreviewWidth == WorkspaceState.defaultPreviewWidth)
    }

    @Test("A dragged divider is remembered; one grabbed while it settles is the user's") @MainActor
    func aDraggedDividerIsRemembered() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.panelayout.drag")
        try app.register()
        let window = MainWindow(
            application: app,
            state: AppState(persistedState: WorkspaceState(isOutlineVisible: false)),
            stateStore: WorkspaceStateStore(stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )
        window.debugLoadInitialNotes()
        window.window.setSizeRequest(width: 1400, height: 900)
        window.present()
        defer { window.window.close() }
        window.setViewMode(.split, animated: false)
        let divider = window.previewPaneDivider
        Self.waitUntil(timeout: .seconds(2)) { window.editorPreviewPane.width > 0 && !divider.isRestoring }
        MainContext.pump(for: .milliseconds(200))

        // Shown, the room is the pane's own width, not the window-based
        // estimate (on CI that was 8 px over: the sidebar's border).
        #expect(window.currentPreviewContainerWidth == window.editorPreviewPane.width)

        // A drag: the preview's new width is remembered.
        let room = window.editorPreviewPane.width
        window.editorPreviewPane.position = room - 500
        #expect(window.state.preferredPreviewWidth == 500)

        // Placing it back after Editor → Split is layout, not a drag.
        window.setViewMode(.editor, animated: false)
        window.setViewMode(.split, animated: false)
        #expect(divider.isRestoring)
        window.editorPreviewPane.position = room - 450
        #expect(window.state.preferredPreviewWidth == 500)

        // Grabbing the handle while it settles hands it to the user.
        divider.pointerPressed(atX: Double(window.editorPreviewPane.position))
        #expect(!divider.isRestoring)
        #expect(!divider.isSettling)
        window.editorPreviewPane.position = room - 420
        #expect(window.state.preferredPreviewWidth == 420)
        MainContext.pump(for: .milliseconds(300))
        #expect(window.editorPreviewPane.position == room - 420, "the settle took the divider back")

        // Grabbing it while the preview slides in stops the slide.
        window.setViewMode(.editor, animated: false)
        MainContext.pump(for: .milliseconds(100))
        window.setViewMode(.split, animated: true)
        #expect(divider.isRestoring, "sliding in")
        divider.pointerPressed(atX: Double(window.editorPreviewPane.position))
        #expect(!divider.isRestoring)
        let grabbedAt = window.editorPreviewPane.position
        MainContext.pump(for: .milliseconds(400))
        // (GtkPaned may nudge it into its bounds; the slide would take it
        // hundreds of pixels.)
        #expect(abs(window.editorPreviewPane.position - grabbedAt) <= 12, "the slide went on")

        // Right to left the pane mirrors, and so does the handle.
        gtk_widget_set_direction(window.editorPreviewPane.widgetPointer, GTK_TEXT_DIR_RTL)
        defer { gtk_widget_set_direction(window.editorPreviewPane.widgetPointer, GTK_TEXT_DIR_NONE) }
        window.setViewMode(.editor, animated: false)
        window.setViewMode(.split, animated: false)
        #expect(divider.isRestoring)
        let mirroredHandle = Double(window.editorPreviewPane.width - window.editorPreviewPane.position)
        divider.pointerPressed(atX: Double(window.editorPreviewPane.position))
        #expect(divider.isRestoring, "a press where the handle would be left to right")
        divider.pointerPressed(atX: mirroredHandle)
        #expect(!divider.isRestoring, "a press on the mirrored handle")
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
