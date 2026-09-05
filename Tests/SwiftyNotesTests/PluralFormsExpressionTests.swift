import Foundation
import Testing

/// The evaluator the catalogue guards use to ask a language which plural form
/// a count selects. It exists because the answer is not the index order: a
/// guard that assumed "form 0 is the singular" would be wrong about Arabic,
/// whose form 0 is the zero form.
@Suite("Plural-Forms expression")
struct PluralFormsExpressionTests {
    private static let germanic = "(n != 1)"
    private static let romance = "(n > 1)"
    private static let single = "0"
    private static let russian = """
    (n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2)
    """
    private static let arabic = """
    (n==0 ? 0 : n==1 ? 1 : n==2 ? 2 : n%100>=3 && n%100<=10 ? 3 : n%100>=11 ? 4 : 5)
    """

    @Test("The two-form rules split the singular from everything else")
    func twoFormRulesSplitTheSingularFromEverythingElse() throws {
        let germanic = try PluralFormsExpression(Self.germanic)
        #expect([0, 2, 3, 11].map(germanic.form(for:)) == [1, 1, 1, 1])
        #expect(germanic.form(for: 1) == 0)

        // French counts zero with the singular; German does not.
        let romance = try PluralFormsExpression(Self.romance)
        #expect([0, 1].map(romance.form(for:)) == [0, 0])
        #expect([2, 3, 11].map(romance.form(for:)) == [1, 1, 1])
    }

    @Test("A single-form rule answers 0 for every count")
    func singleFormRuleAnswersZeroForEveryCount() throws {
        let expression = try PluralFormsExpression(Self.single)
        #expect(Set((0 ... 200).map(expression.form(for:))) == [0])
    }

    @Test("The Russian rule picks one, few and many by the last digits")
    func russianRulePicksOneFewAndManyByTheLastDigits() throws {
        let expression = try PluralFormsExpression(Self.russian)
        #expect([1, 21, 101].map(expression.form(for:)) == [0, 0, 0])
        #expect([2, 4, 23, 104].map(expression.form(for:)) == [1, 1, 1, 1])
        #expect([0, 5, 11, 12, 14, 25, 111].map(expression.form(for:)) == [2, 2, 2, 2, 2, 2, 2])
    }

    @Test("The Arabic rule reserves form 0 for zero and form 2 for the dual")
    func arabicRuleReservesFormZeroForZeroAndFormTwoForTheDual() throws {
        let expression = try PluralFormsExpression(Self.arabic)
        #expect(expression.form(for: 0) == 0)
        #expect(expression.form(for: 1) == 1)
        #expect(expression.form(for: 2) == 2)
        #expect([3, 10, 103].map(expression.form(for:)) == [3, 3, 3])
        #expect([11, 99, 111].map(expression.form(for:)) == [4, 4, 4])
        #expect([100, 102, 1000].map(expression.form(for:)) == [5, 5, 5])
    }

    @Test("A whole Plural-Forms header parses, and a header without one does not")
    func wholePluralFormsHeaderParsesAndAHeaderWithoutOneDoesNot() throws {
        let header = """
        "Content-Type: text/plain; charset=UTF-8\\n"
        "Plural-Forms: nplurals=2; plural=(n != 1);\\n"
        """
        let expression = try #require(try PluralFormsExpression(header: header))
        #expect(expression.form(for: 1) == 0)
        #expect(expression.form(for: 7) == 1)

        #expect(try PluralFormsExpression(header: "nplurals=2;") == nil)
    }

    @Test("Operator precedence follows C, not left-to-right")
    func operatorPrecedenceFollowsCNotLeftToRight() throws {
        // n % 10 == 1 must group as (n % 10) == 1; left-to-right would make it
        // n % (10 == 1) and answer 0 for every count.
        let expression = try PluralFormsExpression("n % 10 == 1")
        #expect([1, 21].map(expression.form(for:)) == [1, 1])
        #expect([2, 10].map(expression.form(for:)) == [0, 0])

        // && binds tighter than ||.
        let mixed = try PluralFormsExpression("n == 1 || n > 100 && n < 200")
        #expect([1, 150].map(mixed.form(for:)) == [1, 1])
        #expect([2, 300].map(mixed.form(for:)) == [0, 0])
    }

    @Test("Only the forms that mean a plain plural are collected")
    func onlyTheFormsThatMeanAPlainPluralAreCollected() throws {
        // Two-form and one-form languages have nothing left to compare once
        // the singular is out: whatever remains is a single form.
        #expect(try PluralFormsExpression(Self.germanic).formsThatOnlyMeanPlural() == [1])
        #expect(try PluralFormsExpression(Self.romance).formsThatOnlyMeanPlural() == [1])
        #expect(try PluralFormsExpression(Self.single).formsThatOnlyMeanPlural() == [])

        // Russian's 2-4 form is not a dual — 3 and 4 select it too — so it
        // stays in and has to read like the 5+ form. Its singular drops out
        // even though 21 and 101 also select it.
        #expect(try PluralFormsExpression(Self.russian).formsThatOnlyMeanPlural() == [1, 2])

        // Arabic's dual is selected by nothing but two, so it drops out
        // alongside the zero and one forms.
        #expect(try PluralFormsExpression(Self.arabic).formsThatOnlyMeanPlural() == [3, 4, 5])
    }

    @Test("A malformed expression throws rather than answering a wrong form")
    func malformedExpressionThrowsRatherThanAnsweringAWrongForm() {
        #expect(throws: PluralFormsExpression.ParseError.self) {
            _ = try PluralFormsExpression("n ==")
        }
        #expect(throws: PluralFormsExpression.ParseError.self) {
            _ = try PluralFormsExpression("(n != 1")
        }
        #expect(throws: PluralFormsExpression.ParseError.self) {
            _ = try PluralFormsExpression("n $ 1")
        }
        #expect(throws: PluralFormsExpression.ParseError.self) {
            _ = try PluralFormsExpression("n != 1)")
        }
    }
}
