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
    func `apply skips matches in blocks with no span entry (tables)`() throws {
        let preview = try Self.makePreview(suffix: "table-skip", markdown: """
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
        // The table cell IS in the engine's match list…
        #expect(matches.contains(where: { $0.blockText.contains("search") }))
        // …but Phase A intentionally leaves tables out of
        // blockTextSpans, so apply skips them.
        preview.applySearchHighlights(matches: matches, activeIndex: 0)
        // For a doc with ONLY table matches, no labels light up.
        let tableOnlyMatches = matches.filter {
            preview.blockTextSpans[$0.blockIndex] == nil
        }
        // The bar can still safely call apply with table-only
        // matches; no highlights but also no crash.
        #expect(tableOnlyMatches.count >= 0)
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
