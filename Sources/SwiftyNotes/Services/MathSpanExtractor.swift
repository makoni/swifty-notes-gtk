import Foundation

/// One TeX math span cut out of the markdown source before parsing, so
/// the CommonMark layer cannot mangle it (`$x^*$` emphasis, `\{` → `{`,
/// `\\` → `\`, …). The span's source text is replaced by
/// ``MathSpanExtractor/placeholder(for:)``.
///
/// - `isDisplay == true`: came from `$$…$$` (or a `math` code fence).
///   A rendered paragraph whose plain text is exactly the span's
///   placeholder becomes a `RenderedBlock.math`.
/// - Inline spans — and display placeholders that ended up inline, e.g.
///   `a $$b$$ c` — are restored inside `RenderedText` as `$tex$`, with
///   the span listed in `RenderedText.mathSpans` (display ones keep
///   `isDisplay == true`).
public struct MathSpan: Sendable, Equatable {
    public let tex: String
    public let isDisplay: Bool

    public init(tex: String, isDisplay: Bool) {
        self.tex = tex
        self.isDisplay = isDisplay
    }
}

/// Cuts math spans out of markdown source before markdown parsing and
/// replaces each with a Private-Use-Area placeholder
/// (``MathSpanExtractor/placeholder(for:)``), which survives HTML escaping
/// and the Pango markup pass. The renderer puts the TeX back where the
/// text landed.
///
/// **Line structure is preserved:** each span is replaced by its
/// placeholder followed by exactly as many `\n` as the span's source text
/// contained, so the output always has the same line count as the input.
/// (In the stored TeX, single newlines become spaces for inline spans;
/// display TeX keeps its newlines.)
///
/// Delimiter rules (pandoc `tex_math_dollars` + GitHub, approximated):
/// - `\$` stays `\$` in the output (markdown then renders a literal `$`)
///   and is never a delimiter.
/// - Display `$$…$$`: may span lines; no blank line inside; content is
///   trimmed (inner newlines kept). A fenced block whose info string's
///   first word is `math` is one display span covering the whole block.
/// - Inline: a `$` immediately followed by a non-space character … the
///   next `$` immediately preceded by a non-space character and not
///   immediately followed by a digit; no blank line between; not `$$`.
///   The close must be the *first* `$` after the open — if that candidate
///   is invalid the open `$` is literal, which is what keeps `$5 and $10`
///   and `$20,000 and $30,000` out of math.
///
/// Verbatim regions (never math):
/// - Fenced code blocks: opening fence of ≥3 `` ` `` or `~` at ≤3 leading
///   spaces (or any indent inside a list — approximation), closed by a
///   fence of the same character and ≥ the opening length. A backtick
///   fence with an info string is accepted as a fence (CommonMark would
///   treat `` ```python `` as text; deliberate deviation so `` ```math ``
///   works).
/// - Indented code: a line indented ≥4 spaces (tab = 4) after a blank
///   line or at document start, outside a list. List context is
///   approximate: a bullet/ordered marker at ≤3 leading spaces enters a
///   list, an unindented non-list line leaves it, blank lines do not end
///   it.
/// - Inline code spans: a run of n backticks closes at the next run of
///   exactly n backticks; the search stops at a blank line, so an
///   unclosed span is literal.
/// - HTML comments `<!-- … -->` (unclosed: runs to the end of the current
///   free-text stretch).
/// - Autolinks `<http://…>` / `<https://…>` on a single line (unclosed:
///   literal `<`).
enum MathSpanExtractor {
    // MARK: - API

    /// Replaces every math span with a placeholder and returns the spans
    /// in order.
    static func extract(from markdown: String) -> (markdown: String, spans: [MathSpan]) {
        let extraction = extractWithSourceRanges(from: markdown)
        return (extraction.markdown, extraction.spans.map(\.span))
    }

    /// Where each math span sits in `markdown`, delimiters included, as
    /// ranges of Unicode scalars — for tools that work on the source, such as
    /// the editor's spell checker, which should leave TeX alone.
    static func sourceRanges(in markdown: String) -> [Range<Int>] {
        extractWithSourceRanges(from: markdown).spans.map(\.source)
    }

    private struct LocatedSpan {
        let span: MathSpan
        /// Scalar range of the span's source, delimiters included.
        let source: Range<Int>
    }

    private static func extractWithSourceRanges(from markdown: String) -> (markdown: String, spans: [LocatedSpan]) {
        // Sanitise the source before generating placeholders, so only the
        // extractor's own placeholders survive (one scalar in, one out: line
        // structure and positions are unchanged).
        var scalars = markdown.unicodeScalars.map(sanitized)
        neutralizeReservedEntities(in: &scalars)
        let lines = lineBounds(scalars)
        // A quoted line holding nothing but `>` markers is blank inside the quote.
        let blankLines = lines.filter { line in
            isBlankLine(scalars: scalars, line: line)
                || isBlankLine(scalars: scalars, line: LineBounds(
                    start: quoteMarkers(scalars: scalars, from: line.start, end: line.contentEnd, maxDepth: .max).end,
                    contentEnd: line.contentEnd,
                    end: line.end,
                ))
        }
        var spans: [LocatedSpan] = []
        var output: [Unicode.Scalar] = []
        /// The columns the content of each open list item starts at,
        /// outermost first.
        var listIndents: [Int] = []
        var listContentIndent: Int? { listIndents.last }
        /// The indent of the indented code block being copied, if any.
        var codeIndent: Int?
        var previousLineWasBlank = true
        var freeStart: Int?
        var freeEnd: Int?
        var fence: FenceState?

        func flushFreeText() {
            guard let start = freeStart, let end = freeEnd else { return }
            freeStart = nil
            freeEnd = nil
            scanFreeText(scalars: scalars, range: start..<end, blankLines: blankLines, spans: &spans, output: &output)
        }

        for line in lines {
            if let current = fence {
                if isClosingFence(scalars: scalars, line: line, state: current) {
                    emitFence(scalars: scalars, state: current, blockEnd: line.end, spans: &spans, output: &output)
                    fence = nil
                } else {
                    fence = FenceState(
                        char: current.char, length: current.length, isMath: current.isMath,
                        blockStart: current.blockStart, contentStart: current.contentStart,
                        contentEnd: line.end,
                    )
                }
                previousLineWasBlank = false
                continue
            }

            let isBlank = isBlankLine(scalars: scalars, line: line)
            let width = leadingWidth(scalars: scalars, line: line)

            // Inside an indented code block: blank lines and lines indented
            // as far stay code.
            if let indent = codeIndent {
                if isBlank || width >= indent {
                    output.append(contentsOf: scalars[line.start..<line.end])
                    previousLineWasBlank = isBlank
                    continue
                }
                codeIndent = nil
            }

            if let open = fenceOpenInfo(scalars: scalars, line: line, inList: listContentIndent != nil) {
                flushFreeText()
                fence = FenceState(
                    char: open.char, length: open.length, isMath: open.isMath,
                    blockStart: line.start, contentStart: line.end, contentEnd: line.end,
                )
                previousLineWasBlank = false
                continue
            }

            // Indented code: four columns past the list item's content (or
            // the margin), after a blank line — it cannot interrupt a
            // paragraph.
            let requiredIndent = (listContentIndent ?? 0) + 4
            if !isBlank, width >= requiredIndent, previousLineWasBlank {
                flushFreeText()
                output.append(contentsOf: scalars[line.start..<line.end])
                codeIndent = requiredIndent
                previousLineWasBlank = false
                continue
            }

            // Free line (blank lines are free too — they keep spans from
            // spanning across them).
            if freeStart == nil { freeStart = line.start }
            freeEnd = line.end
            let previousLineWasBlankBefore = previousLineWasBlank
            previousLineWasBlank = isBlank
            if isBlank { continue }
            if let indent = listItemContentIndent(scalars: scalars, line: line, inList: listContentIndent != nil) {
                // A marker belongs to the item whose content it is indented into.
                while let last = listIndents.last, last > width { listIndents.removeLast() }
                listIndents.append(indent)
            } else if previousLineWasBlankBefore {
                // After a blank line, a line belongs to the innermost item it
                // is indented far enough for (none: the list is over).
                while let last = listIndents.last, width < last { listIndents.removeLast() }
            }
        }
        flushFreeText()

        if let current = fence {
            emitFence(scalars: scalars, state: current, blockEnd: scalars.count, spans: &spans, output: &output)
        }

        return (string(from: output), spans)
    }

    /// The character the preview puts where an inline formula is drawn.
    static let formulaMarker: Unicode.Scalar = "\u{FFFC}"
    private static let replacementCharacter: Unicode.Scalar = "\u{FFFD}"

    /// Characters with a meaning of their own in the rendered text — the
    /// formula marker and the placeholder code points — become U+FFFD when
    /// they come from the note itself, so typed text can neither pose as a
    /// formula nor pull another formula's TeX into place.
    private static func sanitized(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar.value {
        case formulaMarker.value, 0xE000, 0xE001, 0xE010...0xE019:
            replacementCharacter
        default:
            scalar
        }
    }

    /// Numeric character references (`&#xE000;`, `&#65532;`) to the same
    /// reserved characters are rewritten to U+FFFD in place, digits padded
    /// to the same length so no position moves: Markdown decodes them after
    /// the source was sanitised.
    private static func neutralizeReservedEntities(in scalars: inout [Unicode.Scalar]) {
        var i = 0
        while i + 3 < scalars.count {
            guard scalars[i] == "&", scalars[i + 1] == "#" else {
                i += 1
                continue
            }
            let isHex = scalars[i + 2] == "x" || scalars[i + 2] == "X"
            let digitsStart = i + (isHex ? 3 : 2)
            var j = digitsStart
            while j < scalars.count, j - digitsStart < 8, (isHex ? scalars[j].properties.isASCIIHexDigit : ("0"..."9").contains(scalars[j])) {
                j += 1
            }
            guard j > digitsStart, j < scalars.count, scalars[j] == ";",
                  let value = UInt32(String(String.UnicodeScalarView(scalars[digitsStart..<j])), radix: isHex ? 16 : 10),
                  let reserved = Unicode.Scalar(value), sanitized(reserved) != reserved
            else {
                i += 1
                continue
            }
            let digits = String(replacementCharacter.value, radix: isHex ? 16 : 10, uppercase: true)
            let padded = String(repeating: "0", count: max(0, (j - digitsStart) - digits.count)) + digits
            scalars.replaceSubrange(digitsStart..<j, with: padded.unicodeScalars.suffix(j - digitsStart))
            i = j + 1
        }
    }

    /// `U+E000`, then the index as PUA digits (`U+E010+d` per decimal
    /// digit), then `U+E001`.
    static func placeholder(for index: Int) -> String {
        var scalars: [Unicode.Scalar] = ["\u{E000}"]
        for digit in String(max(0, index)).unicodeScalars {
            // `digit` is the *character*; its value is `0x30` + the digit.
            scalars.append(Unicode.Scalar(0xE010 &+ digit.value &- 0x30)!)
        }
        scalars.append("\u{E001}")
        return string(from: scalars)
    }

    /// The most digits a placeholder index may have; longer runs are not
    /// placeholders (and would overflow).
    private static let maxPlaceholderDigits = 6

    /// Finds every placeholder in `text`, in order, with the decoded index.
    /// Ranges are in Unicode scalars of `text`: a placeholder is a run of
    /// code points, and the characters around it may combine with it (a
    /// prepended mark, an emoji modifier), so it cannot be cut out along
    /// character boundaries.
    static func spanIndices(in text: String) -> [(range: Range<Int>, index: Int)] {
        let scalars = Array(text.unicodeScalars)
        var result: [(range: Range<Int>, index: Int)] = []
        var i = 0
        while i < scalars.count {
            guard scalars[i].value == 0xE000 else {
                i += 1
                continue
            }
            var j = i + 1
            var index = 0
            while j < scalars.count, j - i <= maxPlaceholderDigits, (0xE010...0xE019).contains(scalars[j].value) {
                index = index * 10 + Int(scalars[j].value - 0xE010)
                j += 1
            }
            if j > i + 1, j < scalars.count, scalars[j].value == 0xE001 {
                result.append((range: i..<(j + 1), index: index))
                i = j + 1
            } else {
                i += 1
            }
        }
        return result
    }

    /// `text` with every placeholder replaced by `replacement(index)`, built
    /// scalar by scalar (see ``spanIndices(in:)``); a nil replacement keeps
    /// the placeholder.
    static func replacingPlaceholders(in text: String, with replacement: (Int) -> String?) -> String {
        let occurrences = spanIndices(in: text)
        guard !occurrences.isEmpty else { return text }
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        var cursor = 0
        for occurrence in occurrences {
            result.append(contentsOf: scalars[cursor..<occurrence.range.lowerBound])
            if let substitute = replacement(occurrence.index) {
                result.append(contentsOf: substitute.unicodeScalars)
            } else {
                result.append(contentsOf: scalars[occurrence.range])
            }
            cursor = occurrence.range.upperBound
        }
        result.append(contentsOf: scalars[cursor...])
        return String(result)
    }

    // MARK: - Free-text scan (comments, autolinks, code spans, math)

    private static func scanFreeText(
        scalars: [Unicode.Scalar],
        range: Range<Int>,
        blankLines: [LineBounds],
        spans: inout [LocatedSpan],
        output: inout [Unicode.Scalar],
    ) {
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            let s = scalars[i]

            // `\$` stays `\$` (markdown renders a literal `$`); never a delimiter.
            if s.value == 0x5C, i + 1 < end, scalars[i + 1].value == 0x24 {
                output.append(contentsOf: [s, scalars[i + 1]])
                i += 2
                continue
            }

            if s.value == 0x3C { // `<`
                if let gt = autolinkEnd(scalars: scalars, after: i + 1, end: end) {
                    output.append(contentsOf: scalars[i...gt])
                    i = gt + 1
                    continue
                }
                if isCommentStart(scalars: scalars, after: i + 1, end: end) {
                    if let close = findCommentClose(scalars: scalars, from: i + 4, end: end) {
                        // `close` is the first scalar of `-->`.
                        output.append(contentsOf: scalars[i...(close + 2)])
                        i = close + 3
                        continue
                    }
                    // Unclosed comment: swallow the rest of this free-text stretch.
                    output.append(contentsOf: scalars[i..<end])
                    i = end
                    continue
                }
                // A raw HTML tag: `$` in its attributes is not math.
                if let gt = htmlTagEnd(scalars: scalars, after: i + 1, end: end) {
                    output.append(contentsOf: scalars[i...gt])
                    i = gt + 1
                    continue
                }
            }

            // A bare URL, which GFM turns into a link up to the next space.
            if let urlEnd = bareURLEnd(scalars: scalars, at: i, range: range) {
                output.append(contentsOf: scalars[i..<urlEnd])
                i = urlEnd
                continue
            }

            // A link or image destination, `](url "title")`: URLs such as
            // OData's `?$select=a&$top=5` carry dollars that are not math.
            if s.value == 0x5D, i + 1 < end, scalars[i + 1].value == 0x28,
               let close = linkDestinationEnd(scalars: scalars, from: i + 2, end: end)
            {
                output.append(contentsOf: scalars[i...close])
                i = close + 1
                continue
            }

            if s.value == 0x60 { // backtick
                let run = backtickRunLength(scalars: scalars, from: i, end: end)
                if let close = findCodeSpanClose(scalars: scalars, from: i + run, end: end, length: run, blankLines: blankLines) {
                    output.append(contentsOf: scalars[i...(close + run - 1)])
                    i = close + run
                    continue
                }
                // Unclosed run: the backticks are literal (CommonMark).
                output.append(contentsOf: scalars[i...(i + run - 1)])
                i += run
                continue
            }

            if s.value == 0x24 { // `$`
                if i + 1 < end, scalars[i + 1].value == 0x24 {
                    // Display attempt.
                    if let close = findDisplayClose(scalars: scalars, from: i + 2, end: end, blankLines: blankLines) {
                        let content = strippingQuoteMarkers(scalars: scalars, range: (i + 2)..<close, openedAt: i, freeStart: range.lowerBound)
                        let tex = trimmedTeX(content.scalars)
                        if tex.isEmpty {
                            output.append(s)
                            i += 1
                        } else {
                            spans.append(LocatedSpan(span: MathSpan(tex: tex, isDisplay: true), source: i..<(close + 2)))
                            appendPlaceholder(&output, index: spans.count - 1, lineBreaks: content.lineBreaks)
                            i = close + 2
                        }
                        continue
                    }
                    output.append(s)
                    i += 1
                    continue
                }
                // Inline attempt.
                if i + 1 < end, !isWhitespaceScalar(scalars[i + 1]) {
                    if let close = findInlineClose(scalars: scalars, from: i + 1, end: end, blankLines: blankLines) {
                        let content = strippingQuoteMarkers(scalars: scalars, range: (i + 1)..<close, openedAt: i, freeStart: range.lowerBound)
                        let tex = string(from: content.scalars)
                            .replacingOccurrences(of: "\n", with: " ")
                        spans.append(LocatedSpan(span: MathSpan(tex: tex, isDisplay: false), source: i..<(close + 1)))
                        appendPlaceholder(&output, index: spans.count - 1, lineBreaks: content.lineBreaks)
                        i = close + 1
                        continue
                    }
                }
                output.append(s)
                i += 1
                continue
            }

            output.append(s)
            i += 1
        }
    }

    // MARK: - Delimiter search

    private static func findDisplayClose(scalars: [Unicode.Scalar], from: Int, end: Int, blankLines: [LineBounds]) -> Int? {
        var j = from
        while j + 1 < end {
            // `\$` is a dollar inside the TeX, never the closing delimiter.
            if scalars[j].value == 0x5C {
                j += 2
                continue
            }
            if scalars[j].value == 0x24, scalars[j + 1].value == 0x24 {
                // Once a blank line is crossed, every later candidate is
                // equally invalid — stop.
                return containsBlankLine(blankLines, range: from..<j) ? nil : j
            }
            j += 1
        }
        return nil
    }

    private static func findInlineClose(scalars: [Unicode.Scalar], from: Int, end: Int, blankLines: [LineBounds]) -> Int? {
        var j = from
        while j < end {
            if scalars[j].value == 0x5C {
                j += 2
                continue
            }
            if scalars[j].value == 0x24 {
                let prevIsSpace = isWhitespaceScalar(scalars[j - 1])
                let after: UInt32? = j + 1 < end ? scalars[j + 1].value : nil
                let afterIsDigit = after.map { (0x30...0x39).contains($0) } ?? false
                // First candidate decides: invalid → the open `$` is literal.
                if prevIsSpace || afterIsDigit {
                    return nil
                }
                return containsBlankLine(blankLines, range: from..<j) ? nil : j
            }
            j += 1
        }
        return nil
    }

    private static func backtickRunLength(scalars: [Unicode.Scalar], from: Int, end: Int) -> Int {
        var j = from
        while j < end, scalars[j].value == 0x60 { j += 1 }
        return j - from
    }

    private static func findCodeSpanClose(
        scalars: [Unicode.Scalar], from: Int, end: Int, length: Int, blankLines: [LineBounds],
    ) -> Int? {
        var j = from
        while j < end {
            if scalars[j].value == 0x60 {
                var k = j
                while k < end, scalars[k].value == 0x60 { k += 1 }
                if k - j == length {
                    // A code span never spans a blank line (approximation of
                    // the CommonMark rule that it stays inside one paragraph).
                    return containsBlankLine(blankLines, range: from..<j) ? nil : j
                }
                j = k
                continue
            }
            j += 1
        }
        return nil
    }

    private static func isCommentStart(scalars: [Unicode.Scalar], after: Int, end: Int) -> Bool {
        after + 2 < end
            && scalars[after].value == 0x21 // !
            && scalars[after + 1].value == 0x2D // -
            && scalars[after + 2].value == 0x2D // -
    }

    private static func findCommentClose(scalars: [Unicode.Scalar], from: Int, end: Int) -> Int? {
        var j = from
        while j + 2 < end {
            if scalars[j].value == 0x2D, scalars[j + 1].value == 0x2D, scalars[j + 2].value == 0x3E {
                return j
            }
            j += 1
        }
        return nil
    }

    private static func autolinkEnd(scalars: [Unicode.Scalar], after: Int, end: Int) -> Int? {
        // The `<` sits at `after - 1`; accept `http://` / `https://` prefixes.
        func matches(_ prefix: String, at i: Int) -> Bool {
            let p = Array(prefix.unicodeScalars)
            guard i + p.count <= end else { return false }
            for k in p.indices where scalars[i + k].value != p[k].value { return false }
            return true
        }
        guard matches("http://", at: after) || matches("https://", at: after) else { return nil }
        var j = after
        let limit = min(end, after + maxConstructScan)
        while j < limit, scalars[j].value != 0x0A, scalars[j].value != 0x3C {
            if scalars[j].value == 0x3E { return j }
            j += 1
        }
        return nil
    }

    // MARK: - Fences and lines

    private struct FenceState {
        let char: UInt32
        let length: Int
        let isMath: Bool
        let blockStart: Int
        let contentStart: Int
        var contentEnd: Int
    }

    private struct LineBounds {
        let start: Int       // first scalar of the line content
        let contentEnd: Int  // index of the line's trailing \n (or count)
        let end: Int         // contentEnd + 1 (or count)
    }

    private static func lineBounds(_ scalars: [Unicode.Scalar]) -> [LineBounds] {
        var lines: [LineBounds] = []
        var start = 0
        for i in scalars.indices where scalars[i].value == 0x0A {
            lines.append(LineBounds(start: start, contentEnd: i, end: i + 1))
            start = i + 1
        }
        lines.append(LineBounds(start: start, contentEnd: scalars.count, end: scalars.count))
        return lines
    }

    private static func emitFence(
        scalars: [Unicode.Scalar], state: FenceState, blockEnd: Int,
        spans: inout [LocatedSpan], output: inout [Unicode.Scalar],
    ) {
        if state.isMath {
            let tex = trimmedTeX(scalars: scalars, range: state.contentStart..<state.contentEnd)
            if tex.isEmpty {
                output.append(contentsOf: scalars[state.blockStart..<blockEnd])
            } else {
                spans.append(LocatedSpan(span: MathSpan(tex: tex, isDisplay: true), source: state.blockStart..<blockEnd))
                appendPlaceholder(
                    &output, index: spans.count - 1,
                    lineBreaks: Array(repeating: [], count: newlineCount(scalars: scalars, range: state.blockStart..<blockEnd)),
                )
            }
        } else {
            output.append(contentsOf: scalars[state.blockStart..<blockEnd])
        }
    }

    private static func fenceOpenInfo(
        scalars: [Unicode.Scalar], line: LineBounds, inList: Bool,
    ) -> (char: UInt32, length: Int, isMath: Bool)? {
        var i = line.start
        var spaces = 0
        while i < line.contentEnd, scalars[i].value == 0x20 {
            i += 1
            spaces += 1
        }
        guard spaces <= 3 || inList, i < line.contentEnd else { return nil }
        let c = scalars[i].value
        guard c == 0x60 || c == 0x7E else { return nil }
        var j = i
        while j < line.contentEnd, scalars[j].value == c { j += 1 }
        let length = j - i
        guard length >= 3 else { return nil }
        // Info string: first word `math` (case-insensitive) → math fence.
        var k = j
        while k < line.contentEnd, scalars[k].value == 0x20 || scalars[k].value == 0x09 { k += 1 }
        var isMath = false
        if k < line.contentEnd {
            var wordEnd = k
            while wordEnd < line.contentEnd,
                  scalars[wordEnd].value != 0x20 && scalars[wordEnd].value != 0x09
            {
                wordEnd += 1
            }
            isMath = string(from: scalars[k..<wordEnd]).lowercased() == "math"
        }
        return (c, length, isMath)
    }

    private static func isClosingFence(scalars: [Unicode.Scalar], line: LineBounds, state: FenceState) -> Bool {
        var i = line.start
        var spaces = 0
        while i < line.contentEnd, scalars[i].value == 0x20 {
            i += 1
            spaces += 1
        }
        guard spaces <= 3 else { return false }
        var j = i
        while j < line.contentEnd, scalars[j].value == state.char { j += 1 }
        let length = j - i
        while j < line.contentEnd, scalars[j].value == 0x20 { j += 1 }
        return length >= state.length && j == line.contentEnd
    }

    private static func trimmedTeX(scalars: [Unicode.Scalar], range: Range<Int>) -> String {
        trimmedTeX(scalars[range])
    }

    private static func trimmedTeX(_ scalars: some Collection<Unicode.Scalar>) -> String {
        let content = Array(scalars)
        var lo = 0
        var hi = content.count
        while lo < hi, isWhitespaceScalar(content[lo]) { lo += 1 }
        while hi > lo, isWhitespaceScalar(content[hi - 1]) { hi -= 1 }
        return string(from: content[lo..<hi])
    }

    /// The scalars of a span's content in `range` without the blockquote
    /// markers (`>`) that start its continuation lines — as many as the line
    /// where the span opened (at `openedAt`) has — and, for each line break,
    /// the markers removed after it. A formula quoted over several lines
    /// would otherwise draw the `>`s, and the line breaks the placeholder
    /// keeps need the markers back to stay inside the quote.
    private static func strippingQuoteMarkers(
        scalars: [Unicode.Scalar], range: Range<Int>, openedAt: Int, freeStart: Int,
    ) -> (scalars: [Unicode.Scalar], lineBreaks: [ArraySlice<Unicode.Scalar>]) {
        // Only a span over several lines has markers to strip; finding the
        // line start for every span would make a long line quadratic.
        guard scalars[range].contains("\n") else { return (Array(scalars[range]), []) }
        var lineStart = openedAt
        while lineStart > freeStart, scalars[lineStart - 1] != "\n" { lineStart -= 1 }
        let depth = quoteMarkers(scalars: scalars, from: lineStart, end: openedAt, maxDepth: .max).depth

        var content: [Unicode.Scalar] = []
        var lineBreaks: [ArraySlice<Unicode.Scalar>] = []
        var j = range.lowerBound
        while j < range.upperBound {
            content.append(scalars[j])
            if scalars[j] == "\n" {
                let prefixEnd = depth > 0
                    ? quoteMarkers(scalars: scalars, from: j + 1, end: range.upperBound, maxDepth: depth).end
                    : j + 1
                lineBreaks.append(scalars[(j + 1)..<prefixEnd])
                j = prefixEnd
                continue
            }
            j += 1
        }
        return (content, lineBreaks)
    }

    /// Up to `maxDepth` blockquote markers (up to three spaces, `>`, an
    /// optional space) starting at `start`: how many there are and where
    /// they end.
    private static func quoteMarkers(scalars: [Unicode.Scalar], from start: Int, end: Int, maxDepth: Int) -> (depth: Int, end: Int) {
        var depth = 0
        var markersEnd = start
        var j = start
        while depth < maxDepth {
            var k = j
            while k < end, k - j < 3, scalars[k] == " " { k += 1 }
            guard k < end, scalars[k] == ">" else { break }
            k += 1
            if k < end, scalars[k] == " " || scalars[k] == "\t" { k += 1 }
            depth += 1
            markersEnd = k
            j = k
        }
        return (depth, markersEnd)
    }

    private static func string(from scalars: some Sequence<Unicode.Scalar>) -> String {
        var result = ""
        result.unicodeScalars.append(contentsOf: scalars)
        return result
    }

    private static func isBlankLine(scalars: [Unicode.Scalar], line: LineBounds) -> Bool {
        for i in line.start..<line.contentEnd where !isWhitespaceScalar(scalars[i]) {
            return false
        }
        return true
    }

    /// Whether one of `blankLines` (in document order) lies wholly inside
    /// `range`: a binary search, as every delimiter candidate asks.
    private static func containsBlankLine(_ blankLines: [LineBounds], range: Range<Int>) -> Bool {
        var low = 0
        var high = blankLines.count
        while low < high {
            let middle = (low + high) / 2
            if blankLines[middle].start < range.lowerBound { low = middle + 1 } else { high = middle }
        }
        return low < blankLines.count && blankLines[low].contentEnd <= range.upperBound
    }

    private static func leadingWidth(scalars: [Unicode.Scalar], line: LineBounds) -> Int {
        var width = 0
        for i in line.start..<line.contentEnd {
            if scalars[i].value == 0x20 {
                width += 1
            } else if scalars[i].value == 0x09 {
                width += 4
            } else {
                break
            }
        }
        return width
    }

    /// Bullet/ordered list marker at ≤3 leading spaces (the same shape the
    /// renderer's list scanner accepts).
    /// The column a list item's content starts at, when `line` opens one
    /// (`- `, `* `, `+ `, `1. `, `1) `); nested items count while `inList`.
    private static func listItemContentIndent(scalars: [Unicode.Scalar], line: LineBounds, inList: Bool) -> Int? {
        var i = line.start
        var spaces = 0
        while i < line.contentEnd, scalars[i].value == 0x20 {
            i += 1
            spaces += 1
        }
        guard spaces <= 3 || inList, i < line.contentEnd else { return nil }
        let c = scalars[i].value
        var markerEnd: Int
        if c == 0x2D || c == 0x2A || c == 0x2B { // - * +
            markerEnd = i + 1
        } else {
            var j = i
            while j < line.contentEnd, (0x30...0x39).contains(scalars[j].value) { j += 1 }
            guard j > i, j - i <= 9, j < line.contentEnd else { return nil }
            let punct = scalars[j].value
            guard punct == 0x2E || punct == 0x29 else { return nil }
            markerEnd = j + 1
        }
        guard markerEnd < line.contentEnd, scalars[markerEnd].value == 0x20 else { return nil }
        var gap = 0
        while markerEnd + gap < line.contentEnd, scalars[markerEnd + gap].value == 0x20 { gap += 1 }
        // One to four spaces set the content column; more mean the content
        // is indented code one space after the marker.
        let markerWidth = markerEnd - line.start
        return markerWidth + (gap <= 4 ? gap : 1)
    }

    private static func isWhitespaceScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09, 0x0A, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x20:
            return true
        case 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    private static func newlineCount(scalars: [Unicode.Scalar], range: Range<Int>) -> Int {
        var count = 0
        for i in range where scalars[i].value == 0x0A { count += 1 }
        return count
    }

    /// How far the scans for a link destination, an autolink or an HTML tag
    /// look: each starts at every `](` or `<`, so an unbounded scan makes a
    /// long line of them quadratic. Real ones are far shorter.
    private static let maxConstructScan = 2048

    /// The `>` closing a raw HTML tag that starts after `<` at `start`
    /// (`<a href=…>`, `</a>`, `<br/>`), on the same line, or nil. The tag
    /// name must be ASCII and end at a space, `/` or `>`, so prose such as
    /// `x <y, $z$ > 1` is not taken for a tag.
    private static func htmlTagEnd(scalars: [Unicode.Scalar], after start: Int, end lineEnd: Int) -> Int? {
        // CommonMark's grammar, kept to one line: `</name>` or
        // `<name attr="v" attr2=v attr3>`; prose such as `a <b and $x > y$`
        // fails at `$x`, which cannot start an attribute name.
        let end = min(lineEnd, start + maxConstructScan)
        var j = start
        func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
            scalar.isASCII && scalar.properties.isAlphabetic
        }
        func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
            ("0"..."9").contains(scalar)
        }
        func skipSpaces() -> Bool {
            let from = j
            while j < end, scalars[j] == " " || scalars[j] == "\t" { j += 1 }
            return j > from
        }
        let isClosing = j < end && scalars[j] == "/"
        if isClosing { j += 1 }
        guard j < end, isASCIILetter(scalars[j]) else { return nil }
        while j < end, isASCIILetter(scalars[j]) || isASCIIDigit(scalars[j]) || scalars[j] == "-" { j += 1 }
        if isClosing {
            _ = skipSpaces()
            return j < end && scalars[j] == ">" ? j : nil
        }
        while true {
            let spaced = skipSpaces()
            guard j < end else { return nil }
            if scalars[j] == ">" { return j }
            if scalars[j] == "/" {
                return j + 1 < end && scalars[j + 1] == ">" ? j + 1 : nil
            }
            // An attribute: name, then optionally `=` and a value.
            guard spaced, isASCIILetter(scalars[j]) || scalars[j] == "_" || scalars[j] == ":" else { return nil }
            while j < end, isASCIILetter(scalars[j]) || isASCIIDigit(scalars[j]) || "_.:-".unicodeScalars.contains(scalars[j]) { j += 1 }
            let afterName = j
            _ = skipSpaces()
            guard j < end, scalars[j] == "=" else {
                j = afterName
                continue
            }
            j += 1
            _ = skipSpaces()
            guard j < end else { return nil }
            if scalars[j] == "\"" || scalars[j] == "'" {
                let quote = scalars[j]
                j += 1
                while j < end, scalars[j] != quote { j += 1 }
                guard j < end else { return nil }
                j += 1
            } else {
                let valueStart = j
                while j < end, !" \t\"'=<>`".unicodeScalars.contains(scalars[j]) { j += 1 }
                guard j > valueStart else { return nil }
            }
        }
    }

    /// The end of a bare `http://`, `https://` or `www.` URL starting at
    /// `start` (at a word boundary), which runs to the next whitespace or
    /// `<`; nil when no URL starts there.
    private static func bareURLEnd(scalars: [Unicode.Scalar], at start: Int, range: Range<Int>) -> Int? {
        let first = scalars[start]
        guard first == "h" || first == "w" else { return nil }
        if start > range.lowerBound {
            let previous = scalars[start - 1].properties
            if previous.isAlphabetic || previous.numericType != nil { return nil }
        }
        func matches(_ prefix: String) -> Bool {
            let p = Array(prefix.unicodeScalars)
            guard start + p.count <= range.upperBound else { return false }
            for k in p.indices where scalars[start + k] != p[k] { return false }
            return true
        }
        guard matches("http://") || matches("https://") || matches("www.") else { return nil }
        var j = start
        while j < range.upperBound, !scalars[j].properties.isWhitespace, scalars[j] != "<" {
            j += 1
        }
        return j
    }

    /// The `)` closing an inline link's destination and optional title,
    /// which start at `start` (just after `](`), or nil when what follows is
    /// not one: a destination is `<…>` or a run without spaces (parentheses
    /// balanced, backslash escapes), and a title is quoted with `"`, `'` or
    /// parentheses. All on one line.
    private static func linkDestinationEnd(scalars: [Unicode.Scalar], from start: Int, end lineEnd: Int) -> Int? {
        let end = min(lineEnd, start + maxConstructScan)
        var j = start
        func skipSpaces() {
            while j < end, scalars[j] == " " || scalars[j] == "\t" { j += 1 }
        }
        // Another `](` ends the attempt, so a line of them stays linear.
        func opensAnotherLink() -> Bool {
            scalars[j] == "]" && j + 1 < end && scalars[j + 1] == "("
        }
        skipSpaces()
        if j < end, scalars[j] == "<" {
            j += 1
            while j < end, scalars[j] != ">" {
                if scalars[j] == "\n" || scalars[j] == "<" || opensAnotherLink() { return nil }
                j += scalars[j] == "\\" ? 2 : 1
            }
            guard j < end else { return nil }
            j += 1
        } else {
            var depth = 0
            while j < end {
                let scalar = scalars[j]
                if scalar == "\\" {
                    j += 2
                    continue
                }
                if scalar.properties.isWhitespace || scalar.value < 0x20 { break }
                if opensAnotherLink() { return nil }
                if scalar == "(" {
                    depth += 1
                } else if scalar == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                j += 1
            }
            guard depth == 0 else { return nil }
        }
        let destinationEnd = j
        skipSpaces()
        if j < end, j > destinationEnd, let closer = titleCloser(for: scalars[j]) {
            j += 1
            while j < end, scalars[j] != closer {
                if scalars[j] == "\n" || opensAnotherLink() { return nil }
                j += scalars[j] == "\\" ? 2 : 1
            }
            guard j < end else { return nil }
            j += 1
            skipSpaces()
        }
        guard j < end, scalars[j] == ")" else { return nil }
        return j
    }

    private static func titleCloser(for opener: Unicode.Scalar) -> Unicode.Scalar? {
        switch opener {
        case "\"": "\""
        case "'": "'"
        case "(": ")"
        default: nil
        }
    }

    /// The placeholder, then the span's line breaks (each followed by the
    /// quote markers its line had), so the line structure stays intact.
    private static func appendPlaceholder(_ output: inout [Unicode.Scalar], index: Int, lineBreaks: [ArraySlice<Unicode.Scalar>]) {
        output.append(contentsOf: placeholder(for: index).unicodeScalars)
        for markers in lineBreaks {
            output.append("\n")
            output.append(contentsOf: markers)
        }
    }
}
