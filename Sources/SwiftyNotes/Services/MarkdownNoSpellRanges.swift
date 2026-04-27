import Foundation

/// Finds the byte ranges in a Markdown source buffer that the
/// spell-checker should leave alone — fenced code blocks (```` ``` ````-
/// delimited) and inline code spans (`` ` ``-delimited). We feed those
/// ranges to libspelling through a GtkTextTag named
/// `gtksourceview:context-classes:no-spell-check`, which the adapter
/// recognizes and skips.
///
/// We do this manually because the standard `markdown.lang` grammar
/// shipped with GtkSourceView 5.18 doesn't tag code regions with the
/// `no-spell-check` context class on its own (and on some installs the
/// grammar isn't bundled at all).
enum MarkdownNoSpellRanges {
    /// Returns ranges measured in **Swift String Character offsets**
    /// (not UTF-8 bytes). The caller maps them onto `GtkTextBuffer`
    /// offsets through `applyTag(startOffset:endOffset:)`, which
    /// expects character offsets matching `String.count`.
    static func ranges(in text: String) -> [Range<Int>] {
        var ranges = scanFencedBlocks(in: text)
        ranges.append(contentsOf: scanInlineSpans(in: text, excluding: ranges))
        ranges.sort { $0.lowerBound < $1.lowerBound }
        return ranges
    }

    private static func scanFencedBlocks(in text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var lineStart = text.startIndex
        var lineStartOffset = 0
        var openFenceOffset: Int?
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart ..< lineEnd]
            let trimmed = line.drop(while: { $0 == " " })
            // Treat any line starting with three or more backticks as a fence
            // marker — that catches both opening and closing fences and the
            // optional info string after the opener.
            if trimmed.prefix(3) == "```" {
                if let openOffset = openFenceOffset {
                    let lineLength = text.distance(from: lineStart, to: lineEnd)
                    ranges.append(openOffset ..< (lineStartOffset + lineLength))
                    openFenceOffset = nil
                } else {
                    openFenceOffset = lineStartOffset
                }
            }
            if lineEnd == text.endIndex {
                break
            }
            // Step past the trailing newline so the next line's start
            // offset accounts for it.
            let next = text.index(after: lineEnd)
            lineStartOffset += text.distance(from: lineStart, to: next)
            lineStart = next
        }
        if let openOffset = openFenceOffset {
            ranges.append(openOffset ..< text.count)
        }
        return ranges
    }

    private static func scanInlineSpans(in text: String, excluding fencedRanges: [Range<Int>]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var index = text.startIndex
        var offset = 0
        while index < text.endIndex {
            let character = text[index]
            if character == "`" {
                // Skip if this position is already inside a fenced block.
                if fencedRanges.contains(where: { $0.contains(offset) }) {
                    let next = text.index(after: index)
                    offset += text.distance(from: index, to: next)
                    index = next
                    continue
                }
                // Count consecutive backticks; the closing run must match.
                let runStart = index
                let runStartOffset = offset
                var runEnd = index
                var runLength = 0
                while runEnd < text.endIndex, text[runEnd] == "`" {
                    runLength += 1
                    runEnd = text.index(after: runEnd)
                }
                offset += runLength
                index = runEnd

                // Look for a matching closing run of the same length.
                var searchStart = runEnd
                var searchOffset = offset
                while searchStart < text.endIndex {
                    let candidateChar = text[searchStart]
                    if candidateChar == "`" {
                        var closeEnd = searchStart
                        var closeLength = 0
                        while closeEnd < text.endIndex, text[closeEnd] == "`" {
                            closeLength += 1
                            closeEnd = text.index(after: closeEnd)
                        }
                        if closeLength == runLength {
                            let endOffset = searchOffset + closeLength
                            ranges.append(runStartOffset ..< endOffset)
                            offset = endOffset
                            index = closeEnd
                            break
                        }
                        searchOffset += closeLength
                        searchStart = closeEnd
                        continue
                    }
                    let advance = text.index(after: searchStart)
                    searchOffset += text.distance(from: searchStart, to: advance)
                    searchStart = advance
                }
                if index == runStart {
                    // No matching closer; advance past the opener.
                    let advance = text.index(after: index)
                    offset += text.distance(from: index, to: advance)
                    index = advance
                }
                continue
            }
            let next = text.index(after: index)
            offset += text.distance(from: index, to: next)
            index = next
        }
        return ranges
    }
}
