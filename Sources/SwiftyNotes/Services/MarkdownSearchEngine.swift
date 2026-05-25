import Foundation

/// Search-time options that mirror the three toggle buttons exposed
/// in the search bar. Defaults match GNOME Text Editor's defaults:
/// case-insensitive, whole-word off, regex off.
public struct SearchOptions: Sendable, Equatable {
    public var caseSensitive: Bool = false
    public var wholeWord: Bool = false
    public var regex: Bool = false

    public init(caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
    }
}

/// A single hit inside one block. ``blockIndex`` refers to the
/// position inside the `[RenderedBlock]` slice the caller passed in,
/// ``range`` is a substring range over ``blockText`` — the engine's
/// searchable-text view of that block, which is *not* always the
/// same as ``RenderedBlock.plainText``.
///
/// We pin both the index and the text together so the highlighter
/// can produce a Pango-markup overlay without having to re-extract
/// the searchable text from the block.
public struct PreviewMatch: Sendable, Equatable {
    public let blockIndex: Int
    public let range: Range<String.Index>
    public let blockText: String

    public init(blockIndex: Int, range: Range<String.Index>, blockText: String) {
        self.blockIndex = blockIndex
        self.range = range
        self.blockText = blockText
    }
}

/// Pure-logic search over an array of rendered blocks. No GTK
/// types involved — the engine is testable without a display.
///
/// Behaviour contract:
///   - Empty / whitespace-only query: returns `[]`.
///   - Default case-insensitive; ``SearchOptions.caseSensitive``
///     opts back into exact case.
///   - ``SearchOptions.wholeWord`` adds `\b...\b` boundaries.
///   - ``SearchOptions.regex`` interprets the query as a pattern;
///     unparsable patterns return `[]` (no throw — the search bar
///     surfaces "no matches" rather than an error dialog).
///   - Image, image-group, and thematic-break blocks are *not*
///     searched even though they have a `plainText` representation.
///     Their text is metadata, not document content, so matching by
///     it would confuse rather than help.
///   - List items search only the item's text payload, not the
///     bullet / number marker.
///   - Code blocks search only the code body, not the language
///     string prefix that `RenderedBlock.plainText` adds.
///   - Table cells are joined by `\n`, so cross-row matches don't
///     accidentally land on the pipe separator.
public enum MarkdownSearchEngine {
    public static func search(
        blocks: [RenderedBlock],
        query: String,
        options: SearchOptions = SearchOptions(),
    ) -> [PreviewMatch] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        guard let regex = compile(query: query, options: options) else {
            return []
        }

        var matches: [PreviewMatch] = []
        for (index, block) in blocks.enumerated() {
            guard let target = searchableText(for: block) else { continue }
            matches.append(contentsOf: collectMatches(in: target, regex: regex, blockIndex: index))
        }
        return matches
    }

    /// Plain-text overload used by the editor pane — the editor lives
    /// on raw markdown source, so the structured block walk doesn't
    /// apply. Returns ranges over the input string itself.
    ///
    /// Same option semantics as the block-based ``search(blocks:...)``:
    /// empty / whitespace-only query → empty, invalid regex → empty,
    /// no throw.
    public static func matches(
        in text: String,
        query: String,
        options: SearchOptions = SearchOptions(),
    ) -> [Range<String.Index>] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let regex = compile(query: query, options: options)
        else {
            return []
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: nsRange).compactMap { result in
            guard result.range.length > 0,
                  let range = Range(result.range, in: text)
            else { return nil }
            return range
        }
    }

    /// The slice of a block's text that's exposed to the user as
    /// readable content. Differs from ``RenderedBlock.plainText`` in
    /// three deliberate ways: code blocks omit the language prefix,
    /// list items omit the bullet marker, and tables use newlines
    /// between cells so pipe glyphs aren't searchable. `nil` means
    /// "this block has no content to search through" — image,
    /// image-group, thematic-break.
    static func searchableText(for block: RenderedBlock) -> String? {
        switch block {
        case .image, .imageGroup, .thematicBreak:
            return nil
        case let .heading(_, text),
             let .paragraph(text),
             let .blockquote(text):
            return text.plainText
        case let .codeBlock(code, _):
            return code
        case let .listItem(text, _, _, _, _):
            return text.plainText
        case let .table(headers, rows, _):
            let headerLine = headers.map(\.plainText).joined(separator: "\n")
            let cellLines = rows.flatMap { row in
                row.map(\.plainText)
            }
            return ([headerLine] + cellLines).joined(separator: "\n")
        }
    }

    private static func compile(query: String, options: SearchOptions) -> NSRegularExpression? {
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord {
            pattern = "\\b\(pattern)\\b"
        }
        var regexOptions: NSRegularExpression.Options = []
        if !options.caseSensitive {
            regexOptions.insert(.caseInsensitive)
        }
        return try? NSRegularExpression(pattern: pattern, options: regexOptions)
    }

    private static func collectMatches(
        in text: String,
        regex: NSRegularExpression,
        blockIndex: Int,
    ) -> [PreviewMatch] {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: nsRange).compactMap { result in
            guard result.range.length > 0,
                  let range = Range(result.range, in: text)
            else { return nil }
            return PreviewMatch(blockIndex: blockIndex, range: range, blockText: text)
        }
    }
}
