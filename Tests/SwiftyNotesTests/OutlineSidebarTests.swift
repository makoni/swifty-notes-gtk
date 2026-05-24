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

    @Test @MainActor
    func `empty headings render the empty-state hint and a zero badge`() throws {
        let outline = try Self.makeOutline(suffix: "empty")
        outline.render(headings: [])
        #expect(outline.countBadge.text == "0")
        #expect(outline.footerLabel.text == "0 sections · 0 subsections")
        #expect(outline.emptyLabel.visible == true)
        // Pango markup carries the inline-code styling for `## Heading`.
        #expect(outline.emptyLabel.text.contains("<tt>## Heading</tt>"))
    }

    @Test @MainActor
    func `non-empty headings hide the empty-state and update the count`() throws {
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

    @Test @MainActor
    func `footer copes with singular vs plural counts`() throws {
        let outline = try Self.makeOutline(suffix: "plurals")
        outline.render(headings: [
            .init(id: "overview", level: 2, text: "Overview", blockIndex: 0, line: 1),
            .init(id: "goals",    level: 3, text: "Goals",    blockIndex: 1, line: 3),
        ])
        #expect(outline.footerLabel.text == "1 section · 1 subsection")
    }

    @Test @MainActor
    func `render builds one ListBox row per heading and exposes them by index`() throws {
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

    @Test @MainActor
    func `setActiveHeading records the active id for later highlight`() throws {
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

    @Test @MainActor
    func `setting a query filters the visible rows via OutlineFilter`() throws {
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

    @Test @MainActor
    func `toggling collapse hides H3 children of that H2`() throws {
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

    @Test @MainActor
    func `toggling collapse on non-H2 is a no-op`() throws {
        let outline = try Self.makeOutline(suffix: "collapse-h3")
        outline.setHeadings([
            .init(id: "overview", level: 2, text: "Overview", blockIndex: 0, line: 1),
            .init(id: "goals",    level: 3, text: "Goals",    blockIndex: 1, line: 3),
        ])
        outline.toggleCollapsed("goals")
        #expect(outline.collapsedSections.isEmpty)
    }

    @Test @MainActor
    func `deeply nested H4 through H6 headings all render rows`() throws {
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

    @Test @MainActor
    func `setHeadings prunes collapse entries for removed H2 sections`() throws {
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
