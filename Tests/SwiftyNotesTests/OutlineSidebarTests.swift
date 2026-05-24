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
}
#endif
