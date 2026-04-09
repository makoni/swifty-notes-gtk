import Testing
@testable import SwiftyNotes

struct MarkdownFormattingTests {
    @Test
    func boldWrapsSelectedTextAndKeepsInnerSelection() {
        let edit = MarkdownFormatting.edit(
            for: .bold,
            in: "Hello world",
            selection: 6..<11
        )

        #expect(edit.replacementRange == 6..<11)
        #expect(edit.replacementText == "**world**")
        #expect(edit.selectedRange == 6..<15)
    }

    @Test
    func boldUnwrapsSelectionWhenAlreadyFormatted() {
        let edit = MarkdownFormatting.edit(
            for: .bold,
            in: "Hello **world**",
            selection: 6..<15
        )

        #expect(edit.replacementRange == 6..<15)
        #expect(edit.replacementText == "world")
        #expect(edit.selectedRange == 6..<11)
    }

    @Test
    func italicWithoutSelectionInsertsPlaceholder() {
        let edit = MarkdownFormatting.edit(
            for: .italic,
            in: "Hello",
            selection: 5..<5
        )

        #expect(edit.replacementRange == 5..<5)
        #expect(edit.replacementText == "*emphasis*")
        #expect(edit.selectedRange == 5..<15)
    }

    @Test
    func linkForSelectedTextInsertsURLPlaceholder() {
        let edit = MarkdownFormatting.edit(
            for: .link,
            in: "Read docs",
            selection: 5..<9
        )

        #expect(edit.replacementRange == 5..<9)
        #expect(edit.replacementText == "[docs](https://)")
        #expect(edit.selectedRange == 5..<21)
    }

    @Test
    func headingPrefixesCurrentLineAtCursor() {
        let edit = MarkdownFormatting.edit(
            for: .heading,
            in: "First line\nSecond line",
            selection: 12..<12
        )

        #expect(edit.replacementRange == 11..<22)
        #expect(edit.replacementText == "# Second line")
        #expect(edit.selectedRange == 11..<24)
    }

    @Test
    func headingTogglesCurrentLineOff() {
        let edit = MarkdownFormatting.edit(
            for: .heading,
            in: "First line\n# Second line",
            selection: 14..<14
        )

        #expect(edit.replacementRange == 11..<24)
        #expect(edit.replacementText == "Second line")
        #expect(edit.selectedRange == 11..<22)
    }

    @Test
    func bulletListPrefixesEachSelectedLine() {
        let edit = MarkdownFormatting.edit(
            for: .bulletList,
            in: "Alpha\nBeta\nGamma",
            selection: 0..<10
        )

        #expect(edit.replacementRange == 0..<10)
        #expect(edit.replacementText == "- Alpha\n- Beta")
        #expect(edit.selectedRange == 0..<14)
    }

    @Test
    func bulletListTogglesWholeCurrentLineOffAtCursor() {
        let edit = MarkdownFormatting.edit(
            for: .bulletList,
            in: "- Alpha\nBeta",
            selection: 3..<3
        )

        #expect(edit.replacementRange == 0..<7)
        #expect(edit.replacementText == "Alpha")
        #expect(edit.selectedRange == 0..<5)
    }

    @Test
    func numberedListEnumeratesSelectedLines() {
        let edit = MarkdownFormatting.edit(
            for: .numberedList,
            in: "Alpha\nBeta",
            selection: 0..<10
        )

        #expect(edit.replacementText == "1. Alpha\n2. Beta")
        #expect(edit.selectedRange == 0..<16)
    }

    @Test
    func taskListPrefixesSelectedLines() {
        let edit = MarkdownFormatting.edit(
            for: .taskList,
            in: "Ship it",
            selection: 0..<7
        )

        #expect(edit.replacementText == "- [ ] Ship it")
        #expect(edit.selectedRange == 0..<13)
    }

    @Test
    func taskListConvertsExistingBulletListLine() {
        let edit = MarkdownFormatting.edit(
            for: .taskList,
            in: "- Ship it",
            selection: 4..<4
        )

        #expect(edit.replacementRange == 0..<9)
        #expect(edit.replacementText == "- [ ] Ship it")
        #expect(edit.selectedRange == 0..<13)
    }

    @Test
    func taskListTogglesOffWholeLineWhenAlreadyTaskItem() {
        let edit = MarkdownFormatting.edit(
            for: .taskList,
            in: "- [ ] Ship it",
            selection: 7..<7
        )

        #expect(edit.replacementRange == 0..<13)
        #expect(edit.replacementText == "Ship it")
        #expect(edit.selectedRange == 0..<7)
    }
}
