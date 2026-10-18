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
        #expect(result.markup == pangoHighlightedMarkup("Costs <$5>", query: "costs"))
        #expect(result.spans.isEmpty)
    }

    @Test("Formulas read as plain text", arguments: [
        ("Формулы $e^{i\\pi} + 1 = 0$", "Формулы e^{iπ} + 1 = 0"),
        ("$\\frac{a}{b}$, $\\frac{12}{25}$ and $\\frac{-b}{2a}$", "a/b, 12/25 and (-b)/(2a)"),
        ("$\\alpha \\le \\beta \\cdot \\gamma$", "α ≤ β · γ"),
        ("Area $\\text{A} = \\pi r^2$", "Area A = π r^2"),
        ("Costs $5 and $10", "Costs $5 and $10"),
        ("Unknown $\\weird{x}$", "Unknown \\weird{x}"),
    ])
    func formulasReadAsPlainText(text: String, expected: String) {
        #expect(MathInlineText.readable(text) == expected)
    }
}
