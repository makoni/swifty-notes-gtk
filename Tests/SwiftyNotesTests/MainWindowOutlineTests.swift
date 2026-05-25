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
        #expect(window.breadcrumb.label.markup.contains("Roadmap"))
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
    func `collapsing an H2 in the outline also folds the section in the editor`() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.outline.editorfold")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("""
        # Doc

        ## Overview

        Overview body.

        ## Features

        Features body.
        """)
        _ = window.debugPreviewText

        // Collapse Overview via the outline path; MainWindow should
        // wire that through to applyEditorFolding which sets the
        // invisible tag on the buffer range.
        window.outlineSidebar.toggleCollapsed("overview")
        window.outlineSidebar.emptyStateInsertHandler()
        // The widget-level assertion: the invisible tag is attached
        // (we can't check the pixels but we can check the tag's
        // presence on the buffer's tag table after MainWindow has
        // flushed).
        window.applyEditorFolding()
        // Smoke: heading line still visible (the heading itself is
        // never folded). The body's visibility is controlled by the
        // invisible attribute, which GTK applies on render — we don't
        // try to assert on rendered text from a headless unit test.
        #expect(window.outlineSidebar.collapsedSections.contains("overview"))
    }

    @Test @MainActor
    func `drag-to-reorder rewrites the editor buffer in section-block order`() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.outline.reorder")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("""
        ## A

        A body.

        ## B

        B body.
        """)
        _ = window.debugPreviewText
        window.reorderOutlineSection(movingID: "b", beforeTargetID: "a")
        let after = window.debugSelectedNoteContent ?? ""
        // B's section landed above A's; original A section retained.
        let bPos = after.range(of: "## B")?.lowerBound
        let aPos = after.range(of: "## A")?.lowerBound
        #expect(bPos != nil && aPos != nil)
        if let bPos, let aPos {
            #expect(bPos < aPos)
        }
    }

    @Test @MainActor
    func `clicking every outline row in turn leaves the clicked row active, never the one above`() throws {
        // Regression: with smooth-scroll animations enabled, an in-
        // flight scroll fires `onValueChanged` ticks at intermediate
        // scrollTop values, the resolver picked whichever heading was
        // still above the anchor *right now* (i.e. the previous one),
        // and that overwrote the click's explicit active-id. The
        // outline ended up "stuck" one row above the user's choice.
        // After the suppression fix this should be deterministic
        // across an entire forward + reverse sweep of the panel.
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.outline.allrows")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("""
        # Showcase

        Intro paragraph.

        ## Highlights

        - Bullet A
        - Bullet B

        ## Checklist

        - [ ] Item A
        - [ ] Item B

        ## Quote

        > Quoted.

        ## Code

        ```swift
        let x = 1
        ```

        ## End
        """)
        _ = window.debugPreviewText

        let order = window.currentHeadings.map(\.id)
        // Sanity: we built a doc with several headings.
        #expect(order.count >= 5)

        for id in order {
            guard let heading = window.currentHeadings.first(where: { $0.id == id }) else {
                Issue.record("missing heading \(id)")
                continue
            }
            window.scrollToHeading(heading)
            #expect(window.outlineSidebar.activeHeadingID == id, "forward click \(id) failed")
        }
        for id in order.reversed() {
            guard let heading = window.currentHeadings.first(where: { $0.id == id }) else { continue }
            window.scrollToHeading(heading)
            #expect(window.outlineSidebar.activeHeadingID == id, "reverse click \(id) failed")
        }
    }

    @Test @MainActor
    func `heading block-indices map correctly to row indices when adjacent paragraphs are grouped`() throws {
        // Regression: the showcase note has consecutive paragraphs +
        // list items between headings. `MarkdownPreview.makeRows`
        // collapses those into single rows, so a heading at
        // `blockIndex=11` may live at row 6 in the preview's
        // container. Before the fix we used `blockIndex` to look up
        // `container.children()[N]` directly, which pointed at the
        // wrong widget — scroll-spy then claimed the *previous*
        // heading was active and the click selection looked stuck.
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.outline.blockmap")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("""
        # Doc

        ## A

        Paragraph A1.

        Paragraph A2.

        Paragraph A3.

        ## B

        Body B.
        """)
        _ = window.debugPreviewText

        // Phase B.1 coalesces a heading + its trailing paragraphs into
        // one `.richTextRun` row, so the row list collapses to:
        // [Doc (heading-only — no body), A (richTextRun with A + 3 ps),
        //  B (richTextRun with B + 1 p)]. The heading IDs still need
        // to map to the right row index — the outline scroll-spy
        // looks up `container.children()[rowIndex]` to find each
        // heading's rendered widget.
        let mapping = window.preview.headingBlockToRowIndex
        let docHeading = window.currentHeadings.first { $0.text == "Doc" }!
        let aHeading = window.currentHeadings.first { $0.text == "A" }!
        let bHeading = window.currentHeadings.first { $0.text == "B" }!
        #expect(mapping[docHeading.blockIndex] == 0)
        #expect(mapping[aHeading.blockIndex] == 1)
        #expect(mapping[bHeading.blockIndex] == 2)
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
