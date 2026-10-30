import Foundation

/// What Return and Shift+Return do at the end of a list, quote or table line
/// (GitHub issue #34).
enum MarkdownListContinuation {
    /// What pressing Return (softBreak == false) or Shift+Return (softBreak == true) should do.
    /// Returns nil when the editor should fall back to inserting a plain newline.
    static func edit(in text: String, selection: Range<Int>, softBreak: Bool) -> MarkdownFormattingEdit? {
        let normalizedSelection = normalize(selection, in: text)
        guard normalizedSelection.isEmpty else { return nil }
        let caret = normalizedSelection.lowerBound

        let lines = lineRanges(in: text)
        let caretLineIndex = lineIndex(containing: caret, in: lines)
        let caretLine = lines[caretLineIndex]
        let caretLineText = substring(in: text, range: caretLine)

        guard !isInsideCodeBlock(text: text, lineStart: caretLine.lowerBound) else { return nil }

        if isTableRow(caretLineText) {
            return tableEdit(text: text, lines: lines, caretLineIndex: caretLineIndex)
        }

        guard let item = parseListItem(caretLineText) else { return nil }
        return listEdit(item: item, line: caretLineText, lineRange: caretLine, caret: caret, softBreak: softBreak)
    }

    // MARK: - Lists and quotes

    private struct ListItem {
        /// Full marker of the caret's line, indentation included.
        let marker: String
        /// Full marker of the line that continuation inserts, indentation included.
        let newMarker: String
        /// What Shift+Return inserts on the new line instead of a marker.
        let softPrefix: String
        /// The line's text after the marker.
        let content: String
    }

    private static func listEdit(
        item: ListItem,
        line: String,
        lineRange: Range<Int>,
        caret: Int,
        softBreak: Bool,
    ) -> MarkdownFormattingEdit? {
        let lineStart = lineRange.lowerBound

        // An empty item ends its list no matter where in the line the caret is.
        if item.content.trimmingCharacters(in: .whitespaces).isEmpty {
            return MarkdownFormattingEdit(
                replacementRange: lineRange,
                replacementText: "",
                selectedRange: lineStart ..< lineStart
            )
        }

        // A caret inside or before the marker (including its trailing space)
        // is not on the item's content yet, so no continuation.
        let column = caret - lineStart
        guard column > item.marker.count else { return nil }

        let prefix = softBreak ? item.softPrefix : item.newMarker
        let replacementText = String(line.prefix(column)) + "\n" + prefix + String(line.dropFirst(column))
        let selectedCaret = lineStart + column + 1 + prefix.count
        return MarkdownFormattingEdit(
            replacementRange: lineRange,
            replacementText: replacementText,
            selectedRange: selectedCaret ..< selectedCaret
        )
    }

    private static func parseListItem(_ line: String) -> ListItem? {
        let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
        var marker = indentation
        var rest = String(line.dropFirst(indentation.count))
        var inQuote = false

        if rest.hasPrefix("> ") {
            inQuote = true
            marker += "> "
            rest = String(rest.dropFirst(2))
        }

        if let match = rest.wholeMatch(of: /^(\d+)([.)]) (.*)$/) {
            guard let number = Int(String(match.1)) else { return nil }
            let delimiter = String(match.2)
            let fullMarker = marker + String(match.1) + delimiter + " "
            return ListItem(
                marker: fullMarker,
                newMarker: marker + String(number + 1) + delimiter + " ",
                softPrefix: inQuote ? marker : String(repeating: " ", count: fullMarker.count),
                content: String(match.3),
            )
        }

        if let match = rest.wholeMatch(of: /^([-+*]) \[([ xX])\] (.*)$/) {
            let bullet = String(match.1)
            let fullMarker = marker + bullet + " [" + String(match.2) + "] "
            return ListItem(
                marker: fullMarker,
                newMarker: marker + bullet + " [ ] ",
                softPrefix: inQuote ? marker : String(repeating: " ", count: fullMarker.count),
                content: String(match.3),
            )
        }

        if let match = rest.wholeMatch(of: /^([-+*]) (.*)$/) {
            let fullMarker = marker + String(match.1) + " "
            return ListItem(
                marker: fullMarker,
                newMarker: fullMarker,
                softPrefix: inQuote ? marker : String(repeating: " ", count: fullMarker.count),
                content: String(match.2),
            )
        }

        guard inQuote else { return nil }
        return ListItem(
            marker: marker,
            newMarker: marker,
            softPrefix: marker,
            content: rest,
        )
    }

    // MARK: - Tables

    private static func tableEdit(
        text: String,
        lines: [Range<Int>],
        caretLineIndex: Int,
    ) -> MarkdownFormattingEdit? {
        let caretLine = lines[caretLineIndex]
        let caretLineText = substring(in: text, range: caretLine)

        // The caret standing on a separator row never continues, and a run of
        // pipe lines only is a table when one of its rows is a separator.
        guard !isSeparatorLine(caretLineText),
              separatorLine(in: lines, around: caretLineIndex, text: text) != nil
        else {
            return nil
        }

        let cells = tableCells(in: caretLineText)
        let lineStart = caretLine.lowerBound

        // A row whose cells are all blank ends the table.
        if cells.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return MarkdownFormattingEdit(
                replacementRange: caretLine,
                replacementText: "",
                selectedRange: lineStart ..< lineStart
            )
        }

        // The row is not split: the caret stays where the new row's first
        // cell starts, after the first `| `.
        let newRow = "|" + String(repeating: "  |", count: cells.count)
        let replacementText = caretLineText + "\n" + newRow
        let selectedCaret = lineStart + caretLineText.count + "\n| ".count
        return MarkdownFormattingEdit(
            replacementRange: caretLine,
            replacementText: replacementText,
            selectedRange: selectedCaret ..< selectedCaret
        )
    }

    private static func separatorLine(
        in lines: [Range<Int>],
        around caretLineIndex: Int,
        text: String,
    ) -> Int? {
        var top = caretLineIndex
        var bottom = caretLineIndex
        while top > 0, isTableRow(substring(in: text, range: lines[top - 1])) {
            top -= 1
        }
        while bottom < lines.count - 1, isTableRow(substring(in: text, range: lines[bottom + 1])) {
            bottom += 1
        }
        for lineIndex in top ... bottom where isSeparatorLine(substring(in: text, range: lines[lineIndex])) {
            return lineIndex
        }
        return nil
    }

    private static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 2 && trimmed.hasPrefix("|") && trimmed.hasSuffix("|")
    }

    private static func isSeparatorLine(_ line: String) -> Bool {
        let cells = tableCells(in: line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            cell.contains(where: { $0 == "-" }) && cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
        }
    }

    private static func tableCells(in line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return [] }
        let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false)
        return Array(parts.dropFirst().dropLast()).map(String.init)
    }

    // MARK: - Lines and offsets

    private static func lineRanges(in text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var offset = 0
        for character in text {
            if character == "\n" {
                ranges.append(start ..< offset)
                start = offset + 1
            }
            offset += 1
        }
        ranges.append(start ..< text.count)
        return ranges
    }

    private static func lineIndex(containing caret: Int, in lines: [Range<Int>]) -> Int {
        for (index, range) in lines.enumerated() where caret <= range.upperBound {
            return index
        }
        return max(0, lines.count - 1)
    }

    /// Whether the line starting at `lineStart` (a character offset) lies
    /// in a code block — fenced, `math` or indented — found as the preview
    /// and the spell checker find them: a list marker there is code.
    private static func isInsideCodeBlock(text: String, lineStart: Int) -> Bool {
        let scalarOffset = text[..<index(at: lineStart, in: text)].unicodeScalars.count
        return MathSpanExtractor.extract(from: text).codeBlocks.contains { $0.contains(scalarOffset) }
    }

    private static func substring(in text: String, range: Range<Int>) -> String {
        let normalized = normalize(range, in: text)
        let start = index(at: normalized.lowerBound, in: text)
        let end = index(at: normalized.upperBound, in: text)
        return String(text[start ..< end])
    }

    private static func normalize(_ range: Range<Int>, in text: String) -> Range<Int> {
        let count = text.count
        let lower = max(0, min(range.lowerBound, count))
        let upper = max(lower, min(range.upperBound, count))
        return lower ..< upper
    }

    private static func index(at offset: Int, in text: String) -> String.Index {
        text.index(text.startIndex, offsetBy: max(0, min(offset, text.count)))
    }
}
