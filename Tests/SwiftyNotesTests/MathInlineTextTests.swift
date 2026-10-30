import Foundation
import Testing
@testable import SwiftyNotes

struct MathInlineTextTests {
    @Test("A title with a formula becomes a marker and its span")
    func aTitleWithAFormulaBecomesAMarkerAndItsSpan() {
        let result = MathInlineText.markup(for: "Формулы $e^{i\\pi} + 1 = 0$ & <more>")
        #expect(result.markup == "Формулы \u{FFFC} &amp; &lt;more&gt;")
        #expect(result.spans == [MathSpan(tex: "e^{i\\pi} + 1 = 0", isDisplay: false)])
    }

    @Test("Text without formulas is only escaped")
    func textWithoutFormulasIsOnlyEscaped() {
        let result = MathInlineText.markup(for: "Costs $5 and $10 <b>")
        #expect(result.markup == "Costs $5 and $10 &lt;b&gt;")
        #expect(result.spans.isEmpty)
    }

    @Test("A stray object replacement character cannot pose as a formula")
    func aStrayObjectReplacementCharacterCannotPoseAsAFormula() {
        let result = MathInlineText.markup(for: "Odd \u{FFFC} and $x$")
        #expect(result.markup == "Odd \u{FFFD} and \u{FFFC}")
        #expect(result.spans.count == 1)
    }

    @Test("A filter match is highlighted, a formula it touches as a whole", arguments: [
        ("area", "<mark>Area</mark> \u{FFFC} here"),
        ("pi", "Area <mark>\u{FFFC}</mark> here"),
        ("a $", "Are<mark>a </mark><mark>\u{FFFC}</mark> here"),
        ("nothing", "Area \u{FFFC} here"),
    ])
    func aFilterMatchIsHighlighted(query: String, expected: String) {
        let result = MathInlineText.markup(for: "Area $\\pi r^2$ here", highlighting: query)
        let marked = result.markup
            .replacingOccurrences(of: pangoHighlightOpenTag, with: "<mark>")
            .replacingOccurrences(of: "</span>", with: "</mark>")
        #expect(marked == expected)
        #expect(result.spans == [MathSpan(tex: "\\pi r^2", isDisplay: false)])
    }

    @Test("Without formulas the filter highlight is the plain one")
    func withoutFormulasTheFilterHighlightIsThePlainOne() {
        let result = MathInlineText.markup(for: "Costs <$5>", highlighting: "costs")
        #expect(result.markup == pangoHighlightOpenTag + "Costs</span> &lt;$5&gt;")
        #expect(result.spans.isEmpty)
    }

    @Test("Deeply nested TeX is read without exhausting the stack")
    func deeplyNestedTeXIsReadWithoutExhaustingTheStack() {
        let depth = 100_000
        let braces = "$" + String(repeating: "{", count: depth) + "x" + String(repeating: "}", count: depth) + "$"
        let fractions = "$" + String(repeating: "\\frac{1}{", count: depth) + String(repeating: "}", count: depth) + "$"
        // Cut short for display, and never read past what fits on a line.
        #expect(MathInlineText.readable("Deep \(braces)").hasPrefix("Deep ${{{"))
        #expect(MathInlineText.readable(fractions).count == MathInlineText.maxShownCharacters + 1)
    }

    @Test("A title draws at most a few formulas; the rest stay source")
    func aTitleDrawsAtMostAFewFormulas() {
        let text = (0..<12).map { "$x_{\($0)}$" }.joined(separator: " ")
        let result = MathInlineText.markup(for: text)
        #expect(result.spans.count == MathInlineText.maxFormulas)
        let markers = result.markup.unicodeScalars.filter { $0 == MathSpanExtractor.formulaMarker }.count
        #expect(markers == MathInlineText.maxFormulas)
        #expect(result.markup.hasSuffix("$x_{10}$ $x_{11}$"))
    }

    @Test("A very long heading is shown cut short")
    func aVeryLongHeadingIsShownCutShort() {
        let heading = "Start $x$ " + String(repeating: "word ", count: 4000)
        let markup = MathInlineText.markup(for: heading, highlighting: "start")
        #expect(markup.spans.count == 1)
        #expect(markup.markup.count < MathInlineText.maxShownCharacters + 100)
        #expect(markup.markup.hasSuffix("…"))
        let readable = MathInlineText.readable(heading)
        #expect(readable.count <= MathInlineText.maxShownCharacters + 1)
        #expect(readable.hasSuffix("…"))
        #expect(readable.hasPrefix("Start x "))
    }

    @Test("A long formula in a title stays source")
    func aLongFormulaInATitleStaysSource() {
        // Short enough to show, too many bytes to draw (∑ is three).
        let long = String(repeating: "∑", count: MathInlineText.maxFormulaBytes / 3 + 1)
        let result = MathInlineText.markup(for: "Long $\(long)$ and $y$")
        #expect(result.spans == [MathSpan(tex: "y", isDisplay: false)])
        #expect(result.markup.hasPrefix("Long $∑∑"))
        #expect(result.markup.unicodeScalars.filter { $0 == MathSpanExtractor.formulaMarker }.count == 1)
    }

    @Test("Each marker sits where its own formula was written")
    func eachMarkerSitsWhereItsOwnFormulaWasWritten() {
        // A code span's dollars and an escaped one are not formulas, so the
        // markers must not drift onto them.
        let result = MathInlineText.markup(for: "`$a$` \\$ $b$ and $$c$$!")
        #expect(result.markup == "`$a$` \\$ \u{FFFC} and \u{FFFC}!")
        #expect(result.spans == [MathSpan(tex: "b", isDisplay: false), MathSpan(tex: "c", isDisplay: true)])
    }

    @Test("A stray object replacement character without formulas is not a marker")
    func aStrayObjectReplacementCharacterWithoutFormulasIsNotAMarker() {
        let result = MathInlineText.markup(for: "Odd \u{FFFC} title", highlighting: "odd")
        #expect(!result.markup.unicodeScalars.contains(MathSpanExtractor.formulaMarker))
        #expect(result.markup.contains("\u{FFFD}"))
    }

    @Test("Formulas read as plain text", arguments: [
        ("Формулы $e^{i\\pi} + 1 = 0$", "Формулы e^(iπ) + 1 = 0"),
        ("$\\frac{a}{b}$, $\\frac{12}{25}$ and $\\frac{-b}{2a}$", "a/b, 12/25 and (-b)/(2a)"),
        ("$\\alpha \\le \\beta \\cdot \\gamma$", "α ≤ β · γ"),
        ("Area $\\text{A} = \\pi r^2$", "Area A = π r^2"),
        ("Costs $5 and $10", "Costs $5 and $10"),
        ("Unknown $\\weird{x}$", "Unknown \\weird{x}"),
        ("$\\left. f \\right|_0$ and $a\\ b\\\\c$", " f |_0 and a b c"),
        ("$\\sqrt{x+1}$, $\\sqrt{2}$ and $x_{ij}^{2}$", "√(x+1), √2 and x_(ij)^2"),
        ("${a}{b}$", "ab"),
    ])
    func formulasReadAsPlainText(text: String, expected: String) {
        #expect(MathInlineText.readable(text) == expected)
    }
}
