import Foundation
@testable import SwiftyNotes
import Testing

struct MarkdownSearchEngineTests {
    private static let sample: [RenderedBlock] = [
        .heading(level: 1, text: .plain("Doc Title")),
        .paragraph(.plain("First paragraph with the word search in it.")),
        .paragraph(.plain("Another sentence. The word Search appears with capital S.")),
        .blockquote(.plain("Searching for clarity in tests.")),
        .codeBlock(code: "let value = search(for: \"foo\")\n// no match here\n", language: "swift"),
        .listItem(text: .plain("First task"), depth: 0, marker: "- "),
        .listItem(text: .plain("Second task with Search again"), depth: 0, marker: "- "),
        .table(
            headers: [.plain("Area"), .plain("Note")],
            rows: [
                [.plain("Setup"), .plain("describes search settings")],
                [.plain("Run"), .plain("see results here")],
            ],
            alignments: [.leading, .leading],
        ),
        .image(alt: "Search icon", source: "icon.png", title: nil),
        .thematicBreak,
    ]

    @Test("Empty query returns no matches")
    func emptyQueryReturnsNoMatches() {
        let result = MarkdownSearchEngine.search(blocks: Self.sample, query: "", options: .init())
        #expect(result.isEmpty)
    }

    @Test("Whitespace-only query returns no matches")
    func whitespaceOnlyQueryReturnsNoMatches() {
        let result = MarkdownSearchEngine.search(blocks: Self.sample, query: "   ", options: .init())
        #expect(result.isEmpty)
    }

    @Test("Case-insensitive is the default and catches every capitalisation")
    func caseInsensitiveIsTheDefaultAndCatchesEveryCapitalisation() {
        let result = MarkdownSearchEngine.search(blocks: Self.sample, query: "search", options: .init())
        // First paragraph has 1 hit, second paragraph has 1 hit ("Search"),
        // blockquote has 1 hit ("Searching"), code block has 1 hit
        // ("search"), the second list item has 1 hit ("Search"), the
        // table cell "describes search settings" has 1 hit.
        // That's 6 matches across 6 distinct blocks.
        let blockIndices = result.map(\.blockIndex)
        #expect(blockIndices == [1, 2, 3, 4, 6, 7])
    }

    @Test("Case-sensitive excludes mismatched capitalisation")
    func caseSensitiveExcludesMismatchedCapitalisation() {
        var options = SearchOptions()
        options.caseSensitive = true
        let result = MarkdownSearchEngine.search(blocks: Self.sample, query: "Search", options: options)
        // "Search" with capital S appears in: second paragraph, blockquote
        // (as "Searching"), second list item. Lowercase hits drop out:
        // the first paragraph ("search") and the code block.
        #expect(result.map(\.blockIndex) == [2, 3, 6])
    }

    @Test("Whole-word excludes partial matches")
    func wholeWordExcludesPartialMatches() {
        var options = SearchOptions()
        options.wholeWord = true
        let result = MarkdownSearchEngine.search(blocks: Self.sample, query: "search", options: options)
        // "Searching" is a sub-word match and should drop out. The rest
        // (paragraphs, code block, list item, table cell) stay because
        // "search" is a standalone token.
        let blockIndices = result.map(\.blockIndex)
        #expect(!blockIndices.contains(3)) // blockquote "Searching" filtered out
        #expect(blockIndices.contains(1))  // first paragraph
        #expect(blockIndices.contains(2))  // second paragraph
    }

    @Test("Regex mode honours pattern syntax")
    func regexModeHonoursPatternSyntax() {
        var options = SearchOptions()
        options.regex = true
        // Matches the two consecutive capital-S Words "Search" and
        // "Searching", but not the lowercase "search" because the
        // pattern itself is case-sensitive without the regex inline
        // (?i) flag — and our options.caseSensitive default is false,
        // so the regex compiles case-insensitively. So this should
        // catch every "search/Search/Searching".
        let result = MarkdownSearchEngine.search(blocks: Self.sample, query: "search\\w*", options: options)
        #expect(result.count >= 5)
    }

    @Test("Regex mode with explicit case-sensitivity restricts matches")
    func regexModeWithExplicitCaseSensitivityRestrictsMatches() {
        var options = SearchOptions()
        options.regex = true
        options.caseSensitive = true
        let result = MarkdownSearchEngine.search(blocks: Self.sample, query: "Search\\w*", options: options)
        // Should match "Search" (paragraph 2), "Searching" (blockquote),
        // "Search" (second list item). Not "search" in paragraph 1
        // or the code block.
        #expect(result.map(\.blockIndex) == [2, 3, 6])
    }

    @Test("Invalid regex produces no matches, no throw")
    func invalidRegexProducesNoMatchesNoThrow() {
        var options = SearchOptions()
        options.regex = true
        let result = MarkdownSearchEngine.search(blocks: Self.sample, query: "[unclosed", options: options)
        #expect(result.isEmpty)
    }

    @Test("Images and thematic breaks are skipped even when their plainText would match")
    func imagesAndThematicBreaksAreSkippedEvenWhenTheirPlainTextWouldMatch() {
        // The image's alt text contains "Search icon" — but searching
        // by-alt is not a useful contract for an in-document text
        // search, so the engine pretends image blocks don't exist.
        let result = MarkdownSearchEngine.search(blocks: Self.sample, query: "icon", options: .init())
        #expect(result.isEmpty)
    }

    @Test("Multiple matches inside one block are returned in document order")
    func multipleMatchesInsideOneBlockAreReturnedInDocumentOrder() {
        let blocks: [RenderedBlock] = [
            .paragraph(.plain("alpha beta alpha gamma alpha")),
        ]
        let result = MarkdownSearchEngine.search(blocks: blocks, query: "alpha", options: .init())
        #expect(result.count == 3)
        // Ranges should be strictly increasing.
        let starts = result.map { result -> Int in
            blocks[0].plainText.distance(from: blocks[0].plainText.startIndex, to: result.range.lowerBound)
        }
        #expect(starts == [0, 11, 23])
    }

    @Test("Match snippet exposes the matched substring for highlight rendering")
    func matchSnippetExposesTheMatchedSubstringForHighlightRendering() {
        let result = MarkdownSearchEngine.search(blocks: Self.sample, query: "Search", options: .init())
        guard let first = result.first(where: { $0.blockIndex == 2 }) else {
            Issue.record("expected a match in paragraph 2")
            return
        }
        // The match's range, when sliced against the snapshot of the
        // block's searchable text, must reproduce the literal hit
        // (case follows the source).
        #expect(first.blockText[first.range] == "Search")
    }

    @Test("Code block contents are searched, language string is not")
    func codeBlockContentsAreSearchedLanguageStringIsNot() {
        // The language string "swift" alone should not produce a hit
        // — only the actual `code` body. (RenderedBlock.plainText
        // prefixes the language for accessibility; the engine has its
        // own searchable-text extractor that omits it.)
        let result = MarkdownSearchEngine.search(blocks: Self.sample, query: "swift", options: .init())
        #expect(result.isEmpty)

        let codeResult = MarkdownSearchEngine.search(blocks: Self.sample, query: "let value", options: .init())
        #expect(codeResult.map(\.blockIndex) == [4])
    }

    @Test("Table cells are searched, separator pipes are not")
    func tableCellsAreSearchedSeparatorPipesAreNot() {
        let result = MarkdownSearchEngine.search(blocks: Self.sample, query: "settings", options: .init())
        #expect(result.map(\.blockIndex) == [7])
        // The pipe glyph used to join cells in the plainText
        // serialisation shouldn't be searchable — searching for "|"
        // must not produce hits.
        let pipeResult = MarkdownSearchEngine.search(blocks: Self.sample, query: "|", options: .init())
        #expect(pipeResult.isEmpty)
    }

    @Test("Plain-text overload returns ranges into the source string")
    func plainTextOverloadReturnsRangesIntoTheSourceString() {
        let text = "alpha beta alpha gamma"
        let ranges = MarkdownSearchEngine.matches(in: text, query: "alpha", options: .init())
        #expect(ranges.count == 2)
        // Slicing the original text by each range reproduces "alpha".
        #expect(ranges.allSatisfy { text[$0] == "alpha" })
        // Ranges are in document order.
        let starts = ranges.map { text.distance(from: text.startIndex, to: $0.lowerBound) }
        #expect(starts == [0, 11])
    }

    @Test("Plain-text overload honours whole-word, regex, and case options")
    func plainTextOverloadHonoursWholeWordRegexAndCaseOptions() {
        let text = "Test the testing testTube"
        // Whole-word excludes "testing" and "testTube" (they're prefixes).
        var options = SearchOptions(wholeWord: true)
        let wholeWord = MarkdownSearchEngine.matches(in: text, query: "test", options: options)
        #expect(wholeWord.count == 1)
        #expect(text[wholeWord[0]] == "Test")

        // Case-sensitive flips it back so "Test" stays but lowercase
        // "testing" / "testTube" still drop out.
        options.caseSensitive = true
        let caseExact = MarkdownSearchEngine.matches(in: text, query: "Test", options: options)
        #expect(caseExact.count == 1)
        #expect(text[caseExact[0]] == "Test")

        // Regex catches all four.
        let regex = MarkdownSearchEngine.matches(in: text, query: "test\\w*", options: SearchOptions(regex: true))
        #expect(regex.count == 3)
    }

    @Test("listItem marker glyph is not part of the searchable text")
    func listItemMarkerGlyphIsNotPartOfTheSearchableText() {
        // The plainText returned by RenderedBlock for a list item is
        // "- First task" — but searching for "- " is not what the user
        // means by "find" inside a list. The engine searches only the
        // item's text payload.
        let result = MarkdownSearchEngine.search(blocks: Self.sample, query: "-", options: .init())
        #expect(result.isEmpty)
    }

    @Test("searchableText extracts the readable payload per block kind")
    func searchableTextExtractsReadablePayload() {
        // This is the single source of truth for "what slice of a block
        // is searchable" — MarkdownPreview's highlight overlay relies on
        // the exact same offsets, so the behaviour is pinned here before
        // any consumer reuses it.

        // Nothing to search through → nil.
        #expect(MarkdownSearchEngine.searchableText(for: .image(alt: "Logo", source: "x.png", title: nil)) == nil)
        #expect(MarkdownSearchEngine.searchableText(for: .imageGroup(items: [])) == nil)
        #expect(MarkdownSearchEngine.searchableText(for: .thematicBreak) == nil)

        // Text-bearing blocks expose their plain text.
        #expect(MarkdownSearchEngine.searchableText(for: .heading(level: 2, text: .plain("Title"))) == "Title")
        #expect(MarkdownSearchEngine.searchableText(for: .paragraph(.plain("Body text"))) == "Body text")
        #expect(MarkdownSearchEngine.searchableText(for: .blockquote(.plain("Quoted line"))) == "Quoted line")

        // Code block exposes the raw code, without the language prefix.
        #expect(
            MarkdownSearchEngine.searchableText(for: .codeBlock(code: "let x = 1", language: "swift")) == "let x = 1"
        )

        // List item drops the bullet marker.
        #expect(
            MarkdownSearchEngine.searchableText(for: .listItem(text: .plain("Task one"), depth: 0, marker: "- "))
                == "Task one"
        )

        // Table joins header + body cells with newlines so the pipe
        // glyphs between columns are never searchable.
        let table = RenderedBlock.table(
            headers: [.plain("H1"), .plain("H2")],
            rows: [[.plain("a"), .plain("b")], [.plain("c"), .plain("d")]],
            alignments: [.leading, .leading],
        )
        #expect(MarkdownSearchEngine.searchableText(for: table) == "H1\nH2\na\nb\nc\nd")
    }
}
