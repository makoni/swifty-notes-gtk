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
            isPreviewAttached: true,
            isPreviewVisible: true,
            windowWidth: 1200,
            windowHeight: 800,
            hasParent: true,
            hasRoot: true,
            width: 0,
            height: 320
        ))
        #expect(!MainWindow.shouldDeferPreviewRender(
            isPreviewAttached: true,
            isPreviewVisible: true,
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
            isPreviewAttached: false,
            isPreviewVisible: true,
            windowWidth: 1200,
            windowHeight: 800,
            hasParent: false,
            hasRoot: false,
            width: 0,
            height: 0
        ))
        #expect(!MainWindow.shouldDeferPreviewRender(
            isPreviewAttached: true,
            isPreviewVisible: false,
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
        let autosave = AutosaveCoordinator()
        let recorder = SaveRecorder()

        autosave.scheduleSave(after: .milliseconds(10)) {
            await recorder.append(1)
        }
        autosave.scheduleSave(after: .milliseconds(10)) {
            await recorder.append(2)
        }

        try? await Task.sleep(for: .milliseconds(40))

        let result = await recorder.snapshot()
        #expect(result == [2])
    }
}
