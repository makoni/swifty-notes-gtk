import Foundation
import Testing
@testable import SwiftyNotes
import Adwaita
import CAdwaita

struct NoteModelAndRendererTests {
    @Test
    func derivedTitleUsesFirstMeaningfulLine() {
        let title = Note.derivedTitle(from: "\n\n# Hello world\nBody")
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
