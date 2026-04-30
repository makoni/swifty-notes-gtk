import Foundation

/// Decision returned by ``MarkdownLinkPaste/transform(clipboardText:selectedText:isInCodeContext:)``.
public enum LinkPasteAction: Equatable, Sendable {
    /// Paste handler should suppress the default text paste and
    /// insert this string instead.
    case wrap(String)
    /// Paste handler should leave the default GTK text paste alone.
    case passThrough
}

/// Pure logic for the "paste a URL → wrap as markdown link" feature
/// (issue #19). All decisions live here so the integration in the
/// editor can stay tiny.
public enum MarkdownLinkPaste {

    /// True when `text` is a single bare http/https URL with a
    /// non-empty host. Anything else (free-form prose, javascript:,
    /// mailto:, internal whitespace, missing host) is rejected — we
    /// only auto-wrap when there is no ambiguity about user intent.
    public static func isPasteableURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.contains(where: \.isWhitespace) else { return false }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return false }
        return true
    }

    /// True when the cursor sits inside a fenced or inline code span.
    /// Used to suppress the auto-wrap so a pasted URL stays raw inside
    /// `\`\`\`` blocks and `` ` `` runs — markdown rendering of those
    /// regions doesn't process link syntax, so wrapping would be both
    /// visible noise and wrong.
    ///
    /// `textBefore` is everything in the buffer up to (not including)
    /// the cursor. The detector counts unmatched fence delimiters
    /// across the buffer plus unmatched single backticks on the
    /// current line — inline code spans don't cross newlines in
    /// CommonMark, so we reset the inline counter at every line break.
    public static func isInCodeContext(textBefore: String) -> Bool {
        var insideFence = false
        var inlineTicksOnCurrentLine = 0
        var lineStart = textBefore.startIndex

        while lineStart < textBefore.endIndex {
            let lineEnd = textBefore[lineStart...].firstIndex(of: "\n") ?? textBefore.endIndex
            let line = textBefore[lineStart..<lineEnd]
            let trimmedLeading = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmedLeading.hasPrefix("```") {
                insideFence.toggle()
                inlineTicksOnCurrentLine = 0
            } else if !insideFence {
                inlineTicksOnCurrentLine = line.reduce(into: 0) { count, character in
                    if character == "`" { count += 1 }
                }
            }
            if lineEnd == textBefore.endIndex { break }
            lineStart = textBefore.index(after: lineEnd)
            if lineStart < textBefore.endIndex {
                // Crossing into a new line resets inline state since
                // CommonMark's `` ` `` runs cannot span newlines.
                inlineTicksOnCurrentLine = 0
            }
        }

        if insideFence { return true }
        return inlineTicksOnCurrentLine.isMultiple(of: 2) == false
    }

    /// Decides whether to wrap the clipboard payload, and what the
    /// wrapped string should look like. Returns ``LinkPasteAction/passThrough``
    /// when the caller should leave the default paste behaviour alone.
    public static func transform(
        clipboardText: String,
        selectedText: String,
        isInCodeContext: Bool,
    ) -> LinkPasteAction {
        guard !isInCodeContext else { return .passThrough }
        let trimmed = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPasteableURL(trimmed) else { return .passThrough }
        let linkText = selectedText.isEmpty ? trimmed : selectedText
        return .wrap("[\(linkText)](\(trimmed))")
    }
}
