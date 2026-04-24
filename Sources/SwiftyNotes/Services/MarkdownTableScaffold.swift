import Foundation

/// Builds ready-to-insert GitHub-Flavored-Markdown table skeletons.
///
/// Exposed as a plain helper so the UI picker and the editor insert code
/// can share the same text-layout rules and so the scaffold is unit-tested
/// in isolation.
enum MarkdownTableScaffold {
    /// Column header placeholder prefix. The full placeholder is
    /// `"<headerPlaceholderPrefix> <columnNumber>"` — the suffix carries
    /// the column's one-based index. Kept visible to the user on purpose
    /// so the first thing they see in the preview is a recognizable table
    /// header rather than empty pipes.
    static let headerPlaceholderPrefix = "Column"

    /// Returns the raw markdown scaffold for a `rows × cols` table, or
    /// `nil` when either dimension is not a positive integer.
    ///
    /// The returned string has no leading or trailing newline — callers
    /// decide how it should be embedded in the surrounding text (see
    /// ``insertion(into:at:rows:cols:)``).
    static func generate(rows: Int, cols: Int) -> String? {
        guard rows > 0, cols > 0 else { return nil }

        let headers = (1 ... cols).map { "\(headerPlaceholderPrefix) \($0)" }
        let cellWidths = headers.map(\.count)

        func row(_ cells: [String]) -> String {
            "| " + cells.joined(separator: " | ") + " |"
        }

        let headerRow = row(headers)
        let alignmentRow = row(cellWidths.map { String(repeating: "-", count: max($0, 3)) })
        let emptyCells = cellWidths.map { String(repeating: " ", count: $0) }
        let dataRows = Array(repeating: row(emptyCells), count: rows)

        return ([headerRow, alignmentRow] + dataRows).joined(separator: "\n")
    }

    /// A single scaffold insertion ready to hand to the editor's edit
    /// machinery. Pairs the replacement string with the selection range
    /// the editor should apply afterwards (first column-header
    /// placeholder, so the user can start typing immediately).
    struct Insertion: Equatable {
        let replacementRange: Range<Int>
        let replacementText: String
        /// Absolute offsets inside the post-edit text that should be
        /// selected. Already accounts for any leading newline padding
        /// the scaffold carries.
        let selectedRange: Range<Int>
    }

    /// Builds the replacement text + selection for inserting a scaffold
    /// at `cursor`. Honors "smart" line boundaries:
    ///
    /// * When the cursor is already on a blank line the scaffold is
    ///   inserted verbatim and a single trailing newline keeps following
    ///   text on its own line.
    /// * When the cursor is in the middle (or at the start) of a
    ///   non-empty line the scaffold is padded with a leading `"\n"` so
    ///   it lands on a fresh line, and a trailing `"\n\n"` so whatever
    ///   comes next gets a blank separator.
    static func insertion(
        into text: String,
        at cursor: Int,
        rows: Int,
        cols: Int,
    ) -> Insertion {
        let scaffold = generate(rows: rows, cols: cols) ?? ""
        let clampedCursor = max(0, min(cursor, text.count))
        let onBlankLine = isCursorOnBlankLine(in: text, at: clampedCursor)

        let leadingNewlines = onBlankLine ? "" : "\n"
        let trailingNewlines = onBlankLine ? "\n" : "\n\n"
        let replacement = leadingNewlines + scaffold + trailingNewlines

        // Compute the absolute range that selects the first column header
        // placeholder so the user can overwrite "Column 1" on the spot.
        let headerPlaceholder = "\(headerPlaceholderPrefix) 1"
        let placeholderOffsetInScaffold = scaffold.range(of: headerPlaceholder)
            .map { scaffold.distance(from: scaffold.startIndex, to: $0.lowerBound) }
            ?? 0
        let selectionStart = clampedCursor + leadingNewlines.count + placeholderOffsetInScaffold
        let selectionEnd = selectionStart + headerPlaceholder.count

        return Insertion(
            replacementRange: clampedCursor ..< clampedCursor,
            replacementText: replacement,
            selectedRange: selectionStart ..< selectionEnd,
        )
    }

    /// True when `cursor` sits on a line made up entirely of whitespace
    /// (including the empty string / start-of-file / end-of-file cases).
    private static func isCursorOnBlankLine(in text: String, at cursor: Int) -> Bool {
        guard !text.isEmpty else { return true }

        // Walk backwards to the start of the current line.
        let characters = Array(text)
        var lineStart = cursor
        while lineStart > 0, characters[lineStart - 1] != "\n" {
            lineStart -= 1
        }
        // Walk forward to the end of the current line.
        var lineEnd = cursor
        while lineEnd < characters.count, characters[lineEnd] != "\n" {
            lineEnd += 1
        }
        let line = String(characters[lineStart ..< lineEnd])
        return line.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
