import Adwaita
import CAdwaita
import Foundation

@MainActor
extension MarkdownEditor {
    func applyFormatting(_ action: MarkdownFormattingAction) {
        let selection = selectedRange()
        let edit = MarkdownFormatting.edit(
            for: action,
            in: buffer.text,
            selection: selection
        )
        apply(edit)
        focus()
    }

    func select(range: Range<Int>) {
        let normalizedRange = normalize(range: range)
        guard !normalizedRange.isEmpty else {
            placeCursor(at: normalizedRange.lowerBound)
            return
        }

        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(textBufferPointer, &start, Int32(normalizedRange.lowerBound))
        gtk_text_buffer_get_iter_at_offset(textBufferPointer, &end, Int32(normalizedRange.upperBound))
        gtk_text_buffer_select_range(textBufferPointer, &start, &end)
    }

    private var textBufferPointer: UnsafeMutablePointer<GtkTextBuffer> {
        buffer.castedPointer()
    }

    func selectedRange() -> Range<Int> {
        var start = GtkTextIter()
        var end = GtkTextIter()
        if gtk_text_buffer_get_selection_bounds(textBufferPointer, &start, &end) != 0 {
            let startOffset = Int(gtk_text_iter_get_offset(&start))
            let endOffset = Int(gtk_text_iter_get_offset(&end))
            return startOffset..<endOffset
        }

        let insertMark = gtk_text_buffer_get_insert(textBufferPointer)!
        gtk_text_buffer_get_iter_at_mark(textBufferPointer, &start, insertMark)
        let cursorOffset = Int(gtk_text_iter_get_offset(&start))
        return cursorOffset..<cursorOffset
    }

    private func apply(_ edit: MarkdownFormattingEdit) {
        let normalizedRange = normalize(range: edit.replacementRange)
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(textBufferPointer, &start, Int32(normalizedRange.lowerBound))
        gtk_text_buffer_get_iter_at_offset(textBufferPointer, &end, Int32(normalizedRange.upperBound))

        gtk_text_buffer_begin_user_action(textBufferPointer)
        gtk_text_buffer_delete(textBufferPointer, &start, &end)
        gtk_text_buffer_insert(textBufferPointer, &start, edit.replacementText, Int32(edit.replacementText.utf8.count))
        gtk_text_buffer_end_user_action(textBufferPointer)

        select(range: edit.selectedRange)
    }

    private func placeCursor(at offset: Int) {
        var iter = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(textBufferPointer, &iter, Int32(normalize(offset: offset)))
        gtk_text_buffer_place_cursor(textBufferPointer, &iter)
    }

    private func normalize(range: Range<Int>) -> Range<Int> {
        let lower = normalize(offset: range.lowerBound)
        let upper = max(lower, normalize(offset: range.upperBound))
        return lower..<upper
    }

    private func normalize(offset: Int) -> Int {
        max(0, min(offset, buffer.text.count))
    }
}
