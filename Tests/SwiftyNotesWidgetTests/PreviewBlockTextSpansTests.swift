#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

/// Phase A of #27 — verifies that ``MarkdownPreview`` populates
/// ``blockTextSpans`` with the correct plain-text offsets / lengths
/// after rendering, and that ``codeBlockBuffers`` retains a buffer
/// reference for each code block. The actual highlight overlay
/// (PangoAttrList / SourceBuffer tags) sits on top of these maps
/// in phases B-D; getting the offsets right here is what makes the
/// overlay land on the right characters when it ships.
struct PreviewBlockTextSpansTests {
    @MainActor
    private static func makePreview(suffix: String) throws -> MarkdownPreview {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.spans.\(suffix)")
        try app.register()
        return MarkdownPreview(remoteImageLoader: { _, _ in })
    }

    @Test("Heading-only row records a single-block span starting at offset 0") @MainActor
    func headingOnlyRowRecordsASingleBlockSpanStartingAtOffset0() throws {
        let preview = try Self.makePreview(suffix: "heading-only")
        preview.render(blocks: [
            .heading(level: 1, text: .plain("Doc Title")),
        ])
        let span = try #require(preview.blockTextSpans[0])
        #expect(span.plainTextOffset == 0)
        #expect(span.plainTextLength == "Doc Title".count)
        // The post-render walk should have attached the Label
        // pointer so the highlight overlay (phase B) can target it.
        #expect(span.labelPointer != nil)
    }

    @Test("richTextRun row records offsets stepped by heading + double-newline separator") @MainActor
    func richTextRunRowRecordsOffsetsSteppedByHeadingDoubleNewlineSeparator() throws {
        let preview = try Self.makePreview(suffix: "richtext")
        // Heading + 2 paragraphs gets coalesced into one
        // .richTextRun row backed by a single Label whose plain
        // text is: "Doc\n\nBody one.\n\nBody two."
        preview.render(blocks: [
            .heading(level: 1, text: .plain("Doc")),
            .paragraph(.plain("Body one.")),
            .paragraph(.plain("Body two.")),
        ])
        let headingSpan = try #require(preview.blockTextSpans[0])
        let p1Span = try #require(preview.blockTextSpans[1])
        let p2Span = try #require(preview.blockTextSpans[2])
        // heading at the top.
        #expect(headingSpan.plainTextOffset == 0)
        #expect(headingSpan.plainTextLength == "Doc".count)
        // First paragraph follows heading + "\n\n" (2 chars).
        #expect(p1Span.plainTextOffset == "Doc".count + 2)
        #expect(p1Span.plainTextLength == "Body one.".count)
        // Second paragraph follows p1 + "\n\n".
        let p2ExpectedOffset = "Doc".count + 2 + "Body one.".count + 2
        #expect(p2Span.plainTextOffset == p2ExpectedOffset)
        #expect(p2Span.plainTextLength == "Body two.".count)
        // All three blocks share one Label pointer (since they
        // coalesce into one row's widget).
        #expect(headingSpan.labelPointer == p1Span.labelPointer)
        #expect(p1Span.labelPointer == p2Span.labelPointer)
    }

    @Test("Multi-paragraph paragraphRun coalesces blocks with double-newline offsets") @MainActor
    func multiParagraphParagraphRunCoalescesBlocksWithDoubleNewlineOffsets() throws {
        let preview = try Self.makePreview(suffix: "para-run")
        preview.render(blocks: [
            .paragraph(.plain("First paragraph.")),
            .paragraph(.plain("Second paragraph.")),
            .paragraph(.plain("Third paragraph.")),
        ])
        let s0 = try #require(preview.blockTextSpans[0])
        let s1 = try #require(preview.blockTextSpans[1])
        let s2 = try #require(preview.blockTextSpans[2])
        #expect(s0.plainTextOffset == 0)
        #expect(s1.plainTextOffset == "First paragraph.".count + 2)
        #expect(s2.plainTextOffset == "First paragraph.".count + 2 + "Second paragraph.".count + 2)
    }

    @Test("Single paragraph wraps in paragraphRun of one and still has offset 0") @MainActor
    func singleParagraphWrapsInParagraphRunOfOneAndStillHasOffset0() throws {
        let preview = try Self.makePreview(suffix: "para-single")
        preview.render(blocks: [
            .paragraph(.plain("Just one paragraph.")),
        ])
        let span = try #require(preview.blockTextSpans[0])
        #expect(span.plainTextOffset == 0)
        #expect(span.plainTextLength == "Just one paragraph.".count)
        #expect(span.labelPointer != nil)
    }

    @Test("Consecutive blockquotes share a Label and step by double-newline") @MainActor
    func consecutiveBlockquotesShareALabelAndStepByDoubleNewline() throws {
        let preview = try Self.makePreview(suffix: "blockquote-run")
        preview.render(blocks: [
            .blockquote(.plain("First quoted.")),
            .blockquote(.plain("Second quoted.")),
        ])
        let s0 = try #require(preview.blockTextSpans[0])
        let s1 = try #require(preview.blockTextSpans[1])
        #expect(s0.plainTextOffset == 0)
        #expect(s1.plainTextOffset == "First quoted.".count + 2)
        // Same Label (inside the blockquote row's Box).
        #expect(s0.labelPointer == s1.labelPointer)
        #expect(s0.labelPointer != nil)
    }

    @Test("Non-task flat list records a per-item span shifted past the marker prefix") @MainActor
    func nonTaskFlatListRecordsAPerItemSpanShiftedPastThe() throws {
        let preview = try Self.makePreview(suffix: "list-flat")
        // Three items; `displayMarker` turns "-" into "•". The
        // prefix per line is "• " (marker + at least one space
        // padded out to "max marker width + 2" — which is 1 + 2 = 3
        // chars here, so "• " padded to "•  " — wait actually "•"
        // is one Unicode glyph but `String.count` reports 1; pad
        // becomes 3 - 1 = 2 spaces).
        preview.render(blocks: [
            .listItem(text: .plain("alpha"), depth: 0, marker: "-"),
            .listItem(text: .plain("beta"),  depth: 0, marker: "-"),
            .listItem(text: .plain("gamma"), depth: 0, marker: "-"),
        ])
        let s0 = try #require(preview.blockTextSpans[0])
        let s1 = try #require(preview.blockTextSpans[1])
        let s2 = try #require(preview.blockTextSpans[2])
        // Per-item prefix = "•" + 2 spaces = 3 chars (max marker
        // width across the list is 1; padTarget = 1 + 2 = 3).
        let prefixLen = 3
        #expect(s0.plainTextOffset == prefixLen)
        #expect(s0.plainTextLength == "alpha".count)
        // Line separator is "\n" (1 char, list isn't loose).
        #expect(s1.plainTextOffset == prefixLen + "alpha".count + 1 + prefixLen)
        #expect(s2.plainTextOffset == prefixLen + "alpha".count + 1 + prefixLen + "beta".count + 1 + prefixLen)
        // All three blocks share the flat-list-as-label Label.
        #expect(s0.labelPointer == s1.labelPointer)
        #expect(s1.labelPointer == s2.labelPointer)
    }

    @Test("Nested non-task list uses depth-based indent in offsets") @MainActor
    func nestedNonTaskListUsesDepthBasedIndentInOffsets() throws {
        let preview = try Self.makePreview(suffix: "list-nested")
        preview.render(blocks: [
            .listItem(text: .plain("outer"), depth: 0, marker: "-"),
            .listItem(text: .plain("inner"), depth: 1, marker: "-"),
        ])
        let outer = try #require(preview.blockTextSpans[0])
        let inner = try #require(preview.blockTextSpans[1])
        // Outer: prefix = "•" + 2 spaces = 3.
        #expect(outer.plainTextOffset == 3)
        // Inner: depthIndent (2 chars for depth=1) + marker "◦" +
        // 2 spaces = 5 char prefix. Whole inner offset is
        // outer prefix + outer text + "\n" + inner prefix.
        let innerExpectedOffset = 3 + "outer".count + 1 + 5
        #expect(inner.plainTextOffset == innerExpectedOffset)
    }

    @Test("Task list intentionally has no span entries") @MainActor
    func taskListIntentionallyHasNoSpanEntries() throws {
        let preview = try Self.makePreview(suffix: "list-task")
        preview.render(blocks: [
            .listItem(text: .plain("buy milk"), depth: 0, marker: "[ ]", taskIndex: 0),
            .listItem(text: .plain("write tests"), depth: 0, marker: "[x]", taskIndex: 1),
        ])
        // Phase A documents that task lists are skipped — Phase B
        // simply won't highlight matches inside them. Confirm.
        #expect(preview.blockTextSpans[0] == nil)
        #expect(preview.blockTextSpans[1] == nil)
    }

    @Test("Code block doesn't enter blockTextSpans but does retain a SourceBuffer") @MainActor
    func codeBlockDoesntEnterBlockTextSpansButDoesRetainASourceBuffer() throws {
        let preview = try Self.makePreview(suffix: "code")
        preview.render(blocks: [
            .codeBlock(code: "let x = 1\nprint(x)\n", language: "swift"),
        ])
        // Code blocks are handled by the editor-style tag overlay,
        // not the Pango-Label overlay, so they don't appear in
        // blockTextSpans.
        #expect(preview.blockTextSpans[0] == nil)
        // …but their SourceBuffer is retained so the highlight
        // pass can apply text-tag attributes inside.
        let buffer = try #require(preview.codeBlockBuffers[0])
        #expect(buffer.text == "let x = 1\nprint(x)\n")
    }

    @Test("Table block records per-cell highlight geometry with an attached label") @MainActor
    func tableBlockRecordsPerCellHighlightGeometryWithAnAttachedLabel() throws {
        let preview = try Self.makePreview(suffix: "table")
        preview.render(blocks: [
            .table(
                headers: [.plain("Area"), .plain("Note")],
                rows: [[.plain("A1"), .plain("B1")]],
                alignments: [.leading, .leading],
            ),
        ])
        // Tables are NOT in blockTextSpans (their single-offset model
        // can't represent N cells across two coordinate spaces); they
        // live in tableHighlightSpans instead.
        #expect(preview.blockTextSpans[0] == nil)
        let table = try #require(preview.tableHighlightSpans[0])
        // Four cells: Area, Note, A1, B1 — in searchable order.
        #expect(table.cells.count == 4)
        // The post-render walk attached the card's monospace Label.
        #expect(table.labelPointer != nil)
        // Every cell has a rendered field (no over-long rows here).
        #expect(table.cells.allSatisfy { $0.labelOffset != nil })
    }

    @Test("Image and thematicBreak blocks are not in the spans map") @MainActor
    func imageAndThematicBreakBlocksAreNotInTheSpansMap() throws {
        let preview = try Self.makePreview(suffix: "image-rule")
        preview.render(blocks: [
            .heading(level: 1, text: .plain("Doc")),
            .image(alt: "An image", source: "x.png", title: nil),
            .thematicBreak,
            .paragraph(.plain("Body.")),
        ])
        // Heading + paragraph have spans; image + thematic break
        // do not (engine doesn't search them either).
        #expect(preview.blockTextSpans[0] != nil)
        #expect(preview.blockTextSpans[1] == nil)
        #expect(preview.blockTextSpans[2] == nil)
        #expect(preview.blockTextSpans[3] != nil)
    }

    @Test("Rendering a fresh note clears the previous note's spans") @MainActor
    func renderingAFreshNoteClearsThePreviousNotesSpans() throws {
        let preview = try Self.makePreview(suffix: "reset")
        preview.render(blocks: [
            .paragraph(.plain("first note")),
        ])
        #expect(preview.blockTextSpans[0] != nil)
        preview.render(blocks: [
            .heading(level: 2, text: .plain("new heading")),
        ])
        // Index 0 still exists but for the new note's heading.
        let s = try #require(preview.blockTextSpans[0])
        #expect(s.plainTextLength == "new heading".count)
        // And nothing leaks past the new note's last block.
        #expect(preview.blockTextSpans[1] == nil)
    }

    @Test("Empty preview drops the spans map") @MainActor
    func emptyPreviewDropsTheSpansMap() throws {
        let preview = try Self.makePreview(suffix: "empty")
        preview.render(blocks: [
            .paragraph(.plain("something")),
        ])
        #expect(preview.blockTextSpans.isEmpty == false)
        preview.render(blocks: [])
        #expect(preview.blockTextSpans.isEmpty)
        #expect(preview.codeBlockBuffers.isEmpty)
    }
}
#endif
