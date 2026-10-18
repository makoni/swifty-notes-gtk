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
