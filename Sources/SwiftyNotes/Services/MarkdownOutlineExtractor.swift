import Foundation
import Markdown

/// Flattens a Markdown document into a list of ``Heading`` rows ordered
/// by source position. Pairs `[RenderedBlock]` (already produced by the
/// preview renderer) with the source markdown to populate both
/// `blockIndex` and `line` on each heading.
///
/// The renderer is the authority on what's a heading (it has already
/// applied trimming / empty-block dropping), so we walk the blocks for
/// `(level, text, blockIndex)` tuples and use swift-markdown only to
/// supply line numbers. If the two parses disagree on heading count
/// (rare, mostly empty-heading edge cases) we zip up to the shorter of
/// the two — we never crash on mismatch.
enum MarkdownOutlineExtractor {
    static func extract(markdown: String, blocks: [RenderedBlock]) -> [Heading] {
        extract(extraction: MathSpanExtractor.extract(from: markdown), blocks: blocks)
    }

    /// The same, from the math extraction of the markdown, for a caller that
    /// already has one (the renderer takes it too).
    static func extract(extraction: MathSpanExtractor.Extraction, blocks: [RenderedBlock]) -> [Heading] {
        let blockHeadings = blocks.enumerated().compactMap { idx, block -> (Int, String, Int)? in
            guard case let .heading(level, text) = block else { return nil }
            return (level, text.plainText, idx)
        }
        guard !blockHeadings.isEmpty else { return [] }

        let lines = headingLines(in: extraction)

        var occurrences: [String: Int] = [:]
        var result: [Heading] = []
        result.reserveCapacity(min(blockHeadings.count, lines.count))
        for (i, entry) in blockHeadings.enumerated() where i < lines.count {
            let (level, text, blockIndex) = entry
            let id = HeadingSlug.slug(text, occurrences: &occurrences)
            result.append(Heading(
                id: id,
                level: level,
                text: text,
                blockIndex: blockIndex,
                line: lines[i],
            ))
        }
        return result
    }

    /// 1-based source line of each heading in document order, via
    /// swift-markdown. Falls back to `1` if the parser didn't attach a
    /// range (defensive — every CommonMark heading has one in practice).
    private static func headingLines(in extraction: MathSpanExtractor.Extraction) -> [Int] {
        // Parse the source with its math cut out (line numbers unchanged), as
        // the renderer does: a `#` line or setext underline inside `$$…$$` is
        // TeX, not a heading.
        let document = Document(parsing: extraction.markdown)
        var lines: [Int] = []
        for child in document.children {
            collectHeadingLines(from: child, into: &lines)
        }
        return lines
    }

    private static func collectHeadingLines(from markup: Markup, into lines: inout [Int]) {
        if let heading = markup as? Markdown.Heading {
            lines.append(heading.range?.lowerBound.line ?? 1)
            return
        }
        for child in markup.children {
            collectHeadingLines(from: child, into: &lines)
        }
    }
}
