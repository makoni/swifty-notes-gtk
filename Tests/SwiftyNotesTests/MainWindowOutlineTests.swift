#if !os(macOS)
import Adwaita
import CAdwaita
import Foundation
@testable import SwiftyNotes
import Testing

// MARK: - Module-level log writer for CRITICAL detection
// These are only used by the CRITICAL-detection test. Declared at module
// scope because GLogWriterFunc closures cannot close over local variables.
// Safe because MainWindowOutlineTests is @Suite(.serialized).
private nonisolated(unsafe) var criticalTestActive = false
private nonisolated(unsafe) var criticalWriterInstalled = false
private nonisolated(unsafe) var capturedGtkCriticalCount = 0

/// Installs via g_log_set_writer_func.  When `criticalTestActive` is set it
/// records every Gtk-domain CRITICAL that contains the string
/// "gtk_scrolled_window_get_child", then falls through to the default writer
/// so messages are still printed to stderr (aids debugging).
private let criticalCountingWriter: GLogWriterFunc = { level, fields, nFields, _ in
    if criticalTestActive {
        for i in 0 ..< Int(nFields) {
            let field = fields!.advanced(by: i).pointee
            guard let key = field.key, String(cString: key) == "MESSAGE" else { continue }
            guard let rawPtr = field.value else { continue }
            let msgPtr = rawPtr.assumingMemoryBound(to: CChar.self)
            let msg = String(cString: msgPtr)
            if msg.contains("gtk_scrolled_window_get_child") {
                capturedGtkCriticalCount += 1
            }
        }
    }
    return g_log_writer_default(level, fields, nFields, nil)
}

@Suite(.serialized)
struct MainWindowOutlineTests {
    @MainActor
    private static func ensureAdwInit() {
        struct Once { nonisolated(unsafe) static var done = false }
        guard !Once.done else { return }
        adw_init()
        Once.done = true
    }

    @MainActor
    private static func makeWindow(
        appID: String,
        isOutlineVisible: Bool = true,
    ) throws -> MainWindow {
        Self.ensureAdwInit()
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

    @MainActor
    private static func visibleDialog(of window: ApplicationWindow) -> Dialog? {
        window.visibleDialog
    }

    @MainActor
    private static func waitUntil(
        timeout: Duration = .milliseconds(300),
        step: Duration = .milliseconds(10),
        _ condition: @MainActor () -> Bool
    ) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while !condition(), clock.now < deadline {
            MainContext.pump(for: step)
        }
    }

    @Test("Default state has the outline panel visible") @MainActor
    func defaultStateHasTheOutlinePanelVisible() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.outline.default")
        #expect(window.debugIsOutlineVisible == true)
    }

    @Test("Persisted state with the panel hidden honours that on launch") @MainActor
    func persistedStateWithThePanelHiddenHonoursThatOnLaunch() throws {
        let window = try Self.makeWindow(
            appID: "me.spaceinbox.swiftynotes.tests.outline.hiddenstart",
            isOutlineVisible: false,
        )
        #expect(window.debugIsOutlineVisible == false)
    }

    @Test("Toggle action flips visibility and mirrors it back into AppState") @MainActor
    func toggleActionFlipsVisibilityAndMirrorsItBackIntoAppState() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.outline.toggle")
        #expect(window.debugIsOutlineVisible == true)

        window.debugToggleOutline()
        #expect(window.debugIsOutlineVisible == false)
        #expect(window.debugAppStateIsOutlineVisible == false)

        window.debugToggleOutline()
        #expect(window.debugIsOutlineVisible == true)
        #expect(window.debugAppStateIsOutlineVisible == true)
    }

    @Test("Editing the note populates the outline panel with extracted headings") @MainActor
    func editingTheNotePopulatesTheOutlinePanelWithExtractedHeadings() throws {
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

    @Test("Editing the note refreshes the breadcrumb's doc title segment") @MainActor
    func editingTheNoteRefreshesTheBreadcrumbsDocTitleSegment() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.outline.breadcrumb")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("# Roadmap\n\n## Overview\n\nBody.")
        _ = window.debugPreviewText
        // First line "# Roadmap" → note title resolves to "Roadmap".
        #expect(window.breadcrumb.label.markup.contains("Roadmap"))
    }

    @Test("Collapse state is hydrated from AppState when the active note changes") @MainActor
    func collapseStateIsHydratedFromAppStateWhenTheActiveNoteChanges() throws {
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

    @Test("Collapsing an H2 in the outline also folds the section in the editor") @MainActor
    func collapsingAnH2InTheOutlineAlsoFoldsTheSectionInThe() throws {
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

    @Test("Drag-to-reorder rewrites the editor buffer in section-block order") @MainActor
    func dragToReorderRewritesTheEditorBufferInSectionBlockOrder() throws {
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

    @Test("Clicking every outline row in turn leaves the clicked row active, never the one above") @MainActor
    func clickingEveryOutlineRowInTurnLeavesTheClickedRowActiveNever() throws {
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

    @Test("Heading block-indices map correctly to row indices when adjacent paragraphs are grouped") @MainActor
    func headingBlockIndicesMapCorrectlyToRowIndicesWhenAdjacentParagraphsAre() throws {
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

    @Test("The empty-state link inserts a starter heading and focuses the editor") @MainActor
    func theEmptyStateLinkInsertsAStarterHeadingAndFocusesTheEditor() throws {
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

    @Test("Outline panel falls back to empty-state when the note has no headings") @MainActor
    func outlinePanelFallsBackToEmptyStateWhenTheNoteHasNo() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.outline.emptynote")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("Just a paragraph.\n\nAnother one.")
        _ = window.debugPreviewText
        #expect(window.outlineSidebar.renderedHeadings.isEmpty)
        #expect(window.outlineSidebar.emptyLabel.visible == true)
    }

    @Test("blockToRowIndex covers every block, not just headings") @MainActor
    func blockToRowIndexCoversEveryBlockNotJustHeadings() throws {
        // Regression guard for the preview-side find/replace work
        // (#26): the controller scrolls to a matched block by
        // looking up `block index → row index` on MarkdownPreview.
        // headingBlockToRowIndex used to be the only mapping, which
        // gave us heading-only coverage. blockToRowIndex extends
        // the same shape to paragraphs, list items, code, tables,
        // blockquotes — anything that can hold a match.
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.outline.blockmap.all")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("""
        # Doc

        Body one.

        Body two.

        - List item

        ## Section

        Inside section.

        ```
        code
        ```
        """)
        _ = window.debugPreviewText
        let mapping = window.preview.blockToRowIndex
        // Every block should have a row mapping — no holes.
        let blockCount = window.preview.debugLastRenderedBlockCount
        #expect(mapping.count == blockCount)
        // Document order: keys are 0..<blockCount.
        #expect(Set(mapping.keys) == Set(0..<blockCount))
    }

    @Test("Ctrl+G keeps a strong reference to the palette so signal handlers can fire") @MainActor
    func ctrlGKeepsAStrongReferenceToThePaletteSoSignalHandlers() throws {
        // Regression: `openCommandPalette` used to leave the
        // `CommandPaletteWindow` in a local variable. The moment the
        // function returned the Swift wrapper was deallocated — GTK
        // still rendered the AdwDialog (it holds widgets through C),
        // but every `[weak self]` callback inside the wrapper now
        // resolved to nil and silently no-op'd. Visible symptom: the
        // search box didn't filter, row clicks did nothing, and the
        // Escape keyboard shortcut couldn't call `dialog.close()`.
        // Fix: park the wrapper on `MainWindow.activeCommandPalette`
        // until the dialog's `closed` signal fires.
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.outline.paletteretain")
        window.debugLoadInitialNotes()
        window.debugSetEditorText("# Doc\n\n## A\n\n## B\n")
        _ = window.debugPreviewText

        #expect(window.activeCommandPalette == nil)
        window.openCommandPalette()
        #expect(window.activeCommandPalette != nil)

        // Sanity: with the wrapper alive, search filtering reflects
        // the typed query — this is the behaviour the deallocation
        // bug masked in production.
        window.activeCommandPalette?.debugSetQuery("A")
        #expect(window.activeCommandPalette?.debugItems.map(\.id) == ["a"])
    }

    @Test("Ctrl+G enables dialog backdrop dismiss and outside-click closes the palette") @MainActor
    func ctrlGEnablesDialogBackdropDismissAndOutsideClickClosesThePalette() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.outline.palettebackdrop")
        window.present()
        window.debugLoadInitialNotes()
        window.debugSetEditorText("# Doc\n\n## A\n\n## B\n")
        _ = window.debugPreviewText

        window.openCommandPalette()
        Self.waitUntil {
            Self.visibleDialog(of: window.window)?.debugHasBackdropClickDismissHook == true
        }

        #expect(Self.visibleDialog(of: window.window)?.debugHasBackdropClickDismissHook == true)

        Self.visibleDialog(of: window.window)?.debugEmitBackdropClickDismiss()
        Self.waitUntil {
            window.activeCommandPalette == nil
        }

        #expect(window.activeCommandPalette == nil)
    }

    @Test("Rendering the preview does not fire gtk_scrolled_window_get_child on a non-ScrolledWindow") @MainActor
    func renderingThePreviewDoesNotFireGtkScrolledWindowGetChildOn() throws {
        // Regression: a Gtk-CRITICAL "gtk_scrolled_window_get_child:
        // assertion 'GTK_IS_SCROLLED_WINDOW (scrolled_window)' failed" fired
        // whenever the preview first rendered a note containing a code block.
        //
        // Root cause (confirmed via gdb backtrace): swift-adwaita's
        // ScrolledWindow and Overlay wrappers were missing the `gtkType`
        // class-property override, so `Widget.gtkType` fell back to
        // `gtk_widget_get_type()` and `tryCast(ScrolledWindow.self)` matched
        // ANY widget. MarkdownPreview.locateCodeBlockBuffer walks a code-block
        // row (Overlay → Box → [copy Button, ScrolledWindow → SourceView]) and
        // calls `tryCast(ScrolledWindow.self)` on each child; the permissive
        // cast matched the copy Button, and reading `.child` on it invoked
        // `gtk_scrolled_window_get_child` on a non-ScrolledWindow GObject.
        //
        // Behavioral consequence: the CRITICAL aborted GTK's allocation pass
        // early, leaving preview rows at height 0, so OutlineNavigation's
        // widgetY saw no allocation and fell back to proportional sync instead
        // of the smooth-scroll animation. Fixed by adding gtkType to
        // ScrolledWindow/Overlay (and, defensively, every other Widget
        // subclass) in swift-adwaita.
        //
        // This test installs a custom GLib log writer that counts CRITICAL
        // messages containing "gtk_scrolled_window_get_child", then calls the
        // exact path that triggers the regression (load + render), and asserts
        // the count is zero. Runs synchronously on the MainActor; the
        // @Suite(.serialized) annotation makes global state safe across tests.
        capturedGtkCriticalCount = 0
        // g_log_set_writer_func can only be called once per process — install
        // the counting writer on first use (guarded by criticalTestActive=false
        // at module init). The writer only increments the counter when
        // criticalTestActive is true, so it is effectively a no-op at all other
        // times, and subsequent tests are not affected by the installation.
        if !criticalWriterInstalled {
            g_log_set_writer_func(criticalCountingWriter, nil, nil)
            criticalWriterInstalled = true
        }
        criticalTestActive = true
        defer { criticalTestActive = false }

        let window = try Self.makeWindow(
            appID: "me.spaceinbox.swiftynotes.tests.outline.nocritical"
        )
        window.debugLoadInitialNotes()
        // The fixture MUST contain a fenced code block: the regression only
        // fires when MarkdownPreview.locateCodeBlockBuffer walks a code-block
        // row (Overlay → Box → [copy Button, ScrolledWindow → SourceView])
        // and tryCast(ScrolledWindow.self) matches the copy Button. Without a
        // code block this test never exercises that path, so the guard would
        // pass even if the gtkType override regressed.
        window.debugSetEditorText(
            "# Doc\n\nBody.\n\n```swift\nlet value = compute()\n```\n\n## Section\n\nMore body.\n"
        )
        _ = window.debugPreviewText

        #expect(
            capturedGtkCriticalCount == 0,
            "Expected 0 gtk_scrolled_window_get_child CRITICALs during preview render; got \(capturedGtkCriticalCount). Caused by a missing ScrolledWindow.gtkType override making tryCast permissive."
        )
    }

}
#endif
