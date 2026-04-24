import Adwaita
import Foundation

@MainActor
final class MarkdownPreview {
    private enum ResolvedImageSource {
        case local(URL)
        case remote(URL)
    }

    let container: Box
    let rootScroll: ScrolledWindow

    private enum PreviewMetrics {
        static let listIndentPerLevel = 10
        static let listMarkerSpacing = 4
        static let badgeImageHeight = 18
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
        margin-top: 0;
        margin-bottom: 0;
    }

    .preview-task-list-row {
        margin-top: 1px;
        margin-bottom: 1px;
    }

    .preview-paragraph-label,
    .preview-blockquote-label {
        line-height: 1.24;
    }

    .preview-nested-list-row {
        margin-top: -7px;
        margin-bottom: 6px;
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

    .preview-image-link-button {
        padding: 0;
        margin: 0;
        min-width: 0;
        min-height: 0;
    }

    .preview-image-group {
        padding: 0;
        margin: 0;
        min-width: 0;
        min-height: 0;
        background: transparent;
    }

    """)

    private var baseDirectory: URL?
    private weak var window: ApplicationWindow?
    private let remoteImageLoader: PreviewRemoteImageLoadHandler
    private var animatedImagePlayers: [PreviewAnimatedImagePlayer] = []
    private var blockImageRefreshTimerID: UInt32?
    private var lastRefreshedPreviewWidth: Int = -1

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
        rootScroll.kineticScrolling = true
        rootScroll.minContentWidth = MainWindow.minimumPreviewWidth
        rootScroll.setAccessibleLabel("Markdown Preview")
        rootScroll.overlayScrolling = false
        rootScroll.onSizeAllocate { [weak self] _, _ in
            self?.scheduleBlockImageRefresh()
        }
    }

    private func scheduleBlockImageRefresh() {
        let width = rootScroll.width
        guard width != lastRefreshedPreviewWidth else { return }
        if let id = blockImageRefreshTimerID {
            MainContext.cancel(sourceId: id)
            blockImageRefreshTimerID = nil
        }
        blockImageRefreshTimerID = MainContext.timeout(every: .milliseconds(120)) { [weak self] in
            guard let self else { return false }
            blockImageRefreshTimerID = nil
            lastRefreshedPreviewWidth = rootScroll.width
            refreshBlockImageHeights()
            return false
        }
    }

    var plainText: String {
        container.children()
            .compactMap(Self.extractPlainText(from:))
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    var debugAnimatedImagePlayerCount: Int {
        animatedImagePlayers.count
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

    func attach(to window: ApplicationWindow) {
        self.window = window
    }

    func render(blocks: [RenderedBlock], baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory
        clear()
        guard !blocks.isEmpty else {
            container.append(makeParagraph(text: .plain("Nothing to preview yet.")))
            return
        }

        var index = 0
        while index < blocks.count {
            let block = blocks[index]
            if case .listItem = block {
                var items: [(text: RenderedText, depth: Int, marker: String)] = []
                while index < blocks.count {
                    guard case let .listItem(text, depth, marker) = blocks[index] else { break }
                    items.append((text, depth, marker))
                    index += 1
                }
                container.append(makeList(items))
                continue
            }

            container.append(makeWidget(for: block))
            index += 1
        }
    }

    private func makeWidget(for block: RenderedBlock) -> Widget {
        switch block {
        case let .heading(level, text):
            makeHeading(level: level, text: text)
        case let .paragraph(text):
            makeParagraph(text: text)
        case let .codeBlock(code, language):
            makeCodeBlock(code: code, language: language)
        case let .blockquote(text):
            makeBlockquote(text: text)
        case .listItem:
            Box()
        case .thematicBreak:
            makeSeparator()
        case let .table(headers, rows, alignments):
            makeTable(headers: headers, rows: rows, alignments: alignments)
        case let .image(alt, source, title):
            makeImageBlock(alt: alt, source: source, title: title)
        case let .imageGroup(items):
            makeImageGroup(items)
        }
    }

    private func clear() {
        for player in animatedImagePlayers {
            player.stop()
        }
        animatedImagePlayers.removeAll()
        for child in container.children() {
            child.visible = false
            container.remove(child)
        }
    }

    private func makeHeading(level: Int, text: RenderedText) -> Label {
        let label = makeMarkupLabel(text.markup)
        switch level {
        case 1:
            label.addCSSClass(.title1)
            label.marginBottom = 2
        case 2:
            label.addCSSClass(.title2)
        default:
            label.addCSSClass(.title3)
        }
        label.setMargins(0)
        return label
    }

    private func makeParagraph(text: RenderedText) -> Label {
        let label = makeMarkupLabel(text.markup)
        label.addCSSClass("preview-paragraph-label")
        label.selectable = true
        return label
    }

    private func makeCodeBlock(code: String, language: String?) -> Widget {
        let outer = Box(orientation: .vertical, spacing: 0)
        outer.addCSSClass("card")
        outer.addCSSClass("preview-code-block")
        outer.hexpand = true
        outer.halign = .fill
        outer.overflow = .hidden

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
        overlay.child = inner
        overlay.addOverlay(makeCodeBlockCopyButton(for: code))

        outer.append(overlay)
        return outer
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
        case "sh", "shell", "zsh": "sh"
        case "cpp", "cxx", "c++", "hpp", "hxx": "cpp"
        case "cs": "csharp"
        case "yml": "yaml"
        case "md": "markdown"
        case "rs": "rust"
        case "kt": "kotlin"
        case "": nil
        default: rawID
        }
    }

    private func makeCodeBlockCopyButton(for code: String) -> Button {
        let button = Button(label: "Copy")
        button.addCSSClass("osd")
        button.addCSSClass("preview-code-copy")
        button.halign = .end
        button.valign = .start
        button.marginTop = 8
        button.marginEnd = 8
        button.tooltipText = "Copy code to clipboard"
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
            button.label = "Copied"
            MainContext.task(after: .seconds(1)) { [weak button] in
                button?.label = "Copy"
            }
        }
        return button
    }

    private func makeBlockquote(text: RenderedText) -> Widget {
        let row = Box(orientation: .horizontal, spacing: 12)
        row.marginStart = 4
        row.marginEnd = 4

        let accent = Separator(orientation: .vertical)
        accent.marginTop = 2
        accent.marginBottom = 2

        let content = Box(orientation: .vertical, spacing: 6)
        let label = makeMarkupLabel(text.markup)
        label.addCSSClass("preview-blockquote-label")
        label.addCSSClass(.dimLabel)
        label.selectable = true
        content.append(label)

        row.append(accent)
        row.append(content)
        return row
    }

    private func makeList(_ items: [(text: RenderedText, depth: Int, marker: String)]) -> Widget {
        let list = Box(orientation: .vertical, spacing: 0)
        for item in items {
            list.append(makeListItem(
                text: item.text,
                depth: item.depth,
                marker: item.marker,
                compact: !isTaskListMarker(item.marker),
            ))
        }
        return list
    }

    private func makeListItem(text: RenderedText, depth: Int, marker: String, compact: Bool) -> Widget {
        let row = Box(orientation: .horizontal, spacing: PreviewMetrics.listMarkerSpacing)
        row.marginStart = PreviewMetrics.listIndentPerLevel * depth
        row.addCSSClass("preview-list-row")
        row.addCSSClass(compact ? "preview-compact-list-row" : "preview-task-list-row")
        if depth > 0 {
            row.addCSSClass("preview-nested-list-row")
        }

        let markerLabel = Label(displayMarker(for: marker, depth: depth))
        markerLabel.xalign = 0
        markerLabel.yalign = 0
        markerLabel.valign = .start
        markerLabel.addCSSClass(.dimLabel)
        markerLabel.addCSSClass(compact ? "preview-compact-list-marker" : "preview-task-list-marker")
        markerLabel.widthChars = markerWidth(for: marker)

        let content = makeMarkupLabel(text.markup)
        content.selectable = true
        content.hexpand = true
        content.yalign = 0
        content.valign = .start
        content.addCSSClass(compact ? "preview-compact-list-label" : "preview-task-list-label")
        content.setMargins(0)

        row.append(markerLabel)
        row.append(content)
        return row
    }

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

    private func makeImageBlock(alt: String, source: String?, title: String?) -> Widget {
        let wrapper = Box(orientation: .vertical, spacing: 0)
        wrapper.addCSSClass("card")

        let inner = Box(orientation: .vertical, spacing: 10)
        inner.setMargins(14)
        inner.hexpand = true

        if let image = makeBlockImageWidget(alt: alt, source: source, title: title) {
            inner.append(image)
        }

        let label = Label(imageDescription(alt: alt, source: source, title: title))
        label.wrap = true
        label.xalign = 0
        label.addCSSClass(.dimLabel)
        inner.append(label)

        wrapper.append(inner)
        return wrapper
    }

    private func makeImageGroup(_ items: [RenderedImageItem]) -> Widget {
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
            let button = Button(label: "")
            button.hasFrame = false
            button.addCSSClass(.flat)
            button.addCSSClass("preview-image-link-button")
            button.halign = .start
            button.valign = .center
            button.child = picture
            button.tooltipText = item.alt.isEmpty ? link : item.alt
            button.onClicked { [weak window] in
                let launcher = UriLauncher(uri: link)
                launcher.launch(parent: window)
            }
            return button
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
        picture.canShrink = true
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
            let noteLocalURL = baseDirectory.appendingPathComponent(expanded)
            if FileManager.default.fileExists(atPath: noteLocalURL.path()) {
                return .local(noteLocalURL)
            }

            let sharedNotesURL = baseDirectory.deletingLastPathComponent().appendingPathComponent(expanded)
            if baseDirectory.lastPathComponent != "notes",
               FileManager.default.fileExists(atPath: sharedNotesURL.path())
            {
                return .local(sharedNotesURL)
            }
            return .local(noteLocalURL)
        }
        return .local(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded))
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

    private func refreshBlockImageHeights() {
        for child in container.children() {
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

    private func resolvedBlockImageWidth() -> Int {
        let horizontalInsets = 2 * 20 + 2 * 14
        let measured = rootScroll.width - horizontalInsets
        if measured > 0 { return measured }
        return max(rootScroll.minContentWidth - horizontalInsets, 1)
    }
}
