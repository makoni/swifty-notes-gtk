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
}
