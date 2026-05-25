import Adwaita
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

    .preview-table-header {
        margin-top: 0;
        margin-bottom: 0;
        padding-bottom: 4px;
    }

    .preview-table-cell {
        margin-top: 0;
        margin-bottom: 0;
        padding-top: 3px;
        padding-bottom: 3px;
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
                headingBlockToRowIndex[index] = runStartRow
                var segments: [RichTextSegment] = [.heading(level: level, text: text)]
                index += 1
                while index < blocks.count, case let .paragraph(pText) = blocks[index] {
                    segments.append(.paragraph(text: pText))
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
                } else {
                    rows.append(.richTextRun(segments))
                }
                continue
            }

            if case .listItem = block {
                var items: [ListPreviewItem] = []
                while index < blocks.count {
                    guard case let .listItem(text, depth, marker, loose, taskIndex) = blocks[index] else { break }
                    items.append((text, depth, marker, loose, taskIndex))
                    index += 1
                }
                rows.append(.list(items: items))
                continue
            }

            if let textRun = makeTextRun(from: blocks, startingAt: &index) {
                rows.append(textRun)
                continue
            }

            rows.append(makeRow(for: block))
            index += 1
        }
        return rows
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
        let wrapper = Box(orientation: .vertical, spacing: 0)
        wrapper.addCSSClass("card")
        wrapper.addCSSClass("preview-table-card")
        wrapper.hexpand = true
        wrapper.vexpand = false
        wrapper.halign = .fill
        wrapper.valign = .start
        wrapper.overflow = .hidden

        let inner = Box(orientation: .vertical, spacing: 10)
        inner.setMargins(14)
        inner.hexpand = true
        inner.vexpand = false
        inner.halign = .fill
        inner.valign = .start

        let grid = Grid(columnSpacing: 18, rowSpacing: 6)
        grid.columnHomogeneous = false
        grid.hexpand = true
        grid.vexpand = false
        grid.halign = .fill
        grid.valign = .start

        for (column, header) in headers.enumerated() {
            let label = makeMarkupLabel("<b>\(header.markup)</b>")
            label.addCSSClass("preview-table-header")
            applyTableCellWrapping(label)
            applyAlignment(label, alignments: alignments, column: column)
            grid.attach(label, column: column, row: 0)
        }

        let separator = Separator()
        separator.marginTop = 0
        separator.marginBottom = 4
        grid.attach(separator, column: 0, row: 1, width: max(headers.count, 1))

        for (rowIndex, row) in rows.enumerated() {
            for (column, cell) in row.enumerated() {
                let label = makeMarkupLabel(cell.markup)
                label.selectable = true
                label.addCSSClass("preview-table-cell")
                applyTableCellWrapping(label)
                applyAlignment(label, alignments: alignments, column: column)
                grid.attach(label, column: column, row: rowIndex + 2)
            }
        }

        inner.append(grid)
        wrapper.append(inner)
        return wrapper
    }

    private func applyTableCellWrapping(_ label: Label) {
        label.maxWidthChars = 40
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

    private func applyAlignment(_ label: Label, alignments: [RenderedTableAlignment], column: Int) {
        guard column < alignments.count else {
            label.xalign = 0
            return
        }
        switch alignments[column] {
        case .leading:
            label.xalign = 0
            label.justify = .left
        case .center:
            label.xalign = 0.5
            label.justify = .center
        case .trailing:
            label.xalign = 1
            label.justify = .right
        }
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
