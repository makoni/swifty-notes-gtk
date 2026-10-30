import Foundation

/// Finds the ranges of a Markdown source buffer that the spell-checker
/// should leave alone — fenced and indented code blocks, inline code spans
/// (`` ` ``-delimited) and TeX math. We feed those ranges to libspelling
/// through a GtkTextTag named `gtksourceview:context-classes:no-spell-check`,
/// which the adapter recognizes and skips.
///
/// We do this manually because the standard `markdown.lang` grammar
/// shipped with GtkSourceView 5.18 doesn't tag code regions with the
/// `no-spell-check` context class on its own (and on some installs the
/// grammar isn't bundled at all).
enum MarkdownNoSpellRanges {
    /// Returns ranges measured in **Unicode scalars** (code points), the
    /// unit `GtkTextBuffer` offsets count in — not `String` characters,
    /// which differ after an emoji with a modifier, a flag or a decomposed
    /// accent. They are sorted, and none lies inside another.
    static func ranges(in text: String) -> [Range<Int>] {
        ranges(in: MathSpanExtractor.extract(from: text))
    }

    /// The same, from the math extraction of the text, for a caller that
    /// already has one: code blocks are the extractor's, so the spell
    /// checker and the preview agree on what is code.
    static func ranges(in extraction: MathSpanExtractor.Extraction) -> [Range<Int>] {
        let scalars = Array(extraction.source.unicodeScalars)
        var ranges = extraction.codeBlocks
        ranges.append(contentsOf: inlineCodeSpans(in: scalars, skipping: extraction.codeBlocks))
        ranges.append(contentsOf: extraction.located.map(\.source))
        // A `math` fence is both a code block and a span; keep one.
        ranges.sort { $0.lowerBound != $1.lowerBound ? $0.lowerBound < $1.lowerBound : $0.upperBound > $1.upperBound }
        var outermost: [Range<Int>] = []
        for range in ranges where outermost.last.map({ range.upperBound > $0.upperBound }) ?? true {
            outermost.append(range)
        }
        return outermost
    }

    /// Backtick code spans outside `blocks` (sorted): a run of backticks
    /// up to the next run of the same length; an unmatched run is literal.
    private static func inlineCodeSpans(in scalars: [Unicode.Scalar], skipping blocks: [Range<Int>]) -> [Range<Int>] {
        func runLength(at start: Int) -> Int {
            var end = start
            while end < scalars.count, scalars[end] == "`" { end += 1 }
            return end - start
        }
        var ranges: [Range<Int>] = []
        var nextBlock = 0
        var i = 0
        while i < scalars.count {
            // A code block's backticks are code already.
            while nextBlock < blocks.count, blocks[nextBlock].upperBound <= i { nextBlock += 1 }
            if nextBlock < blocks.count, blocks[nextBlock].contains(i) {
                i = blocks[nextBlock].upperBound
                continue
            }
            guard scalars[i] == "`" else {
                i += 1
                continue
            }
            let run = runLength(at: i)
            var j = i + run
            var closeEnd: Int?
            while j < scalars.count {
                guard scalars[j] == "`" else {
                    j += 1
                    continue
                }
                let candidate = runLength(at: j)
                if candidate == run {
                    closeEnd = j + candidate
                    break
                }
                j += candidate
            }
            if let closeEnd {
                ranges.append(i ..< closeEnd)
                i = closeEnd
            } else {
                i += run
            }
        }
        return ranges
    }
}
