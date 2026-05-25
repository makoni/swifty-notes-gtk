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

    @Test @MainActor
    func `bar mounted on preview is forced into read-only mode`() throws {
        let rig = try Self.makeRig(suffix: "readonly", markdown: "# Doc\n\nbody.")
        // The bar's replace half should be inert because the
        // preview pane has nothing to replace.
        #expect(rig.bar.isReadOnly == true)
        #expect(rig.bar.replaceButton.sensitive == false)
        #expect(rig.bar.replaceAllButton.sensitive == false)
    }

    @Test @MainActor
    func `typing a query finds matches across multiple block types`() throws {
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

    @Test @MainActor
    func `step forward + backward navigates active match with wrap`() throws {
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

    @Test @MainActor
    func `clearing query empties matches and count`() throws {
        let rig = try Self.makeRig(suffix: "clear", markdown: "find me find me")
        rig.bar.debugTypeQuery("find")
        #expect(rig.controller.debugMatchCount == 2)
        rig.bar.debugTypeQuery("")
        #expect(rig.controller.debugMatchCount == 0)
        #expect(rig.controller.debugActiveIndex == nil)
        #expect(rig.bar.countLabel.text.isEmpty)
    }

    @Test @MainActor
    func `re-rendering the preview refreshes the cached matches`() throws {
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

    @Test @MainActor
    func `closing the bar resets cached state`() throws {
        let rig = try Self.makeRig(suffix: "close", markdown: "needle needle")
        rig.bar.setVisible(true, mode: .find)
        rig.bar.debugTypeQuery("needle")
        #expect(rig.controller.debugMatchCount == 2)
        rig.bar.setVisible(false)
        #expect(rig.controller.debugMatchCount == 0)
        #expect(rig.controller.debugCachedQuery.isEmpty)
    }

    @Test @MainActor
    func `images and thematic breaks do not contribute matches even when alt-text would match`() throws {
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
