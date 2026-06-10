import Foundation
@testable import SwiftyNotes
import Testing

struct MarkdownOutlineExtractorTests {
    @Test("Extracts a single heading")
    func extractsASingleHeading() {
        let markdown = "# Roadmap\n\nSome paragraph."
        let blocks: [RenderedBlock] = [
            .heading(level: 1, text: .plain("Roadmap")),
            .paragraph(.plain("Some paragraph.")),
        ]
        let headings = MarkdownOutlineExtractor.extract(markdown: markdown, blocks: blocks)
        #expect(headings == [
            Heading(id: "roadmap", level: 1, text: "Roadmap", blockIndex: 0, line: 1),
        ])
    }

    @Test("Extracts mixed levels in source order with stable IDs")
    func extractsMixedLevelsInSourceOrderWithStableIDs() {
        let markdown = """
        # Doc

        ## Overview

        Body.

        ## Features

        ### Outline

        Click to scroll.
        """
        let blocks: [RenderedBlock] = [
            .heading(level: 1, text: .plain("Doc")),
            .heading(level: 2, text: .plain("Overview")),
            .paragraph(.plain("Body.")),
            .heading(level: 2, text: .plain("Features")),
            .heading(level: 3, text: .plain("Outline")),
            .paragraph(.plain("Click to scroll.")),
        ]
        let headings = MarkdownOutlineExtractor.extract(markdown: markdown, blocks: blocks)
        #expect(headings == [
            Heading(id: "doc",      level: 1, text: "Doc",      blockIndex: 0, line: 1),
            Heading(id: "overview", level: 2, text: "Overview", blockIndex: 1, line: 3),
            Heading(id: "features", level: 2, text: "Features", blockIndex: 3, line: 7),
            Heading(id: "outline",  level: 3, text: "Outline",  blockIndex: 4, line: 9),
        ])
    }

    @Test("Dedup gives -2, -3 to duplicate heading text in document order")
    func dedupGives23ToDuplicateHeadingTextInDocumentOrder() {
        let markdown = """
        ## Goals
        ## Goals
        ## Non-goals
        ## Goals
        """
        let blocks: [RenderedBlock] = [
            .heading(level: 2, text: .plain("Goals")),
            .heading(level: 2, text: .plain("Goals")),
            .heading(level: 2, text: .plain("Non-goals")),
            .heading(level: 2, text: .plain("Goals")),
        ]
        let ids = MarkdownOutlineExtractor.extract(markdown: markdown, blocks: blocks).map(\.id)
        #expect(ids == ["goals", "goals-2", "non-goals", "goals-3"])
    }

    @Test("Returns empty when there are no headings")
    func returnsEmptyWhenThereAreNoHeadings() {
        let markdown = "Just a paragraph.\n\nAnother one."
        let blocks: [RenderedBlock] = [
            .paragraph(.plain("Just a paragraph.")),
            .paragraph(.plain("Another one.")),
        ]
        #expect(MarkdownOutlineExtractor.extract(markdown: markdown, blocks: blocks).isEmpty)
    }

    @Test("Survives a markdown-blocks count mismatch by zipping up to min")
    func survivesAMarkdownBlocksCountMismatchByZippingUpToMin() {
        // If the renderer drops a heading (e.g. empty after trimming) but
        // swift-markdown still parses it, we should not crash — we just
        // skip the trailing slot. The reverse mismatch is handled the
        // same way.
        let markdown = """
        # First
        # Second
        """
        let blocks: [RenderedBlock] = [
            .heading(level: 1, text: .plain("First")),
        ]
        let headings = MarkdownOutlineExtractor.extract(markdown: markdown, blocks: blocks)
        #expect(headings == [
            Heading(id: "first", level: 1, text: "First", blockIndex: 0, line: 1),
        ])
    }

    @Test("H6 is the deepest level we surface")
    func h6IsTheDeepestLevelWeSurface() {
        let markdown = """
        ###### Deep
        """
        let blocks: [RenderedBlock] = [
            .heading(level: 6, text: .plain("Deep")),
        ]
        let headings = MarkdownOutlineExtractor.extract(markdown: markdown, blocks: blocks)
        #expect(headings == [
            Heading(id: "deep", level: 6, text: "Deep", blockIndex: 0, line: 1),
        ])
    }
}
