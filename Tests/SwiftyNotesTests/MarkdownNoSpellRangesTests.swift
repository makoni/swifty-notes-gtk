import Foundation
@testable import SwiftyNotes
import Testing

struct MarkdownNoSpellRangesTests {
    @Test("Plain prose has no skip ranges")
    func plainProseHasNoSkipRanges() {
        let ranges = MarkdownNoSpellRanges.ranges(in: "This is just a paragraph.\n")
        #expect(ranges.isEmpty)
    }

    @Test("Inline backtick span is skipped")
    func inlineBacktickSpanIsSkipped() throws {
        let text = "Use `printf` to write."
        let ranges = MarkdownNoSpellRanges.ranges(in: text)
        #expect(ranges.count == 1)
        let range = try #require(ranges.first)
        let lower = text.index(text.startIndex, offsetBy: range.lowerBound)
        let upper = text.index(text.startIndex, offsetBy: range.upperBound)
        #expect(text[lower ..< upper] == "`printf`")
    }

    @Test("Unmatched inline backtick is left alone so the rest of the prose stays checkable")
    func unmatchedInlineBacktickIsLeftAloneSoTheRestOfTheProse() {
        let text = "We need a `lonely backtick to be ignored."
        let ranges = MarkdownNoSpellRanges.ranges(in: text)
        #expect(ranges.isEmpty)
    }

    @Test("Fenced code block from opener to closer is skipped including the fence lines")
    func fencedCodeBlockFromOpenerToCloserIsSkippedIncludingTheFence() throws {
        let text = """
        Some prose.
        ```swift
        let x = 1
        ```
        More prose.
        """
        let ranges = MarkdownNoSpellRanges.ranges(in: text)
        #expect(ranges.count == 1)
        let range = try #require(ranges.first)
        let lower = text.index(text.startIndex, offsetBy: range.lowerBound)
        let upper = text.index(text.startIndex, offsetBy: range.upperBound)
        let captured = String(text[lower ..< upper])
        #expect(captured.contains("```swift"))
        #expect(captured.contains("let x = 1"))
        #expect(captured.contains("```"))
    }

    @Test("Unterminated fence runs to the end of the document so trailing code keeps skipping")
    func unterminatedFenceRunsToTheEndOfTheDocumentSoTrailingCode() throws {
        let text = """
        ```
        let x = misspeled
        """
        let ranges = MarkdownNoSpellRanges.ranges(in: text)
        #expect(ranges.count == 1)
        let range = try #require(ranges.first)
        #expect(range.upperBound == text.count)
    }

    @Test("Inline backticks inside a fenced block do not produce extra ranges")
    func inlineBackticksInsideAFencedBlockDoNotProduceExtraRanges() {
        let text = """
        ```
        echo `whoami`
        ```
        """
        let ranges = MarkdownNoSpellRanges.ranges(in: text)
        #expect(ranges.count == 1)
    }

    @Test("Multiple inline spans on one line are reported separately")
    func multipleInlineSpansOnOneLineAreReportedSeparately() {
        let text = "Run `git status` and then `git push`."
        let ranges = MarkdownNoSpellRanges.ranges(in: text)
        #expect(ranges.count == 2)
    }

    @Test("Leaves TeX in math spans to the formula, not the spell checker")
    func leavesTexInMathSpansAlone() {
        let text = "Café: $\\frac{a}{b}$ and\n$$\n\\mathbb{R}\n$$\nend"
        let ranges = MarkdownNoSpellRanges.ranges(in: text)
        let scalars = Array(text.unicodeScalars)
        let covered = ranges.map { range in
            String(String.UnicodeScalarView(scalars[range]))
        }
        #expect(covered.contains("$\\frac{a}{b}$"))
        #expect(covered.contains("$$\n\\mathbb{R}\n$$"))
        #expect(!covered.contains { $0.contains("Café") || $0.contains("end") })
    }

    @Test("Ranges count code points, as GtkTextBuffer offsets do")
    func rangesCountCodePoints() {
        // 👍🏽 is one character but two code points.
        let text = "Hi 👍🏽 `code` and $x$"
        let ranges = MarkdownNoSpellRanges.ranges(in: text)
        let scalars = Array(text.unicodeScalars)
        #expect(ranges.map { String(String.UnicodeScalarView(scalars[$0])) } == ["`code`", "$x$"])
    }

    private func covered(_ text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        return MarkdownNoSpellRanges.ranges(in: text).map { String(String.UnicodeScalarView(scalars[$0])) }
    }

    @Test("A fence inside an indented code block is code, not a fence that runs on")
    func aFenceInsideAnIndentedCodeBlockIsCodeNotAFenceThatRunsOn() {
        // An unclosed ``` used to swallow the prose after the code block.
        let text = "Intro\n\n    ```\n    let x = 1\n\nSome prose wrods."
        #expect(covered(text) == ["    ```\n    let x = 1\n"])
    }

    @Test("Indented code blocks are skipped")
    func indentedCodeBlocksAreSkipped() {
        #expect(covered("Prose\n\n    misspeled code\n\nMore") == ["    misspeled code\n"])
        // Indented text in a list item is the item's paragraph, not code.
        #expect(covered("- item\n\n    more wrods").isEmpty)
    }

    @Test("Tilde fences are skipped and close only on tildes")
    func tildeFencesAreSkippedAndCloseOnlyOnTildes() {
        let text = "~~~\nfirst\n```\nsecond\n~~~\nProse"
        #expect(covered(text) == ["~~~\nfirst\n```\nsecond\n~~~\n"])
        // A backtick fence is not closed by tildes either.
        #expect(covered("```\na\n~~~\nb\n```\nProse") == ["```\na\n~~~\nb\n```\n"])
    }

    @Test("A fence line with an info string does not close the fence")
    func aFenceLineWithAnInfoStringDoesNotCloseTheFence() {
        // It is content; the bare fence after it closes the block.
        let text = "```\na\n```js\nb\n```\nProse"
        #expect(covered(text) == ["```\na\n```js\nb\n```\n"])
    }

    @Test("An unclosed tilde fence runs to the end like a backtick one")
    func anUnclosedTildeFenceRunsToTheEnd() {
        let text = "Prose\n~~~\ncode wrods"
        #expect(covered(text) == ["~~~\ncode wrods"])
    }

    @Test("A math fence is one range, not two")
    func aMathFenceIsOneRangeNotTwo() {
        #expect(covered("```math\n\\alpha\n```\nProse") == ["```math\n\\alpha\n```\n"])
    }

    @Test("Ranges from an extraction the caller has match ranges from the text")
    func rangesFromAnExtractionMatchRangesFromTheText() {
        let text = "Café `code` $x$\n\n```\ncode\n```\n\n    more\n"
        #expect(MarkdownNoSpellRanges.ranges(in: MathSpanExtractor.extract(from: text)) == MarkdownNoSpellRanges.ranges(in: text))
    }
}
