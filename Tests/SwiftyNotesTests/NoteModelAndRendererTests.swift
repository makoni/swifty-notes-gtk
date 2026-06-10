import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

struct NoteModelAndRendererTests {
    @Test("Derived title uses first meaningful line")
    func derivedTitleUsesFirstMeaningfulLine() {
        let title = Note.derivedTitle(from: "\n\n# Hello world\nBody")
        #expect(title == "Hello world")
    }

    @Test("Derived title skips leading standalone image")
    func derivedTitleSkipsLeadingStandaloneImage() {
        let title = Note.derivedTitle(from: "![Cover](assets/cover.png)\n\n# Hello world\nBody")
        #expect(title == "Hello world")
    }

    @Test("Derived title falls back for empty note")
    func derivedTitleFallsBackForEmptyNote() {
        #expect(Note.derivedTitle(from: " \n\n ") == "New Note")
    }

    @Test("Note retitle replaces first meaningful line")
    func noteRetitleReplacesFirstMeaningfulLine() {
        let note = Note(
            id: UUID(),
            filename: "note.md",
            createdAt: Date(),
            updatedAt: Date(),
            content: "Shopping list\n- eggs",
        )

        let renamed = note.retitled("Groceries")
        #expect(renamed.title == "Groceries")
        #expect(renamed.content.hasPrefix("Groceries"))
    }

    @Test("Note retitle preserves leading image and replaces heading after it")
    func noteRetitlePreservesLeadingImageAndReplacesHeadingAfterIt() {
        let note = Note(
            id: UUID(),
            filename: "note.md",
            createdAt: Date(),
            updatedAt: Date(),
            content: "![Cover](assets/cover.png)\n\n# Original\n\nBody",
        )

        let renamed = note.retitled("Updated")
        #expect(renamed.title == "Updated")
        #expect(renamed.content == "![Cover](assets/cover.png)\n\n# Updated\n\nBody")
    }

    @Test("Note search and export filename use readable title")
    func noteSearchAndExportFilenameUseReadableTitle() {
        let note = Note(
            id: UUID(),
            filename: "note.md",
            createdAt: Date(),
            updatedAt: Date(),
            content: "# Hello, Swift GTK!",
        )

        #expect(note.matches(searchQuery: "swift gtk"))
        #expect(note.suggestedExportFilename == "hello-swift-gtk.md")
        #expect(note.stableID == note.id.uuidString.lowercased())
    }

    @Test("Renderer builds heading and paragraph blocks")
    func rendererBuildsHeadingAndParagraphBlocks() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: "# Title\n\nParagraph", darkAppearance: false)
        #expect(blocks.count >= 2)
        #expect(blocks.first?.style == .heading(level: 1))
        #expect(blocks.first?.text == "Title")
    }

    @Test("Renderer builds task list markers")
    func rendererBuildsTaskListMarkers() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        - [x] Done
        - [ ] Todo
        """, darkAppearance: false)

        #expect(blocks.count == 2)
        #expect(blocks[0] == .listItem(text: .plain("Done"), depth: 0, marker: "[x]", loose: false, taskIndex: 0))
        #expect(blocks[1] == .listItem(text: .plain("Todo"), depth: 0, marker: "[ ]", loose: false, taskIndex: 1))
    }

    @Test("Renderer preserves task list markers when item contains inline markdown")
    func rendererPreservesTaskListMarkersWhenItemContainsInlineMarkdown() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        - [ ] Если было выделено **слово**, то после нажатия должно быть `код`
        """, darkAppearance: false)

        #expect(blocks.count == 1)
        guard case let .listItem(text, depth, marker, _, _) = blocks[0] else {
            Issue.record("Expected a task list item block")
            return
        }

        #expect(depth == 0)
        #expect(marker == "[ ]")
        #expect(text.plainText == "Если было выделено слово, то после нажатия должно быть код")
    }

    @Test("Renderer uses theme aware inline code background")
    func rendererUsesThemeAwareInlineCodeBackground() {
        let renderer = MarkdownRenderer()
        let lightBlocks = renderer.blocks(for: "Use `code` here", darkAppearance: false)
        let darkBlocks = renderer.blocks(for: "Use `code` here", darkAppearance: true)

        guard case let .paragraph(lightText) = lightBlocks.first,
              case let .paragraph(darkText) = darkBlocks.first
        else {
            Issue.record("Expected paragraph blocks")
            return
        }

        #expect(lightText.markup.contains("font_family=\"monospace\""))
        #expect(lightText.markup.contains("background=\"#f6f5f4\""))
        #expect(darkText.markup.contains("background=\"#3b3644\""))
        #expect(lightText.markup != darkText.markup)
    }

    @Test("Renderer builds standalone image block")
    func rendererBuildsStandaloneImageBlock() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(
            for: "![Swift and Adwaita showcase artwork](markdown-demo-image.png)",
            darkAppearance: false,
        )

        #expect(blocks == [
            .image(
                alt: "Swift and Adwaita showcase artwork",
                source: "markdown-demo-image.png",
                title: nil,
            ),
        ])
    }

    @Test("Renderer builds standalone HTML image block")
    func rendererBuildsStandaloneHTMLImageBlock() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(
            for: #"<img alt="Swift Adwaita" src="https://spaceinbox.me/images/swift-adwaita-2.webp">"#,
            darkAppearance: false,
        )

        #expect(blocks == [
            .image(
                alt: "Swift Adwaita",
                source: "https://spaceinbox.me/images/swift-adwaita-2.webp",
                title: nil,
            ),
        ])
    }

    @Test("Renderer builds image group for linked badge images") @MainActor
    func rendererBuildsImageGroupForLinkedBadgeImages() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        [![CI](https://github.com/makoni/swift-adwaita/actions/workflows/ci.yml/badge.svg)](https://github.com/makoni/swift-adwaita/actions/workflows/ci.yml)
        [![Swift 6.0+](https://img.shields.io/badge/Swift-6.0+-F05138.svg)](https://swift.org)
        """, darkAppearance: false)

        #expect(blocks == [
            .imageGroup(items: [
                .init(
                    alt: "CI",
                    source: "https://github.com/makoni/swift-adwaita/actions/workflows/ci.yml/badge.svg",
                    title: nil,
                    linkDestination: "https://github.com/makoni/swift-adwaita/actions/workflows/ci.yml",
                ),
                .init(
                    alt: "Swift 6.0+",
                    source: "https://img.shields.io/badge/Swift-6.0+-F05138.svg",
                    title: nil,
                    linkDestination: "https://swift.org",
                ),
            ]),
        ])
    }

    // MARK: - Image-only line segmentation (#16)
    //
    // CommonMark glues an image-only line that follows a paragraph (or
    // any other block) without an intervening blank line into the
    // previous paragraph as inline content. The renderer used to fall
    // back to a [Image: …] placeholder for those cases. We now segment
    // mixed-content paragraphs by line and promote image-only lines to
    // their own block, marking them as `.plain` so the preview renders
    // them in-flow without the heavier `.card` chrome.

    @Test("Renderer promotes an image right under a paragraph to a plain block image")
    func rendererPromotesAnImageRightUnderAParagraphToAPlainBlock() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        Some paragraph text
        ![alt text](image.png)
        """, darkAppearance: false)

        #expect(blocks.count == 2)
        guard case let .paragraph(text) = blocks.first else {
            Issue.record("Expected paragraph as the first block; got \(String(describing: blocks.first))")
            return
        }
        #expect(text.plainText.contains("Some paragraph text"))
        #expect(blocks.last == .image(
            alt: "alt text",
            source: "image.png",
            title: nil,
            style: .plain,
        ))
    }

    @Test("Renderer promotes an image right above a paragraph to a plain block image")
    func rendererPromotesAnImageRightAboveAParagraphToAPlainBlock() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        ![alt text](image.png)
        More paragraph text
        """, darkAppearance: false)

        #expect(blocks.count == 2)
        #expect(blocks.first == .image(
            alt: "alt text",
            source: "image.png",
            title: nil,
            style: .plain,
        ))
        guard case let .paragraph(text) = blocks.last else {
            Issue.record("Expected paragraph as the last block; got \(String(describing: blocks.last))")
            return
        }
        #expect(text.plainText.contains("More paragraph text"))
    }

    @Test("Renderer keeps card style for an image surrounded by blank lines")
    func rendererKeepsCardStyleForAnImageSurroundedByBlankLines() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        Above

        ![alt](image.png)

        Below
        """, darkAppearance: false)

        // Three blocks in order: paragraph, card image, paragraph.
        #expect(blocks.count == 3)
        #expect(blocks[1] == .image(
            alt: "alt",
            source: "image.png",
            title: nil,
            style: .card,
        ))
    }

    @Test("Renderer splits a sentence that embeds an inline image into text image text blocks")
    func rendererSplitsASentenceThatEmbedsAnInlineImageIntoTextImage() {
        // The renderer can't draw an image mid-line in a Pango label, so an
        // image inside a sentence becomes its own block sandwiched between
        // the text segments on either side. Each segment renders as its
        // own paragraph; the image is a plain block image (or image group
        // of one for linked images).
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(
            for: "Click ![icon](icon.png) here to continue.",
            darkAppearance: false,
        )

        #expect(blocks.count == 3)
        guard case let .paragraph(before) = blocks.first,
              blocks.indices.contains(1),
              case let .paragraph(after) = blocks.last
        else {
            Issue.record("Expected paragraph + image + paragraph; got \(blocks)")
            return
        }
        #expect(before.plainText.trimmingCharacters(in: .whitespaces) == "Click")
        #expect(after.plainText.contains("here to continue"))
        #expect(blocks[1] == .image(alt: "icon", source: "icon.png", title: nil, style: .plain))
    }

    @Test("Renderer groups consecutive inline images into a horizontal imageGroup so badge rows stay in a row")
    func rendererGroupsConsecutiveInlineImagesIntoAHorizontalImageGroupSoBadgeRows() {
        // Two badges next to each other inside a sentence must end up as
        // a single .imageGroup so the preview lays them out horizontally.
        // If we naively split per image, badges stack vertically and the
        // "row of shields" becomes a column.
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        Look at [![A](a.svg)](https://example.com) [![B](b.svg)](https://example.com) right here.
        """, darkAppearance: false)

        #expect(blocks.count == 3)
        guard case let .paragraph(before) = blocks.first,
              blocks.indices.contains(1),
              case let .paragraph(after) = blocks.last
        else {
            Issue.record("Expected paragraph + imageGroup + paragraph; got \(blocks)")
            return
        }
        #expect(before.plainText.contains("Look at"))
        #expect(after.plainText.contains("right here"))
        guard case let .imageGroup(items, style) = blocks[1] else {
            Issue.record("Expected imageGroup; got \(blocks[1])")
            return
        }
        #expect(style == .plain)
        #expect(items.count == 2)
        #expect(items[0].alt == "A")
        #expect(items[1].alt == "B")
    }

    @Test("Renderer drops trailing whitespace after an image but keeps text before it")
    func rendererDropsTrailingWhitespaceAfterAnImageButKeepsTextBeforeIt() {
        // The whitespace immediately before an image becomes its own text
        // segment. It should not produce an empty paragraph — the trim in
        // flushText drops it. Equally, trailing whitespace after a final
        // image at end of paragraph should not produce an empty trailing
        // paragraph either.
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(
            for: "intro ![alone](alone.png)",
            darkAppearance: false,
        )

        #expect(blocks.count == 2)
        guard case .paragraph = blocks.first else {
            Issue.record("Expected paragraph first; got \(blocks)")
            return
        }
        #expect(blocks[1] == .image(alt: "alone", source: "alone.png", title: nil, style: .plain))
    }

    @Test("Renderer splits multiple image-only lines mixed with text into separate plain blocks")
    func rendererSplitsMultipleImageOnlyLinesMixedWithTextIntoSeparatePlain() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        Look at these:
        ![one](one.png)
        ![two](two.png)
        ![three](three.png)
        """, darkAppearance: false)

        // Paragraph then 3 plain image blocks — no grouping, since the
        // text introduces them and each line stands on its own.
        #expect(blocks.count == 4)
        guard case let .paragraph(intro) = blocks.first else {
            Issue.record("Expected intro paragraph; got \(String(describing: blocks.first))")
            return
        }
        #expect(intro.plainText.contains("Look at these"))
        #expect(blocks[1] == .image(alt: "one", source: "one.png", title: nil, style: .plain))
        #expect(blocks[2] == .image(alt: "two", source: "two.png", title: nil, style: .plain))
        #expect(blocks[3] == .image(alt: "three", source: "three.png", title: nil, style: .plain))
    }

    @Test("Renderer keeps a pure image-only paragraph as a card image group")
    func rendererKeepsAPureImageOnlyParagraphAsACardImageGroup() {
        // No surrounding text in the paragraph at all — author wants a
        // gallery-style standalone block. Card stays.
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        ![one](one.png)
        ![two](two.png)
        """, darkAppearance: false)

        #expect(blocks.count == 1)
        guard case let .imageGroup(items, style) = blocks.first else {
            Issue.record("Expected an image group; got \(String(describing: blocks.first))")
            return
        }
        #expect(style == .card)
        #expect(items.count == 2)
    }

    @Test("Renderer marks list items preceded by a blank line as loose, leaving items in a tight run unflagged")
    func rendererMarksListItemsPrecededByABlankLineAsLooseLeaving() {
        // The flag is per-item, not per-list — this is what lets the
        // preview keep a contiguous tight run together while pushing
        // blank-separated items apart, matching what users expect
        // when they write `- a\n- b\n\n- c` (read as "two items, gap,
        // one item", not as "three uniformly-loose items").
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        - This
        - Is
        - A
        - List

        - This is a single item list

        - As is this
        """, darkAppearance: false)

        let looseFlags = blocks.compactMap { block -> Bool? in
            guard case let .listItem(_, _, _, loose, _) = block else { return nil }
            return loose
        }
        #expect(looseFlags == [false, false, false, false, true, true])
    }

    @Test("Renderer marks every item of a tight list as not loose")
    func rendererMarksEveryItemOfATightListAsNotLoose() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        - First
        - Second
        - Third
        """, darkAppearance: false)

        #expect(blocks.count == 3)
        for block in blocks {
            guard case let .listItem(_, _, _, loose, _) = block else {
                Issue.record("Expected list item, got \(block)")
                continue
            }
            #expect(loose == false)
        }
    }

    @Test("Renderer carries the loose flag through to task list items so blank-separated checkboxes get paragraph spacing")
    func rendererCarriesTheLooseFlagThroughToTaskListItemsSoBlank() {
        // Task lists go through a different listBlocks path: the
        // checkbox `<input>` is followed by a whitespace text node,
        // and HTMLFormatter wraps the rest of the item in `<p>`. An
        // earlier version of the loose-flag wiring let the trailing
        // whitespace fill `inlineNodes` first, which pushed the `<p>`
        // into the nested-block branch — the item then surfaced as a
        // bare `.paragraph` and only got promoted to `.listItem` by
        // `restoringTaskListMarkers`, which constructed a fresh node
        // with `loose: false` regardless of the source. Pin the fixed
        // path so task lists separated by blank lines render with the
        // same loose spacing as their bullet counterparts.
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        - [ ] First

        - [x] Second

        - [ ] Third
        """, darkAppearance: false)

        let looseFlags = blocks.compactMap { block -> Bool? in
            guard case let .listItem(_, _, _, loose, _) = block else { return nil }
            return loose
        }
        // `First` is the first item — no preceding blank inside the
        // list, so it stays tight. `Second` and `Third` follow a
        // blank line and get the loose flag.
        #expect(looseFlags == [false, true, true])
    }

    @Test("toggleTaskItem flips an unchecked task at the given index to checked, leaving other task items untouched")
    func toggleTaskItemFlipsAnUncheckedTaskAtTheGivenIndexToCheckedLeaving() {
        let original = """
        # Plan

        - [ ] First
        - [ ] Second
        - [x] Third already done
        """
        let toggled = TaskListToggle.toggle(in: original, atTaskIndex: 1)
        #expect(toggled == """
        # Plan

        - [ ] First
        - [x] Second
        - [x] Third already done
        """)
    }

    @Test("toggleTaskItem flips a checked task to unchecked at the given index")
    func toggleTaskItemFlipsACheckedTaskToUncheckedAtTheGivenIndex() {
        let original = """
        - [x] Done
        - [ ] Pending
        """
        let toggled = TaskListToggle.toggle(in: original, atTaskIndex: 0)
        #expect(toggled == """
        - [ ] Done
        - [ ] Pending
        """)
    }

    @Test("toggleTaskItem leaves non-task content untouched even if it contains brackets that resemble checkbox markers")
    func toggleTaskItemLeavesNonTaskContentUntouchedEvenIfItContainsBracketsThat() {
        // A standalone `[x]` inside prose isn't a task list marker —
        // only `[ ]` / `[x]` directly after a list bullet (and a
        // single space) should toggle. Otherwise a click could rewrite
        // unrelated brackets in the user's note.
        let original = """
        Mention of [x] in prose.

        - [ ] Real task
        """
        let toggled = TaskListToggle.toggle(in: original, atTaskIndex: 0)
        #expect(toggled == """
        Mention of [x] in prose.

        - [x] Real task
        """)
    }

    @Test("toggleTaskItem returns the input unchanged when the index is out of bounds")
    func toggleTaskItemReturnsTheInputUnchangedWhenTheIndexIsOutOfBounds() {
        let original = """
        - [ ] Only one
        """
        let toggled = TaskListToggle.toggle(in: original, atTaskIndex: 5)
        #expect(toggled == original)
    }

    @Test("Renderer assigns a stable task-item index in document order so the preview can wire clicks back to the source line")
    func rendererAssignsAStableTaskItemIndexInDocumentOrderSoThe() {
        // Each `[x]` / `[ ]` item carries its own 0-based index among
        // every task item in the document. Non-task list items keep
        // `taskIndex == nil`. The preview wires a click handler to
        // each task marker that hands this index off to the source-
        // toggle service.
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        # Note

        - [ ] First todo
        - Bullet, not a task
        - [x] Second todo

        Some prose here.

        - [ ] Third todo
        """, darkAppearance: false)

        let taskIndices = blocks.compactMap { block -> (marker: String, taskIndex: Int?)? in
            guard case let .listItem(_, _, marker, _, taskIndex) = block else { return nil }
            return (marker, taskIndex)
        }

        #expect(taskIndices.count == 4)
        #expect(taskIndices[0].marker == "[ ]")
        #expect(taskIndices[0].taskIndex == 0)
        #expect(taskIndices[1].marker == "-")
        #expect(taskIndices[1].taskIndex == nil)
        #expect(taskIndices[2].marker == "[x]")
        #expect(taskIndices[2].taskIndex == 1)
        #expect(taskIndices[3].marker == "[ ]")
        #expect(taskIndices[3].taskIndex == 2)
    }

    @Test("Renderer restarts ordered list numbering when the author writes a fresh ordinal after a blank line")
    func rendererRestartsOrderedListNumberingWhenTheAuthorWritesAFreshOrdinal() {
        // CommonMark merges `1. a\n2. b\n3. c\n\n1. d` into one list
        // and renumbers the trailing `1.` as `4.` — the explicit
        // number in source is dropped. That's confusing for authors
        // who type `1.` after a gap to start a fresh logical group.
        // Honour the explicit ordinal in that case.
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        1. Step one
        2. Step two
        3. Step three

        1. Stand-alone follow-up
        """, darkAppearance: false)

        let markers = blocks.compactMap { block -> String? in
            guard case let .listItem(_, _, marker, _, _) = block else { return nil }
            return marker
        }
        #expect(markers == ["1.", "2.", "3.", "1."])
    }

    @Test("Renderer trims trailing whitespace from list item text so wrapping labels don't grow an empty second line")
    func rendererTrimsTrailingWhitespaceFromListItemTextSoWrappingLabelsDont() {
        // swift-markdown's HTMLFormatter emits tight list items as
        // `<li>First\n</li>` with a literal trailing newline. A
        // GtkLabel with `wrap=true` renders that `\n` as an empty
        // second line, doubling the row height — that's what made
        // every bullet/numbered list in the preview look airy. The
        // renderer must strip that whitespace before handing the
        // text off to the preview.
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        - First
        - Second
        - Third
        """, darkAppearance: false)

        #expect(blocks.count == 3)
        for block in blocks {
            guard case let .listItem(text, _, _, _, _) = block else {
                Issue.record("Expected list item, got \(block)")
                continue
            }
            #expect(!text.plainText.hasSuffix("\n"))
            #expect(!text.plainText.hasSuffix(" "))
            #expect(!text.markup.hasSuffix("\n"))
            #expect(!text.markup.hasSuffix(" "))
        }
    }

    @Test("Renderer builds aligned table block")
    func rendererBuildsAlignedTableBlock() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        | Feature | Example | Result |
        | :-- | :-- | :-: |
        | Emphasis | `**bold**` | Ready |
        | Checklist | `- [x] Ship it` | Ready |
        """, darkAppearance: false)

        guard case let .table(headers, rows, alignments) = blocks.first else {
            Issue.record("Expected a table block")
            return
        }

        #expect(headers.map(\.plainText) == ["Feature", "Example", "Result"])
        #expect(rows.count == 2)
        #expect(rows[0].map(\.plainText) == ["Emphasis", "**bold**", "Ready"])
        #expect(rows[1].map(\.plainText) == ["Checklist", "- [x] Ship it", "Ready"])
        #expect(alignments == [.leading, .leading, .center])
    }

    @Test("Html subset parser treats unsupported tags as literal text")
    func htmlSubsetParserTreatsUnsupportedTagsAsLiteralText() {
        let nodes = HTMLSubsetParser().parse("<pre><code>swiftynotes cli get <note-id></code></pre>")
        let blocks = HTMLPreviewDocumentBuilder(darkAppearance: false).blocks(from: nodes, listDepth: 0)

        #expect(blocks == [
            .codeBlock(code: "swiftynotes cli get <note-id>", language: nil),
        ])
    }

    @Test("Renderer builds blocks for CLI seed note")
    func rendererBuildsBlocksForCLISeedNote() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: SwiftyNotesCLISeed.content, darkAppearance: false)

        #expect(!blocks.isEmpty)
        #expect(blocks.contains { block in
            if case let .heading(level, text) = block {
                return level == 1 && text.plainText == "Using Swifty Notes CLI"
            }
            return false
        })
        #expect(blocks.contains { block in
            if case let .codeBlock(code, language) = block {
                return language == "bash" && code.contains("swiftynotes cli list")
            }
            return false
        })
    }

    @Test("Incremental preview block builder reparses only changed text segment in long safe document")
    func incrementalPreviewBlockBuilderReparsesOnlyChangedTextSegmentInLongSafe() {
        var builder = IncrementalPreviewBlockBuilder()
        let original = (1 ... 120).map { index in
            "## Section \(index)\n\nBody \(index) with **bold** text and `code`."
        }.joined(separator: "\n\n")
        let updated = original + " More typing at the tail."

        let first = builder.blocks(for: original, darkAppearance: false)
        let second = builder.blocks(for: updated, darkAppearance: false)
        let expected = MarkdownRenderer().blocks(for: updated, darkAppearance: false)

        #expect(first.count == 240)
        #expect(second == expected)
        #expect(builder.debugFullRenderCount == 1)
        #expect(builder.debugIncrementalRenderCount == 1)
    }

    @Test("Incremental preview block builder falls back for list documents")
    func incrementalPreviewBlockBuilderFallsBackForListDocuments() {
        var builder = IncrementalPreviewBlockBuilder()
        let original = "# Title\n\n- One\n- Two"
        let updated = "# Title\n\n- One\n- Two\n- Three"

        _ = builder.blocks(for: original, darkAppearance: false)
        let blocks = builder.blocks(for: updated, darkAppearance: false)
        let expected = MarkdownRenderer().blocks(for: updated, darkAppearance: false)

        #expect(blocks == expected)
        #expect(builder.debugFullRenderCount == 2)
        #expect(builder.debugIncrementalRenderCount == 0)
    }

    @Test("Preview render deferral waits for visible allocated preview pane")
    func previewRenderDeferralWaitsForVisibleAllocatedPreviewPane() {
        #expect(MainWindow.shouldDeferPreviewRender(
            isPreviewPresented: true,
            windowWidth: 1200,
            windowHeight: 800,
            hasParent: true,
            hasRoot: true,
            width: 0,
            height: 320,
        ))
        #expect(!MainWindow.shouldDeferPreviewRender(
            isPreviewPresented: true,
            windowWidth: 0,
            windowHeight: 0,
            hasParent: true,
            hasRoot: false,
            width: 540,
            height: 320,
        ))
    }

    @Test("Preview render deferral skips detached or hidden preview pane")
    func previewRenderDeferralSkipsDetachedOrHiddenPreviewPane() {
        #expect(!MainWindow.shouldDeferPreviewRender(
            isPreviewPresented: true,
            windowWidth: 1200,
            windowHeight: 800,
            hasParent: false,
            hasRoot: false,
            width: 0,
            height: 0,
        ))
        #expect(!MainWindow.shouldDeferPreviewRender(
            isPreviewPresented: false,
            windowWidth: 1200,
            windowHeight: 800,
            hasParent: true,
            hasRoot: false,
            width: 0,
            height: 0,
        ))
    }

    @Test("Autosave coordinator runs latest task") @MainActor
    func autosaveCoordinatorRunsLatestTask() {
        let scheduler = TestMainActorScheduler()
        let autosave = AutosaveCoordinator(taskScheduler: scheduler.schedule(after:operation:))
        var values: [Int] = []

        autosave.scheduleSave(after: .milliseconds(10)) {
            values.append(1)
        }
        autosave.scheduleSave(after: .milliseconds(10)) {
            values.append(2)
        }

        scheduler.runPendingActions()

        #expect(values == [2])
    }
}
