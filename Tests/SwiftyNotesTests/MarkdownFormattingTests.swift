@testable import SwiftyNotes
import Testing

struct MarkdownFormattingTests {
    // MARK: - Table scaffold

    @Test
    func `table scaffold builds header alignment and data rows`() {
        let scaffold = MarkdownTableScaffold.generate(rows: 2, cols: 3)

        #expect(scaffold == """
        | Column 1 | Column 2 | Column 3 |
        | -------- | -------- | -------- |
        |          |          |          |
        |          |          |          |
        """)
    }

    @Test
    func `table scaffold single row single column`() {
        let scaffold = MarkdownTableScaffold.generate(rows: 1, cols: 1)

        #expect(scaffold == """
        | Column 1 |
        | -------- |
        |          |
        """)
    }

    @Test
    func `table scaffold ignores non positive dimensions`() {
        #expect(MarkdownTableScaffold.generate(rows: 0, cols: 3) == nil)
        #expect(MarkdownTableScaffold.generate(rows: 2, cols: 0) == nil)
        #expect(MarkdownTableScaffold.generate(rows: -1, cols: 3) == nil)
    }

    @Test
    func `table insertion at start of empty buffer writes scaffold with trailing newline`() {
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

    @Test
    func `table insertion in the middle of A paragraph surrounds the scaffold with blank lines`() {
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

    @Test
    func `table insertion on empty line does not add extra blank lines`() {
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

    @Test
    func `bold wraps selected text and keeps inner selection`() {
        let edit = MarkdownFormatting.edit(
            for: .bold,
            in: "Hello world",
            selection: 6 ..< 11,
        )

        #expect(edit.replacementRange == 6 ..< 11)
        #expect(edit.replacementText == "**world**")
        #expect(edit.selectedRange == 6 ..< 15)
    }

    @Test
    func `bold unwraps selection when already formatted`() {
        let edit = MarkdownFormatting.edit(
            for: .bold,
            in: "Hello **world**",
            selection: 6 ..< 15,
        )

        #expect(edit.replacementRange == 6 ..< 15)
        #expect(edit.replacementText == "world")
        #expect(edit.selectedRange == 6 ..< 11)
    }

    @Test
    func `italic without selection inserts placeholder`() {
        let edit = MarkdownFormatting.edit(
            for: .italic,
            in: "Hello",
            selection: 5 ..< 5,
        )

        #expect(edit.replacementRange == 5 ..< 5)
        #expect(edit.replacementText == "*emphasis*")
        #expect(edit.selectedRange == 5 ..< 15)
    }

    @Test
    func `link for selected text inserts URL placeholder`() {
        let edit = MarkdownFormatting.edit(
            for: .link,
            in: "Read docs",
            selection: 5 ..< 9,
        )

        #expect(edit.replacementRange == 5 ..< 9)
        #expect(edit.replacementText == "[docs](https://)")
        #expect(edit.selectedRange == 5 ..< 21)
    }

    @Test
    func `heading prefixes current line at cursor`() {
        let edit = MarkdownFormatting.edit(
            for: .heading,
            in: "First line\nSecond line",
            selection: 12 ..< 12,
        )

        #expect(edit.replacementRange == 11 ..< 22)
        #expect(edit.replacementText == "# Second line")
        #expect(edit.selectedRange == 11 ..< 24)
    }

    @Test
    func `heading toggles current line off`() {
        let edit = MarkdownFormatting.edit(
            for: .heading,
            in: "First line\n# Second line",
            selection: 14 ..< 14,
        )

        #expect(edit.replacementRange == 11 ..< 24)
        #expect(edit.replacementText == "Second line")
        #expect(edit.selectedRange == 11 ..< 22)
    }

    @Test
    func `bullet list prefixes each selected line`() {
        let edit = MarkdownFormatting.edit(
            for: .bulletList,
            in: "Alpha\nBeta\nGamma",
            selection: 0 ..< 10,
        )

        #expect(edit.replacementRange == 0 ..< 10)
        #expect(edit.replacementText == "- Alpha\n- Beta")
        #expect(edit.selectedRange == 0 ..< 14)
    }

    @Test
    func `bullet list toggles whole current line off at cursor`() {
        let edit = MarkdownFormatting.edit(
            for: .bulletList,
            in: "- Alpha\nBeta",
            selection: 3 ..< 3,
        )

        #expect(edit.replacementRange == 0 ..< 7)
        #expect(edit.replacementText == "Alpha")
        #expect(edit.selectedRange == 0 ..< 5)
    }

    @Test
    func `numbered list enumerates selected lines`() {
        let edit = MarkdownFormatting.edit(
            for: .numberedList,
            in: "Alpha\nBeta",
            selection: 0 ..< 10,
        )

        #expect(edit.replacementText == "1. Alpha\n2. Beta")
        #expect(edit.selectedRange == 0 ..< 16)
    }

    @Test
    func `task list prefixes selected lines`() {
        let edit = MarkdownFormatting.edit(
            for: .taskList,
            in: "Ship it",
            selection: 0 ..< 7,
        )

        #expect(edit.replacementText == "- [ ] Ship it")
        #expect(edit.selectedRange == 0 ..< 13)
    }

    @Test
    func `task list converts existing bullet list line`() {
        let edit = MarkdownFormatting.edit(
            for: .taskList,
            in: "- Ship it",
            selection: 4 ..< 4,
        )

        #expect(edit.replacementRange == 0 ..< 9)
        #expect(edit.replacementText == "- [ ] Ship it")
        #expect(edit.selectedRange == 0 ..< 13)
    }

    @Test
    func `task list toggles off whole line when already task item`() {
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
