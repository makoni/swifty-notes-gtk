import Adwaita
import CSpelling
import Foundation

@MainActor
final class MarkdownPreview {
    private enum ResolvedImageSource {
        case local(URL)
        case remote(URL)
    }

    private typealias ListPreviewItem = (text: RenderedText, depth: Int, marker: String, loose: Bool, taskIndex: Int?)

    /// Inline segment carried inside a ``PreviewRow/richTextRun``.
    /// Phase B.1 of SCROLL_PERF_PLAN.md coalesces a heading and its
    /// trailing paragraphs into a single rich-text Label — segments
    /// describe what each part of that Label is so the markup builder
    /// can apply the right Pango styling.
    enum RichTextSegment: Sendable, Equatable {
        case heading(level: Int, text: RenderedText)
        case paragraph(text: RenderedText)

        var equalityKey: String {
            switch self {
            case let .heading(level, text):
                "h:\(level):\(text.plainText)"
            case let .paragraph(text):
                "p:\(text.plainText)"
            }
        }
    }

    private enum PreviewRow: Equatable {
        case heading(level: Int, text: RenderedText)
        case paragraphRun([RenderedText])
        case richTextRun([RichTextSegment])
        case codeBlock(code: String, language: String?)
        case blockquoteRun([RenderedText])
        case list(items: [ListPreviewItem])
        case thematicBreak
        case table(headers: [RenderedText], rows: [[RenderedText]], alignments: [RenderedTableAlignment])
        case image(alt: String, source: String?, title: String?, style: ImageBlockStyle)
        case imageGroup(items: [RenderedImageItem], style: ImageBlockStyle)

        var supportsVirtualization: Bool {
            switch self {
            case .image, .imageGroup:
                false
            default:
                true
            }
        }

        var supportsIncrementalUpdate: Bool {
            switch self {
            case .image, .imageGroup:
                false
            default:
                true
            }
        }

        var supportsCustomTextLayout: Bool {
            switch self {
            case .heading, .paragraphRun, .richTextRun, .blockquoteRun, .thematicBreak:
                true
            case let .list(items):
                items.allSatisfy { $0.taskIndex == nil }
            case .codeBlock, .table, .image, .imageGroup:
                false
            }
        }

        static func == (lhs: PreviewRow, rhs: PreviewRow) -> Bool {
            switch (lhs, rhs) {
            case let (.heading(lhsLevel, lhsText), .heading(rhsLevel, rhsText)):
                lhsLevel == rhsLevel && lhsText == rhsText
            case let (.paragraphRun(lhsTexts), .paragraphRun(rhsTexts)):
                lhsTexts == rhsTexts
            case let (.richTextRun(lhsSegs), .richTextRun(rhsSegs)):
                lhsSegs == rhsSegs
            case let (.codeBlock(lhsCode, lhsLanguage), .codeBlock(rhsCode, rhsLanguage)):
                lhsCode == rhsCode && lhsLanguage == rhsLanguage
            case let (.blockquoteRun(lhsTexts), .blockquoteRun(rhsTexts)):
                lhsTexts == rhsTexts
            case let (.list(lhsItems), .list(rhsItems)):
                lhsItems.elementsEqual(rhsItems) { lhsItem, rhsItem in
                    lhsItem.text == rhsItem.text
                        && lhsItem.depth == rhsItem.depth
                        && lhsItem.marker == rhsItem.marker
                        && lhsItem.loose == rhsItem.loose
                        && lhsItem.taskIndex == rhsItem.taskIndex
                }
            case (.thematicBreak, .thematicBreak):
                true
            case let (.table(lhsHeaders, lhsRows, lhsAlignments), .table(rhsHeaders, rhsRows, rhsAlignments)):
                lhsHeaders == rhsHeaders && lhsRows == rhsRows && lhsAlignments == rhsAlignments
            case let (.image(lhsAlt, lhsSource, lhsTitle, lhsStyle), .image(rhsAlt, rhsSource, rhsTitle, rhsStyle)):
                lhsAlt == rhsAlt && lhsSource == rhsSource && lhsTitle == rhsTitle && lhsStyle == rhsStyle
            case let (.imageGroup(lhsItems, lhsStyle), .imageGroup(rhsItems, rhsStyle)):
                lhsItems == rhsItems && lhsStyle == rhsStyle
            default:
                false
            }
        }
    }

    private enum RenderMode: Equatable {
        case stacked
        case virtualized
        case customText
    }

    private struct RowDiff {
        let prefixCount: Int
        let oldChangedRange: Range<Int>
        let newChangedRange: Range<Int>

        var hasChanges: Bool {
            !oldChangedRange.isEmpty || !newChangedRange.isEmpty
        }

        static func between(old oldRows: [PreviewRow], new newRows: [PreviewRow]) -> Self {
            let sharedCount = min(oldRows.count, newRows.count)
            var prefixCount = 0
            while prefixCount < sharedCount, oldRows[prefixCount] == newRows[prefixCount] {
                prefixCount += 1
            }

            var suffixCount = 0
            while suffixCount < sharedCount - prefixCount,
                  oldRows[oldRows.count - 1 - suffixCount] == newRows[newRows.count - 1 - suffixCount]
            {
                suffixCount += 1
            }

            return .init(
                prefixCount: prefixCount,
                oldChangedRange: prefixCount ..< (oldRows.count - suffixCount),
                newChangedRange: prefixCount ..< (newRows.count - suffixCount),
            )
        }
    }

    let container: Box
    let rootScroll: ScrolledWindow

    private enum PreviewMetrics {
        static let listIndentPerLevel = 10
        static let listMarkerSpacing = 4
        static let badgeImageHeight = 22
        static let badgeSpacing = 6
        static let badgeLineSpacing = 4
    }

    private static let previewCSS = CSSProvider.loadGlobal("""
    .preview-list-row {
        margin-top: 1px;
        margin-bottom: 1px;
        padding-top: 0;
        padding-bottom: 0;
        min-height: 0;
    }

    .preview-compact-list-row {
        margin-top: 2px;
        margin-bottom: 2px;
    }

    .preview-task-list-row {
        margin-top: 2px;
        margin-bottom: 2px;
    }

    .preview-paragraph-label,
    .preview-blockquote-label {
        line-height: 1.24;
    }

    .preview-nested-list-row {
        margin-top: 2px;
        margin-bottom: 2px;
    }

    /* A list item the author put behind a blank line in the source
       gets paragraph-style top margin — only the items that were
       blank-separated push apart, contiguous tight runs stay
       together. The gap matches the container's 20px inter-block
       spacing so a blank-separated item visually reads as the start
       of a fresh sub-list, identical to having two distinct lists. */
    .preview-loose-list-row {
        margin-top: 18px;
    }

    .preview-compact-list-label,
    .preview-compact-list-marker,
    .preview-task-list-label,
    .preview-task-list-marker {
        margin-top: 0;
        margin-bottom: 0;
        padding-top: 0;
        padding-bottom: 0;
        min-height: 0;
    }

    .preview-compact-list-label,
    .preview-compact-list-marker {
        line-height: 1.14;
    }

    .preview-task-list-label,
    .preview-task-list-marker {
        line-height: 1.14;
    }

    .preview-image-link {
        padding: 0;
        margin: 0;
        min-width: 0;
        min-height: 0;
        background: transparent;
    }

    .preview-image-link:hover {
        opacity: 0.85;
    }

    .preview-image-group {
        padding: 0;
        margin: 0;
        min-width: 0;
        min-height: 0;
        background: transparent;
    }

    .preview-image-card {
        padding: 14px;
    }

    /* Let the card (`.preview-code-block`) own the background so the
       SWIFT-style language badge and the syntax-highlighted code share
       one visual surface. SourceBuffer's style-scheme would otherwise
       paint the code area in its own scheme background, producing a
       darker inset rectangle. We keep the scheme's token colours for
       highlighting but blank out every background layer. */
    .preview-code-sourceview,
    .preview-code-sourceview text,
    .preview-code-sourceview text selection {
        background: transparent;
        background-color: transparent;
    }

    .preview-code-scroll {
        background: transparent;
        background-color: transparent;
    }

    """)

    private var baseDirectory: URL?
    private weak var window: ApplicationWindow?
    private let remoteImageLoader: PreviewRemoteImageLoadHandler
    private var animatedImagePlayers: [PreviewAnimatedImagePlayer] = []
    private var lastObservedPreviewWidth: Int = -1
    private var lastRenderedBlocks: [RenderedBlock] = []
    private var renderedRows: [PreviewRow] = []
    /// Maps `RenderedBlock` index (the same one stored on
    /// ``Heading.blockIndex``) to the matching ``PreviewRow`` index
    /// in `container.children()`. Populated by ``makeRows`` so the
    /// outline scroll-spy can find each heading's rendered widget
    /// even when adjacent blocks were grouped into a single row
    /// (consecutive paragraphs collapse into one `paragraphRun`,
    /// list items collapse into one `list`, …).
    private(set) var headingBlockToRowIndex: [Int: Int] = [:]
    /// Same shape as ``headingBlockToRowIndex`` but covers EVERY
    /// block — paragraphs, lists, code, tables. Used by the
    /// preview-side search controller (#26) to scroll to the
    /// rendered widget for a given match's block.
    private(set) var blockToRowIndex: [Int: Int] = [:]

    /// Where each block's searchable plain text lives inside its
    /// rendered Label's plain text. Needed by the preview-side
    /// match-highlight overlay (#27) so a PangoAttrList for one
    /// match can be turned into the byte range it occupies inside
    /// the rendered Label, even when the row coalesces several
    /// blocks (`paragraphRun`, `richTextRun`, `blockquoteRun`,
    /// flat-list-as-label) or pads each item with a marker glyph.
    ///
    /// Blocks that don't fit the "single Pango Label" model are
    /// deliberately absent: tables (Label content joins cells in a
    /// different order than the engine's searchable view), task
    /// lists (Grid / Box layout, no single label), images / image
    /// groups / thematic breaks (engine doesn't search them). The
    /// highlight pass simply skips matches whose blockIndex isn't
    /// in this map — those blocks still get scrolled to, just not
    /// underlined.
    ///
    /// The label pointer in each span fills in only after the row
    /// widgets are constructed; ``makeRows`` populates the offset
    /// / length, and the post-render walk attaches the Label.
    struct BlockTextSpan: Equatable {
        var labelPointer: OpaquePointer?
        let plainTextOffset: Int
        let plainTextLength: Int
    }
    private(set) var blockTextSpans: [Int: BlockTextSpan] = [:]

    /// One table cell's position in two coordinate spaces:
    /// `searchableOffset` is the cell's start in the flat,
    /// `"\n"`-joined searchable string the search engine matches
    /// against (see ``MarkdownSearchEngine/searchableText(for:)``);
    /// `labelOffset` is the cell body's start (in `Character`s) inside
    /// the column-aligned monospace `Label.text` the table renders to.
    /// `labelOffset` is `nil` for a cell with no rendered field — an
    /// over-long row carrying more cells than there are columns; such a
    /// cell is searchable but can't be highlighted, so its matches are
    /// skipped. `length` is the cell's plain-text `Character` count,
    /// identical in both spaces.
    struct TableCellGeometry: Equatable {
        let searchableOffset: Int
        let length: Int
        let labelOffset: Int?
    }

    /// Highlight mapping for a single table block: the rendered card's
    /// monospace `Label` (filled in by the post-render walk, like
    /// ``BlockTextSpan/labelPointer``) plus the per-cell geometry that
    /// translates a match in searchable-space into a range in the
    /// label's aligned text. Tables need this richer model because one
    /// block renders to one Label holding N cells across two coordinate
    /// spaces — ``BlockTextSpan``'s single offset can't represent that.
    struct TableHighlightSpan: Equatable {
        var labelPointer: OpaquePointer?
        let cells: [TableCellGeometry]
    }
    private(set) var tableHighlightSpans: [Int: TableHighlightSpan] = [:]

    /// `GtkSourceBuffer` behind each rendered code block, keyed by
    /// the block's index in the original `[RenderedBlock]`. The
    /// match-highlight overlay applies tags to these buffers the
    /// same way the editor side highlights its own buffer — same
    /// `swifty-notes-search-match` / `*-active` tags from the
    /// CSpelling shim.
    private(set) var codeBlockBuffers: [Int: SourceBuffer] = [:]
    private var renderedBaseDirectory: URL?
    private var renderMode: RenderMode = .stacked
    private var virtualizedRows: [PreviewRow] = []
    private var virtualizedStore: ListStore?
    private var virtualizedSelection: NoSelection?
    private var virtualizedFactory: SignalListItemFactory?
    private var virtualizedListView: ListView?
    private var customTextLabel: Label?
    var debugForceVirtualizedRows = false
    var debugForceCustomTextLayout = false

    init(remoteImageLoader: @escaping PreviewRemoteImageLoadHandler = { url, completion in
        PreviewRemoteImageLoader.shared.loadImage(url, completion: completion)
    }) {
        _ = Self.previewCSS
        self.remoteImageLoader = remoteImageLoader
        container = Box(orientation: .vertical, spacing: 20)
        container.setMargins(20)
        container.vexpand = true

        rootScroll = ScrolledWindow(child: container)
        rootScroll.setPolicy(horizontal: .never, vertical: .automatic)
        #if os(macOS)
        // GTK4-on-Quartz layers kinetic scrolling on top of macOS's own
        // trackpad inertia, producing visible double-acceleration jitter
        // when scrolling rendered markdown in split view. macOS only.
        rootScroll.kineticScrolling = false
        #else
        rootScroll.kineticScrolling = true
        #endif
        rootScroll.minContentWidth = MainWindow.minimumPreviewWidth
        rootScroll.setAccessibleLabel("Markdown Preview")
        rootScroll.overlayScrolling = false

        // GtkWidget does not expose `width` as a GObject property, so
        // `notify::width` (the basis for swift-adwaita's onSizeAllocate)
        // never fires on resize. A per-frame tick callback is the
        // robust way to react to allocation changes — it's a single
        // integer compare per frame, only triggers a refresh when the
        // width actually changes, and avoids missing the case where
        // the user widens the preview pane beyond its initial width.
        rootScroll.addTickCallback { [weak self] in
            guard let self else { return false }
            let width = rootScroll.width
            if width > 0, width != lastObservedPreviewWidth {
                lastObservedPreviewWidth = width
                refreshBlockImageHeights()
            }
            return true
        }
    }

    var plainText: String {
        if lastRenderedBlocks.isEmpty {
            return "Nothing to preview yet."
        }
        return lastRenderedBlocks.map(\.plainText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    var debugAnimatedImagePlayerCount: Int {
        animatedImagePlayers.count
    }

    /// How many `RenderedBlock`s the preview rendered in its last
    /// pass. Exposed for find/replace tests that assert
    /// `blockToRowIndex` covers every block.
    var debugLastRenderedBlockCount: Int {
        lastRenderedBlocks.count
    }

    /// The current `RenderedBlock` slice exposed for the
    /// PreviewSearchController to feed into MarkdownSearchEngine.
    /// Not a `debug*` API in the strictest sense — search runs in
    /// production — but kept off the public surface (internal) so
    /// it tracks alongside `lastRenderedBlocks` and isn't mistaken
    /// for stable history.
    var debugLastRenderedBlocks: [RenderedBlock] {
        lastRenderedBlocks
    }

    /// Test-only: which Label pointers currently carry highlight
    /// attributes from the find/replace bar. Lets the Phase B
    /// tests verify that apply/clear transitions touch the right
    /// labels.
    var debugHighlightedLabelPointers: Set<OpaquePointer> {
        highlightedLabelPointers
    }

    /// Test-only: which code-block blockIndexes currently carry
    /// highlight tags. Used by Phase C tests to confirm the
    /// SourceBuffer-tag overlay activates / clears at the right
    /// times.
    var debugHighlightedCodeBlockBlockIndexes: Set<Int> {
        Set(highlightedCodeBlockBuffers.keys)
    }

    /// Test-only: the exact substrings the most recent
    /// ``applySearchHighlights(matches:activeIndex:)`` painted on
    /// Label-backed blocks, captured from the live `label.text` at the
    /// resolved range. Lets tests assert the RIGHT substring got the
    /// background (not just that *some* label lit up) — essential for
    /// the table path, where the offset map translates between two
    /// coordinate spaces.
    var debugAppliedHighlightTexts: [String] {
        debugAppliedHighlights.map(\.text)
    }

    /// Test-only: just the active-match substrings from the most recent
    /// apply, so tests can confirm the active style lands on the right
    /// cell.
    var debugActiveHighlightTexts: [String] {
        debugAppliedHighlights.filter(\.isActive).map(\.text)
    }

    /// Perf-focused debug metric for tests and investigations: how many
    /// immediate block widgets the preview is currently asking GTK to
    /// lay out/snapshot.
    var debugTopLevelWidgetCount: Int {
        if debugUsesVirtualizedRows {
            return 1
        }
        return container.children().count
    }

    /// Recursive widget count of the preview subtree. Useful as a
    /// headless proxy for scenegraph growth while iterating on scroll
    /// performance work.
    var debugWidgetTreeCount: Int {
        if debugUsesVirtualizedRows, let root = rootScroll.child {
            return Self.widgetTreeCount(in: root)
        }
        return Self.widgetTreeCount(in: container)
    }

    var debugUsesVirtualizedRows: Bool {
        renderMode == .virtualized
    }

    var debugUsesCustomTextLayout: Bool {
        renderMode == .customText
    }

    private static func extractPlainText(from widget: Widget) -> String? {
        if let label = widget.tryCast(Label.self) {
            return label.text
        }
        if let sourceView = widget.tryCast(SourceView.self) {
            return sourceView.buffer.text
        }
        if let picture = widget.tryCast(Picture.self) {
            return picture.alternativeText
        }

        let nestedText = widget.children()
            .compactMap(extractPlainText(from:))
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return nestedText.isEmpty ? nil : nestedText
    }

    private static func widgetTreeCount(in widget: Widget) -> Int {
        1 + widget.children().reduce(0) { partialResult, child in
            partialResult + widgetTreeCount(in: child)
        }
    }

    func attach(to window: ApplicationWindow) {
        self.window = window
    }

    func render(blocks: [RenderedBlock], baseDirectory: URL? = nil) {
        let standardizedBaseDirectory = baseDirectory?.standardizedFileURL
        self.baseDirectory = standardizedBaseDirectory
        lastRenderedBlocks = blocks
        let rows = makeRows(from: blocks)
        let targetRenderMode = resolvedRenderMode(for: rows)

        guard !blocks.isEmpty else {
            clear()
            renderedBaseDirectory = standardizedBaseDirectory
            renderedRows = []
            renderMode = .stacked
            container.append(makeParagraph(text: .plain("Nothing to preview yet.")))
            return
        }

        guard !shouldSkipRender(rows: rows, renderMode: targetRenderMode, baseDirectory: standardizedBaseDirectory) else {
            // `makeRows(from:)` above unconditionally reset
            // `blockTextSpans` / `tableHighlightSpans` / `codeBlockBuffers`
            // and repopulated them WITHOUT widget pointers. When we skip the
            // actual re-render (content unchanged) the existing row widgets
            // are still valid, so re-link the freshly-rebuilt spans to them —
            // otherwise every no-op re-render (e.g. refreshPreview on a view-
            // mode switch) silently drops the search-highlight label pointers
            // and the overlay stops painting.
            attachWidgetPointersToBlockSpans()
            return
        }

        if targetRenderMode == .customText, renderMode == .customText {
            updateCustomTextDocument(rows: rows)
            renderedRows = rows
            renderedBaseDirectory = standardizedBaseDirectory
            return
        }

        if canIncrementallyUpdate(
            to: rows,
            renderMode: targetRenderMode,
            baseDirectory: standardizedBaseDirectory,
        ) {
            if targetRenderMode == .virtualized {
                updateVirtualizedRows(to: rows)
            } else {
                updateNonVirtualizedRows(to: rows)
            }
            renderedRows = rows
            renderedBaseDirectory = standardizedBaseDirectory
            renderMode = targetRenderMode
            attachWidgetPointersToBlockSpans()
            return
        }

        clear()
        renderedRows = rows
        renderedBaseDirectory = standardizedBaseDirectory
        renderMode = targetRenderMode
        if targetRenderMode == .virtualized {
            renderVirtualized(rows: rows)
            return
        }
        if targetRenderMode == .customText {
            container.append(makeCustomTextDocument(rows: rows))
            return
        }

        for row in rows {
            container.append(makeWidget(for: row))
        }
        attachWidgetPointersToBlockSpans()
    }

    private func resolvedRenderMode(for rows: [PreviewRow]) -> RenderMode {
        guard !rows.isEmpty else { return .stacked }
        let forcedVirtualization = debugForceVirtualizedRows || (
            ProcessInfo.processInfo.environment["SWIFTY_NOTES_DEBUG_FORCE_VIRTUALIZED_PREVIEW"]
                .map { ["1", "true", "yes"].contains($0.lowercased()) } ?? false
        )
        if forcedVirtualization && rows.allSatisfy(\.supportsVirtualization) {
            return .virtualized
        }
        if shouldUseCustomTextLayout(rows) {
            return .customText
        }
        if shouldUseVirtualizedRows(rows) {
            return .virtualized
        }
        return .stacked
    }

    private func shouldSkipRender(rows: [PreviewRow], renderMode: RenderMode, baseDirectory: URL?) -> Bool {
        !renderedRows.isEmpty
            && renderedRows == rows
            && renderedBaseDirectory == baseDirectory
            && self.renderMode == renderMode
    }

    private func canIncrementallyUpdate(to newRows: [PreviewRow], renderMode: RenderMode, baseDirectory: URL?) -> Bool {
        !renderedRows.isEmpty
            && renderedBaseDirectory == baseDirectory
            && self.renderMode == renderMode
            && renderMode != .customText
            && renderedRows.allSatisfy(\.supportsIncrementalUpdate)
            && newRows.allSatisfy(\.supportsIncrementalUpdate)
    }

    private func makeRows(from blocks: [RenderedBlock]) -> [PreviewRow] {
        var rows: [PreviewRow] = []
        var index = 0
        // Reset before populating — a previous render may have
        // tracked an entirely different note.
        headingBlockToRowIndex = [:]
        blockToRowIndex = [:]
        blockTextSpans = [:]
        tableHighlightSpans = [:]
        codeBlockBuffers = [:]
        while index < blocks.count {
            let block = blocks[index]

            // Phase B.1: greedily coalesce a heading + its trailing
            // paragraphs into one ``richTextRun`` row. Each heading
            // STARTS a new run, so heading.y always equals row.y
            // (preserves outline scroll-spy precision). Lists,
            // blockquotes, code, tables, images, thematic breaks all
            // close the current run.
            if case let .heading(level, text) = block {
                let runStartRow = rows.count
                let headingStartBlock = index
                headingBlockToRowIndex[index] = runStartRow
                blockToRowIndex[index] = runStartRow
                var segments: [RichTextSegment] = [.heading(level: level, text: text)]
                var coalescedBlockIndices: [Int] = [index]
                index += 1
                while index < blocks.count, case let .paragraph(pText) = blocks[index] {
                    segments.append(.paragraph(text: pText))
                    blockToRowIndex[index] = runStartRow
                    coalescedBlockIndices.append(index)
                    index += 1
                }
                if segments.count == 1 {
                    // Heading with no trailing paragraph — keep the
                    // legacy `.heading` row so the incremental-update
                    // path (which special-cases heading-only rows)
                    // and the equality / Pango layout that the
                    // existing `.heading` widget builder uses stay
                    // unchanged in the common no-body-paragraph case.
                    rows.append(.heading(level: level, text: text))
                    recordSpansForSingleBlockLabel(blockIndex: headingStartBlock, plainText: text.plainText)
                } else {
                    rows.append(.richTextRun(segments))
                    recordSpansForCoalescedTextRow(blocks: blocks, indices: coalescedBlockIndices)
                }
                continue
            }

            if case .listItem = block {
                let listStartRow = rows.count
                var items: [ListPreviewItem] = []
                var listBlockIndices: [Int] = []
                while index < blocks.count {
                    guard case let .listItem(text, depth, marker, loose, taskIndex) = blocks[index] else { break }
                    items.append((text, depth, marker, loose, taskIndex))
                    blockToRowIndex[index] = listStartRow
                    listBlockIndices.append(index)
                    index += 1
                }
                rows.append(.list(items: items))
                recordSpansForListRow(items: items, indices: listBlockIndices)
                continue
            }

            if let textRunStart = makeTextRunWithMap(from: blocks, startingAt: &index, rowIndex: rows.count) {
                rows.append(textRunStart)
                continue
            }

            blockToRowIndex[index] = rows.count
            switch block {
            case let .paragraph(text), let .blockquote(text):
                recordSpansForSingleBlockLabel(blockIndex: index, plainText: text.plainText)
            case let .table(headers, tableRows, alignments):
                recordTableSpans(blockIndex: index, headers: headers, rows: tableRows, alignments: alignments)
            default:
                break
            }
            rows.append(makeRow(for: block))
            index += 1
        }
        return rows
    }

    /// Like ``makeTextRun(from:startingAt:)`` but also records each
    /// consumed block's index → row mapping, so the preview-search
    /// controller can scroll back to any block within a coalesced
    /// paragraph or blockquote run.
    private func makeTextRunWithMap(
        from blocks: [RenderedBlock],
        startingAt index: inout Int,
        rowIndex: Int,
    ) -> PreviewRow? {
        let start = index
        guard let row = makeTextRun(from: blocks, startingAt: &index) else { return nil }
        let coalescedIndices = Array(start..<index)
        for consumedIndex in coalescedIndices {
            blockToRowIndex[consumedIndex] = rowIndex
        }
        recordSpansForCoalescedTextRow(blocks: blocks, indices: coalescedIndices)
        return row
    }

    // MARK: - blockTextSpans population (#27 Phase A)

    /// Records a `BlockTextSpan` for a row that renders into a
    /// single Label with one block's plain text starting at offset
    /// 0. Covers `heading`, `paragraph`, and `blockquote` blocks
    /// that didn't get coalesced into a multi-block run.
    private func recordSpansForSingleBlockLabel(blockIndex: Int, plainText: String) {
        blockTextSpans[blockIndex] = BlockTextSpan(
            labelPointer: nil,
            plainTextOffset: 0,
            plainTextLength: plainText.count,
        )
    }

    /// Records spans for a `paragraphRun`, `richTextRun`, or
    /// `blockquoteRun` row — anywhere multiple `.paragraph` /
    /// `.heading` / `.blockquote` blocks share one Label, joined
    /// by `"\n\n"` (matches ``joinedMarkup`` and
    /// ``richTextRunMarkup``).
    private func recordSpansForCoalescedTextRow(blocks: [RenderedBlock], indices: [Int]) {
        let separatorLength = 2 // "\n\n"
        var runningOffset = 0
        for (position, blockIndex) in indices.enumerated() {
            let plainText = Self.searchablePlainText(for: blocks[blockIndex]) ?? ""
            blockTextSpans[blockIndex] = BlockTextSpan(
                labelPointer: nil,
                plainTextOffset: runningOffset,
                plainTextLength: plainText.count,
            )
            runningOffset += plainText.count
            if position < indices.count - 1 {
                runningOffset += separatorLength
            }
        }
    }

    /// Records spans for a `list` row when the row will render as
    /// a flat single Label (non-task items only — task lists with
    /// checkboxes use a Grid / Box layout per item, where there
    /// isn't a single Label to attach a span to, so they're left
    /// out of `blockTextSpans` deliberately). Mirrors the layout
    /// rules used by ``flatListMarkup``: per-line prefix is
    /// `depthIndent + marker + pad`, line separator is `\n` or
    /// `\n\n` for loose lists.
    private func recordSpansForListRow(items: [ListPreviewItem], indices: [Int]) {
        guard items.allSatisfy({ $0.taskIndex == nil }) else { return }
        let markers = items.map { displayMarker(for: $0.marker, depth: $0.depth) }
        let maxMarkerWidth = markers.map(\.count).max() ?? 1
        let padTarget = maxMarkerWidth + 2
        let lineSeparatorLength = items.contains(where: \.loose) ? 2 : 1
        var runningOffset = 0
        for (position, item) in items.enumerated() {
            let marker = markers[position]
            let padCount = max(padTarget - marker.count, 1)
            let depthIndentCount = item.depth > 0 ? item.depth * 2 : 0
            let prefixLength = depthIndentCount + marker.count + padCount
            let itemPlainText = item.text.plainText
            blockTextSpans[indices[position]] = BlockTextSpan(
                labelPointer: nil,
                plainTextOffset: runningOffset + prefixLength,
                plainTextLength: itemPlainText.count,
            )
            runningOffset += prefixLength + itemPlainText.count
            if position < items.count - 1 {
                runningOffset += lineSeparatorLength
            }
        }
    }

    /// Records the per-cell highlight geometry for a table block. The
    /// `labelPointer` fills in later in ``attachWidgetPointersToBlockSpans``
    /// once the card's monospace Label exists.
    private func recordTableSpans(
        blockIndex: Int,
        headers: [RenderedText],
        rows: [[RenderedText]],
        alignments: [RenderedTableAlignment],
    ) {
        let layout = Self.tableLayout(headers: headers, rows: rows, alignments: alignments)
        tableHighlightSpans[blockIndex] = TableHighlightSpan(labelPointer: nil, cells: layout.cells)
    }

    /// Walks the rendered row widgets and writes Label pointers
    /// into the matching ``blockTextSpans`` entries (so the
    /// highlight overlay knows which Label to apply Pango
    /// attributes to) plus retains code-block ``SourceBuffer``
    /// references in ``codeBlockBuffers`` (so the editor's tag
    /// helpers can apply highlight tags inside code blocks).
    ///
    /// Called after every render path that mutates
    /// ``container.children()`` — fresh stacked render and
    /// in-place incremental update. Virtualized + custom-text
    /// modes skip highlighting (deliberate: virtualized realizes
    /// rows lazily, custom-text replaces the per-row tree with a
    /// single Label not suitable for per-block highlighting).
    func attachWidgetPointersToBlockSpans() {
        guard renderMode == .stacked else { return }
        let children = container.children()
        guard children.count == renderedRows.count else { return }
        for (rowIndex, row) in renderedRows.enumerated() {
            let widget = children[rowIndex]
            if let labelPointer = Self.locateTargetLabelPointer(in: widget, for: row) {
                for (blockIndex, var span) in blockTextSpans
                where blockToRowIndex[blockIndex] == rowIndex
                {
                    span.labelPointer = labelPointer
                    blockTextSpans[blockIndex] = span
                }
            }
            if case .codeBlock = row, let buffer = Self.locateCodeBlockBuffer(in: widget) {
                for (blockIndex, mappedRow) in blockToRowIndex where mappedRow == rowIndex {
                    codeBlockBuffers[blockIndex] = buffer
                }
            }
            if case .table = row, let labelPointer = Self.locateTableLabelPointer(in: widget) {
                for (blockIndex, mappedRow) in blockToRowIndex
                where mappedRow == rowIndex && tableHighlightSpans[blockIndex] != nil
                {
                    tableHighlightSpans[blockIndex]?.labelPointer = labelPointer
                }
            }
        }
    }

    /// The monospace body Label inside a table card. ``makeTable``
    /// builds `Box(.card) → [Label]` and tags the body with the
    /// `preview-table-body` CSS class. Select by that class rather than
    /// by position, so a future caption/footer Label added to the card
    /// can't be mistaken for the body.
    private static func locateTableLabelPointer(in widget: Widget) -> OpaquePointer? {
        guard let box = widget.tryCast(Box.self) else { return nil }
        for child in box.children() {
            if let label = child.tryCast(Label.self), label.hasCSSClass("preview-table-body") {
                return label.opaquePointer
            }
        }
        return nil
    }

    private static func locateTargetLabelPointer(in widget: Widget, for row: PreviewRow) -> OpaquePointer? {
        switch row {
        case .heading, .paragraphRun, .richTextRun:
            return widget.tryCast(Label.self)?.opaquePointer
        case .blockquoteRun:
            // Box → [Separator, Label]; the Label is the last child.
            guard let box = widget.tryCast(Box.self) else { return nil }
            for child in box.children().reversed() {
                if let label = child.tryCast(Label.self) {
                    return label.opaquePointer
                }
            }
            return nil
        case .list:
            // Flat non-task list renders as a single Label; task /
            // nested-task lists return a Box and don't get
            // per-block spans (Phase A intentionally skips them).
            return widget.tryCast(Label.self)?.opaquePointer
        default:
            return nil
        }
    }

    private static func locateCodeBlockBuffer(in widget: Widget) -> SourceBuffer? {
        guard let overlay = widget.tryCast(Overlay.self) else { return nil }
        guard let inner = overlay.child?.tryCast(Box.self) else { return nil }
        for child in inner.children() {
            if let scroll = child.tryCast(ScrolledWindow.self),
               let view = scroll.child?.tryCast(SourceView.self)
            {
                return view.buffer
            }
        }
        return nil
    }

    // MARK: - Search highlight overlay (#27 Phase B)

    /// Labels that currently carry a PangoAttrList from a previous
    /// `applySearchHighlights` call. Used so the next apply can
    /// clear stale labels (those no longer in the new match set)
    /// without touching every label in the preview — O(affected),
    /// not O(all rows).
    private var highlightedLabelPointers: Set<OpaquePointer> = []

    /// Code-block buffers that currently carry GtkTextTags from a
    /// previous `applySearchHighlights` call — same role as
    /// `highlightedLabelPointers`, just for the SourceBuffer-backed
    /// code-block side of the overlay.
    private var highlightedCodeBlockBuffers: [Int: SourceBuffer] = [:]

    /// Memoization key for ``applySearchHighlights``. Typing one
    /// character at a time in the find bar produces a stream of
    /// calls — most of them with identical (matches, activeIndex)
    /// once the controller debounces. Skipping a no-op call here
    /// keeps the Pango attribute traffic flat: the slow path
    /// (allocating attribute lists + walking the matches per
    /// label) only runs when something has actually changed.
    private var lastAppliedMatches: [PreviewMatch] = []
    private var lastAppliedActiveIndex: Int?
    private var lastAppliedNonEmpty: Bool = false
    private(set) var debugHighlightApplyCount: Int = 0

    /// Substrings painted by the most recent label-highlight pass,
    /// captured for ``debugAppliedHighlightTexts`` /
    /// ``debugActiveHighlightTexts``. Always maintained (not behind a
    /// compilation flag) but only ever read by tests; the cost is an
    /// array of the painted cell substrings, rebuilt per apply and reset
    /// on clear, so it never grows unbounded.
    private var debugAppliedHighlights: [(text: String, isActive: Bool)] = []

    /// Apply yellow-background Pango attributes over the rendered
    /// labels for each match, plus a saturated-orange + bold style
    /// for the match at `activeDisplayIndex` (0-based into
    /// `matches`). Layers ON TOP of the existing Pango markup that
    /// `label.markup = ...` already parsed — no widget rebuilds,
    /// no markup mutation. Reversible via ``clearSearchHighlights``.
    ///
    /// Matches whose blockIndex has no Label/table/code mapping are
    /// silently skipped (task lists, etc — blocks with no single-Label
    /// surface to paint). The caller's step navigation still scrolls
    /// there; we just don't underline.
    func applySearchHighlights(matches: [PreviewMatch], activeIndex: Int?) {
        // Memoization: re-running apply with the exact same
        // matches + active index is a no-op visually. Skip the
        // grouping + attribute allocation entirely. (Phase E:
        // protects the typing path from O(matches) work per
        // keystroke once the bar's debounced.)
        if matches == lastAppliedMatches,
           activeIndex == lastAppliedActiveIndex,
           lastAppliedNonEmpty == !matches.isEmpty
        {
            return
        }
        debugHighlightApplyCount += 1
        lastAppliedMatches = matches
        lastAppliedActiveIndex = activeIndex
        lastAppliedNonEmpty = !matches.isEmpty

        // Group matches into two buckets: Label-backed (Pango
        // attribute overlay) and code-block-backed (SourceBuffer
        // tag overlay). The dual path is identical in spirit to
        // the editor side — same colours, same active style —
        // applied through the medium that fits each block kind.
        //
        // Label hits are resolved to Character ranges in the target
        // Label's text up front, so single-Label blocks (heading,
        // paragraph, blockquote, list) and table cells share one apply
        // + clear path — table labels land in `highlightedLabelPointers`
        // like any other, so the stale-clear below covers them too.
        var labelHits: [OpaquePointer: [ResolvedLabelHit]] = [:]
        var codeHits: [Int: [(match: PreviewMatch, isActive: Bool)]] = [:]
        for (index, match) in matches.enumerated() {
            let isActive = (index == activeIndex)
            if let resolved = resolveLabelHit(for: match, isActive: isActive) {
                labelHits[resolved.labelPointer, default: []].append(resolved.hit)
                continue
            }
            if codeBlockBuffers[match.blockIndex] != nil {
                codeHits[match.blockIndex, default: []].append((match, isActive: isActive))
            }
        }

        let newHighlightedLabels = Set(labelHits.keys)
        for labelPointer in highlightedLabelPointers where !newHighlightedLabels.contains(labelPointer) {
            Label(borrowing: UnsafeMutableRawPointer(labelPointer)).attributes = nil
        }
        highlightedLabelPointers = newHighlightedLabels
        debugAppliedHighlights = []
        for (labelPointer, hits) in labelHits {
            applyAttributes(forLabel: labelPointer, hits: hits)
        }

        let newHighlightedBuffers = Set(codeHits.keys)
        for (blockIndex, buffer) in highlightedCodeBlockBuffers where !newHighlightedBuffers.contains(blockIndex) {
            clearTags(on: buffer)
        }
        highlightedCodeBlockBuffers = [:]
        for (blockIndex, hits) in codeHits {
            guard let buffer = codeBlockBuffers[blockIndex] else { continue }
            applyTags(on: buffer, hits: hits)
            highlightedCodeBlockBuffers[blockIndex] = buffer
        }
    }

    /// Drop any active highlight attributes / tags so the preview
    /// reads as if nobody had ever searched. Called when the
    /// preview's search bar closes.
    func clearSearchHighlights() {
        for labelPointer in highlightedLabelPointers {
            Label(borrowing: UnsafeMutableRawPointer(labelPointer)).attributes = nil
        }
        highlightedLabelPointers = []
        debugAppliedHighlights = []
        for buffer in highlightedCodeBlockBuffers.values {
            clearTags(on: buffer)
        }
        highlightedCodeBlockBuffers = [:]
        // Reset the memoization key so a subsequent apply with the
        // exact pre-clear matches doesn't get swallowed as "same
        // as last".
        lastAppliedMatches = []
        lastAppliedActiveIndex = nil
        lastAppliedNonEmpty = false
    }

    /// Apply highlight tags to a single code-block buffer using
    /// the same C shim helpers the editor uses, so the visual
    /// styling stays consistent across panes.
    private func applyTags(on buffer: SourceBuffer, hits: [(match: PreviewMatch, isActive: Bool)]) {
        let bufferPointer = UnsafeMutableRawPointer(buffer.opaquePointer)
        let matchTag = swifty_notes_search_create_match_tag(bufferPointer)
        let activeTag = swifty_notes_search_create_active_tag(bufferPointer)
        swifty_notes_search_clear_tags(bufferPointer, matchTag, activeTag)
        for (match, isActive) in hits {
            let blockText = match.blockText
            let startOffset = blockText.distance(from: blockText.startIndex, to: match.range.lowerBound)
            let endOffset = blockText.distance(from: blockText.startIndex, to: match.range.upperBound)
            let tag = isActive ? activeTag : matchTag
            guard let tag else { continue }
            swifty_notes_search_apply_tag(
                bufferPointer,
                tag,
                Int32(startOffset),
                Int32(endOffset),
            )
        }
    }

    private func clearTags(on buffer: SourceBuffer) {
        let bufferPointer = UnsafeMutableRawPointer(buffer.opaquePointer)
        let matchTag = swifty_notes_search_create_match_tag(bufferPointer)
        let activeTag = swifty_notes_search_create_active_tag(bufferPointer)
        swifty_notes_search_clear_tags(bufferPointer, matchTag, activeTag)
    }

    // Highlight colours, shared with the editor side's
    // `swifty-notes-search-match` / `*-active` GtkTextTags so a
    // match looks the same on both panes.
    private static let matchBackground = RGBA(red: 0xFF / 255, green: 0xF5 / 255, blue: 0x9D / 255)
    private static let matchForeground = RGBA(red: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255)
    private static let activeMatchBackground = RGBA(red: 0xF9 / 255, green: 0xA8 / 255, blue: 0x25 / 255)

    /// A match resolved to a `Character` range in a specific Label's
    /// plain text — the common currency that lets single-Label blocks
    /// and table cells flow through one apply path. `charStart`/`charEnd`
    /// index into `label.text`.
    private struct ResolvedLabelHit: Equatable {
        let charStart: Int
        let charEnd: Int
        let isActive: Bool
    }

    /// Translate a match into the Label and `Character` range that should
    /// carry its highlight, or `nil` if the match has no single-Label
    /// surface (code blocks, unmapped blocks) or can't be placed (a table
    /// cell with no rendered field, or a match straddling a cell
    /// boundary). Offsets are computed as `Character` distances over
    /// `match.blockText` — never reused as `String.Index` against the
    /// label's text, which is a different string.
    private func resolveLabelHit(
        for match: PreviewMatch,
        isActive: Bool,
    ) -> (labelPointer: OpaquePointer, hit: ResolvedLabelHit)? {
        let blockText = match.blockText
        let matchStart = blockText.distance(from: blockText.startIndex, to: match.range.lowerBound)
        let matchEnd = blockText.distance(from: blockText.startIndex, to: match.range.upperBound)

        if let span = blockTextSpans[match.blockIndex], let labelPointer = span.labelPointer {
            return (labelPointer, ResolvedLabelHit(
                charStart: span.plainTextOffset + matchStart,
                charEnd: span.plainTextOffset + matchEnd,
                isActive: isActive,
            ))
        }

        if let table = tableHighlightSpans[match.blockIndex], let labelPointer = table.labelPointer {
            // The match must lie entirely within one cell that has a
            // rendered field. A cross-cell match (only reachable via a
            // regex / newline query, since cells are "\n"-joined) or a
            // match in an over-long row's extra cell has nowhere valid to
            // paint, so it's skipped — the step navigation still scrolls.
            for cell in table.cells {
                guard let labelOffset = cell.labelOffset else { continue }
                let cellEnd = cell.searchableOffset + cell.length
                guard matchStart >= cell.searchableOffset, matchEnd <= cellEnd else { continue }
                let localOffset = matchStart - cell.searchableOffset
                return (labelPointer, ResolvedLabelHit(
                    charStart: labelOffset + localOffset,
                    charEnd: labelOffset + localOffset + (matchEnd - matchStart),
                    isActive: isActive,
                ))
            }
        }

        return nil
    }

    private func applyAttributes(
        forLabel labelPointer: OpaquePointer,
        hits: [ResolvedLabelHit],
    ) {
        // swift-adwaita's `TextAttributes` range helpers take a Swift
        // `Range<String.Index>` over the label's plain text and do the
        // UTF-8 byte-offset translation + boundary validation
        // internally — so the preview no longer hand-rolls
        // `pango_attr_*_new` + manual `String.utf8.distance` (that
        // boilerplate moved into the library). `label.text` returns
        // exactly the plain text Pango lays out (markup tags stripped),
        // which is the coordinate space the resolved char offsets live in.
        let label = Label(borrowing: UnsafeMutableRawPointer(labelPointer))
        let plainText = label.text
        let totalChars = plainText.count
        let attributes = TextAttributes()

        for hit in hits {
            // Re-validate every resolved range against the live label text
            // so any residual offset drift degrades to "no highlight"
            // rather than an out-of-bounds index crash.
            guard hit.charStart >= 0, hit.charEnd <= totalChars, hit.charStart < hit.charEnd else { continue }
            let startIndex = plainText.index(plainText.startIndex, offsetBy: hit.charStart)
            let endIndex = plainText.index(plainText.startIndex, offsetBy: hit.charEnd)
            let range = startIndex..<endIndex
            debugAppliedHighlights.append((text: String(plainText[range]), isActive: hit.isActive))

            attributes.addBackgroundColor(Self.matchBackground, range: range, in: plainText)
            attributes.addForegroundColor(Self.matchForeground, range: range, in: plainText)
            if hit.isActive {
                attributes.addBackgroundColor(Self.activeMatchBackground, range: range, in: plainText)
                attributes.addBold(range: range, in: plainText)
            }
        }

        label.attributes = attributes
    }

    /// Pure-logic accessor mirroring ``MarkdownSearchEngine.searchableText``
    /// — kept private here to avoid bringing the engine into the
    /// preview's import surface. The two implementations must stay
    /// in sync for the highlight overlay to land on the right
    /// substring.
    private static func searchablePlainText(for block: RenderedBlock) -> String? {
        switch block {
        case .image, .imageGroup, .thematicBreak:
            return nil
        case let .heading(_, text), let .paragraph(text), let .blockquote(text):
            return text.plainText
        case let .codeBlock(code, _):
            return code
        case let .listItem(text, _, _, _, _):
            return text.plainText
        case let .table(headers, rows, _):
            let headerLine = headers.map(\.plainText).joined(separator: "\n")
            let cellLines = rows.flatMap { row in row.map(\.plainText) }
            return ([headerLine] + cellLines).joined(separator: "\n")
        }
    }

    private func shouldUseVirtualizedRows(_ rows: [PreviewRow]) -> Bool {
        let forcedByEnvironment = ProcessInfo.processInfo.environment["SWIFTY_NOTES_DEBUG_FORCE_VIRTUALIZED_PREVIEW"]
            .map { ["1", "true", "yes"].contains($0.lowercased()) } ?? false
        let forced = debugForceVirtualizedRows || forcedByEnvironment
        let wantsVirtualization = forced || rows.count >= 120
        return wantsVirtualization && rows.allSatisfy(\.supportsVirtualization)
    }

    private func shouldUseCustomTextLayout(_ rows: [PreviewRow]) -> Bool {
        let forcedByEnvironment = ProcessInfo.processInfo.environment["SWIFTY_NOTES_DEBUG_FORCE_CUSTOM_TEXT_PREVIEW"]
            .map { ["1", "true", "yes"].contains($0.lowercased()) } ?? false
        let forced = debugForceCustomTextLayout || forcedByEnvironment
        let wantsCustomTextLayout = forced || rows.count >= 160
        return wantsCustomTextLayout && rows.allSatisfy(\.supportsCustomTextLayout)
    }

    private func renderVirtualized(rows: [PreviewRow]) {
        virtualizedRows = rows

        let store = ListStore()
        for _ in rows {
            store.appendPlaceholder()
        }

        let factory = SignalListItemFactory()
        factory.onBind { [weak self] listItem in
            guard let self else { return }
            let position = listItem.position
            guard position >= 0, position < virtualizedRows.count else {
                listItem.child = nil
                return
            }
            listItem.child = makeVirtualizedRowWidget(
                for: virtualizedRows[position],
                isFirst: position == 0,
                isLast: position == virtualizedRows.count - 1,
            )
        }
        factory.onUnbind { listItem in
            listItem.child = nil
        }

        let selection = NoSelection(model: store)
        let listView = ListView(model: selection, factory: factory)
        listView.showSeparators = false
        listView.singleClickActivate = false
        listView.hexpand = true
        listView.vexpand = true

        virtualizedStore = store
        virtualizedSelection = selection
        virtualizedFactory = factory
        virtualizedListView = listView
        rootScroll.child = listView
    }

    private func makeCustomTextDocument(rows: [PreviewRow]) -> Label {
        let label = makeMarkupLabel(customTextMarkup(for: rows))
        label.addCSSClass("preview-paragraph-label")
        label.selectable = true
        label.hexpand = true
        label.halign = .fill
        customTextLabel = label
        return label
    }

    private func updateCustomTextDocument(rows: [PreviewRow]) {
        guard let label = customTextLabel else {
            clear()
            container.append(makeCustomTextDocument(rows: rows))
            return
        }
        label.markup = customTextMarkup(for: rows)
    }

    private func updateVirtualizedRows(to newRows: [PreviewRow]) {
        guard let store = virtualizedStore else {
            renderVirtualized(rows: newRows)
            return
        }

        let diff = RowDiff.between(old: renderedRows, new: newRows)
        guard diff.hasChanges else { return }

        virtualizedRows = newRows
        for index in diff.oldChangedRange.reversed() {
            store.remove(at: index)
        }
        for index in diff.newChangedRange {
            store.insertPlaceholder(at: index)
        }
    }

    private func updateNonVirtualizedRows(to newRows: [PreviewRow]) {
        let diff = RowDiff.between(old: renderedRows, new: newRows)
        guard diff.hasChanges else { return }

        let existingChildren = container.children()
        if diff.oldChangedRange.count == diff.newChangedRange.count,
           updateNonVirtualizedRowsInPlace(
               existingChildren: existingChildren,
               oldRows: Array(renderedRows[diff.oldChangedRange]),
               newRows: Array(newRows[diff.newChangedRange]),
               startingAt: diff.oldChangedRange.lowerBound,
           )
        {
            return
        }

        for index in diff.oldChangedRange.reversed() {
            let child = existingChildren[index]
            child.visible = false
            container.remove(child)
        }

        let retainedChildren = container.children()
        var sibling: Widget?
        if diff.prefixCount > 0 {
            sibling = retainedChildren[diff.prefixCount - 1]
        }

        for row in newRows[diff.newChangedRange] {
            let widget = makeWidget(for: row)
            container.insertChildAfter(widget, sibling: sibling)
            sibling = widget
        }
    }

    private func updateNonVirtualizedRowsInPlace(
        existingChildren: [Widget],
        oldRows: [PreviewRow],
        newRows: [PreviewRow],
        startingAt startIndex: Int,
    ) -> Bool {
        guard oldRows.count == newRows.count else { return false }
        for offset in oldRows.indices {
            guard updateWidgetInPlace(
                existingChildren[startIndex + offset],
                from: oldRows[offset],
                to: newRows[offset],
            ) else {
                return false
            }
        }
        return true
    }

    private func updateWidgetInPlace(_ widget: Widget, from oldRow: PreviewRow, to newRow: PreviewRow) -> Bool {
        switch (oldRow, newRow) {
        case let (.heading(_, _), .heading(level, text)):
            guard let label = widget.tryCast(Label.self) else { return false }
            configureHeadingLabel(label, level: level, text: text)
            return true
        case let (.paragraphRun(_), .paragraphRun(texts)):
            guard let label = widget.tryCast(Label.self) else { return false }
            configureParagraphLabel(label, texts: texts)
            return true
        case let (.richTextRun(_), .richTextRun(segments)):
            guard let label = widget.tryCast(Label.self) else { return false }
            label.markup = richTextRunMarkup(segments)
            return true
        case let (.list(oldItems), .list(newItems)):
            // Phase B.2: any non-task list (depth-0 or nested) now
            // uses a single Label. If both renders agree on that
            // shape we can swap the markup in place; otherwise the
            // row shape changed (e.g. user added a checkbox → task
            // list) and the caller has to rebuild.
            let oldNonTask = oldItems.allSatisfy { $0.taskIndex == nil }
            let newNonTask = newItems.allSatisfy { $0.taskIndex == nil }
            guard oldNonTask, newNonTask else { return false }
            guard let label = widget.tryCast(Label.self) else { return false }
            label.markup = flatListMarkup(newItems)
            return true
        case let (.blockquoteRun(_), .blockquoteRun(texts)):
            guard let row = widget.tryCast(Box.self) else { return false }
            return configureBlockquoteRow(row, texts: texts)
        case (.thematicBreak, .thematicBreak):
            return true
        default:
            return false
        }
    }

    private func makeVirtualizedRowWidget(for row: PreviewRow, isFirst: Bool, isLast: Bool) -> Widget {
        let wrapper = Box(orientation: .vertical, spacing: 0)
        wrapper.hexpand = true
        wrapper.halign = .fill
        wrapper.marginStart = 20
        wrapper.marginEnd = 20
        wrapper.marginTop = isFirst ? 20 : 0
        wrapper.marginBottom = isLast ? 20 : 20
        wrapper.append(makeWidget(for: row))
        return wrapper
    }

    private func makeTextRun(from blocks: [RenderedBlock], startingAt index: inout Int) -> PreviewRow? {
        switch blocks[index] {
        case let .paragraph(text):
            var texts = [text]
            index += 1
            while index < blocks.count {
                guard case let .paragraph(nextText) = blocks[index] else { break }
                texts.append(nextText)
                index += 1
            }
            return .paragraphRun(texts)
        case let .blockquote(text):
            var texts = [text]
            index += 1
            while index < blocks.count {
                guard case let .blockquote(nextText) = blocks[index] else { break }
                texts.append(nextText)
                index += 1
            }
            return .blockquoteRun(texts)
        default:
            return nil
        }
    }

    private func makeRow(for block: RenderedBlock) -> PreviewRow {
        switch block {
        case let .heading(level, text):
            .heading(level: level, text: text)
        case let .paragraph(text):
            .paragraphRun([text])
        case let .codeBlock(code, language):
            .codeBlock(code: code, language: language)
        case let .blockquote(text):
            .blockquoteRun([text])
        case .listItem:
            .list(items: [])
        case .thematicBreak:
            .thematicBreak
        case let .table(headers, rows, alignments):
            .table(headers: headers, rows: rows, alignments: alignments)
        case let .image(alt, source, title, style):
            .image(alt: alt, source: source, title: title, style: style)
        case let .imageGroup(items, style):
            .imageGroup(items: items, style: style)
        }
    }

    private func makeWidget(for row: PreviewRow) -> Widget {
        switch row {
        case let .heading(level, text):
            makeHeading(level: level, text: text)
        case let .paragraphRun(texts):
            makeParagraphRun(texts)
        case let .richTextRun(segments):
            makeRichTextRun(segments)
        case let .codeBlock(code, language):
            makeCodeBlock(code: code, language: language)
        case let .blockquoteRun(texts):
            makeBlockquoteRun(texts)
        case let .list(items):
            makeList(items)
        case .thematicBreak:
            makeSeparator()
        case let .table(headers, rows, alignments):
            makeTable(headers: headers, rows: rows, alignments: alignments)
        case let .image(alt, source, title, style):
            makeImageBlock(alt: alt, source: source, title: title, style: style)
        case let .imageGroup(items, style):
            makeImageGroup(items, style: style)
        }
    }

    private func clear() {
        for player in animatedImagePlayers {
            player.stop()
        }
        animatedImagePlayers.removeAll()
        renderedRows.removeAll()
        renderedBaseDirectory = nil
        renderMode = .stacked
        virtualizedRows.removeAll()
        virtualizedFactory = nil
        virtualizedSelection = nil
        virtualizedStore = nil
        virtualizedListView = nil
        customTextLabel = nil
        // NOTE: blockTextSpans + codeBlockBuffers are NOT reset
        // here — `makeRows` runs before `clear()` in `render()`
        // and rewrites the spans for the new blocks. Wiping them
        // here would leave the post-render walk with no spans to
        // attach Label pointers to. They're reset at the top of
        // `makeRows` instead.
        //
        // The highlight tracking sets DO need resetting here: the
        // labels they reference are about to be removed below, so
        // a later clear/apply would dereference freed pointers.
        // The next applySearchHighlights from the controller will
        // re-populate against the rebuilt widget tree. The
        // memoization key is reset too so an "identical" call
        // against the new tree doesn't get short-circuited as
        // "same as last".
        highlightedLabelPointers = []
        highlightedCodeBlockBuffers = [:]
        lastAppliedMatches = []
        lastAppliedActiveIndex = nil
        lastAppliedNonEmpty = false
        if rootScroll.child?.widgetPointer != container.widgetPointer {
            rootScroll.child = container
        }
        for child in container.children() {
            child.visible = false
            container.remove(child)
        }
    }

    private func makeHeading(level: Int, text: RenderedText) -> Label {
        let label = makeMarkupLabel(text.markup)
        configureHeadingLabel(label, level: level, text: text)
        return label
    }

    private func makeParagraph(text: RenderedText) -> Label {
        makeParagraphRun([text])
    }

    private func makeParagraphRun(_ texts: [RenderedText]) -> Label {
        let label = makeMarkupLabel(joinedMarkup(for: texts))
        configureParagraphLabel(label, texts: texts)
        return label
    }

    /// Phase B.1: render a heading + its trailing paragraphs as a
    /// single Label whose markup mixes a heading-styled span and the
    /// body paragraph spans. Cuts a heading-with-body pair from 2
    /// widgets down to 1 — the render walk has fewer
    /// `gtk_widget_snapshot_child` recursions per frame and the
    /// Pango layout is a single object instead of two.
    ///
    /// Heading is always the first segment (by construction in
    /// `makeRows`), so its Y aligns with the row's top and the
    /// outline scroll-spy continues to land precisely on the
    /// heading line.
    private func makeRichTextRun(_ segments: [RichTextSegment]) -> Label {
        let label = makeMarkupLabel(richTextRunMarkup(segments))
        // Reuse the paragraph styling baseline (selectable text,
        // preview-paragraph-label class). The heading span carries
        // its size/weight inline via Pango markup, not via a CSS
        // class — applying `.title1`/`.title2` to the whole Label
        // would also scale the paragraph body, which we don't want.
        if !label.hasCSSClass("preview-paragraph-label") {
            label.addCSSClass("preview-paragraph-label")
        }
        if !label.hasCSSClass("preview-rich-text-run") {
            label.addCSSClass("preview-rich-text-run")
        }
        label.selectable = true
        return label
    }

    /// Markup string used by both the stacked Label and the
    /// custom-text-layout path. Heading sizes mirror the symbolic
    /// Pango sizes the legacy customTextMarkup uses for `.heading`
    /// rows, so behaviour matches the pre-B.1 customText output
    /// when this run reaches that mode.
    private func richTextRunMarkup(_ segments: [RichTextSegment]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(segments.count)
        for segment in segments {
            switch segment {
            case let .heading(level, text):
                let size: String = switch level {
                case 1: "xx-large"
                case 2: "x-large"
                default: "large"
                }
                parts.append("<span weight=\"bold\" size=\"\(size)\">\(text.markup)</span>")
            case let .paragraph(text):
                parts.append(text.markup)
            }
        }
        // Double newline between segments matches the visual gap
        // between separate `heading` + `paragraphRun` widgets that the
        // pre-B.1 render produced (each Label had its own margin).
        return parts.joined(separator: "\n\n")
    }

    private func makeCodeBlock(code: String, language: String?) -> Widget {
        let inner = Box(orientation: .vertical, spacing: 10)
        inner.setMargins(14)
        inner.hexpand = true
        inner.halign = .fill

        if let language, !language.isEmpty {
            let badge = Label(language.uppercased())
            badge.addCSSClass(.dimLabel)
            badge.addCSSClass("monospace")
            badge.xalign = 0
            inner.append(badge)
        }

        let buffer = Self.makeSourceBuffer(for: code, language: language)
        let view = SourceView(buffer: buffer)
        view.editable = false
        view.cursorVisible = false
        view.isFocusable = false
        view.monospace = true
        view.wrapMode = .none
        view.leftMargin = 0
        view.rightMargin = 0
        view.topMargin = 0
        view.bottomMargin = 0
        view.addCSSClass("preview-code-sourceview")

        let scroll = ScrolledWindow(child: view)
        scroll.setPolicy(horizontal: .automatic, vertical: .never)
        scroll.propagateNaturalHeight = true
        scroll.propagateNaturalWidth = false
        scroll.hexpand = true
        scroll.halign = .fill
        scroll.addCSSClass("preview-code-scroll")
        inner.append(scroll)

        let overlay = Overlay()
        overlay.addCSSClass("card")
        overlay.addCSSClass("preview-code-block")
        overlay.hexpand = true
        overlay.halign = .fill
        overlay.overflow = .hidden
        overlay.child = inner
        overlay.addOverlay(makeCodeBlockCopyButton(for: code))
        return overlay
    }

    /// Builds a ``SourceBuffer`` primed with the code block's text and the
    /// right language for syntax highlighting. Unknown / absent languages
    /// fall back to a language-less buffer so the caller still renders as
    /// plain monospace with a consistent style scheme.
    private static func makeSourceBuffer(for code: String, language: String?) -> SourceBuffer {
        let buffer: SourceBuffer
        if let rawID = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !rawID.isEmpty,
           let normalised = sourceLanguageAlias(for: rawID),
           let lang = SourceLanguageManager.default.language(id: normalised)
        {
            buffer = SourceBuffer(language: lang)
            buffer.highlightSyntax = true
        } else {
            buffer = SourceBuffer()
            buffer.highlightSyntax = false
        }
        buffer.text = code
        buffer.styleScheme = SourceStyleSchemeManager.default.preferredScheme(dark: StyleManager.default.dark)
        return buffer
    }

    /// Maps common markdown fence info-strings onto GtkSourceView language
    /// ids. The manager already accepts the canonical ids verbatim, so this
    /// only needs to cover aliases users are used to typing. Anything not
    /// listed is passed through unchanged — the subsequent
    /// ``SourceLanguageManager/language(id:)`` lookup decides whether it
    /// matches a shipped .lang file or falls back to language-less mode.
    ///
    /// `js`/`jsx` intentionally route to `typescript` because GtkSourceView
    /// 5.18 dropped the standalone `javascript` language id in favour of
    /// the TypeScript grammar (TS is a superset of JS and parses plain JS
    /// files without issue).
    private static func sourceLanguageAlias(for rawID: String) -> String? {
        switch rawID {
        case "js", "jsx", "ts", "tsx": "typescript"
        case "py": "python"
        case "rb": "ruby"
        // `sh` is GtkSourceView's shell-script grammar — it covers bash,
        // dash, zsh, and POSIX sh. There is no separate `bash.lang` in
        // upstream GtkSourceView, so `bash` (an extremely common fence
        // info-string) has to alias here or it falls through to a raw
        // `bash` lookup that returns nil and we lose highlighting.
        case "bash", "sh", "shell", "zsh": "sh"
        case "cpp", "cxx", "c++", "hpp", "hxx": "cpp"
        // GtkSourceView ships the C# grammar under the id `c-sharp`
        // (hyphenated) — `csharp` is NOT a valid id and produces a nil
        // language lookup. Both `cs` and `csharp` need to alias to the
        // hyphenated form.
        case "cs", "csharp": "c-sharp"
        case "yml": "yaml"
        case "md": "markdown"
        case "rs": "rust"
        case "kt": "kotlin"
        case "": nil
        default: rawID
        }
    }

    private static let copyIconName = "edit-copy-symbolic"
    private static let copyConfirmedIconName = "object-select-symbolic"

    private func makeCodeBlockCopyButton(for code: String) -> Button {
        let button = Button(iconName: Self.copyIconName)
        button.addCSSClass("osd")
        button.addCSSClass("circular")
        button.addCSSClass("preview-code-copy")
        button.halign = .end
        button.valign = .start
        button.marginTop = 8
        button.marginEnd = 8
        button.tooltipText = "Copy code to clipboard"
        button.setAccessibleLabel("Copy code to clipboard")
        // Outer capture is strong on purpose: GTK owns the underlying
        // widget but nothing else holds the Swift Button wrapper, so a
        // weak capture here would dangle by the time the signal fires.
        // The retain breaks naturally when GTK disposes the widget —
        // that disconnects the signal and frees the ClosureBox that
        // retains the wrapper.
        //
        // The nested `task(after:)` must capture the button weakly: it
        // outlives the click handler and can fire on a timeline where
        // the widget has already been destroyed (for example when the
        // preview unmounts mid-test). A weak grab there keeps the
        // timeout a no-op instead of writing to a freed GtkButton.
        button.onClicked { [button, code] in
            button.clipboard.setText(code)
            button.iconName = Self.copyConfirmedIconName
            MainContext.task(after: .seconds(1)) { [weak button] in
                button?.iconName = Self.copyIconName
            }
        }
        return button
    }

    private func makeBlockquote(text: RenderedText) -> Widget {
        makeBlockquoteRun([text])
    }

    private func makeBlockquoteRun(_ texts: [RenderedText]) -> Widget {
        let row = Box(orientation: .horizontal, spacing: 12)
        row.marginStart = 4
        row.marginEnd = 4

        let accent = Separator(orientation: .vertical)
        accent.marginTop = 2
        accent.marginBottom = 2

        let label = makeMarkupLabel(joinedMarkup(for: texts))
        configureBlockquoteLabel(label, texts: texts)

        row.append(accent)
        row.append(label)
        return row
    }

    private func configureHeadingLabel(_ label: Label, level: Int, text: RenderedText) {
        label.markup = text.markup
        label.removeCSSClass(.title1)
        label.removeCSSClass(.title2)
        label.removeCSSClass(.title3)
        label.setMargins(0)
        switch level {
        case 1:
            label.addCSSClass(.title1)
            label.marginBottom = 2
        case 2:
            label.addCSSClass(.title2)
        default:
            label.addCSSClass(.title3)
        }
    }

    private func configureParagraphLabel(_ label: Label, texts: [RenderedText]) {
        label.markup = joinedMarkup(for: texts)
        if !label.hasCSSClass("preview-paragraph-label") {
            label.addCSSClass("preview-paragraph-label")
        }
        label.selectable = true
    }

    private func configureBlockquoteLabel(_ label: Label, texts: [RenderedText]) {
        label.markup = joinedMarkup(for: texts)
        if !label.hasCSSClass("preview-blockquote-label") {
            label.addCSSClass("preview-blockquote-label")
        }
        if !label.hasCSSClass(.dimLabel) {
            label.addCSSClass(.dimLabel)
        }
        label.selectable = true
        label.hexpand = true
        label.halign = .fill
    }

    private func configureBlockquoteRow(_ row: Box, texts: [RenderedText]) -> Bool {
        guard let label = row.children().last?.tryCast(Label.self) else { return false }
        configureBlockquoteLabel(label, texts: texts)
        return true
    }

    private func customTextMarkup(for rows: [PreviewRow]) -> String {
        rows.enumerated().map { index, row in
            customTextMarkup(for: row, isLast: index == rows.count - 1)
        }.joined()
    }

    private func customTextMarkup(for row: PreviewRow, isLast: Bool) -> String {
        let separator = isLast ? "" : "\n\n"
        switch row {
        case let .heading(level, text):
            let size: String
            switch level {
            case 1:
                size = "xx-large"
            case 2:
                size = "x-large"
            default:
                size = "large"
            }
            return "<span weight=\"bold\" size=\"\(size)\">\(text.markup)</span>\(separator)"
        case let .paragraphRun(texts):
            return joinedMarkup(for: texts) + separator
        case let .richTextRun(segments):
            return richTextRunMarkup(segments) + separator
        case let .blockquoteRun(texts):
            let quoteMarkup = texts.map { "<span alpha=\"70%\">│ \($0.markup)</span>" }
                .joined(separator: "\n\n")
            return quoteMarkup + separator
        case let .list(items):
            return customTextMarkup(forListItems: items) + separator
        case .thematicBreak:
            return "<span alpha=\"45%\">────────────────</span>\(separator)"
        case .codeBlock, .table, .image, .imageGroup:
            return separator
        }
    }

    private func customTextMarkup(forListItems items: [ListPreviewItem]) -> String {
        var lines: [String] = []
        for (index, item) in items.enumerated() {
            let indentation = String(repeating: "\u{00A0}\u{00A0}", count: item.depth)
            let line = "\(indentation)\(displayMarker(for: item.marker, depth: item.depth)) \(item.text.markup)"
            if item.loose, index > 0 {
                lines.append("")
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private func joinedMarkup(for texts: [RenderedText]) -> String {
        texts.map(\.markup).joined(separator: "\n\n")
    }

    private func makeList(_ items: [(text: RenderedText, depth: Int, marker: String, loose: Bool, taskIndex: Int?)]) -> Widget {
        // Phase B.2 (extended): any list with no checkbox marker
        // collapses to a single Label, regardless of depth. Indent
        // per nesting level is approximated through leading spaces
        // in the Pango markup. Task lists still need per-row
        // widgets because checkbox markers are interactive.
        if items.allSatisfy({ $0.taskIndex == nil }) {
            return makeFlatListAsLabel(items)
        }

        if items.allSatisfy({ $0.depth == 0 }) {
            return makeFlatList(items)
        }

        let list = Box(orientation: .vertical, spacing: 0)
        for item in items {
            list.append(makeListItem(
                text: item.text,
                depth: item.depth,
                marker: item.marker,
                compact: !isTaskListMarker(item.marker),
                loose: item.loose,
                taskIndex: item.taskIndex,
            ))
        }
        return list
    }

    /// Markup string for a non-task list (any depth). Shared between
    /// the initial-build path (``makeFlatListAsLabel``) and the
    /// in-place update path (``updateWidgetInPlace``), so a typing-
    /// debounced refresh that only changed one bullet can keep the
    /// Label widget alive and just swap its `markup`.
    ///
    /// Indent per nesting level is rendered through leading spaces
    /// (Pango Label has no per-line `indent` knob exposed through
    /// swift-adwaita yet — see Phase B.2 trade-off comment in
    /// `makeFlatListAsLabel`). Two spaces per depth level approximates
    /// the 10 px / level the per-row Box layout uses; visually close
    /// for short bullets, slightly tighter for deep nesting.
    private func flatListMarkup(_ items: [(text: RenderedText, depth: Int, marker: String, loose: Bool, taskIndex: Int?)]) -> String {
        let markers = items.map { displayMarker(for: $0.marker, depth: $0.depth) }
        let maxMarkerWidth = markers.map(\.count).max() ?? 1
        let padTarget = maxMarkerWidth + 2
        var lines: [String] = []
        lines.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let marker = markers[index]
            let padCount = max(padTarget - marker.count, 1)
            let pad = String(repeating: " ", count: padCount)
            let depthIndent = item.depth > 0 ? String(repeating: "  ", count: item.depth) : ""
            lines.append("\(depthIndent)<span alpha=\"60%\">\(marker)</span>\(pad)\(item.text.markup)")
        }
        let separator = items.contains(where: \.loose) ? "\n\n" : "\n"
        return lines.joined(separator: separator)
    }

    /// Phase B.2 single-Label path for a flat list of non-task items.
    /// Cuts a 4-bullet list from `Grid + 8 Labels` (9 widgets) down to
    /// one Label — that's the per-frame snapshot of a third of the
    /// showcase's preview-pane widget count.
    ///
    /// Visual fidelity trade-off: long bullets that wrap onto a
    /// second line don't get a hanging indent (the wrapped text
    /// starts back at column 0 because Pango Label doesn't expose
    /// `pango_layout_set_indent` through swift-adwaita yet). Markers
    /// stay aligned per-list via fixed-width padding computed off
    /// the widest marker in the list — visually identical to the
    /// Grid layout for the common case of single-line items.
    private func makeFlatListAsLabel(_ items: [(text: RenderedText, depth: Int, marker: String, loose: Bool, taskIndex: Int?)]) -> Widget {
        let label = makeMarkupLabel(flatListMarkup(items))
        label.selectable = true
        label.hexpand = true
        label.halign = .fill
        label.xalign = 0
        if !label.hasCSSClass("preview-flat-list-label") {
            label.addCSSClass("preview-flat-list-label")
        }
        return label
    }

    private func makeFlatList(_ items: [(text: RenderedText, depth: Int, marker: String, loose: Bool, taskIndex: Int?)]) -> Widget {
        let grid = Grid(columnSpacing: PreviewMetrics.listMarkerSpacing, rowSpacing: 0)
        grid.hexpand = true
        grid.halign = .fill
        grid.valign = .start

        for (rowIndex, item) in items.enumerated() {
            let compact = !isTaskListMarker(item.marker)
            let cells = makeListItemCells(
                text: item.text,
                depth: item.depth,
                marker: item.marker,
                compact: compact,
                taskIndex: item.taskIndex,
            )
            applyFlatListSpacing(markerLabel: cells.markerLabel, contentLabel: cells.contentLabel, loose: item.loose)
            grid.attach(cells.markerLabel, column: 0, row: rowIndex)
            grid.attach(cells.contentLabel, column: 1, row: rowIndex)
        }

        return grid
    }

    private func makeListItem(text: RenderedText, depth: Int, marker: String, compact: Bool, loose: Bool, taskIndex: Int?) -> Widget {
        let row = Box(orientation: .horizontal, spacing: PreviewMetrics.listMarkerSpacing)
        row.marginStart = PreviewMetrics.listIndentPerLevel * depth
        row.addCSSClass("preview-list-row")
        row.addCSSClass(compact ? "preview-compact-list-row" : "preview-task-list-row")
        if loose {
            row.addCSSClass("preview-loose-list-row")
        }
        if depth > 0 {
            row.addCSSClass("preview-nested-list-row")
        }

        let cells = makeListItemCells(text: text, depth: depth, marker: marker, compact: compact, taskIndex: taskIndex)
        row.append(cells.markerLabel)
        row.append(cells.contentLabel)

        return row
    }

    private func makeListItemCells(text: RenderedText, depth: Int, marker: String, compact: Bool, taskIndex: Int?) -> (markerLabel: Label, contentLabel: Label) {
        let markerLabel = Label(displayMarker(for: marker, depth: depth))
        markerLabel.xalign = 0
        markerLabel.yalign = 0
        markerLabel.valign = .start
        markerLabel.addCSSClass(.dimLabel)
        markerLabel.addCSSClass(compact ? "preview-compact-list-marker" : "preview-task-list-marker")
        markerLabel.widthChars = markerWidth(for: marker)

        let contentLabel = makeMarkupLabel(text.markup)
        contentLabel.selectable = true
        contentLabel.hexpand = true
        contentLabel.halign = .fill
        contentLabel.yalign = 0
        contentLabel.valign = .start
        contentLabel.addCSSClass(compact ? "preview-compact-list-label" : "preview-task-list-label")
        contentLabel.setMargins(0)

        if let taskIndex {
            markerLabel.addCSSClass("preview-task-checkbox")
            markerLabel.setCursor(name: "pointer")
            let click = GestureClick()
            click.onReleased { [weak self] _, _, _ in
                self?.taskCheckboxToggleHandler?(taskIndex)
            }
            markerLabel.addController(click)
        }

        return (markerLabel, contentLabel)
    }

    private func applyFlatListSpacing(markerLabel: Label, contentLabel: Label, loose: Bool) {
        let topMargin = loose ? 18 : 2
        markerLabel.marginTop = topMargin
        markerLabel.marginBottom = 2
        contentLabel.marginTop = topMargin
        contentLabel.marginBottom = 2
    }

    /// Invoked when the user clicks the `☐` / `☑` glyph in front of a
    /// task list item. The `Int` is the 0-based document-order index
    /// stamped on `RenderedBlock.listItem.taskIndex`. The receiver is
    /// expected to hand it off to `TaskListToggle.toggle(in:atTaskIndex:)`,
    /// persist the rewritten markdown, and re-render the preview.
    var taskCheckboxToggleHandler: ((Int) -> Void)?

    private func displayMarker(for marker: String, depth: Int) -> String {
        switch marker {
        case "[x]":
            "☑"
        case "[ ]":
            "☐"
        case "-":
            depth == 0 ? "•" : "◦"
        default:
            marker
        }
    }

    private func isTaskListMarker(_ marker: String) -> Bool {
        marker == "[x]" || marker == "[ ]"
    }

    private func markerWidth(for marker: String) -> Int {
        switch marker {
        case "-":
            1
        case "[x]", "[ ]":
            2
        default:
            max(marker.count, 2)
        }
    }

    private func makeSeparator() -> Separator {
        let separator = Separator()
        separator.marginTop = 6
        separator.marginBottom = 6
        return separator
    }

    private func makeTable(headers: [RenderedText], rows: [[RenderedText]], alignments: [RenderedTableAlignment]) -> Widget {
        // Phase B.3 (scroll perf): the previous Grid-with-cells layout
        // was the heaviest remaining preview block on the showcase note
        // (wrapper Box + inner Box + Grid + 1 separator + N labels — 12
        // widgets for a 4-row × 2-column table). GTK's per-frame
        // snapshot walk dominated scroll CPU on that note, so we
        // collapse the table body into a single monospaced Pango
        // markup Label inside the existing card wrapper. Character-
        // count padding keeps the columns aligned because <tt> picks a
        // monospace family. Loss: cells no longer auto-wrap (wide
        // cells stretch the label and the scrolled-window scrolls
        // horizontally); markdown tables in practice keep cells
        // short, so this is an acceptable trade.
        let wrapper = Box(orientation: .vertical, spacing: 0)
        wrapper.addCSSClass("card")
        wrapper.addCSSClass("preview-table-card")
        wrapper.hexpand = true
        wrapper.vexpand = false
        wrapper.halign = .fill
        wrapper.valign = .start
        wrapper.overflow = .hidden

        let label = makeMarkupLabel(tableMarkup(headers: headers, rows: rows, alignments: alignments))
        label.addCSSClass("preview-table-body")
        label.marginStart = 14
        label.marginEnd = 14
        label.marginTop = 14
        label.marginBottom = 14
        label.hexpand = true
        label.halign = .fill
        label.xalign = 0
        // Inherit makeMarkupLabel's wrap=true default. Character-count
        // padding gives clean column alignment when there's enough
        // horizontal room (the common case); at very narrow widths
        // Pango falls back to word-wrap and columns soften — still
        // readable, just no longer pixel-aligned. The narrow-shrink
        // test relies on this.
        wrapper.append(label)
        return wrapper
    }

    /// Build the Pango-markup string for an entire table. Thin wrapper
    /// over ``tableLayout(headers:rows:alignments:)`` — the layout
    /// function is the single source of truth for the geometry, shared
    /// with the search-highlight offset map so the two never drift.
    private func tableMarkup(headers: [RenderedText], rows: [[RenderedText]], alignments: [RenderedTableAlignment]) -> String {
        Self.tableLayout(headers: headers, rows: rows, alignments: alignments).markup
    }

    /// Pure geometry for a rendered table. Produces, in one pass and
    /// from a single set of column widths:
    ///
    /// - `markup`: the monospace Pango markup the card's `Label` renders
    ///   (headers bold, a muted `─` divider line, per-column alignment).
    /// - `labelPlainText`: exactly what Pango lays out for that markup
    ///   after stripping tags and unescaping entities — the coordinate
    ///   space `labelOffset` indexes into. Every line is `totalWidth`
    ///   `Character`s wide (cells padded to column width, joined by two
    ///   spaces; the divider is `totalWidth` `─` glyphs), so a line's
    ///   start is simply `lineIndex * (totalWidth + 1)`.
    /// - `cells`: per-cell geometry in the SAME order
    ///   ``MarkdownSearchEngine/searchableText(for:)`` emits cells —
    ///   all header cells (row-major), then every body cell using each
    ///   row's REAL cell count (`row` as-is, not padded to
    ///   `columnCount`) — so a `searchableOffset` lines up with the
    ///   match ranges the engine returns even for ragged rows.
    ///
    /// Offsets are `Character` counts throughout (matching how the
    /// widths, the search engine, and `TextAttributes` range helpers
    /// all count), never UTF-8/UTF-16 or markup-string lengths — a cell
    /// rendered from `<b>x</b>` or `a&amp;b` contributes its *plain*
    /// length to the label, so the map must too.
    static func tableLayout(
        headers: [RenderedText],
        rows: [[RenderedText]],
        alignments: [RenderedTableAlignment],
    ) -> (markup: String, labelPlainText: String, cells: [TableCellGeometry]) {
        let columnCount = headers.count
        guard columnCount > 0 else { return ("", "", []) }

        var widths = Array(repeating: 0, count: columnCount)
        for (index, cell) in headers.enumerated() {
            widths[index] = max(widths[index], cell.plainText.count)
        }
        for row in rows {
            for (index, cell) in row.enumerated() where index < columnCount {
                widths[index] = max(widths[index], cell.plainText.count)
            }
        }
        let totalWidth = widths.reduce(0, +) + max(0, columnCount - 1) * 2

        // Leading-pad (number of spaces BEFORE the cell body) for a
        // column, given the cell's plain length. The single formula that
        // both the row renderer and the offset map use, so a cell body's
        // start can never disagree between the two.
        func leadingPad(column: Int, cellLength: Int) -> Int {
            let pad = max(0, widths[column] - cellLength)
            let alignment: RenderedTableAlignment = column < alignments.count ? alignments[column] : .leading
            switch alignment {
            case .leading: return 0
            case .trailing: return pad
            case .center: return pad / 2
            }
        }

        // Character offset of column `column`'s field start within a
        // line: preceding columns' widths plus the two-space joiner.
        func columnFieldStart(_ column: Int) -> Int {
            var start = 0
            for col in 0..<column {
                start += widths[col] + 2
            }
            return start
        }

        func renderRow(_ cells: [RenderedText], bold: Bool) -> (markup: String, plain: String) {
            var markupPieces: [String] = []
            var plainPieces: [String] = []
            markupPieces.reserveCapacity(columnCount)
            plainPieces.reserveCapacity(columnCount)
            for column in 0..<columnCount {
                let cell = column < cells.count ? cells[column] : RenderedText.plain("")
                let pad = max(0, widths[column] - cell.plainText.count)
                let left = leadingPad(column: column, cellLength: cell.plainText.count)
                let right = pad - left
                let body = bold ? "<b>\(cell.markup)</b>" : cell.markup
                let leftSpaces = String(repeating: " ", count: left)
                let rightSpaces = String(repeating: " ", count: right)
                markupPieces.append(leftSpaces + body + rightSpaces)
                plainPieces.append(leftSpaces + cell.plainText + rightSpaces)
            }
            return (markupPieces.joined(separator: "  "), plainPieces.joined(separator: "  "))
        }

        var markupLines: [String] = []
        var plainLines: [String] = []
        markupLines.reserveCapacity(rows.count + 2)
        plainLines.reserveCapacity(rows.count + 2)

        let header = renderRow(headers, bold: true)
        markupLines.append(header.markup)
        plainLines.append(header.plain)
        markupLines.append("<span alpha=\"45%\">\(String(repeating: "─", count: totalWidth))</span>")
        plainLines.append(String(repeating: "─", count: totalWidth))
        for row in rows {
            let rendered = renderRow(row, bold: false)
            markupLines.append(rendered.markup)
            plainLines.append(rendered.plain)
        }

        let markup = "<tt>\(markupLines.joined(separator: "\n"))</tt>"
        let labelPlainText = plainLines.joined(separator: "\n")

        // Every line is `totalWidth` chars + one `\n` join, so a line's
        // start in `labelPlainText` is uniform.
        func lineStart(_ lineIndex: Int) -> Int { lineIndex * (totalWidth + 1) }

        var cells: [TableCellGeometry] = []
        var searchableOffset = 0

        func appendCell(_ cell: RenderedText, column: Int, lineIndex: Int) {
            let length = cell.plainText.count
            let labelOffset: Int? = column < columnCount
                ? lineStart(lineIndex) + columnFieldStart(column) + leadingPad(column: column, cellLength: length)
                : nil
            cells.append(TableCellGeometry(
                searchableOffset: searchableOffset,
                length: length,
                labelOffset: labelOffset,
            ))
            // Searchable string joins every cell — header and body — with
            // a single "\n"; advance past this cell's text and that join.
            searchableOffset += length + 1
        }

        // Header cells occupy label line 0.
        for column in 0..<headers.count {
            appendCell(headers[column], column: column, lineIndex: 0)
        }
        // Body rows start at line 2 (line 1 is the divider). Iterate each
        // row's REAL cells so the searchable order matches the engine's.
        for (rowIndex, row) in rows.enumerated() {
            for column in 0..<row.count {
                appendCell(row[column], column: column, lineIndex: 2 + rowIndex)
            }
        }

        return (markup, labelPlainText, cells)
    }

    private func makeImageBlock(alt: String, source: String?, title: String?, style: ImageBlockStyle) -> Widget {
        switch style {
        case .card:
            return makeCardImageBlock(alt: alt, source: source, title: title)
        case .plain:
            return makePlainImageBlock(alt: alt, source: source, title: title)
        }
    }

    /// Featured-image rendering used when the markdown puts the image in
    /// its own paragraph (blank lines around it). Wraps the picture in a
    /// libadwaita `.card` with a caption underneath.
    private func makeCardImageBlock(alt: String, source: String?, title: String?) -> Widget {
        let wrapper = Box(orientation: .vertical, spacing: 10)
        wrapper.addCSSClass("card")
        wrapper.addCSSClass("preview-image-card")
        wrapper.hexpand = true

        if let image = makeBlockImageWidget(alt: alt, source: source, title: title) {
            wrapper.append(image)
        }

        let label = Label(imageDescription(alt: alt, source: source, title: title))
        label.wrap = true
        label.xalign = 0
        label.addCSSClass(.dimLabel)
        wrapper.append(label)
        return wrapper
    }

    /// Tight, in-flow rendering used when the image lives on its own line
    /// inside a mixed-content paragraph. No card chrome and no caption —
    /// the picture sits in the same column as the surrounding prose so the
    /// transition between text and image stays visually contiguous.
    private func makePlainImageBlock(alt: String, source: String?, title: String?) -> Widget {
        makeBlockImageWidget(alt: alt, source: source, title: title) ?? Box()
    }

    private func makeImageGroup(_ items: [RenderedImageItem], style _: ImageBlockStyle) -> Widget {
        // Image groups (typically badge rows) historically render without
        // any chrome regardless of how the source paragraph framed them,
        // so we accept the style flag for API symmetry but ignore it.
        let row = Box(orientation: .horizontal, spacing: PreviewMetrics.badgeSpacing)
        row.halign = .start
        row.valign = .start
        row.hexpand = false
        row.addCSSClass("preview-image-group")
        for item in items {
            row.append(makeLinkedImageWidget(item))
        }
        return row
    }

    private func makeLinkedImageWidget(_ item: RenderedImageItem) -> Widget {
        let picture = makePictureWidget(
            alt: item.alt,
            source: item.source,
            title: item.title,
            preferredHeight: PreviewMetrics.badgeImageHeight,
            expandsHorizontally: false,
        )

        if let source = item.source,
           let resolved = resolveImageSource(source)
        {
            switch resolved {
            case let .local(localURL):
                PreviewImagePaintableLoader.loadImage(
                    at: localURL,
                    into: picture,
                    preferredHeight: PreviewMetrics.badgeImageHeight,
                    constrainWidthToAspectRatio: true,
                )
            case let .remote(remoteURL):
                remoteImageLoader(remoteURL) { [picture] localURL in
                    guard let localURL else { return }
                    PreviewImagePaintableLoader.loadImage(
                        at: localURL,
                        into: picture,
                        preferredHeight: PreviewMetrics.badgeImageHeight,
                        constrainWidthToAspectRatio: true,
                    )
                }
            }
        }

        if let link = item.linkDestination?.trimmingCharacters(in: .whitespacesAndNewlines),
           !link.isEmpty
        {
            // Wrapping the picture in a `Button` worked but inherited the
            // libadwaita min-height (~30px), which silently capped how
            // large badges could render even when the Picture itself
            // requested more. A plain Box with a `GestureClick` keeps the
            // hit target without imposing size constraints or chrome.
            let wrapper = Box(orientation: .horizontal, spacing: 0)
            wrapper.addCSSClass("preview-image-link")
            wrapper.halign = .start
            wrapper.valign = .center
            wrapper.append(picture)
            wrapper.tooltipText = item.alt.isEmpty ? link : item.alt

            let click = GestureClick()
            click.onReleased { [weak window] _, _, _ in
                let launcher = UriLauncher(uri: link)
                launcher.launch(parent: window)
            }
            wrapper.addController(click)
            return wrapper
        }

        picture.tooltipText = item.alt.isEmpty ? item.plainText : item.alt
        return picture
    }

    private func makeBlockImageWidget(alt: String, source: String?, title: String?) -> Widget? {
        guard let source,
              let resolved = resolveImageSource(source)
        else {
            return nil
        }

        let picture = makePictureWidget(
            alt: alt,
            source: source,
            title: title,
            preferredHeight: nil,
            expandsHorizontally: true,
        )
        picture.tooltipText = imageAlternativeText(alt: alt, source: source, title: title)

        let clamp = Clamp()
        let initialWidth = resolvedBlockImageWidth()
        clamp.maximumSize = initialWidth
        clamp.tighteningThreshold = initialWidth
        clamp.hexpand = true
        clamp.halign = .fill
        clamp.child = picture
        clamp.overflow = .hidden

        switch resolved {
        case let .local(localURL):
            loadBlockImage(at: localURL, into: picture, clamp: clamp)
        case let .remote(remoteURL):
            remoteImageLoader(remoteURL) { [self, picture, clamp] localURL in
                guard let localURL else { return }
                loadBlockImage(at: localURL, into: picture, clamp: clamp)
            }
        }
        return clamp
    }

    private func makePictureWidget(
        alt: String,
        source: String?,
        title: String?,
        preferredHeight: Int?,
        expandsHorizontally: Bool,
    ) -> Picture {
        let picture = Picture()
        picture.alternativeText = imageAlternativeText(alt: alt, source: source, title: title)
        // For badges (preferredHeight set) we must NOT let GTK shrink the
        // Picture below its size request — otherwise a late-arriving
        // image (remote SVG) lands after initial layout already settled
        // on a 0-width allocation and the badge ends up rendered tiny.
        picture.canShrink = preferredHeight == nil
        picture.contentFit = .contain
        picture.hexpand = expandsHorizontally
        picture.vexpand = expandsHorizontally
        picture.halign = expandsHorizontally ? .fill : .start
        picture.valign = expandsHorizontally ? .fill : .center
        if let preferredHeight {
            picture.setSizeRequest(width: -1, height: preferredHeight)
        }
        return picture
    }

    private func loadBlockImage(at localURL: URL, into picture: Picture, clamp: Clamp) {
        if isAnimatedGIF(localURL),
           let player = PreviewAnimatedImagePlayer(
               localURL: localURL,
               picture: picture,
           )
        {
            animatedImagePlayers.append(player)
            updateBlockImageSize(of: picture, clamp: clamp)
            return
        }
        PreviewImagePaintableLoader.loadImage(at: localURL, into: picture) { [weak self, picture, clamp] in
            self?.updateBlockImageSize(of: picture, clamp: clamp)
        }
    }

    private func isAnimatedGIF(_ localURL: URL) -> Bool {
        localURL.pathExtension.caseInsensitiveCompare("gif") == .orderedSame
    }

    private func updateBlockImageSize(of picture: Picture, clamp: Clamp) {
        let availableWidth = resolvedBlockImageWidth()

        let intrinsicWidth: Int
        let intrinsicHeight: Int
        // Prefer the SVG's declared width/height over Picture.intrinsicSize:
        // some GdkPixbuf / glycin SVG loaders return a square default
        // regardless of the `width` and `height` attributes in the XML,
        // which breaks aspect-ratio layout.
        let svgDims: (width: Double, height: Double)? = picture.fileURL
            .flatMap { PreviewImagePaintableLoader.svgDimensions(from: $0) }
        if let svgDims {
            intrinsicWidth = max(Int(svgDims.width.rounded()), 1)
            intrinsicHeight = max(Int(svgDims.height.rounded()), 1)
        } else if let intrinsic = picture.intrinsicSize {
            intrinsicWidth = intrinsic.width
            intrinsicHeight = intrinsic.height
        } else {
            applyClampSize(clamp, targetSize: availableWidth)
            return
        }

        let displayWidth = min(intrinsicWidth, availableWidth)
        let aspectRatio = Double(intrinsicWidth) / Double(intrinsicHeight)
        let displayHeight = max(Int((Double(displayWidth) / aspectRatio).rounded()), 1)

        let clampChanged = applyClampSize(clamp, targetSize: displayWidth)

        // For SVG wrap the picture in an AspectFrame that pins the
        // declared ratio — some GdkPixbuf / glycin SVG loaders report a
        // square intrinsic aspect regardless of the <svg width/height>
        // attributes, which would otherwise make the preview card square.
        // We only insert the frame lazily here (after parsing the XML)
        // to keep raster-image allocation unchanged.
        let pictureChanged: Bool
        if svgDims != nil, clamp.child?.tryCast(AspectFrame.self) == nil {
            let frame = AspectFrame(ratio: Float(aspectRatio), obeyChild: false)
            frame.hexpand = true
            frame.halign = .fill
            clamp.child = nil
            frame.child = picture
            clamp.child = frame
            picture.setSizeRequest(width: -1, height: displayHeight)
            pictureChanged = true
        } else if let frame = clamp.child?.tryCast(AspectFrame.self) {
            let desiredRatio = Float(aspectRatio)
            if abs(frame.ratio - desiredRatio) > 0.001 {
                frame.ratio = desiredRatio
            }
            pictureChanged = picture.sizeRequest.height != displayHeight
            if pictureChanged {
                picture.setSizeRequest(width: -1, height: displayHeight)
            }
        } else {
            pictureChanged = picture.sizeRequest.height != displayHeight
            if pictureChanged {
                picture.setSizeRequest(width: -1, height: displayHeight)
            }
        }

        if clampChanged || pictureChanged {
            clamp.queueResize()
        }
    }

    @discardableResult
    private func applyClampSize(_ clamp: Clamp, targetSize: Int) -> Bool {
        guard clamp.maximumSize != targetSize || clamp.tighteningThreshold != targetSize else {
            return false
        }
        clamp.maximumSize = targetSize
        clamp.tighteningThreshold = targetSize
        return true
    }

    private func imageAlternativeText(alt: String, source: String?, title: String?) -> String {
        if !alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return alt
        }
        if let title,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return title
        }
        if let source,
           !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return source
        }
        return "Image"
    }

    private func imageDescription(alt: String, source: String?, title: String?) -> String {
        let descriptionParts = [alt, title].compactMap { value -> String? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        if descriptionParts.isEmpty {
            return source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Image"
        }
        return descriptionParts.joined(separator: " — ")
    }

    private func makeMarkupLabel(_ markup: String) -> Label {
        let label = Label("")
        label.markup = markup
        label.wrap = true
        label.naturalWrapMode = .word
        label.pangoWrapMode = .wordChar
        label.xalign = 0
        label.justify = .left
        label.selectable = true
        label.onActivateLink { [weak window] uri in
            let launcher = UriLauncher(uri: uri)
            launcher.launch(parent: window)
        }
        return label
    }

    private func resolveImageSource(_ source: String) -> ResolvedImageSource? {
        if let remoteURL = URL(string: source),
           let scheme = remoteURL.scheme?.lowercased(),
           scheme == "http" || scheme == "https"
        {
            return .remote(remoteURL)
        }
        let expanded = (source as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return .local(URL(fileURLWithPath: expanded))
        }
        if let baseDirectory {
            // `URL.path()` returns a percent-encoded string on Swift 6;
            // FileManager.fileExists expects a decoded native path. Notes
            // stored under "My Notes/" (or any folder/filename containing
            // spaces) wouldn't be found here without `percentEncoded: false`
            // — same class of bug as issue #3 / #24.
            let noteLocalURL = baseDirectory.appendingPathComponent(expanded)
            if FileManager.default.fileExists(atPath: noteLocalURL.path(percentEncoded: false)) {
                return .local(noteLocalURL)
            }

            let sharedNotesURL = baseDirectory.deletingLastPathComponent().appendingPathComponent(expanded)
            if baseDirectory.lastPathComponent != "notes",
               FileManager.default.fileExists(atPath: sharedNotesURL.path(percentEncoded: false))
            {
                return .local(sharedNotesURL)
            }
            return .local(noteLocalURL)
        }
        return .local(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded))
    }

    private func resolvedBlockImageWidth() -> Int {
        let horizontalInsets = 2 * 20 + 2 * 14
        let measured = rootScroll.width - horizontalInsets
        if measured > 0 { return measured }
        return max(rootScroll.minContentWidth - horizontalInsets, 1)
    }

    private func refreshBlockImageHeights() {
        let root = rootScroll.child ?? container
        for child in root.children() {
            guard let (clamp, picture) = firstClampWithPicture(in: child) else { continue }
            updateBlockImageSize(of: picture, clamp: clamp)
        }
    }

    private func firstClampWithPicture(in widget: Widget) -> (Clamp, Picture)? {
        if let clamp = widget.tryCast(Clamp.self),
           let picture = firstPicture(in: widget)
        {
            return (clamp, picture)
        }
        for child in widget.children() {
            if let found = firstClampWithPicture(in: child) { return found }
        }
        return nil
    }

    private func firstPicture(in widget: Widget) -> Picture? {
        if let picture = widget.tryCast(Picture.self) {
            return picture
        }
        for child in widget.children() {
            if let picture = firstPicture(in: child) {
                return picture
            }
        }
        return nil
    }
}
