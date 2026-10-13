import Adwaita
import Foundation

@MainActor
extension MarkdownEditor {
    func applyFormatting(_ action: MarkdownFormattingAction) {
        let selection = selectedRange()
        let edit = MarkdownFormatting.edit(
            for: action,
            in: buffer.text,
            selection: selection,
        )
        apply(edit)
        focus()
    }

    /// Continues a list item, task, quote or table row on Return (`softBreak` = Shift+Return keeps typing inside
    /// the same item). Returns false when the line is not one of those, so GTK inserts its plain newline.
    func handleReturn(softBreak: Bool) -> Bool {
        Self.handleReturn(buffer: buffer, softBreak: softBreak)
    }

    /// Buffer-bound continuation core. It takes the `SourceBuffer` explicitly (instead of
    /// `self`) so the editor's Return key controller — whose escaping closure is owned by a child of
    /// `view` — can capture just the buffer rather than the whole `MarkdownEditor` struct. It reuses the
    /// same undo-grouped edit + caret placement as the formatting actions (one undo step, same caret).
    static func handleReturn(buffer: SourceBuffer, softBreak: Bool) -> Bool {
        guard let edit = MarkdownListContinuation.edit(
            in: buffer.text,
            selection: buffer.selectedRange,
            softBreak: softBreak,
        ) else {
            return false
        }
        applyEdit(buffer: buffer, edit: edit)
        return true
    }

    /// Inserts a markdown table scaffold at the cursor and selects the
    /// first header-cell placeholder so the user can start typing the
    /// column name immediately. Honors the "smart" insert rules in
    /// ``MarkdownTableScaffold/insertion(into:at:rows:cols:)`` — blank
    /// lines are preserved, non-empty lines get a line break so the
    /// scaffold lands on its own fresh line.
    func insertTable(rows: Int, cols: Int, alignments: [MarkdownTableAlignment] = []) {
        guard rows > 0, cols > 0 else { return }
        let insertion = MarkdownTableScaffold.insertion(
            into: buffer.text,
            at: selectedRange().lowerBound,
            rows: rows,
            cols: cols,
            alignments: alignments,
        )
        apply(
            MarkdownFormattingEdit(
                replacementRange: insertion.replacementRange,
                replacementText: insertion.replacementText,
                selectedRange: insertion.selectedRange,
            ),
        )
        focus()
    }

    func select(range: Range<Int>) {
        Self.select(buffer: buffer, range: range)
    }

    func selectedRange() -> Range<Int> {
        buffer.selectedRange
    }

    private func apply(_ edit: MarkdownFormattingEdit) {
        Self.applyEdit(buffer: buffer, edit: edit)
    }

    private static func applyEdit(buffer: SourceBuffer, edit: MarkdownFormattingEdit) {
        let normalizedRange = normalize(range: edit.replacementRange, in: buffer)
        buffer.beginUserAction()
        buffer.delete(range: normalizedRange)
        buffer.insert(edit.replacementText, at: normalizedRange.lowerBound)
        buffer.endUserAction()
        select(buffer: buffer, range: edit.selectedRange)
    }

    private static func select(buffer: SourceBuffer, range: Range<Int>) {
        let normalizedRange = normalize(range: range, in: buffer)
        guard !normalizedRange.isEmpty else {
            buffer.placeCursor(at: normalizedRange.lowerBound)
            return
        }
        buffer.select(range: normalizedRange)
    }

    private static func normalize(range: Range<Int>, in buffer: SourceBuffer) -> Range<Int> {
        let lower = normalize(offset: range.lowerBound, in: buffer)
        let upper = max(lower, normalize(offset: range.upperBound, in: buffer))
        return lower ..< upper
    }

    private static func normalize(offset: Int, in buffer: SourceBuffer) -> Int {
        max(0, min(offset, buffer.text.count))
    }
}
