#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

struct PreviewSearchControllerTests {
    @MainActor
    private static func makeRig(suffix: String, markdown: String) throws -> (
        preview: MarkdownPreview,
        bar: FindReplaceBar,
        controller: PreviewSearchController,
    ) {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.previewsearch.\(suffix)")
        try app.register()
        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        let blocks = MarkdownRenderer().blocks(for: markdown, darkAppearance: false)
        preview.render(blocks: blocks)
        let bar = FindReplaceBar()
        let controller = PreviewSearchController(bar: bar, preview: preview)
        return (preview, bar, controller)
    }

    @Test("Bar mounted on preview is forced into read-only mode") @MainActor
    func barMountedOnPreviewIsForcedIntoReadOnlyMode() throws {
        let rig = try Self.makeRig(suffix: "readonly", markdown: "# Doc\n\nbody.")
        // The bar's replace half should be inert because the
        // preview pane has nothing to replace.
        #expect(rig.bar.isReadOnly == true)
        #expect(rig.bar.replaceButton.sensitive == false)
        #expect(rig.bar.replaceAllButton.sensitive == false)
    }

    @Test("Typing a query that only hits a table lights up the table highlight") @MainActor
    func typingAQueryThatOnlyHitsATableLightsUpTheTable() throws {
        let rig = try Self.makeRig(
            suffix: "table-only",
            markdown: """
            # Doc

            | area | note |
            |------|------|
            | search | other |
            """,
        )
        rig.bar.debugTypeQuery("search")
        // The only match is inside a table cell — end to end, the
        // controller must drive the preview to paint that cell.
        #expect(rig.controller.debugMatchCount >= 1)
        #expect(!rig.preview.debugHighlightedLabelPointers.isEmpty)
        #expect(rig.preview.debugAppliedHighlightTexts.contains("search"))
    }

    @Test("Typing a query finds matches across multiple block types") @MainActor
    func typingAQueryFindsMatchesAcrossMultipleBlockTypes() throws {
        let rig = try Self.makeRig(
            suffix: "multi-block",
            markdown: """
            # Search Doc

            Body mentions search.

            > Quote about search.

            ```
            search() {}
            ```

            - search item
            """,
        )
        rig.bar.debugTypeQuery("search")
        // Heading "Search Doc", paragraph "search", blockquote
        // "search", code block "search", list item "search" — five
        // distinct block hits.
        #expect(rig.controller.debugMatchCount >= 5)
    }

    @Test("Step forward + backward navigates active match with wrap") @MainActor
    func stepForwardBackwardNavigatesActiveMatchWithWrap() throws {
        let rig = try Self.makeRig(
            suffix: "step",
            markdown: """
            # Title

            alpha.

            alpha again.

            alpha once more.
            """,
        )
        rig.bar.debugTypeQuery("alpha")
        // Auto-step landed on match 0 already.
        #expect(rig.controller.debugActiveIndex == 0)
        rig.bar.debugClickNext()
        #expect(rig.controller.debugActiveIndex == 1)
        rig.bar.debugClickNext()
        #expect(rig.controller.debugActiveIndex == 2)
        rig.bar.debugClickNext()
        // Wrap.
        #expect(rig.controller.debugActiveIndex == 0)
        rig.bar.debugClickPrev()
        // Wrap backward.
        #expect(rig.controller.debugActiveIndex == 2)
    }

    @Test("Clearing query empties matches and count") @MainActor
    func clearingQueryEmptiesMatchesAndCount() throws {
        let rig = try Self.makeRig(suffix: "clear", markdown: "find me find me")
        rig.bar.debugTypeQuery("find")
        #expect(rig.controller.debugMatchCount == 2)
        rig.bar.debugTypeQuery("")
        #expect(rig.controller.debugMatchCount == 0)
        #expect(rig.controller.debugActiveIndex == nil)
        #expect(rig.bar.countLabel.text.isEmpty)
    }

    @Test("Re-rendering the preview refreshes the cached matches") @MainActor
    func reRenderingThePreviewRefreshesTheCachedMatches() throws {
        let rig = try Self.makeRig(suffix: "rerender", markdown: "alpha beta")
        rig.bar.debugTypeQuery("alpha")
        #expect(rig.controller.debugMatchCount == 1)
        // Drop the active match and add new ones — controller
        // should pick up the new block list after the host calls
        // onPreviewRerendered.
        let updated = MarkdownRenderer().blocks(for: "alpha alpha alpha", darkAppearance: false)
        rig.preview.render(blocks: updated)
        rig.controller.onPreviewRerendered()
        #expect(rig.controller.debugMatchCount == 3)
    }

    @Test("Closing the bar resets cached state") @MainActor
    func closingTheBarResetsCachedState() throws {
        let rig = try Self.makeRig(suffix: "close", markdown: "needle needle")
        rig.bar.setVisible(true, mode: .find)
        rig.bar.debugTypeQuery("needle")
        #expect(rig.controller.debugMatchCount == 2)
        rig.bar.setVisible(false)
        #expect(rig.controller.debugMatchCount == 0)
        #expect(rig.controller.debugCachedQuery.isEmpty)
    }

    @Test("Typing a query activates Pango highlights on matching labels") @MainActor
    func typingAQueryActivatesPangoHighlightsOnMatchingLabels() throws {
        // Phase D: PreviewSearchController must call
        // preview.applySearchHighlights when the bar's query
        // changes. Verifying through the public hook:
        // debugHighlightedLabelPointers on the preview becomes
        // non-empty.
        let rig = try Self.makeRig(suffix: "wire-apply", markdown: """
        # Title

        first match here

        second match line
        """)
        rig.bar.debugTypeQuery("match")
        #expect(rig.controller.debugMatchCount == 2)
        #expect(!rig.preview.debugHighlightedLabelPointers.isEmpty)
    }

    @Test("Closing the bar clears all preview highlight attributes") @MainActor
    func closingTheBarClearsAllPreviewHighlightAttributes() throws {
        let rig = try Self.makeRig(suffix: "wire-clear", markdown: "needle in haystack and needle")
        rig.bar.setVisible(true, mode: .find)
        rig.bar.debugTypeQuery("needle")
        #expect(!rig.preview.debugHighlightedLabelPointers.isEmpty)
        rig.bar.setVisible(false)
        // Controller's onClose path routed through clearState ->
        // preview.clearSearchHighlights, so no labels carry
        // attributes any more.
        #expect(rig.preview.debugHighlightedLabelPointers.isEmpty)
    }

    @Test("Code-block-only query activates the SourceBuffer-tag overlay") @MainActor
    func codeBlockOnlyQueryActivatesTheSourceBufferTagOverlay() throws {
        let rig = try Self.makeRig(suffix: "wire-code", markdown: """
        # Doc

        body text without the term

        ```
        let value = findMe()
        ```
        """)
        rig.bar.debugTypeQuery("findMe")
        #expect(rig.controller.debugMatchCount == 1)
        // Label overlay stays empty (only code-block match), but
        // the code-block buffer is highlighted.
        #expect(rig.preview.debugHighlightedLabelPointers.isEmpty)
        #expect(!rig.preview.debugHighlightedCodeBlockBlockIndexes.isEmpty)
    }

    @Test("Images and thematic breaks do not contribute matches even when alt-text would match") @MainActor
    func imagesAndThematicBreaksDoNotContributeMatchesEvenWhenAltText() throws {
        let rig = try Self.makeRig(
            suffix: "skip-image",
            markdown: """
            # Doc

            ![A picture of a dog](dog.png)

            ---

            Body mentions dog.
            """,
        )
        rig.bar.debugTypeQuery("dog")
        // Only the paragraph match should count — the image alt
        // text and the thematic break are skipped.
        #expect(rig.controller.debugMatchCount == 1)
    }
}
#endif
