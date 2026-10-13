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

    /// What the editor's Return-key controller does with a key press. `inputMethodConsumes` is asked first and only
    /// for Return/KP_Enter; when it returns true the press is handled (the input method committed a composition) and
    /// nothing else happens.
    static func handleReturnKey(
        keyval: UInt32,
        modifiers: UInt32,
        buffer: SourceBuffer,
        inputMethodConsumes: () -> Bool,
    ) -> Bool {
        // The Return key in both its locations on the main row and the
        // numpad.
        guard keyval == GDK_KEY_Return || keyval == GDK_KEY_KP_Enter else { return false }
        // Let the input method claim Return first: it commits a CJK
        // composition and we must not also insert a newline (the
        // GtkSourceView pattern).
        if inputMethodConsumes() {
            return true
        }
        // Decide between Return and Shift+Return. Mask out the lock bits
        // (Caps Lock = 1 << 1, plus the X11 NumLock slot 1 << 4 that GTK4
        // does not populate); any remaining modifier bit — Control, Alt,
        // Super, Meta, a mouse button — means this is not our key, so let
        // GTK's default newline (and auto-indent) run.
        let masked = modifiers & ~((UInt32(1) << 1) | (UInt32(1) << 4))
        let shiftBit = UInt32(1) << 0
        if (masked & ~shiftBit) != 0 {
            return false
        }
        return handleReturn(buffer: buffer, softBreak: (masked & shiftBit) != 0)
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
