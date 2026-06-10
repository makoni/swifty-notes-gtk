#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

struct BreadcrumbStripTests {
    @MainActor
    private static func makeStrip(suffix: String) throws -> BreadcrumbStrip {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.breadcrumb.\(suffix)")
        try app.register()
        return BreadcrumbStrip()
    }

    @Test("With no active heading, only the doc title is visible") @MainActor
    func withNoActiveHeadingOnlyTheDocTitleIsVisible() throws {
        let strip = try Self.makeStrip(suffix: "noactive")
        strip.update(
            docTitle: "Q3 Roadmap",
            headings: [
                .init(id: "overview", level: 2, text: "Overview", blockIndex: 0, line: 1),
            ],
            activeID: nil,
        )
        // Only the doc title contributes — no separator or section span.
        let markup = strip.label.markup
        #expect(markup.contains("Q3 Roadmap"))
        #expect(!markup.contains("›"))
    }

    @Test("H1 active heading lands in the section slot with no leaf") @MainActor
    func h1ActiveHeadingLandsInTheSectionSlotWithNoLeaf() throws {
        let strip = try Self.makeStrip(suffix: "h1")
        strip.update(
            docTitle: "Doc",
            headings: [.init(id: "intro", level: 1, text: "Intro", blockIndex: 0, line: 1)],
            activeID: "intro",
        )
        let markup = strip.label.markup
        #expect(markup.contains("Doc"))
        #expect(markup.contains("Intro"))
        // Doc › Intro, but no second chevron / leaf segment.
        #expect(markup.filter { $0 == "›" }.count == 1)
    }

    @Test("H2 active heading lands in the section slot with no leaf") @MainActor
    func h2ActiveHeadingLandsInTheSectionSlotWithNoLeaf() throws {
        let strip = try Self.makeStrip(suffix: "h2")
        strip.update(
            docTitle: "Doc",
            headings: [.init(id: "overview", level: 2, text: "Overview", blockIndex: 0, line: 1)],
            activeID: "overview",
        )
        let markup = strip.label.markup
        #expect(markup.contains("Overview"))
        #expect(markup.filter { $0 == "›" }.count == 1)
    }

    @Test("H3 active heading uses the most recent H2 as its section") @MainActor
    func h3ActiveHeadingUsesTheMostRecentH2AsItsSection() throws {
        let strip = try Self.makeStrip(suffix: "h3parent")
        let headings: [Heading] = [
            .init(id: "doc",      level: 1, text: "Doc",       blockIndex: 0, line: 1),
            .init(id: "overview", level: 2, text: "Overview",  blockIndex: 1, line: 3),
            .init(id: "goals",    level: 3, text: "Goals",     blockIndex: 2, line: 5),
            .init(id: "features", level: 2, text: "Features",  blockIndex: 3, line: 7),
            .init(id: "outline",  level: 3, text: "Outline",   blockIndex: 4, line: 9),
        ]
        // Activate Goals — its parent is Overview, not Features.
        strip.update(docTitle: "Doc", headings: headings, activeID: "goals")
        var markup = strip.label.markup
        #expect(markup.contains("Doc"))
        #expect(markup.contains("Overview"))
        #expect(markup.contains("Goals"))
        // Two chevrons: doc › section › leaf.
        #expect(markup.filter { $0 == "›" }.count == 2)

        // Activate Outline — its parent is Features.
        strip.update(docTitle: "Doc", headings: headings, activeID: "outline")
        markup = strip.label.markup
        #expect(markup.contains("Features"))
        #expect(markup.contains("Outline"))
    }

    @Test("Update no-ops when the doc title, section, and leaf are unchanged") @MainActor
    func updateNoOpsWhenTheDocTitleSectionAndLeafAreUnchanged() throws {
        // Performance regression guard: scroll-spy calls this ~60/s
        // during a kinetic scroll, almost always with the same tuple.
        let strip = try Self.makeStrip(suffix: "memo")
        strip.update(docTitle: "Doc", section: "Section", leaf: "Leaf")
        let originalLabelPtr = strip.label.opaquePointer
        let originalMarkup = strip.label.markup
        strip.update(docTitle: "Doc", section: "Section", leaf: "Leaf")
        // Same widget identity (no replacement) and same markup state.
        #expect(strip.label.opaquePointer == originalLabelPtr)
        #expect(strip.label.markup == originalMarkup)
        // Changing one field must flow through.
        strip.update(docTitle: "Doc", section: "Section", leaf: "Other")
        #expect(strip.label.markup.contains("Other"))
    }

    @Test("Empty doc title hides the leading segment and its chevron") @MainActor
    func emptyDocTitleHidesTheLeadingSegmentAndItsChevron() throws {
        let strip = try Self.makeStrip(suffix: "emptydoc")
        strip.update(docTitle: "", section: "Section", leaf: nil)
        let markup = strip.label.markup
        // No doc title means no leading chevron either — the markup
        // starts straight with the section span.
        #expect(!markup.contains("›"))
        #expect(markup.contains("Section"))
    }

    @Test("Pango-special characters in headings are escaped, not interpreted") @MainActor
    func pangoSpecialCharactersInHeadingsAreEscapedNotInterpreted() throws {
        let strip = try Self.makeStrip(suffix: "escape")
        // Headings with `&`, `<`, `>` would crash Pango if passed raw
        // into a `markup` string. They have to be entity-escaped.
        strip.update(docTitle: "A & B", section: "<x>", leaf: nil)
        let markup = strip.label.markup
        #expect(markup.contains("A &amp; B"))
        #expect(markup.contains("&lt;x&gt;"))
    }
}
#endif
