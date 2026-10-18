import Foundation
import Testing
@testable import SwiftyNotes

struct MathSpanExtractorTests {
    /// Runs the extractor and asserts the line-structure invariant on the
    /// way: the output must have exactly the input's line count.
    private func extract(_ markdown: String) -> (markdown: String, spans: [MathSpan]) {
        let result = MathSpanExtractor.extract(from: markdown)
        #expect(
            markdown.components(separatedBy: "\n").count == result.markdown.components(separatedBy: "\n").count,
            "line count must be preserved: \(markdown) -> \(result.markdown)",
        )
        return result
    }

    @Test("Roots produce two inline spans")
    func rootsProduceTwoInlineSpans() {
        let result = extract("Roots $x^*$ and $y^*$ here")
        #expect(result.spans.count == 2)
        #expect(result.spans.map(\.tex) == ["x^*", "y^*"])
        #expect(result.spans.allSatisfy { !$0.isDisplay })
        #expect(
            result.markdown
                == "Roots \(MathSpanExtractor.placeholder(for: 0)) and \(MathSpanExtractor.placeholder(for: 1)) here",
        )
    }

    @Test("Set builder with braces is one inline span")
    func setBuilderIsOneInlineSpan() {
        let result = extract("Set $\\{x \\mid x>0\\}$")
        #expect(result.spans.count == 1)
        #expect(result.spans[0].tex == "\\{x \\mid x>0\\}")
        #expect(!result.spans[0].isDisplay)
    }

    @Test("pmatrix keeps doubled backslashes")
    func pmatrixKeepsDoubledBackslashes() {
        let result = extract("A = $\\begin{pmatrix} 1 \\\\ 2 \\end{pmatrix}$")
        #expect(result.spans.count == 1)
        #expect(result.spans[0].tex == "\\begin{pmatrix} 1 \\\\ 2 \\end{pmatrix}")
    }

    @Test("Two dollars around amounts are not math")
    func twoDollarsAroundAmountsAreNotMath() {
        let result = extract("It costs $5 and $10.")
        #expect(result.spans.isEmpty)
        #expect(result.markdown == "It costs $5 and $10.")
    }

    @Test("Thousands with commas are not math")
    func thousandsWithCommasAreNotMath() {
        let result = extract("$20,000 and $30,000")
        #expect(result.spans.isEmpty)
        #expect(result.markdown == "$20,000 and $30,000")
    }

    @Test("Escaped dollar is never a delimiter")
    func escapedDollarIsNeverADelimiter() {
        let result = extract("Price is \\$5")
        #expect(result.spans.isEmpty)
        #expect(result.markdown == "Price is \\$5")
    }

    @Test("Inline code span is verbatim")
    func inlineCodeSpanIsVerbatim() {
        let result = extract("`code $x$`")
        #expect(result.spans.isEmpty)
        #expect(result.markdown == "`code $x$`")
    }

    @Test("Fenced block is verbatim")
    func fencedBlockIsVerbatim() {
        let markdown = "```\n$x$\n```"
        let result = extract(markdown)
        #expect(result.spans.isEmpty)
        #expect(result.markdown == markdown)
    }

    @Test("Indented code is verbatim")
    func indentedCodeIsVerbatim() {
        let markdown = "\n    $x$\n"
        let result = extract(markdown)
        #expect(result.spans.isEmpty)
        #expect(result.markdown == markdown)
    }

    @Test("Multiline display math becomes one display span")
    func multilineDisplayMathBecomesOneDisplaySpan() {
        // Input: `$$\n\int_0^1 f\n$$` (the multiline literal carries no
        // trailing newline), so the span holds two newlines and the output
        // is the placeholder followed by those two (line count preserved).
        let result = extract("""
            $$
            \\int_0^1 f
            $$
            """)
        #expect(result.spans.count == 1)
        #expect(result.spans[0].isDisplay)
        #expect(result.spans[0].tex == "\\int_0^1 f")
        #expect(result.markdown == "\(MathSpanExtractor.placeholder(for: 0))\n\n")
    }

    @Test("Single-line display math becomes one display span")
    func singleLineDisplayMathBecomesOneDisplaySpan() {
        let result = extract("$$a=b$$")
        #expect(result.spans.count == 1)
        #expect(result.spans[0].isDisplay)
        #expect(result.spans[0].tex == "a=b")
        #expect(result.markdown == MathSpanExtractor.placeholder(for: 0))
    }

    @Test("math fence is one display span")
    func mathFenceIsOneDisplaySpan() {
        let result = extract("```math\nx+y\n```")
        #expect(result.spans.count == 1)
        #expect(result.spans[0].isDisplay)
        #expect(result.spans[0].tex == "x+y")
        #expect(result.markdown == "\(MathSpanExtractor.placeholder(for: 0))\n\n")
    }

    @Test("Display math with a blank line inside is not math")
    func displayMathWithBlankLineInsideIsNotMath() {
        let markdown = "$$\na\n\nb\n$$"
        let result = extract(markdown)
        #expect(result.spans.isEmpty)
        #expect(result.markdown == markdown)
    }

    @Test("Unclosed dollar is literal")
    func unclosedDollarIsLiteral() {
        let result = extract("The $x remains")
        #expect(result.spans.isEmpty)
        #expect(result.markdown == "The $x remains")
    }

    @Test("Inline span across a line break stores spaces")
    func inlineSpanAcrossLineBreakStoresSpaces() {
        let result = extract("$a\nb$")
        #expect(result.spans.count == 1)
        #expect(result.spans[0].tex == "a b")
        #expect(!result.spans[0].isDisplay)
        #expect(result.markdown == "\(MathSpanExtractor.placeholder(for: 0))\n")
    }

    @Test("Cyrillic and emoji around math")
    func cyrillicAndEmojiAroundMath() {
        let result = extract("Привет $x$ мир 🎉")
        #expect(result.spans.count == 1)
        #expect(result.spans[0].tex == "x")
        #expect(result.markdown == "Привет \(MathSpanExtractor.placeholder(for: 0)) мир 🎉")
    }

    @Test("Placeholder round-trips through spanIndices")
    func placeholderRoundTripsThroughSpanIndices() {
        for index in [0, 1, 5, 9, 10, 100, 999] {
            let placeholder = MathSpanExtractor.placeholder(for: index)
            let text = "a \(placeholder) b \(placeholder) c"
            let found = MathSpanExtractor.spanIndices(in: text)
            #expect(found.count == 2)
            #expect(found.map(\.index) == [index, index])
            let scalars = Array(text.unicodeScalars)
            for occurrence in found {
                #expect(String(String.UnicodeScalarView(scalars[occurrence.range])) == placeholder)
            }
        }
    }
    // MARK: - Each inline delimiter rule on its own

    @Test("A closing dollar after a space does not close")
    func aClosingDollarAfterASpaceDoesNotClose() {
        #expect(extract("$a $b").spans.isEmpty)
    }

    @Test("A closing dollar before a digit does not close")
    func aClosingDollarBeforeADigitDoesNotClose() {
        #expect(extract("$a$1").spans.isEmpty)
    }

    @Test("A dollar before a space does not open")
    func aDollarBeforeASpaceDoesNotOpen() {
        #expect(extract("$ a$").spans.isEmpty)
    }

    @Test("An escaped dollar does not open")
    func anEscapedDollarDoesNotOpen() {
        let result = extract("\\$x$")
        #expect(result.spans.isEmpty)
        #expect(result.markdown == "\\$x$")
    }

    @Test("An escaped dollar inside TeX does not close")
    func anEscapedDollarInsideTexDoesNotClose() {
        #expect(extract("$a\\$b$").spans == [MathSpan(tex: "a\\$b", isDisplay: false)])
        #expect(extract("$$\\$100 \\times 2$$").spans == [MathSpan(tex: "\\$100 \\times 2", isDisplay: true)])
    }

    // MARK: - Verbatim regions

    @Test("Verbatim regions keep their dollars", arguments: [
        "$a\n\nb$",
        "<https://example.com/$a$>",
        "<!-- $a$ -->",
        "~~~\n$a$\n~~~",
        "````\n$a$\n```\n$b$\n````",
        "- item\n\n      code $a$",
        "1. item\n\n       code $a$",
        "    $a$",
        "    code\n    $a$",
        "text\n\n    code\n\n    $a$",
    ])
    func verbatimRegionsKeepTheirDollars(markdown: String) {
        let result = extract(markdown)
        #expect(result.spans.isEmpty, "\(markdown)")
        #expect(result.markdown == markdown)
    }

    @Test("A code span cannot cross a blank line, so math after one is math")
    func aCodeSpanCannotCrossABlankLine() {
        #expect(extract("`a\n\n$b$` c`").spans == [MathSpan(tex: "b", isDisplay: false)])
    }

    @Test("An escaped dollar right before the closing pair stays in display TeX")
    func anEscapedDollarRightBeforeTheClosingPairStaysInDisplayTex() {
        #expect(extract("$$\\$$$").spans == [MathSpan(tex: "\\$", isDisplay: true)])
    }

    @Test("A comment at the very end, or right before math")
    func aCommentAtTheVeryEndOrRightBeforeMath() {
        #expect(extract("text <!-- $a$ -->").markdown == "text <!-- $a$ -->")
        #expect(extract("<!-- c -->$x$").spans == [MathSpan(tex: "x", isDisplay: false)])
    }

    @Test("Random Markdown-ish text never crashes and keeps its lines")
    func randomMarkdownIshTextNeverCrashesAndKeepsItsLines() {
        // A fixed linear congruential sequence, so a failure reproduces.
        var state: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        let pieces = ["$", "$$", "\\", "`", "```", "~~~", "<", ">", "<!--", "-->", "](", ")", "(", "[", "]",
                      "\n", "\n\n", " ", "    ", "> ", "- ", "a", "x^2", "http://", "www.", "<a ", "&", "\u{FFFC}", "\u{E000}"]
        for _ in 0..<3000 {
            let markdown = (0..<next(24)).map { _ in pieces[next(pieces.count)] }.joined()
            _ = extract(markdown)
            // Every span starts at a delimiter: `$`, or a fence's backtick or tilde.
            let scalars = Array(markdown.unicodeScalars)
            for range in MathSpanExtractor.sourceRanges(in: markdown) {
                #expect(["$", "`", "~"].contains(scalars[range.lowerBound]), "\(markdown.debugDescription)")
            }
        }
    }

    @Test("Indented text in a list item is a paragraph, not code")
    func indentedTextInAListItemIsAParagraphNotCode() {
        #expect(extract("- item\n\n    more $a$").spans == [MathSpan(tex: "a", isDisplay: false)])
        #expect(extract("- item\n  - nested\n\n      more $a$").spans == [MathSpan(tex: "a", isDisplay: false)])
        // A paragraph back at the margin ends the code block.
        #expect(extract("    code\n\nafter $a$").spans == [MathSpan(tex: "a", isDisplay: false)])
    }

    @Test("Long lines of link, autolink and tag openers stay fast")
    func longLinesOfLinkAutolinkAndTagOpenersStayFast() {
        // Each opener used to scan to the end of the line: seconds at 100 KB.
        for piece in ["](", "](a (", "](<", "<http://", "<a "] {
            let line = String(repeating: piece, count: 100_000 / piece.count) + " $x$"
            let start = ContinuousClock.now
            let result = MathSpanExtractor.extract(from: line)
            let elapsed = ContinuousClock.now - start
            #expect(result.spans == [MathSpan(tex: "x", isDisplay: false)], "\(piece)")
            #expect(elapsed < .milliseconds(1500), "\(piece): \(elapsed)")
        }
    }

    @Test("A fence indented four spaces is code, not a fence")
    func aFenceIndentedFourSpacesIsCodeNotAFence() {
        let result = extract("    ```math\n    x\n    ```")
        #expect(result.spans.isEmpty)
        #expect(result.markdown == "    ```math\n    x\n    ```")
    }
}
