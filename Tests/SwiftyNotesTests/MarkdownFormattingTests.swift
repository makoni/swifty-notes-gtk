@testable import SwiftyNotes
import Testing

struct MarkdownFormattingTests {
    // MARK: - Table scaffold

    @Test("Table scaffold builds header alignment and data rows")
    func tableScaffoldBuildsHeaderAlignmentAndDataRows() {
        let scaffold = MarkdownTableScaffold.generate(rows: 2, cols: 3)

        #expect(scaffold == """
        | Column 1 | Column 2 | Column 3 |
        | -------- | -------- | -------- |
        |          |          |          |
        |          |          |          |
        """)
    }

    @Test("Table scaffold encodes alignment row per column")
    func tableScaffoldEncodesAlignmentRowPerColumn() {
        let scaffold = MarkdownTableScaffold.generate(
            rows: 1,
            cols: 3,
            alignments: [.left, .center, .right],
        )

        #expect(scaffold == """
        | Column 1 | Column 2 | Column 3 |
        | :------- | :------: | -------: |
        |          |          |          |
        """)
    }

    @Test("Table scaffold pads alignment array to match column count")
    func tableScaffoldPadsAlignmentArrayToMatchColumnCount() {
        // Short alignment arrays extend with .left so callers that only
        // care about the first few columns still get valid output.
        let scaffold = MarkdownTableScaffold.generate(
            rows: 1,
            cols: 4,
            alignments: [.right],
        )

        #expect(scaffold == """
        | Column 1 | Column 2 | Column 3 | Column 4 |
        | -------: | -------- | -------- | -------- |
        |          |          |          |          |
        """)
    }

    @Test("Table scaffold single row single column")
    func tableScaffoldSingleRowSingleColumn() {
        let scaffold = MarkdownTableScaffold.generate(rows: 1, cols: 1)

        #expect(scaffold == """
        | Column 1 |
        | -------- |
        |          |
        """)
    }

    @Test("Table scaffold ignores non positive dimensions")
    func tableScaffoldIgnoresNonPositiveDimensions() {
        #expect(MarkdownTableScaffold.generate(rows: 0, cols: 3) == nil)
        #expect(MarkdownTableScaffold.generate(rows: 2, cols: 0) == nil)
        #expect(MarkdownTableScaffold.generate(rows: -1, cols: 3) == nil)
    }

    @Test("Table insertion at start of empty buffer writes scaffold with trailing newline")
    func tableInsertionAtStartOfEmptyBufferWritesScaffoldWithTrailingNewline() {
        let edit = MarkdownTableScaffold.insertion(
            into: "",
            at: 0,
            rows: 1,
            cols: 2,
        )

        #expect(edit.replacementRange == 0 ..< 0)
        #expect(edit.replacementText == """
        | Column 1 | Column 2 |
        | -------- | -------- |
        |          |          |
        """ + "\n")
        // First header cell content should be selected so the user can start typing.
        #expect(edit.replacementText[
            edit.replacementText.index(
                edit.replacementText.startIndex,
                offsetBy: edit.selectedRange.lowerBound - edit.replacementRange.lowerBound,
            ) ..< edit.replacementText.index(
                edit.replacementText.startIndex,
                offsetBy: edit.selectedRange.upperBound - edit.replacementRange.lowerBound,
            ),
        ] == "Column 1")
    }

    @Test("Table insertion in the middle of A paragraph surrounds the scaffold with blank lines")
    func tableInsertionInTheMiddleOfAParagraphSurroundsTheScaffoldWith() {
        let text = "Intro paragraph ends here.\nNext paragraph."
        let cursor = 27 // just after "\n" between the two paragraphs — start of "Next"
        let edit = MarkdownTableScaffold.insertion(
            into: text,
            at: cursor,
            rows: 1,
            cols: 1,
        )

        // Cursor lands on the start of a non-empty line (`Next paragraph.`) so the
        // scaffold must land on its own blank line pair.
        #expect(edit.replacementText.hasPrefix("\n"))
        #expect(edit.replacementText.hasSuffix("\n\n"))
        #expect(edit.replacementText.contains("| Column 1 |"))
    }

    @Test("Table insertion on empty line does not add extra blank lines")
    func tableInsertionOnEmptyLineDoesNotAddExtraBlankLines() {
        let text = "Paragraph\n\nAfter table."
        let cursor = 10 // on the empty line between paragraphs
        let edit = MarkdownTableScaffold.insertion(
            into: text,
            at: cursor,
            rows: 1,
            cols: 1,
        )

        #expect(!edit.replacementText.hasPrefix("\n"))
        #expect(edit.replacementText.hasSuffix("\n"))
    }

    @Test("Bold wraps selected text and keeps inner selection")
    func boldWrapsSelectedTextAndKeepsInnerSelection() {
        let edit = MarkdownFormatting.edit(
            for: .bold,
            in: "Hello world",
            selection: 6 ..< 11,
        )

        #expect(edit.replacementRange == 6 ..< 11)
        #expect(edit.replacementText == "**world**")
        #expect(edit.selectedRange == 6 ..< 15)
    }

    @Test("Bold unwraps selection when already formatted")
    func boldUnwrapsSelectionWhenAlreadyFormatted() {
        let edit = MarkdownFormatting.edit(
            for: .bold,
            in: "Hello **world**",
            selection: 6 ..< 15,
        )

        #expect(edit.replacementRange == 6 ..< 15)
        #expect(edit.replacementText == "world")
        #expect(edit.selectedRange == 6 ..< 11)
    }

    @Test("Italic without selection inserts placeholder")
    func italicWithoutSelectionInsertsPlaceholder() {
        let edit = MarkdownFormatting.edit(
            for: .italic,
            in: "Hello",
            selection: 5 ..< 5,
        )

        #expect(edit.replacementRange == 5 ..< 5)
        #expect(edit.replacementText == "*emphasis*")
        #expect(edit.selectedRange == 5 ..< 15)
    }

    @Test("Link for selected text inserts URL placeholder")
    func linkForSelectedTextInsertsURLPlaceholder() {
        let edit = MarkdownFormatting.edit(
            for: .link,
            in: "Read docs",
            selection: 5 ..< 9,
        )

        #expect(edit.replacementRange == 5 ..< 9)
        #expect(edit.replacementText == "[docs](https://)")
        #expect(edit.selectedRange == 5 ..< 21)
    }

    @Test("Heading prefixes current line at cursor")
    func headingPrefixesCurrentLineAtCursor() {
        let edit = MarkdownFormatting.edit(
            for: .heading,
            in: "First line\nSecond line",
            selection: 12 ..< 12,
        )

        #expect(edit.replacementRange == 11 ..< 22)
        #expect(edit.replacementText == "# Second line")
        #expect(edit.selectedRange == 11 ..< 24)
    }

    @Test("Heading toggles current line off")
    func headingTogglesCurrentLineOff() {
        let edit = MarkdownFormatting.edit(
            for: .heading,
            in: "First line\n# Second line",
            selection: 14 ..< 14,
        )

        #expect(edit.replacementRange == 11 ..< 24)
        #expect(edit.replacementText == "Second line")
        #expect(edit.selectedRange == 11 ..< 22)
    }

    @Test("Bullet list prefixes each selected line")
    func bulletListPrefixesEachSelectedLine() {
        let edit = MarkdownFormatting.edit(
            for: .bulletList,
            in: "Alpha\nBeta\nGamma",
            selection: 0 ..< 10,
        )

        #expect(edit.replacementRange == 0 ..< 10)
        #expect(edit.replacementText == "- Alpha\n- Beta")
        #expect(edit.selectedRange == 0 ..< 14)
    }

    @Test("Bullet list toggles whole current line off at cursor")
    func bulletListTogglesWholeCurrentLineOffAtCursor() {
        let edit = MarkdownFormatting.edit(
            for: .bulletList,
            in: "- Alpha\nBeta",
            selection: 3 ..< 3,
        )

        #expect(edit.replacementRange == 0 ..< 7)
        #expect(edit.replacementText == "Alpha")
        #expect(edit.selectedRange == 0 ..< 5)
    }

    @Test("Numbered list enumerates selected lines")
    func numberedListEnumeratesSelectedLines() {
        let edit = MarkdownFormatting.edit(
            for: .numberedList,
            in: "Alpha\nBeta",
            selection: 0 ..< 10,
        )

        #expect(edit.replacementText == "1. Alpha\n2. Beta")
        #expect(edit.selectedRange == 0 ..< 16)
    }

    @Test("Task list prefixes selected lines")
    func taskListPrefixesSelectedLines() {
        let edit = MarkdownFormatting.edit(
            for: .taskList,
            in: "Ship it",
            selection: 0 ..< 7,
        )

        #expect(edit.replacementText == "- [ ] Ship it")
        #expect(edit.selectedRange == 0 ..< 13)
    }

    @Test("Task list converts existing bullet list line")
    func taskListConvertsExistingBulletListLine() {
        let edit = MarkdownFormatting.edit(
            for: .taskList,
            in: "- Ship it",
            selection: 4 ..< 4,
        )

        #expect(edit.replacementRange == 0 ..< 9)
        #expect(edit.replacementText == "- [ ] Ship it")
        #expect(edit.selectedRange == 0 ..< 13)
    }

    @Test("Task list toggles off whole line when already task item")
    func taskListTogglesOffWholeLineWhenAlreadyTaskItem() {
        let edit = MarkdownFormatting.edit(
            for: .taskList,
            in: "- [ ] Ship it",
            selection: 7 ..< 7,
        )

        #expect(edit.replacementRange == 0 ..< 13)
        #expect(edit.replacementText == "Ship it")
        #expect(edit.selectedRange == 0 ..< 7)
    }
}
