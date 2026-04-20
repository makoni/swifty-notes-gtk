import Adwaita
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
        buffer.select(range: normalizedRange)
    }

    func selectedRange() -> Range<Int> {
        buffer.selectedRange
    }

    private func apply(_ edit: MarkdownFormattingEdit) {
        let normalizedRange = normalize(range: edit.replacementRange)
        buffer.beginUserAction()
        buffer.delete(range: normalizedRange)
        buffer.insert(edit.replacementText, at: normalizedRange.lowerBound)
        buffer.endUserAction()
        select(range: edit.selectedRange)
    }

    private func placeCursor(at offset: Int) {
        buffer.placeCursor(at: normalize(offset: offset))
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
