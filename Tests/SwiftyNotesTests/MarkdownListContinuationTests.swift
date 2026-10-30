@testable import SwiftyNotes
import Testing

// Return and Shift+Return continuation for lists, quotes and tables
// (GitHub issue #34, part 1). `‸` marks the caret; a `nil` expectation
// means the editor falls back to inserting a plain newline.

extension MarkdownFormattingTests {
    // MARK: - Helpers

    private func splitCaret(_ marked: String) -> (text: String, caret: Int) {
        let caretRange = marked.range(of: "‸")!
        let caret = marked.distance(from: marked.startIndex, to: caretRange.lowerBound)
        let text = marked.replacingCharacters(in: caretRange, with: "")
        return (text, caret)
    }

    private func rendered(_ text: String, _ edit: MarkdownFormattingEdit?) -> String? {
        guard let edit else { return nil }
        #expect(edit.selectedRange.isEmpty, "selectedRange must be a caret (an empty range)")
        let start = text.index(text.startIndex, offsetBy: edit.replacementRange.lowerBound)
        let end = text.index(text.startIndex, offsetBy: edit.replacementRange.upperBound)
        let result = String(text[..<start]) + edit.replacementText + String(text[end...])
        let caret = result.index(result.startIndex, offsetBy: edit.selectedRange.lowerBound)
        return String(result[..<caret]) + "‸" + String(result[caret...])
    }

    private func continuation(_ marked: String, softBreak: Bool = false) -> String? {
        let (text, caret) = splitCaret(marked)
        let edit = MarkdownListContinuation.edit(in: text, selection: caret ..< caret, softBreak: softBreak)
        return rendered(text, edit)
    }

    // MARK: - Bulleted lists

    @Test("Return continues a bulleted item")
    func returnContinuesABulletedItem() {
        #expect(continuation("- one‸") == "- one\n- ‸")
    }

    @Test("Return continues star and plus bulleted items")
    func returnContinuesStarAndPlusBulletedItems() {
        #expect(continuation("* one‸") == "* one\n* ‸")
        #expect(continuation("+ one‸") == "+ one\n+ ‸")
    }

    @Test("Return keeps the indentation of a nested bulleted item")
    func returnKeepsTheIndentationOfANestedBulletedItem() {
        #expect(continuation("  - nested‸") == "  - nested\n  - ‸")
    }

    @Test("Return moves the text after the caret to the new item")
    func returnMovesTheTextAfterTheCaretToTheNewItem() {
        #expect(continuation("- on‸e") == "- on\n- ‸e")
    }

    @Test("Return clears an empty bulleted item")
    func returnClearsAnEmptyBulletedItem() {
        #expect(continuation("- ‸") == "‸")
    }

    @Test("Return clears an empty indented bulleted item")
    func returnClearsAnEmptyIndentedBulletedItem() {
        #expect(continuation("  - ‸") == "‸")
    }

    @Test("Return before a bulleted marker falls back to a plain newline")
    func returnBeforeABulletedMarkerFallsBackToAPlainNewline() {
        #expect(continuation("‸- one") == nil)
    }

    @Test("Return inside a bulleted marker falls back to a plain newline")
    func returnInsideABulletedMarkerFallsBackToAPlainNewline() {
        #expect(continuation("-‸ one") == nil)
    }

    @Test("Return does not treat a marker without a trailing space as a list")
    func returnDoesNotTreatAMarkerWithoutATrailingSpaceAsAList() {
        #expect(continuation("-one‸") == nil)
    }

    @Test("Return at the start of a bulleted item's content falls back to a plain newline")
    func returnAtTheStartOfABulletedItemsContentFallsBackToAPlainNewline() {
        #expect(continuation("- ‸one") == nil)
    }

    // MARK: - Ordered lists

    @Test("Return increments an ordered item")
    func returnIncrementsAnOrderedItem() {
        #expect(continuation("1. one‸") == "1. one\n2. ‸")
    }

    @Test("Return keeps the ordered item delimiter")
    func returnKeepsTheOrderedItemDelimiter() {
        #expect(continuation("9) nine‸") == "9) nine\n10) ‸")
    }

    @Test("Return clears an empty ordered item")
    func returnClearsAnEmptyOrderedItem() {
        #expect(continuation("1. ‸") == "‸")
    }

    // MARK: - Task lists

    @Test("Return starts the next task item unchecked")
    func returnStartsTheNextTaskItemUnchecked() {
        #expect(continuation("- [x] done‸") == "- [x] done\n- [ ] ‸")
    }

    @Test("Return clears an empty task item")
    func returnClearsAnEmptyTaskItem() {
        #expect(continuation("- [ ] ‸") == "‸")
    }

    @Test("Return continues an unchecked task item")
    func returnContinuesAnUncheckedTaskItem() {
        #expect(continuation("- [ ] done‸") == "- [ ] done\n- [ ] ‸")
    }

    @Test("Return starts the next task item unchecked when the current one is checked with X")
    func returnStartsTheNextTaskItemUncheckedWhenTheCurrentOneIsCheckedWithX() {
        #expect(continuation("- [X] done‸") == "- [X] done\n- [ ] ‸")
    }

    // MARK: - Quotes

    @Test("Return continues a quote")
    func returnContinuesAQuote() {
        #expect(continuation("> quote‸") == "> quote\n> ‸")
    }

    @Test("Return clears an empty quote")
    func returnClearsAnEmptyQuote() {
        #expect(continuation("> ‸") == "‸")
    }

    @Test("Return continues a list inside a quote")
    func returnContinuesAListInsideAQuote() {
        #expect(continuation("> - item‸") == "> - item\n> - ‸")
    }

    // MARK: - Fenced code blocks

    @Test("Return inside an open code fence falls back to a plain newline")
    func returnInsideAnOpenCodeFenceFallsBackToAPlainNewline() {
        #expect(continuation("```\n- item‸") == nil)
        #expect(continuation("~~~\n- item‸") == nil)
    }

    @Test("Return after a closed code fence continues the list")
    func returnAfterAClosedCodeFenceContinuesTheList() {
        #expect(continuation("```\n- a\n```\n- b‸") == "```\n- a\n```\n- b\n- ‸")
    }

    @Test("A fence of the other character does not close a code block")
    func aFenceOfTheOtherCharacterDoesNotCloseACodeBlock() {
        #expect(continuation("~~~\n```\n- item‸") == nil)
        #expect(continuation("```\n~~~\n- item‸") == nil)
    }

    @Test("A fence inside indented code opens no code block")
    func aFenceInsideIndentedCodeOpensNoCodeBlock() {
        #expect(continuation("    ```\n\n- item‸") == "    ```\n\n- item\n- ‸")
    }

    @Test("Return inside indented code or a math fence falls back to a plain newline")
    func returnInsideIndentedCodeOrAMathFenceFallsBackToAPlainNewline() {
        #expect(continuation("Text\n\n    - item‸") == nil)
        #expect(continuation("```math\n- x‸") == nil)
    }

    @Test("Code blocks are found in code points before the caret line")
    func codeBlocksAreFoundInCodePointsBeforeTheCaretLine() {
        // 👍🏽 is one character but two code points.
        #expect(continuation("👍🏽\n```\nx\n```\n- b‸") == "👍🏽\n```\nx\n```\n- b\n- ‸")
    }

    // MARK: - Tables

    @Test("Return appends an empty row to the table")
    func returnAppendsAnEmptyRowToTheTable() {
        #expect(continuation("| a | b |\n|---|---|\n| 1 | 2 |‸") == "| a | b |\n|---|---|\n| 1 | 2 |\n| ‸ |  |")
    }

    @Test("Return does not split the table row the caret is in")
    func returnDoesNotSplitTheTableRowTheCaretIsIn() {
        #expect(continuation("| a | b |\n|---|---|\n| 1‸ | 2 |") == "| a | b |\n|---|---|\n| 1 | 2 |\n| ‸ |  |")
    }

    @Test("Return removes a blank table row")
    func returnRemovesABlankTableRow() {
        #expect(continuation("| a | b |\n|---|---|\n|  |  |‸") == "| a | b |\n|---|---|\n‸")
    }

    @Test("Return appends an empty row with the table's column count")
    func returnAppendsAnEmptyRowWithTheTablesColumnCount() {
        #expect(continuation("| a | b | c |\n|---|---|---|\n| 1 | 2 | 3 |‸") == "| a | b | c |\n|---|---|---|\n| 1 | 2 | 3 |\n| ‸ |  |  |")
    }

    @Test("Return on a table header row appends the empty row after it")
    func returnOnATableHeaderRowAppendsTheEmptyRowAfterIt() {
        #expect(continuation("| a | b |‸\n|---|---|\n| 1 | 2 |") == "| a | b |\n| ‸ |  |\n|---|---|\n| 1 | 2 |")
    }

    @Test("Return continues a partially filled table row")
    func returnContinuesAPartiallyFilledTableRow() {
        #expect(continuation("| a | b |\n|---|---|\n| x |  |‸") == "| a | b |\n|---|---|\n| x |  |\n| ‸ |  |")
    }

    @Test("Return on a table separator row falls back to a plain newline")
    func returnOnATableSeparatorRowFallsBackToAPlainNewline() {
        #expect(continuation("| a | b |\n|---|---‸|") == nil)
    }

    @Test("Return on pipe lines without a separator row falls back to a plain newline")
    func returnOnPipeLinesWithoutASeparatorRowFallsBackToAPlainNewline() {
        #expect(continuation("| a | b |‸") == nil)
    }

    // MARK: - Shift+Return

    @Test("Shift+Return indents a bulleted item to its content column")
    func shiftReturnIndentsABulletedItemToItsContentColumn() {
        #expect(continuation("- one‸", softBreak: true) == "- one\n  ‸")
    }

    @Test("Shift+Return indents an ordered item to its content column")
    func shiftReturnIndentsAnOrderedItemToItsContentColumn() {
        #expect(continuation("1. one‸", softBreak: true) == "1. one\n   ‸")
    }

    @Test("Shift+Return on a plain line falls back to a plain newline")
    func shiftReturnOnAPlainLineFallsBackToAPlainNewline() {
        #expect(continuation("plain‸", softBreak: true) == nil)
    }

    @Test("Shift+Return appends a table row like Return does")
    func shiftReturnAppendsATableRowLikeReturnDoes() {
        #expect(continuation("| a | b |\n|---|---|\n| 1 | 2 |‸", softBreak: true) == "| a | b |\n|---|---|\n| 1 | 2 |\n| ‸ |  |")
    }

    @Test("Shift+Return removes a blank table row like Return does")
    func shiftReturnRemovesABlankTableRowLikeReturnDoes() {
        #expect(continuation("| a | b |\n|---|---|\n|  |  |‸", softBreak: true) == "| a | b |\n|---|---|\n‸")
    }

    @Test("Shift+Return continues a quote")
    func shiftReturnContinuesAQuote() {
        #expect(continuation("> quote‸", softBreak: true) == "> quote\n> ‸")
    }

    @Test("Shift+Return continues a list inside a quote")
    func shiftReturnContinuesAListInsideAQuote() {
        #expect(continuation("> - item‸", softBreak: true) == "> - item\n> ‸")
    }

    @Test("Shift+Return clears an empty bulleted item")
    func shiftReturnClearsAnEmptyBulletedItem() {
        #expect(continuation("- ‸", softBreak: true) == "‸")
    }

    // MARK: - Character offsets

    @Test("Return counts offsets in Characters, not UTF-16 units")
    func returnCountsOffsetsInCharactersNotUTF16Units() {
        #expect(continuation("- party‸🎉") == "- party\n- ‸🎉")
    }

    @Test("Return counts table offsets in Characters, not UTF-16 units")
    func returnCountsTableOffsetsInCharactersNotUTF16Units() {
        #expect(continuation("| a |\n|---|\n| 🎉‸ |") == "| a |\n|---|\n| 🎉 |\n| ‸ |")
    }

    // MARK: - Plain lines and selections

    @Test("Return on a plain line falls back to a plain newline")
    func returnOnAPlainLineFallsBackToAPlainNewline() {
        #expect(continuation("plain‸") == nil)
    }

    @Test("Return only rewrites the line the caret is in")
    func returnOnlyRewritesTheLineTheCaretIsIn() {
        #expect(continuation("- one‸\n- two") == "- one\n- ‸\n- two")
    }

    @Test("A non-empty selection falls back to a plain newline")
    func aNonEmptySelectionFallsBackToAPlainNewline() {
        let cases: [(text: String, selection: Range<Int>)] = [
            ("- one", 2 ..< 4),
            ("1. one", 4 ..< 5),
            ("> quote", 2 ..< 5),
            ("| a | b |", 2 ..< 3),
            ("plain", 1 ..< 3),
            ("- one\n- two", 3 ..< 7),
        ]
        for (text, selection) in cases {
            for softBreak in [false, true] {
                let edit = MarkdownListContinuation.edit(in: text, selection: selection, softBreak: softBreak)
                #expect(rendered(text, edit) == nil, "text=\(text) selection=\(selection) softBreak=\(softBreak)")
            }
        }
    }
}
