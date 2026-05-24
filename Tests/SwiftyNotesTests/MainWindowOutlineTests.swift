#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

struct MainWindowOutlineTests {
    @MainActor
    private static func makeWindow(
        appID: String,
        isOutlineVisible: Bool = true,
    ) throws -> MainWindow {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = Application(id: appID)
        try app.register()
        return MainWindow(
            application: app,
            state: AppState(persistedState: WorkspaceState(isOutlineVisible: isOutlineVisible)),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )
    }

    @Test @MainActor
    func `default state has the outline panel visible`() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.outline.default")
        #expect(window.debugIsOutlineVisible == true)
    }

    @Test @MainActor
    func `persisted state with the panel hidden honours that on launch`() throws {
        let window = try Self.makeWindow(
            appID: "me.spaceinbox.swiftynotes.tests.outline.hiddenstart",
            isOutlineVisible: false,
        )
        #expect(window.debugIsOutlineVisible == false)
    }

    @Test @MainActor
    func `toggle action flips visibility and mirrors it back into AppState`() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.outline.toggle")
        #expect(window.debugIsOutlineVisible == true)

        window.debugToggleOutline()
        #expect(window.debugIsOutlineVisible == false)
        #expect(window.debugAppStateIsOutlineVisible == false)

        window.debugToggleOutline()
        #expect(window.debugIsOutlineVisible == true)
        #expect(window.debugAppStateIsOutlineVisible == true)
    }

    @Test @MainActor
    func `editing the note populates the outline panel with extracted headings`() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.outline.populate")
        window.debugLoadInitialNotes()
        // Replace the seeded content with a tiny TOC-worthy doc so we
        // can assert specific heading rows without depending on whatever
        // shape the showcase seed happens to take.
        window.debugSetEditorText("""
        # Doc

        ## Overview

        Body.

        ## Features

        ### Outline

        Click to scroll.
        """)
        // Touch the deferred preview text to force a flush — the typing
        // refresh schedules through the GLib main loop, and reading the
        // outline before that flush would see stale headings from the
        // seed.
        _ = window.debugPreviewText
        let headings = window.outlineSidebar.renderedHeadings
        #expect(headings.map(\.id) == ["doc", "overview", "features", "outline"])
        #expect(headings.map(\.level) == [1, 2, 2, 3])
    }

    @Test @MainActor
    func `editing the note refreshes the breadcrumb's doc title segment`() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.outline.breadcrumb")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("# Roadmap\n\n## Overview\n\nBody.")
        _ = window.debugPreviewText
        // First line "# Roadmap" → note title resolves to "Roadmap".
        #expect(window.breadcrumb.docLabel.text == "Roadmap")
    }

    @Test @MainActor
    func `collapse state is hydrated from AppState when the active note changes`() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.outline.hydrate")
        window.debugLoadInitialNotes()
        guard let noteID = window.debugSelectedNoteID else {
            Issue.record("seed should select a note")
            return
        }
        // Seed AppState directly — that's where note transition hydrates from.
        window.debugAppState.collapsedOutlineSections[noteID] = ["overview"]
        window.debugAppState.recentOutlineJumps[noteID] = ["features", "goals"]

        // Force a refresh that simulates a fresh note transition by
        // clearing the cached current id then re-running refreshPreview.
        window.debugResetOutlineNoteID()
        window.debugSetEditorText("# Doc\n\n## Overview\n\n## Features\n\n## Goals\n")
        _ = window.debugPreviewText

        #expect(window.outlineSidebar.collapsedSections == ["overview"])
        #expect(window.debugOutlineRecentIDs == ["features", "goals"])
    }

    @Test @MainActor
    func `the empty-state link inserts a starter heading and focuses the editor`() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.outline.insertheading")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("Paragraph one.\n")
        _ = window.debugPreviewText
        let before = window.debugSelectedNoteContent ?? ""
        // Drive the activate-link handler directly — Pango simulates a
        // click on the `<a href="insert-heading">` segment.
        window.outlineSidebar.emptyStateInsertHandler()?()
        let after = window.debugSelectedNoteContent ?? ""
        #expect(after.contains("## Heading"))
        #expect(after.count > before.count)
    }

    @Test @MainActor
    func `outline panel falls back to empty-state when the note has no headings`() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.outline.emptynote")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("Just a paragraph.\n\nAnother one.")
        _ = window.debugPreviewText
        #expect(window.outlineSidebar.renderedHeadings.isEmpty)
        #expect(window.outlineSidebar.emptyLabel.visible == true)
    }
}
#endif
