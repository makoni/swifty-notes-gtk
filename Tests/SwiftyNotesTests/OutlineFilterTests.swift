import Foundation
@testable import SwiftyNotes
import Testing

struct OutlineFilterTests {
    /// Document shape:
    ///   H1 Doc
    ///   H2 Overview
    ///     H3 Goals
    ///     H3 Non-goals
    ///   H2 Features
    ///     H3 Outline
    ///     H3 Search
    private let document: [Heading] = [
        .init(id: "doc",       level: 1, text: "Doc",        blockIndex: 0, line: 1),
        .init(id: "overview",  level: 2, text: "Overview",   blockIndex: 1, line: 3),
        .init(id: "goals",     level: 3, text: "Goals",      blockIndex: 2, line: 5),
        .init(id: "non-goals", level: 3, text: "Non-goals",  blockIndex: 3, line: 7),
        .init(id: "features",  level: 2, text: "Features",   blockIndex: 4, line: 9),
        .init(id: "outline",   level: 3, text: "Outline",    blockIndex: 5, line: 11),
        .init(id: "search",    level: 3, text: "Search",     blockIndex: 6, line: 13),
    ]

    @Test("With empty query and empty collapsed set, returns everything")
    func withEmptyQueryAndEmptyCollapsedSetReturnsEverything() {
        let visible = OutlineFilter.visible(headings: document, query: "", collapsed: [])
        #expect(visible.map(\.id) == ["doc", "overview", "goals", "non-goals", "features", "outline", "search"])
    }

    @Test("Collapsing an H2 hides its H3 children but keeps siblings")
    func collapsingAnH2HidesItsH3ChildrenButKeepsSiblings() {
        let visible = OutlineFilter.visible(headings: document, query: "", collapsed: ["overview"])
        #expect(visible.map(\.id) == ["doc", "overview", "features", "outline", "search"])
    }

    @Test("Collapsing both H2 sections hides every H3")
    func collapsingBothH2SectionsHidesEveryH3() {
        let visible = OutlineFilter.visible(headings: document, query: "", collapsed: ["overview", "features"])
        #expect(visible.map(\.id) == ["doc", "overview", "features"])
    }

    @Test("A non-empty query filters by case-insensitive substring on text")
    func aNonEmptyQueryFiltersByCaseInsensitiveSubstringOnText() {
        let visible = OutlineFilter.visible(headings: document, query: "go", collapsed: [])
        #expect(visible.map(\.id) == ["goals", "non-goals"])
    }

    @Test("Query ignores the collapsed set so matches under a collapsed section still surface")
    func queryIgnoresTheCollapsedSetSoMatchesUnderACollapsedSectionStill() {
        // The user collapsed Overview but searches for "goals" — they
        // would expect to find them anyway.
        let visible = OutlineFilter.visible(headings: document, query: "goals", collapsed: ["overview"])
        #expect(visible.map(\.id) == ["goals", "non-goals"])
    }

    @Test("Query is case-insensitive and trims leading and trailing whitespace")
    func queryIsCaseInsensitiveAndTrimsLeadingAndTrailingWhitespace() {
        #expect(OutlineFilter.visible(headings: document, query: "OUTLINE", collapsed: []).map(\.id) == ["outline"])
        #expect(OutlineFilter.visible(headings: document, query: "  outline  ", collapsed: []).map(\.id) == ["outline"])
    }

    @Test("Query with no matches returns empty")
    func queryWithNoMatchesReturnsEmpty() {
        #expect(OutlineFilter.visible(headings: document, query: "zzz", collapsed: []).isEmpty)
    }

    @Test("H1 is never hidden by collapsing it — collapse only applies to H2 children")
    func h1IsNeverHiddenByCollapsingItCollapseOnlyAppliesToH2() {
        // Collapsing the document-level H1 would be surprising. Only H2
        // collapses make sense for the rule "hide my H3 children".
        let visible = OutlineFilter.visible(headings: document, query: "", collapsed: ["doc"])
        #expect(visible.contains(where: { $0.id == "overview" }))
        #expect(visible.contains(where: { $0.id == "features" }))
    }
}
