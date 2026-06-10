import Foundation
@testable import SwiftyNotes
import Testing

struct PaletteRankerTests {
    @Test("Empty query returns headings in document order with no ranking applied")
    func emptyQueryReturnsHeadingsInDocumentOrderWithNoRankingApplied() {
        let headings: [Heading] = [
            .init(id: "a", level: 2, text: "Alpha", blockIndex: 0, line: 1),
            .init(id: "b", level: 2, text: "Beta",  blockIndex: 1, line: 3),
        ]
        let ranked = PaletteRanker.rank(headings: headings, query: "")
        #expect(ranked.map(\.id) == ["a", "b"])
    }

    @Test("Whitespace-only query behaves like an empty query")
    func whitespaceOnlyQueryBehavesLikeAnEmptyQuery() {
        let headings: [Heading] = [
            .init(id: "a", level: 2, text: "Alpha", blockIndex: 0, line: 1),
            .init(id: "b", level: 2, text: "Beta",  blockIndex: 1, line: 3),
        ]
        #expect(PaletteRanker.rank(headings: headings, query: "   ").map(\.id) == ["a", "b"])
    }

    @Test("Non-matches drop out")
    func nonMatchesDropOut() {
        let headings: [Heading] = [
            .init(id: "a", level: 2, text: "Alpha", blockIndex: 0, line: 1),
        ]
        #expect(PaletteRanker.rank(headings: headings, query: "zzz").isEmpty)
    }

    @Test("Match is case-insensitive")
    func matchIsCaseInsensitive() {
        let headings: [Heading] = [
            .init(id: "outline", level: 2, text: "Outline", blockIndex: 0, line: 1),
        ]
        #expect(PaletteRanker.rank(headings: headings, query: "OUTLINE").first?.id == "outline")
    }

    @Test("Ranks title-start above title-contains above parent-contains")
    func ranksTitleStartAboveTitleContainsAboveParentContains() {
        // Design rules (palette.jsx):
        //   score 0 — query matches at index 0 of the heading text
        //   score 1 — matches later in the heading text
        //   score 2 — matches only in the parent H2's text
        //
        // Construct one heading per rank so the order in the result
        // is unambiguous.
        let headings: [Heading] = [
            .init(id: "overview",       level: 2, text: "Overview",        blockIndex: 0, line: 1),
            // Score 2: own text doesn't contain "overview" but parent does.
            .init(id: "child-of-over",  level: 3, text: "Goals",           blockIndex: 1, line: 3),
            // Different H2 so the matches below don't fall under Overview.
            .init(id: "features",       level: 2, text: "Features",        blockIndex: 2, line: 5),
            // Score 1: title contains "overview" but not at the start.
            .init(id: "tail-match",     level: 3, text: "Goals overview",  blockIndex: 3, line: 7),
        ]
        let ranked = PaletteRanker.rank(headings: headings, query: "overview")
        #expect(ranked.map(\.id) == ["overview", "tail-match", "child-of-over"])
    }

    @Test("Within the same rank, document order is preserved")
    func withinTheSameRankDocumentOrderIsPreserved() {
        // All three score 0 (title-start). They should come out in the
        // order they appear in the source.
        let headings: [Heading] = [
            .init(id: "first",  level: 2, text: "Outline first",  blockIndex: 0, line: 1),
            .init(id: "second", level: 2, text: "Outline second", blockIndex: 1, line: 3),
            .init(id: "third",  level: 2, text: "Outline third",  blockIndex: 2, line: 5),
        ]
        let ranked = PaletteRanker.rank(headings: headings, query: "outline")
        #expect(ranked.map(\.id) == ["first", "second", "third"])
    }

    @Test("H1 headings have no parent and rank only on own text")
    func h1HeadingsHaveNoParentAndRankOnlyOnOwnText() {
        // Collapsing the document-level H1 would be surprising — in the
        // palette the same rule applies: H1 has no parent context.
        let docs: [Heading] = [
            .init(id: "intro",  level: 1, text: "Intro",  blockIndex: 0, line: 1),
            .init(id: "body",   level: 2, text: "Body",   blockIndex: 1, line: 3),
            .init(id: "child",  level: 3, text: "Goals",  blockIndex: 2, line: 5),
        ]
        // "Body" matches the parent of "Goals" → score 2; "Body" itself
        // matches its own title at 0 → score 0; "Intro" has no match.
        let ranked = PaletteRanker.rank(headings: docs, query: "body")
        #expect(ranked.map(\.id) == ["body", "child"])
    }

    @Test("Parent-contains does not surface H2 rows whose own text misses")
    func parentContainsDoesNotSurfaceH2RowsWhoseOwnTextMisses() {
        // The parent rule lifts H3+ rows because the section above them
        // matched; it must not also re-match the H2 itself as a
        // "parent-of-myself" hit.
        let headings: [Heading] = [
            .init(id: "alpha", level: 2, text: "Alpha",        blockIndex: 0, line: 1),
            .init(id: "child", level: 3, text: "Whatever",     blockIndex: 1, line: 3),
            .init(id: "beta",  level: 2, text: "Beta",         blockIndex: 2, line: 5),
        ]
        let ranked = PaletteRanker.rank(headings: headings, query: "alpha")
        #expect(ranked.map(\.id) == ["alpha", "child"])
    }
}
