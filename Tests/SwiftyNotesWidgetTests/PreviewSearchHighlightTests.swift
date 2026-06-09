#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

/// Phase B of #27 — verifies that ``MarkdownPreview.applySearchHighlights``
/// + ``MarkdownPreview.clearSearchHighlights`` toggle Pango
/// attributes on the right set of labels, and that the controller
/// can call them safely. The tests can't easily introspect the
/// PangoAttrList byte ranges from headless GTK, but they can
/// verify the labels-with-highlights set transitions correctly —
/// which is exactly what the controller depends on.
struct PreviewSearchHighlightTests {
    @MainActor
    private static func makePreview(suffix: String, markdown: String) throws -> MarkdownPreview {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.highlight.\(suffix)")
        try app.register()
        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        let blocks = MarkdownRenderer().blocks(for: markdown, darkAppearance: false)
        preview.render(blocks: blocks)
        return preview
    }

    @Test @MainActor
    func `apply with matches in two blocks marks both their labels`() throws {
        let preview = try Self.makePreview(suffix: "two-blocks", markdown: """
        # Doc

        First paragraph search.

        Second paragraph search.
        """)
        let matches = MarkdownSearchEngine.search(
            blocks: preview.debugLastRenderedBlocks,
            query: "search",
            options: .init(),
        )
        // Should find 2 hits in the body paragraphs (excluded
        // since # Doc has no search hit).
        #expect(matches.count == 2)
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        let blockIndices = matches.map(\.blockIndex)
        let expectedLabels: Set<OpaquePointer> = Set(blockIndices.compactMap {
            preview.blockTextSpans[$0]?.labelPointer
        })
        // In a coalesced richTextRun both paragraphs share a Label,
        // so the highlight target set is 1 label. In other cases
        // it'd be 2. Either way, every match's target label must
        // be in the highlighted set.
        #expect(expectedLabels.isSubset(of: preview.debugHighlightedLabelPointers))
        #expect(!preview.debugHighlightedLabelPointers.isEmpty)
    }

    @Test @MainActor
    func `clearSearchHighlights drops every previously-highlighted label`() throws {
        let preview = try Self.makePreview(suffix: "clear", markdown: """
        # Title

        body search body
        """)
        let matches = MarkdownSearchEngine.search(
            blocks: preview.debugLastRenderedBlocks,
            query: "search",
            options: .init(),
        )
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        #expect(!preview.debugHighlightedLabelPointers.isEmpty)
        preview.clearSearchHighlights()
        #expect(preview.debugHighlightedLabelPointers.isEmpty)
    }

    @Test @MainActor
    func `applying empty match set clears prior highlights`() throws {
        let preview = try Self.makePreview(suffix: "empty-apply", markdown: """
        first search second search
        """)
        let matches = MarkdownSearchEngine.search(
            blocks: preview.debugLastRenderedBlocks,
            query: "search",
            options: .init(),
        )
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        #expect(!preview.debugHighlightedLabelPointers.isEmpty)
        // Empty match set should sweep highlights away the same way
        // clearSearchHighlights does.
        preview.applySearchHighlights(matches: [], activeIndex: nil)
        #expect(preview.debugHighlightedLabelPointers.isEmpty)
    }

    @Test @MainActor
    func `switching the query replaces highlights without leaving stale ones`() throws {
        // Regression: changing the find query left the previous query's
        // highlights painted on labels that no longer match (and a different
        // shade lingered under the new matches). The applied-highlight set
        // must reflect ONLY the current query after a switch — no stale
        // substrings from the prior one. (The visual half — forcing GTK to
        // repaint a use-markup label whose attributes changed — is handled by
        // the markup round-trip in applyAttributes / clearLabelOverlay and is
        // verified manually, since headless tests don't render.)
        let preview = try Self.makePreview(suffix: "switch-query", markdown: """
        # Why it stands out

        A second paragraph with the letter d sprinkled around.
        """)
        let why = MarkdownSearchEngine.search(blocks: preview.debugLastRenderedBlocks, query: "Why", options: .init())
        preview.applySearchHighlights(matches: why, activeIndex: 0)
        #expect(preview.debugAppliedHighlightTexts.contains("Why"))

        let d = MarkdownSearchEngine.search(blocks: preview.debugLastRenderedBlocks, query: "d", options: .init())
        preview.applySearchHighlights(matches: d, activeIndex: 0)
        // After switching to "d", nothing from "Why" must remain in the
        // applied set — every applied substring is a "d"/"D".
        #expect(!preview.debugAppliedHighlightTexts.contains("Why"))
        #expect(!preview.debugAppliedHighlightTexts.isEmpty)
        #expect(preview.debugAppliedHighlightTexts.allSatisfy { $0.lowercased() == "d" })
    }

    @Test @MainActor
    func `replacing an overlay blanks the label markup so GTK rebuilds the layout`() throws {
        // Regression guard for the VISUAL half of the stale-highlight bug
        // that the logical test above (debugAppliedHighlightTexts) can't
        // catch. gtk_label_set_attributes alone does NOT invalidate a
        // use-markup label's cached PangoLayout, so replacing one overlay
        // with another left the OLD highlight painted. The fix toggles the
        // markup through "" to force a real layout rebuild — and set_markup
        // with the SAME string is a GTK no-op, so the only way to prove the
        // rebuild happened is that the label's LIVE markup actually became
        // empty mid-toggle. This reads that value back from GTK; a
        // regression that drops the empty write (turning it back into a
        // same-string no-op) reads back the original markup → fails here.
        let preview = try Self.makePreview(suffix: "blank-rebuild", markdown: """
        Why does the dog run today
        """)
        let why = MarkdownSearchEngine.search(blocks: preview.debugLastRenderedBlocks, query: "Why", options: .init())
        preview.applySearchHighlights(matches: why, activeIndex: 0)

        // Switch to a different substring in the SAME paragraph label —
        // this replaces the existing overlay, the exact path that left a
        // stale highlight before the layout-rebuild fix.
        let dog = MarkdownSearchEngine.search(blocks: preview.debugLastRenderedBlocks, query: "dog", options: .init())
        preview.applySearchHighlights(matches: dog, activeIndex: 0)

        #expect(!preview.debugMarkupRebuildBlankReads.isEmpty)
        // Every rebuild in the switch pass must have observed an empty
        // markup at the GTK level — that empty write is the fix.
        #expect(preview.debugMarkupRebuildBlankReads.allSatisfy { $0 })
    }

    @Test @MainActor
    func `search highlight lands correctly after an emoji shortcode in the block`() throws {
        // Offset-alignment guard for #28 × #27: a shortcode like
        // :white_check_mark: (19 source characters) collapses to ✅ (one
        // Character) in the rendered text. The highlight overlay computes
        // Character offsets over that rendered text, so a search term *after*
        // the emoji must still be painted on exactly the right span — not
        // shifted by the source/rendered length difference.
        let preview = try Self.makePreview(suffix: "emoji-offset", markdown: """
        Shipped :white_check_mark: and findme here
        """)
        let matches = MarkdownSearchEngine.search(
            blocks: preview.debugLastRenderedBlocks,
            query: "findme",
            options: .init(),
        )
        #expect(!matches.isEmpty)
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        #expect(preview.debugAppliedHighlightTexts == ["findme"])
    }

    @Test @MainActor
    func `search highlight aligns after a multi-scalar flag emoji shortcode`() throws {
        // Hardens the offset guard against scalar-vs-Character bugs: :de: → 🇩🇪
        // is ONE Swift Character but two Unicode scalars / eight UTF-8 bytes.
        // If the highlight offsets were ever computed in scalars or bytes
        // instead of Characters, the painted span would drift off "findme".
        let preview = try Self.makePreview(suffix: "flag-offset", markdown: """
        Region :de: then findme here
        """)
        let matches = MarkdownSearchEngine.search(
            blocks: preview.debugLastRenderedBlocks,
            query: "findme",
            options: .init(),
        )
        #expect(!matches.isEmpty)
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        #expect(preview.debugAppliedHighlightTexts == ["findme"])
    }

    @Test @MainActor
    func `table-only match highlights the matched cell substring`() throws {
        let preview = try Self.makePreview(suffix: "table-hit", markdown: """
        # Doc

        | a | b |
        |---|---|
        | search | other |
        """)
        let matches = MarkdownSearchEngine.search(
            blocks: preview.debugLastRenderedBlocks,
            query: "search",
            options: .init(),
        )
        // The match lands in a table cell.
        #expect(matches.contains(where: { $0.blockText.contains("search") }))
        // A table-only query now lights up the table's Label and the
        // applied highlight covers exactly the matched cell substring —
        // not the whole cell, not a neighbouring cell.
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        #expect(!preview.debugHighlightedLabelPointers.isEmpty)
        #expect(preview.debugAppliedHighlightTexts.contains("search"))
        // The active match wears the active style on the right cell too.
        #expect(preview.debugActiveHighlightTexts == ["search"])
    }

    @Test @MainActor
    func `clearing restores a highlighted table label`() throws {
        let preview = try Self.makePreview(suffix: "table-clear", markdown: """
        | a | b |
        |---|---|
        | search | other |
        """)
        let matches = MarkdownSearchEngine.search(
            blocks: preview.debugLastRenderedBlocks,
            query: "search",
            options: .init(),
        )
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        #expect(!preview.debugHighlightedLabelPointers.isEmpty)
        preview.clearSearchHighlights()
        #expect(preview.debugHighlightedLabelPointers.isEmpty)
        #expect(preview.debugAppliedHighlightTexts.isEmpty)
    }

    @Test @MainActor
    func `re-rendering identical content keeps span label pointers so highlights still paint`() throws {
        // Regression: a no-op re-render (shouldSkipRender, e.g. refreshPreview
        // on a view-mode switch) ran makeRows — which resets blockTextSpans
        // and repopulates them WITHOUT label pointers — then returned early,
        // skipping the attach walk. The freshly-rebuilt spans were left with
        // nil label pointers, so applySearchHighlights painted nothing even
        // though matches existed. This was the real cause of "preview search
        // highlight does nothing" once preview-only mode started rendering.
        let preview = try Self.makePreview(suffix: "skip-render", markdown: """
        # Heading with searchword

        Body paragraph.
        """)
        let blocks = preview.debugLastRenderedBlocks
        // Render the IDENTICAL content again — hits the skip-render path.
        preview.render(blocks: blocks)

        let matches = MarkdownSearchEngine.search(blocks: blocks, query: "searchword", options: .init())
        #expect(!matches.isEmpty)
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        // The heading label must still be linked after the no-op render, so
        // the overlay paints the matched substring.
        #expect(!preview.debugHighlightedLabelPointers.isEmpty)
        #expect(preview.debugAppliedHighlightTexts.contains("searchword"))
    }

    @Test @MainActor
    func `partial match inside a table cell highlights only the matched substring`() throws {
        // Cell text is longer than the query — exercises the localOffset /
        // match-length translation (the whole reason per-cell offset math
        // exists). A bug that painted the whole cell, or dropped localOffset,
        // would surface here.
        let preview = try Self.makePreview(suffix: "table-partial", markdown: """
        | label | value |
        |-------|-------|
        | x | searchable |
        """)
        let matches = MarkdownSearchEngine.search(
            blocks: preview.debugLastRenderedBlocks,
            query: "search",
            options: .init(),
        )
        #expect(!matches.isEmpty)
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        // "search" is a prefix of cell "searchable" — only those 6 chars,
        // not the whole cell, must be painted.
        #expect(preview.debugAppliedHighlightTexts == ["search"])
    }

    @Test @MainActor
    func `match in the middle of a table cell highlights at the right offset`() throws {
        // Query matches NOT at the cell start, so localOffset > 0.
        let preview = try Self.makePreview(suffix: "table-midcell", markdown: """
        | label | value |
        |-------|-------|
        | x | alpha beta gamma |
        """)
        let matches = MarkdownSearchEngine.search(
            blocks: preview.debugLastRenderedBlocks,
            query: "beta",
            options: .init(),
        )
        #expect(!matches.isEmpty)
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        #expect(preview.debugAppliedHighlightTexts == ["beta"])
    }

    @Test @MainActor
    func `two tables in one document highlight independently`() throws {
        let preview = try Self.makePreview(suffix: "two-tables", markdown: """
        | a | b |
        |---|---|
        | alpha | x |

        Some prose between.

        | c | d |
        |---|---|
        | y | alpha |
        """)
        let matches = MarkdownSearchEngine.search(
            blocks: preview.debugLastRenderedBlocks,
            query: "alpha",
            options: .init(),
        )
        // One "alpha" in each table.
        #expect(matches.count == 2)
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        // Two distinct table labels light up, and both painted "alpha".
        #expect(preview.debugHighlightedLabelPointers.count == 2)
        #expect(preview.debugAppliedHighlightTexts == ["alpha", "alpha"])
    }

    @Test @MainActor
    func `match in a body cell highlights that cell, not the header`() throws {
        // "Name" appears only as a body value; ensure the highlight lands
        // on the body cell (post-divider) and reads back as "Name".
        let preview = try Self.makePreview(suffix: "table-body", markdown: """
        | col | who |
        |-----|-----|
        | x   | Name |
        """)
        let matches = MarkdownSearchEngine.search(
            blocks: preview.debugLastRenderedBlocks,
            query: "Name",
            options: .init(),
        )
        #expect(!matches.isEmpty)
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        #expect(preview.debugAppliedHighlightTexts == ["Name"])
    }

    @Test @MainActor
    func `applying twice with same matches doesn't duplicate the label set`() throws {
        let preview = try Self.makePreview(suffix: "idempotent", markdown: """
        search again search
        """)
        let matches = MarkdownSearchEngine.search(
            blocks: preview.debugLastRenderedBlocks,
            query: "search",
            options: .init(),
        )
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        let firstSet = preview.debugHighlightedLabelPointers
        preview.applySearchHighlights(matches: matches, activeIndex: 1)
        // The active style changed (index 0 → 1) but the set of
        // labels carrying highlights is the same — both matches
        // are in the same paragraph Label.
        #expect(preview.debugHighlightedLabelPointers == firstSet)
    }

    @Test @MainActor
    func `code-block matches activate the SourceBuffer-tag overlay`() throws {
        let preview = try Self.makePreview(suffix: "code-tag", markdown: """
        # Doc

        body text

        ```
        let value = findMe()
        another findMe call
        ```
        """)
        let matches = MarkdownSearchEngine.search(
            blocks: preview.debugLastRenderedBlocks,
            query: "findMe",
            options: .init(),
        )
        // Two matches inside the code block; none in label-backed
        // blocks (this doc doesn't contain "findMe" elsewhere).
        #expect(matches.count == 2)
        let codeBlockIndex = matches[0].blockIndex
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        // Code-block buffer's blockIndex should now be marked
        // highlighted; label set stays empty since none of the
        // matches landed in a label-backed block.
        #expect(preview.debugHighlightedCodeBlockBlockIndexes.contains(codeBlockIndex))
        #expect(preview.debugHighlightedLabelPointers.isEmpty)

        // Clear: code-block highlights drop out too.
        preview.clearSearchHighlights()
        #expect(preview.debugHighlightedCodeBlockBlockIndexes.isEmpty)
    }

    @Test @MainActor
    func `matches across labels + code blocks light up both overlays`() throws {
        let preview = try Self.makePreview(suffix: "mixed", markdown: """
        # Title with findMe

        body findMe text

        ```
        findMe in code
        ```
        """)
        let matches = MarkdownSearchEngine.search(
            blocks: preview.debugLastRenderedBlocks,
            query: "findMe",
            options: .init(),
        )
        #expect(matches.count == 3)
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        // Both overlays are active.
        #expect(!preview.debugHighlightedLabelPointers.isEmpty)
        #expect(!preview.debugHighlightedCodeBlockBlockIndexes.isEmpty)
    }

    @Test @MainActor
    func `applying the same matches twice is memoized as a no-op`() throws {
        let preview = try Self.makePreview(suffix: "memo", markdown: "alpha search beta search")
        let matches = MarkdownSearchEngine.search(
            blocks: preview.debugLastRenderedBlocks,
            query: "search",
            options: .init(),
        )
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        let firstApplyCount = preview.debugHighlightApplyCount
        // Same arguments again — memoization should swallow this.
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        #expect(preview.debugHighlightApplyCount == firstApplyCount)
        // Stepping to a new active index IS a different argument
        // and DOES trigger work.
        preview.applySearchHighlights(matches: matches, activeIndex: 1)
        #expect(preview.debugHighlightApplyCount == firstApplyCount + 1)
    }

    @Test @MainActor
    func `applying highlights does not grow the preview widget tree`() throws {
        // Perf gate: the overlay is supposed to be an attribute
        // swap, not a widget rebuild. The recursive widget count
        // before and after must be identical — sysprof showed
        // attribute-only paths cost 14× less per frame than the
        // tree growth the alternative markup-rebuild approach
        // would have introduced.
        let preview = try Self.makePreview(suffix: "tree-stable", markdown: """
        # Doc

        body text body text

        ```
        code line one
        code line two
        ```
        """)
        let countBefore = preview.debugWidgetTreeCount
        let matches = MarkdownSearchEngine.search(
            blocks: preview.debugLastRenderedBlocks,
            query: "code",
            options: .init(),
        )
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        #expect(preview.debugWidgetTreeCount == countBefore)
        preview.clearSearchHighlights()
        #expect(preview.debugWidgetTreeCount == countBefore)
    }

    @Test @MainActor
    func `re-rendering preview keeps highlight pipeline working`() throws {
        let preview = try Self.makePreview(suffix: "rerender", markdown: "alpha search")
        let matches = MarkdownSearchEngine.search(
            blocks: preview.debugLastRenderedBlocks,
            query: "search",
            options: .init(),
        )
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        #expect(!preview.debugHighlightedLabelPointers.isEmpty)
        // After a re-render, the incremental update path may reuse
        // the same Label widget (and so the same opaque pointer)
        // if the new row shape matches the old. That's fine —
        // attachWidgetPointersToBlockSpans re-points blockTextSpans
        // at the live pointer. What we want to verify is that the
        // pipeline still works end-to-end after a render:
        // controller can clear, then re-apply against new matches,
        // and the labels light up against the rebuilt structure.
        let newBlocks = MarkdownRenderer().blocks(for: """
        first paragraph

        second search paragraph
        """, darkAppearance: false)
        preview.render(blocks: newBlocks)
        preview.clearSearchHighlights()
        #expect(preview.debugHighlightedLabelPointers.isEmpty)
        let newMatches = MarkdownSearchEngine.search(
            blocks: preview.debugLastRenderedBlocks,
            query: "search",
            options: .init(),
        )
        preview.applySearchHighlights(matches: newMatches, activeIndex: 0)
        #expect(!preview.debugHighlightedLabelPointers.isEmpty)
    }
}
#endif
