import Foundation
import Testing
@testable import SwiftyNotes
import Adwaita

struct NoteModelAndRendererTests {
    @Test
    func derivedTitleUsesFirstMeaningfulLine() {
        let title = Note.derivedTitle(from: "\n\n# Hello world\nBody")
        #expect(title == "Hello world")
    }

    @Test
    func derivedTitleSkipsLeadingStandaloneImage() {
        let title = Note.derivedTitle(from: "![Cover](assets/cover.png)\n\n# Hello world\nBody")
        #expect(title == "Hello world")
    }

    @Test
    func derivedTitleFallsBackForEmptyNote() {
        #expect(Note.derivedTitle(from: " \n\n ") == "New Note")
    }

    @Test
    func noteRetitleReplacesFirstMeaningfulLine() {
        let note = Note(
            id: UUID(),
            filename: "note.md",
            createdAt: Date(),
            updatedAt: Date(),
            content: "Shopping list\n- eggs"
        )

        let renamed = note.retitled("Groceries")
        #expect(renamed.title == "Groceries")
        #expect(renamed.content.hasPrefix("Groceries"))
    }

    @Test
    func noteRetitlePreservesLeadingImageAndReplacesHeadingAfterIt() {
        let note = Note(
            id: UUID(),
            filename: "note.md",
            createdAt: Date(),
            updatedAt: Date(),
            content: "![Cover](assets/cover.png)\n\n# Original\n\nBody"
        )

        let renamed = note.retitled("Updated")
        #expect(renamed.title == "Updated")
        #expect(renamed.content == "![Cover](assets/cover.png)\n\n# Updated\n\nBody")
    }

    @Test
    func noteSearchAndExportFilenameUseReadableTitle() {
        let note = Note(
            id: UUID(),
            filename: "note.md",
            createdAt: Date(),
            updatedAt: Date(),
            content: "# Hello, Swift GTK!"
        )

        #expect(note.matches(searchQuery: "swift gtk"))
        #expect(note.suggestedExportFilename == "hello-swift-gtk.md")
        #expect(note.stableID == note.id.uuidString.lowercased())
    }

    @Test
    func rendererBuildsHeadingAndParagraphBlocks() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: "# Title\n\nParagraph", darkAppearance: false)
        #expect(blocks.count >= 2)
        #expect(blocks.first?.style == .heading(level: 1))
        #expect(blocks.first?.text == "Title")
    }

    @Test
    func rendererBuildsTaskListMarkers() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        - [x] Done
        - [ ] Todo
        """, darkAppearance: false)

        #expect(blocks.count == 2)
        #expect(blocks[0] == .listItem(text: .plain("Done"), depth: 0, marker: "[x]"))
        #expect(blocks[1] == .listItem(text: .plain("Todo"), depth: 0, marker: "[ ]"))
    }

    @Test
    func rendererPreservesTaskListMarkersWhenItemContainsInlineMarkdown() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        - [ ] Если было выделено **слово**, то после нажатия должно быть `код`
        """, darkAppearance: false)

        #expect(blocks.count == 1)
        guard case let .listItem(text, depth, marker) = blocks[0] else {
            Issue.record("Expected a task list item block")
            return
        }

        #expect(depth == 0)
        #expect(marker == "[ ]")
        #expect(text.plainText == "Если было выделено слово, то после нажатия должно быть код")
    }

    @Test
    func rendererUsesThemeAwareInlineCodeBackground() {
        let renderer = MarkdownRenderer()
        let lightBlocks = renderer.blocks(for: "Use `code` here", darkAppearance: false)
        let darkBlocks = renderer.blocks(for: "Use `code` here", darkAppearance: true)

        guard case let .paragraph(lightText) = lightBlocks.first,
              case let .paragraph(darkText) = darkBlocks.first else {
            Issue.record("Expected paragraph blocks")
            return
        }

        #expect(lightText.markup.contains("font_family=\"monospace\""))
        #expect(lightText.markup.contains("background=\"#f6f5f4\""))
        #expect(darkText.markup.contains("background=\"#3b3644\""))
        #expect(lightText.markup != darkText.markup)
    }

    @Test
    func rendererBuildsStandaloneImageBlock() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(
            for: "![Swift and Adwaita showcase artwork](markdown-demo-image.png)",
            darkAppearance: false
        )

        #expect(blocks == [
            .image(
                alt: "Swift and Adwaita showcase artwork",
                source: "markdown-demo-image.png",
                title: nil
            )
        ])
    }

    @Test
    func rendererBuildsStandaloneHTMLImageBlock() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(
            for: #"<img alt="Swift Adwaita" src="https://spaceinbox.me/images/swift-adwaita-2.webp">"#,
            darkAppearance: false
        )

        #expect(blocks == [
            .image(
                alt: "Swift Adwaita",
                source: "https://spaceinbox.me/images/swift-adwaita-2.webp",
                title: nil
            )
        ])
    }

    @Test @MainActor
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
                    linkDestination: "https://github.com/makoni/swift-adwaita/actions/workflows/ci.yml"
                ),
                .init(
                    alt: "Swift 6.0+",
                    source: "https://img.shields.io/badge/Swift-6.0+-F05138.svg",
                    title: nil,
                    linkDestination: "https://swift.org"
                )
            ])
        ])
    }

    @Test
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

    @Test
    func htmlSubsetParserTreatsUnsupportedTagsAsLiteralText() {
        let nodes = HTMLSubsetParser().parse("<pre><code>swiftynotes cli get <note-id></code></pre>")
        let blocks = HTMLPreviewDocumentBuilder(darkAppearance: false).blocks(from: nodes, listDepth: 0)

        #expect(blocks == [
            .codeBlock(code: "swiftynotes cli get <note-id>", language: nil)
        ])
    }

    @Test
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

    @Test
    func previewRenderDeferralWaitsForVisibleAllocatedPreviewPane() {
        #expect(MainWindow.shouldDeferPreviewRender(
            isPreviewPresented: true,
            windowWidth: 1200,
            windowHeight: 800,
            hasParent: true,
            hasRoot: true,
            width: 0,
            height: 320
        ))
        #expect(!MainWindow.shouldDeferPreviewRender(
            isPreviewPresented: true,
            windowWidth: 0,
            windowHeight: 0,
            hasParent: true,
            hasRoot: false,
            width: 540,
            height: 320
        ))
    }

    @Test
    func previewRenderDeferralSkipsDetachedOrHiddenPreviewPane() {
        #expect(!MainWindow.shouldDeferPreviewRender(
            isPreviewPresented: true,
            windowWidth: 1200,
            windowHeight: 800,
            hasParent: false,
            hasRoot: false,
            width: 0,
            height: 0
        ))
        #expect(!MainWindow.shouldDeferPreviewRender(
            isPreviewPresented: false,
            windowWidth: 1200,
            windowHeight: 800,
            hasParent: true,
            hasRoot: false,
            width: 0,
            height: 0
        ))
    }

    @Test @MainActor
    func autosaveCoordinatorRunsLatestTask() async {
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
