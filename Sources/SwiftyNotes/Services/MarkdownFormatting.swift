import Foundation

enum MarkdownFormattingAction: CaseIterable, Hashable {
    case heading
    case bold
    case italic
    case code
    case link
    case quote
    case bulletList
    case numberedList
    case taskList

    var accessibilityLabel: String {
        switch self {
        case .heading:
            "Heading"
        case .bold:
            "Bold"
        case .italic:
            "Italic"
        case .code:
            "Code"
        case .link:
            "Link"
        case .quote:
            "Quote"
        case .bulletList:
            "Bulleted List"
        case .numberedList:
            "Numbered List"
        case .taskList:
            "Task List"
        }
    }

    var tooltip: String {
        switch self {
        case .heading:
            "Turn the current line into a heading"
        case .bold:
            "Wrap the selection in bold markdown"
        case .italic:
            "Wrap the selection in italic markdown"
        case .code:
            "Insert inline code or a fenced code block"
        case .link:
            "Insert a markdown link"
        case .quote:
            "Prefix the selected lines as a quote"
        case .bulletList:
            "Prefix the selected lines as a bulleted list"
        case .numberedList:
            "Prefix the selected lines as a numbered list"
        case .taskList:
            "Prefix the selected lines as a task list"
        }
    }

    var iconName: String? {
        switch self {
        case .bold:
            "format-text-bold-symbolic"
        case .italic:
            "format-text-italic-symbolic"
        case .link:
            "insert-link-symbolic"
        case .quote:
            "format-justify-left-symbolic"
        case .bulletList:
            "view-list-bullet-symbolic"
        case .numberedList:
            "view-list-ordered-symbolic"
        default:
            nil
        }
    }

    var shortLabel: String? {
        switch self {
        case .heading:
            "H1"
        case .quote:
            "Quote"
        case .code:
            "</>"
        case .bulletList:
            "Bullets"
        case .numberedList:
            "1."
        case .taskList:
            "[ ]"
        default:
            nil
        }
    }
}

struct MarkdownFormattingEdit: Equatable {
    let replacementRange: Range<Int>
    let replacementText: String
    let selectedRange: Range<Int>
}

enum MarkdownFormatting {
    static func edit(
        for action: MarkdownFormattingAction,
        in text: String,
        selection: Range<Int>
    ) -> MarkdownFormattingEdit {
        let normalizedSelection = normalize(selection, in: text)
        switch action {
        case .bold:
            return toggleInline(in: text, selection: normalizedSelection, prefix: "**", suffix: "**", placeholder: "bold")
        case .italic:
            return toggleInline(in: text, selection: normalizedSelection, prefix: "*", suffix: "*", placeholder: "emphasis")
        case .code:
            return toggleCode(in: text, selection: normalizedSelection)
        case .link:
            return toggleLink(in: text, selection: normalizedSelection)
        case .heading:
            return toggleLines(in: text, selection: normalizedSelection, action: action)
        case .quote:
            return toggleLines(in: text, selection: normalizedSelection, action: action)
        case .bulletList:
            return toggleLines(in: text, selection: normalizedSelection, action: action)
        case .numberedList:
            return toggleLines(in: text, selection: normalizedSelection, action: action)
        case .taskList:
            return toggleLines(in: text, selection: normalizedSelection, action: action)
        }
    }

    private static func toggleInline(
        in text: String,
        selection: Range<Int>,
        prefix: String,
        suffix: String,
        placeholder: String
    ) -> MarkdownFormattingEdit {
        let selectedText = substring(in: text, range: selection)
        if let unwrappedText = unwrapInline(selectedText, prefix: prefix, suffix: suffix) {
            return MarkdownFormattingEdit(
                replacementRange: selection,
                replacementText: unwrappedText,
                selectedRange: selection.lowerBound..<(selection.lowerBound + unwrappedText.count)
            )
        }

        let innerText = selectedText.isEmpty ? placeholder : selectedText
        let replacementText = prefix + innerText + suffix
        return MarkdownFormattingEdit(
            replacementRange: selection,
            replacementText: replacementText,
            selectedRange: selection.lowerBound..<(selection.lowerBound + replacementText.count)
        )
    }

    private static func toggleCode(
        in text: String,
        selection: Range<Int>
    ) -> MarkdownFormattingEdit {
        let selectedText = substring(in: text, range: selection)
        if let unwrappedText = unwrapCode(selectedText) {
            return MarkdownFormattingEdit(
                replacementRange: selection,
                replacementText: unwrappedText,
                selectedRange: selection.lowerBound..<(selection.lowerBound + unwrappedText.count)
            )
        }

        if selectedText.contains("\n") {
            let replacementText = "```\n\(selectedText)\n```"
            return MarkdownFormattingEdit(
                replacementRange: selection,
                replacementText: replacementText,
                selectedRange: selection.lowerBound..<(selection.lowerBound + replacementText.count)
            )
        }
        return toggleInline(in: text, selection: selection, prefix: "`", suffix: "`", placeholder: "code")
    }

    private static func toggleLink(
        in text: String,
        selection: Range<Int>
    ) -> MarkdownFormattingEdit {
        let selectedText = substring(in: text, range: selection)
        if let label = unwrapLink(selectedText) {
            return MarkdownFormattingEdit(
                replacementRange: selection,
                replacementText: label,
                selectedRange: selection.lowerBound..<(selection.lowerBound + label.count)
            )
        }

        let label = selectedText.isEmpty ? "link text" : selectedText
        let urlPlaceholder = "https://"
        let replacementText = "[\(label)](\(urlPlaceholder))"
        return MarkdownFormattingEdit(
            replacementRange: selection,
            replacementText: replacementText,
            selectedRange: selection.lowerBound..<(selection.lowerBound + replacementText.count)
        )
    }

    private static func toggleLines(
        in text: String,
        selection: Range<Int>,
        action: MarkdownFormattingAction
    ) -> MarkdownFormattingEdit {
        let lineRange = linesCovered(by: selection, in: text)
        let block = substring(in: text, range: lineRange)
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let parsedLines = lines.map(parseBlockLine)
        let shouldRemove = parsedLines.allSatisfy { line in
            matches(action: action, line: line)
        }

        let replacementLines = parsedLines.enumerated().map { index, line in
            transform(line: line, action: action, index: index, shouldRemove: shouldRemove)
        }.joined(separator: "\n")
        return MarkdownFormattingEdit(
            replacementRange: lineRange,
            replacementText: replacementLines,
            selectedRange: lineRange.lowerBound..<(lineRange.lowerBound + replacementLines.count)
        )
    }

    private static func linesCovered(by selection: Range<Int>, in text: String) -> Range<Int> {
        let count = text.count
        let lowerBound = max(0, min(selection.lowerBound, count))
        let upperBound = max(0, min(selection.upperBound, count))
        let lastSelectedOffset = upperBound > lowerBound ? upperBound - 1 : upperBound
        let start = lineStart(containing: lowerBound, in: text)
        let end = lineEnd(containing: lastSelectedOffset, in: text)
        return start..<end
    }

    private static func lineStart(containing offset: Int, in text: String) -> Int {
        let clamped = max(0, min(offset, text.count))
        let endIndex = index(at: clamped, in: text)
        let prefix = text[..<endIndex]
        return (prefix.lastIndex(of: "\n").map { text.distance(from: text.startIndex, to: text.index(after: $0)) }) ?? 0
    }

    private static func lineEnd(containing offset: Int, in text: String) -> Int {
        let clamped = max(0, min(offset, text.count))
        let startIndex = index(at: clamped, in: text)
        guard let newlineIndex = text[startIndex...].firstIndex(of: "\n") else {
            return text.count
        }
        return text.distance(from: text.startIndex, to: newlineIndex)
    }

    private static func substring(in text: String, range: Range<Int>) -> String {
        let normalized = normalize(range, in: text)
        let start = index(at: normalized.lowerBound, in: text)
        let end = index(at: normalized.upperBound, in: text)
        return String(text[start..<end])
    }

    private static func normalize(_ range: Range<Int>, in text: String) -> Range<Int> {
        let count = text.count
        let lower = max(0, min(range.lowerBound, count))
        let upper = max(lower, min(range.upperBound, count))
        return lower..<upper
    }

    private static func index(at offset: Int, in text: String) -> String.Index {
        text.index(text.startIndex, offsetBy: max(0, min(offset, text.count)))
    }

    private static func unwrapInline(_ text: String, prefix: String, suffix: String) -> String? {
        guard text.count >= prefix.count + suffix.count,
              text.hasPrefix(prefix),
              text.hasSuffix(suffix)
        else {
            return nil
        }

        if prefix == "*", suffix == "*", (text.hasPrefix("**") || text.hasSuffix("**")) {
            return nil
        }

        return String(text.dropFirst(prefix.count).dropLast(suffix.count))
    }

    private static func unwrapCode(_ text: String) -> String? {
        if text.hasPrefix("```\n"), text.hasSuffix("\n```"), text.count >= 8 {
            return String(text.dropFirst(4).dropLast(4))
        }
        return unwrapInline(text, prefix: "`", suffix: "`")
    }

    private static func unwrapLink(_ text: String) -> String? {
        guard text.hasPrefix("["),
              text.hasSuffix(")"),
              let separatorRange = text.range(of: "](")
        else {
            return nil
        }

        let label = String(text[text.index(after: text.startIndex)..<separatorRange.lowerBound])
        let urlStart = separatorRange.upperBound
        guard urlStart <= text.index(before: text.endIndex) else { return nil }
        let url = String(text[urlStart..<text.index(before: text.endIndex)])
        guard !label.isEmpty, !url.isEmpty else { return nil }
        return label
    }

    private static func matches(action: MarkdownFormattingAction, line: ParsedBlockLine) -> Bool {
        switch action {
        case .heading:
            if case .heading(level: 1) = line.kind { return true }
            return false
        case .quote:
            if case .quote = line.kind { return true }
            return false
        case .bulletList:
            if case .bulletList = line.kind { return true }
            return false
        case .numberedList:
            if case .numberedList = line.kind { return true }
            return false
        case .taskList:
            if case .taskList = line.kind { return true }
            return false
        case .bold, .italic, .code, .link:
            return false
        }
    }

    private static func transform(
        line: ParsedBlockLine,
        action: MarkdownFormattingAction,
        index: Int,
        shouldRemove: Bool
    ) -> String {
        let baseContent = line.content
        if shouldRemove {
            return line.indentation + baseContent
        }

        let prefix: String = switch action {
        case .heading:
            "# "
        case .quote:
            "> "
        case .bulletList:
            "- "
        case .numberedList:
            "\(index + 1). "
        case .taskList:
            "- [ ] "
        case .bold, .italic, .code, .link:
            ""
        }
        return line.indentation + prefix + baseContent
    }

    private static func parseBlockLine(_ line: String) -> ParsedBlockLine {
        let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
        let contentStart = line.index(line.startIndex, offsetBy: indentation.count)
        let trimmed = String(line[contentStart...])

        if let match = trimmed.wholeMatch(of: /^(#{1,6})\s+(.*)$/) {
            return ParsedBlockLine(
                indentation: indentation,
                content: String(match.2),
                kind: .heading(level: match.1.count)
            )
        }

        if let match = trimmed.wholeMatch(of: /^>\s+(.*)$/) {
            return ParsedBlockLine(
                indentation: indentation,
                content: String(match.1),
                kind: .quote
            )
        }

        if let match = trimmed.wholeMatch(of: /^(?:[-+*]|\d+\.)\s+\[([xX ])\]\s+(.*)$/) {
            return ParsedBlockLine(
                indentation: indentation,
                content: String(match.2),
                kind: .taskList(checked: match.1.lowercased() == "x")
            )
        }

        if let match = trimmed.wholeMatch(of: /^([-+*])\s+(.*)$/) {
            return ParsedBlockLine(
                indentation: indentation,
                content: String(match.2),
                kind: .bulletList
            )
        }

        if let match = trimmed.wholeMatch(of: /^(\d+)\.\s+(.*)$/) {
            return ParsedBlockLine(
                indentation: indentation,
                content: String(match.2),
                kind: .numberedList
            )
        }

        return ParsedBlockLine(
            indentation: indentation,
            content: trimmed,
            kind: .none
        )
    }
}

private struct ParsedBlockLine {
    let indentation: String
    let content: String
    let kind: ParsedBlockKind
}

private enum ParsedBlockKind {
    case none
    case heading(level: Int)
    case quote
    case bulletList
    case numberedList
    case taskList(checked: Bool)
}
