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
        let scalars = markdown.unicodeScalars.map(sanitized)
        let lines = lineBounds(scalars)
        var spans: [LocatedSpan] = []
        var output: [Unicode.Scalar] = []
        var inList = false
        var previousLineWasBlank = true
        var freeStart: Int?
        var freeEnd: Int?
        var fence: FenceState?

        func flushFreeText() {
            guard let start = freeStart, let end = freeEnd else { return }
            freeStart = nil
            freeEnd = nil
            scanFreeText(scalars: scalars, range: start..<end, lines: lines, spans: &spans, output: &output)
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

            if let open = fenceOpenInfo(scalars: scalars, line: line, inList: inList) {
                flushFreeText()
                fence = FenceState(
                    char: open.char, length: open.length, isMath: open.isMath,
                    blockStart: line.start, contentStart: line.end, contentEnd: line.end,
                )
                previousLineWasBlank = false
                continue
            }

            if !isBlank, leadingWidth(scalars: scalars, line: line) >= 4, !inList, previousLineWasBlank {
                flushFreeText()
                output.append(contentsOf: scalars[line.start..<line.end])
                previousLineWasBlank = false
                continue
            }

            // Free line (blank lines are free too — they keep spans from
            // spanning across them).
            if freeStart == nil { freeStart = line.start }
            freeEnd = line.end
            previousLineWasBlank = isBlank
            if isBlank { continue }
            if parseListMarker(scalars: scalars, line: line) {
                inList = true
            } else if leadingWidth(scalars: scalars, line: line) < 4 {
                inList = false
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
        lines: [LineBounds],
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
                        output.append(contentsOf: scalars[i...(close + 3)])
                        i = close + 4
                        continue
                    }
                    // Unclosed comment: swallow the rest of this free-text stretch.
                    output.append(contentsOf: scalars[i..<end])
                    i = end
                    continue
                }
            }

            if s.value == 0x60 { // backtick
                let run = backtickRunLength(scalars: scalars, from: i, end: end)
                if let close = findCodeSpanClose(scalars: scalars, from: i + run, end: end, length: run, lines: lines) {
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
                    if let close = findDisplayClose(scalars: scalars, from: i + 2, end: end, lines: lines) {
                        let tex = trimmedTeX(scalars: scalars, range: (i + 2)..<close)
                        if tex.isEmpty {
                            output.append(s)
                            i += 1
                        } else {
                            spans.append(LocatedSpan(span: MathSpan(tex: tex, isDisplay: true), source: i..<(close + 2)))
                            appendPlaceholder(&output, index: spans.count - 1, newlines: newlineCount(scalars: scalars, range: i..<(close + 2)))
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
                    if let close = findInlineClose(scalars: scalars, from: i + 1, end: end, lines: lines) {
                        let tex = string(from: scalars[(i + 1)..<close])
                            .replacingOccurrences(of: "\n", with: " ")
                        spans.append(LocatedSpan(span: MathSpan(tex: tex, isDisplay: false), source: i..<(close + 1)))
                        appendPlaceholder(&output, index: spans.count - 1, newlines: newlineCount(scalars: scalars, range: i..<close))
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

    private static func findDisplayClose(scalars: [Unicode.Scalar], from: Int, end: Int, lines: [LineBounds]) -> Int? {
        var j = from
        while j + 1 < end {
            if scalars[j].value == 0x24, scalars[j + 1].value == 0x24 {
                // Once a blank line is crossed, every later candidate is
                // equally invalid — stop.
                return containsBlankLine(scalars: scalars, lines: lines, range: from..<j) ? nil : j
            }
            j += 1
        }
        return nil
    }

    private static func findInlineClose(scalars: [Unicode.Scalar], from: Int, end: Int, lines: [LineBounds]) -> Int? {
        var j = from
        while j < end {
            if scalars[j].value == 0x24 {
                let prevIsSpace = isWhitespaceScalar(scalars[j - 1])
                let after: UInt32? = j + 1 < end ? scalars[j + 1].value : nil
                let afterIsDigit = after.map { (0x30...0x39).contains($0) } ?? false
                // First candidate decides: invalid → the open `$` is literal.
                if prevIsSpace || afterIsDigit {
                    return nil
                }
                return containsBlankLine(scalars: scalars, lines: lines, range: from..<j) ? nil : j
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
        scalars: [Unicode.Scalar], from: Int, end: Int, length: Int, lines: [LineBounds],
    ) -> Int? {
        var j = from
        while j < end {
            if scalars[j].value == 0x60 {
                var k = j
                while k < end, scalars[k].value == 0x60 { k += 1 }
                if k - j == length {
                    // A code span never spans a blank line (approximation of
                    // the CommonMark rule that it stays inside one paragraph).
                    return containsBlankLine(scalars: scalars, lines: lines, range: from..<j) ? nil : j
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
        while j < end, scalars[j].value != 0x0A {
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
                    newlines: newlineCount(scalars: scalars, range: state.blockStart..<blockEnd),
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
        var lo = range.lowerBound
        var hi = range.upperBound
        while lo < hi, isWhitespaceScalar(scalars[lo]) { lo += 1 }
        while hi > lo, isWhitespaceScalar(scalars[hi - 1]) { hi -= 1 }
        return string(from: scalars[lo..<hi])
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

    private static func containsBlankLine(scalars: [Unicode.Scalar], lines: [LineBounds], range: Range<Int>) -> Bool {
        for line in lines where line.start >= range.lowerBound && line.contentEnd <= range.upperBound {
            if isBlankLine(scalars: scalars, line: line) { return true }
        }
        return false
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
    private static func parseListMarker(scalars: [Unicode.Scalar], line: LineBounds) -> Bool {
        var i = line.start
        var spaces = 0
        while i < line.contentEnd, scalars[i].value == 0x20 {
            i += 1
            spaces += 1
        }
        guard spaces <= 3, i < line.contentEnd else { return false }
        let c = scalars[i].value
        if c == 0x2D || c == 0x2A || c == 0x2B { // - * +
            let next = i + 1
            return next < line.contentEnd && scalars[next].value == 0x20
        }
        var j = i
        while j < line.contentEnd, (0x30...0x39).contains(scalars[j].value) { j += 1 }
        guard j > i, j < line.contentEnd else { return false }
        let punct = scalars[j].value
        guard punct == 0x2E || punct == 0x29 else { return false }
        let afterPunct = j + 1
        return afterPunct < line.contentEnd && scalars[afterPunct].value == 0x20
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

    private static func appendPlaceholder(_ output: inout [Unicode.Scalar], index: Int, newlines: Int) {
        output.append(contentsOf: placeholder(for: index).unicodeScalars)
        for _ in 0..<newlines { output.append("\n") }
    }
}
