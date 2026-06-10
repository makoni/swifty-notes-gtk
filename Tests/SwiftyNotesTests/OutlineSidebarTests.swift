#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

struct OutlineSidebarTests {
    @MainActor
    private static func makeOutline(suffix: String) throws -> OutlineSidebar {
        // Each test gets its own GApplication id — without registering
        // one, GTK isn't initialised and constructing widgets segfaults
        // inside libgtk.
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.outline.\(suffix)")
        try app.register()
        return OutlineSidebar()
    }

    @Test("Empty headings render the empty-state hint and a zero badge") @MainActor
    func emptyHeadingsRenderTheEmptyStateHintAndAZeroBadge() throws {
        let outline = try Self.makeOutline(suffix: "empty")
        outline.render(headings: [])
        #expect(outline.countBadge.text == "0")
        #expect(outline.footerLabel.text == "0 sections · 0 subsections")
        #expect(outline.emptyLabel.visible == true)
        // Pango markup carries the inline-code styling for `## Heading`
        // *and* the `<a href>` hyperlink for the insert handler. Has to
        // live in `.markup` (not `.text`) — `gtk_label_set_text` strips
        // markup.
        #expect(outline.emptyLabel.markup.contains("<tt>## Heading</tt>"))
        #expect(outline.emptyLabel.markup.contains("href=\"insert-heading\""))
    }

    @Test("Non-empty headings hide the empty-state and update the count") @MainActor
    func nonEmptyHeadingsHideTheEmptyStateAndUpdateTheCount() throws {
        let outline = try Self.makeOutline(suffix: "non-empty")
        outline.render(headings: [
            .init(id: "intro",    level: 1, text: "Intro",    blockIndex: 0, line: 1),
            .init(id: "overview", level: 2, text: "Overview", blockIndex: 1, line: 3),
            .init(id: "goals",    level: 3, text: "Goals",    blockIndex: 2, line: 5),
            .init(id: "non",      level: 3, text: "Non-goals", blockIndex: 3, line: 7),
        ])
        #expect(outline.countBadge.text == "4")
        #expect(outline.emptyLabel.visible == false)
        // Footer counts only H2/H3 (the design's "sections / subsections"
        // model). H1 is the doc-level heading and intentionally omitted.
        #expect(outline.footerLabel.text == "1 section · 2 subsections")
    }

    @Test("Footer copes with singular vs plural counts") @MainActor
    func footerCopesWithSingularVsPluralCounts() throws {
        let outline = try Self.makeOutline(suffix: "plurals")
        outline.render(headings: [
            .init(id: "overview", level: 2, text: "Overview", blockIndex: 0, line: 1),
            .init(id: "goals",    level: 3, text: "Goals",    blockIndex: 1, line: 3),
        ])
        #expect(outline.footerLabel.text == "1 section · 1 subsection")
    }

    @Test("Render builds one ListBox row per heading and exposes them by index") @MainActor
    func renderBuildsOneListBoxRowPerHeadingAndExposesThemByIndex() throws {
        let outline = try Self.makeOutline(suffix: "rows")
        let headings: [Heading] = [
            .init(id: "intro",  level: 1, text: "Intro",  blockIndex: 0, line: 1),
            .init(id: "body",   level: 2, text: "Body",   blockIndex: 1, line: 3),
            .init(id: "goals",  level: 3, text: "Goals",  blockIndex: 2, line: 5),
        ]
        outline.render(headings: headings)
        #expect(outline.renderedHeadings == headings)
        #expect(outline.heading(at: 0)?.id == "intro")
        #expect(outline.heading(at: 1)?.id == "body")
        #expect(outline.heading(at: 2)?.id == "goals")
        #expect(outline.heading(at: 99) == nil)
    }

    @Test("setActiveHeading records the active id for later highlight") @MainActor
    func setActiveHeadingRecordsTheActiveIdForLaterHighlight() throws {
        let outline = try Self.makeOutline(suffix: "active")
        outline.render(headings: [
            .init(id: "intro", level: 1, text: "Intro", blockIndex: 0, line: 1),
        ])
        #expect(outline.activeHeadingID == nil)
        outline.setActiveHeading("intro")
        #expect(outline.activeHeadingID == "intro")
        outline.setActiveHeading(nil)
        #expect(outline.activeHeadingID == nil)
    }

    @Test("Setting a query filters the visible rows via OutlineFilter") @MainActor
    func settingAQueryFiltersTheVisibleRowsViaOutlineFilter() throws {
        let outline = try Self.makeOutline(suffix: "query")
        outline.setHeadings([
            .init(id: "doc",      level: 1, text: "Doc",       blockIndex: 0, line: 1),
            .init(id: "overview", level: 2, text: "Overview",  blockIndex: 1, line: 3),
            .init(id: "goals",    level: 3, text: "Goals",     blockIndex: 2, line: 5),
            .init(id: "features", level: 2, text: "Features",  blockIndex: 3, line: 7),
        ])
        outline.setQuery("over")
        #expect(outline.renderedHeadings.map(\.id) == ["overview"])
        #expect(outline.allHeadings.count == 4) // unfiltered storage unchanged
        outline.setQuery("")
        #expect(outline.renderedHeadings.count == 4)
    }

    @Test("Toggling collapse hides H3 children of that H2") @MainActor
    func togglingCollapseHidesH3ChildrenOfThatH2() throws {
        let outline = try Self.makeOutline(suffix: "collapse")
        outline.setHeadings([
            .init(id: "overview", level: 2, text: "Overview",  blockIndex: 0, line: 1),
            .init(id: "goals",    level: 3, text: "Goals",     blockIndex: 1, line: 3),
            .init(id: "non",      level: 3, text: "Non-goals", blockIndex: 2, line: 5),
            .init(id: "features", level: 2, text: "Features",  blockIndex: 3, line: 7),
        ])
        outline.toggleCollapsed("overview")
        #expect(outline.collapsedSections.contains("overview"))
        #expect(outline.renderedHeadings.map(\.id) == ["overview", "features"])
        outline.toggleCollapsed("overview")
        #expect(outline.collapsedSections.isEmpty)
        #expect(outline.renderedHeadings.map(\.id) == ["overview", "goals", "non", "features"])
    }

    @Test("Toggling collapse on non-H2 is a no-op") @MainActor
    func togglingCollapseOnNonH2IsANoOp() throws {
        let outline = try Self.makeOutline(suffix: "collapse-h3")
        outline.setHeadings([
            .init(id: "overview", level: 2, text: "Overview", blockIndex: 0, line: 1),
            .init(id: "goals",    level: 3, text: "Goals",    blockIndex: 1, line: 3),
        ])
        outline.toggleCollapsed("goals")
        #expect(outline.collapsedSections.isEmpty)
    }

    @Test("setActiveHeading early-exits and does not rebuild rows on no-op") @MainActor
    func setActiveHeadingEarlyExitsAndDoesNotRebuildRowsOnNoOp() throws {
        // Performance regression guard: the scroll-spy fires this
        // method ~30/s during a kinetic scroll, often with the same
        // id back-to-back. Touching `list.removeAll` + re-appending
        // 8 rows on every tick (the original implementation) tanks
        // FPS on long notes. The contract is: same-id calls must be
        // no-ops and different-id calls must not rebuild rows.
        let outline = try Self.makeOutline(suffix: "noop")
        outline.setHeadings([
            .init(id: "a", level: 2, text: "A", blockIndex: 0, line: 1),
            .init(id: "b", level: 2, text: "B", blockIndex: 1, line: 3),
            .init(id: "c", level: 2, text: "C", blockIndex: 2, line: 5),
        ])
        // Capture the row identities. Storing the GObject pointer
        // (opaquePointer) catches widget rebuilds across activation
        // changes — if a row is replaced, the pointer changes.
        let originalRows = (0..<3).compactMap { outline.list.rowAt( $0)?.opaquePointer }
        #expect(originalRows.count == 3)

        outline.setActiveHeading("a")
        outline.setActiveHeading("a") // repeat
        outline.setActiveHeading("b")
        outline.setActiveHeading("c")
        outline.setActiveHeading(nil)

        let afterRows = (0..<3).compactMap { outline.list.rowAt( $0)?.opaquePointer }
        #expect(afterRows == originalRows, "row widgets must survive setActiveHeading toggles")
    }

    @Test("Clicked row stays selected in the ListBox after re-render") @MainActor
    func clickedRowStaysSelectedInTheListBoxAfterReRender() throws {
        // Regression: setActiveHeading used to clear the ListBox
        // selection via removeAll(), leaving the first row visually
        // selected even though scroll-spy / click had moved past it.
        let outline = try Self.makeOutline(suffix: "selection-persists")
        outline.setHeadings([
            .init(id: "a", level: 2, text: "A", blockIndex: 0, line: 1),
            .init(id: "b", level: 2, text: "B", blockIndex: 1, line: 3),
            .init(id: "c", level: 2, text: "C", blockIndex: 2, line: 5),
        ])
        outline.setActiveHeading("b")
        #expect(outline.list.selectedRow?.index == 1)
        outline.setActiveHeading("c")
        #expect(outline.list.selectedRow?.index == 2)
        outline.setActiveHeading(nil)
        #expect(outline.list.selectedRow == nil)
    }

    @Test("Search highlight uses Pango markup, not literal text") @MainActor
    func searchHighlightUsesPangoMarkupNotLiteralText() throws {
        // Regression: label.text uses gtk_label_set_text which strips
        // markup. The highlight has to land on label.markup instead.
        let outline = try Self.makeOutline(suffix: "search-markup")
        outline.setHeadings([
            .init(id: "overview", level: 2, text: "Overview", blockIndex: 0, line: 1),
        ])
        outline.setQuery("over")
        let label = outline.rowLabel(at: 0)
        #expect(label?.useMarkup == true)
        // `.markup` returns the markup string (the raw `<span…>…`).
        #expect(label?.markup.contains("<span") == true)
        // `.text` returns the rendered text — what the user actually
        // sees on screen — which must be the plain heading text, not
        // the raw markup.
        #expect(label?.text == "Overview")
    }

    @Test("Deeply nested H4 through H6 headings all render rows") @MainActor
    func deeplyNestedH4ThroughH6HeadingsAllRenderRows() throws {
        let outline = try Self.makeOutline(suffix: "deep")
        let deep: [Heading] = [
            .init(id: "h1", level: 1, text: "Document",  blockIndex: 0, line: 1),
            .init(id: "h2", level: 2, text: "Section",   blockIndex: 1, line: 3),
            .init(id: "h3", level: 3, text: "Sub",       blockIndex: 2, line: 5),
            .init(id: "h4", level: 4, text: "Sub-sub",   blockIndex: 3, line: 7),
            .init(id: "h5", level: 5, text: "Detail",    blockIndex: 4, line: 9),
            .init(id: "h6", level: 6, text: "Footnote",  blockIndex: 5, line: 11),
        ]
        outline.setHeadings(deep)
        #expect(outline.renderedHeadings.map(\.level) == [1, 2, 3, 4, 5, 6])
        // Collapse model still only governs the H2 — H4+ rows have an
        // H3 parent in some intervening section, but the collapse rule
        // is "hide H3+ under collapsed H2", which covers H4–H6 too.
        outline.toggleCollapsed("h2")
        #expect(outline.renderedHeadings.map(\.id) == ["h1", "h2"])
    }

    @Test("setHeadings prunes collapse entries for removed H2 sections") @MainActor
    func setHeadingsPrunesCollapseEntriesForRemovedH2Sections() throws {
        let outline = try Self.makeOutline(suffix: "prune")
        outline.setHeadings([
            .init(id: "overview", level: 2, text: "Overview", blockIndex: 0, line: 1),
            .init(id: "features", level: 2, text: "Features", blockIndex: 1, line: 3),
        ])
        outline.toggleCollapsed("overview")
        outline.toggleCollapsed("features")
        #expect(outline.collapsedSections == ["overview", "features"])
        // Replace with a new heading set that drops "features" — its
        // collapse entry should be gone so the set doesn't accumulate
        // stale ids across edits.
        outline.setHeadings([
            .init(id: "overview", level: 2, text: "Overview", blockIndex: 0, line: 1),
        ])
        #expect(outline.collapsedSections == ["overview"])
    }
}
#endif
