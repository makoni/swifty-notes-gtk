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
}
