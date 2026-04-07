import Adwaita
import CAdwaita
import Foundation

@MainActor
final class MarkdownPreview {
    let container: Box
    let rootScroll: ScrolledWindow

    private static let previewCSS = CSSProvider.loadGlobal("""
    .preview-list-row,
    .preview-list-label,
    .preview-list-marker {
        margin-top: 0;
        margin-bottom: 0;
        padding-top: 0;
        padding-bottom: 0;
        min-height: 0;
    }

    .preview-task-list-label,
    .preview-task-list-marker {
        line-height: 0.88;
    }

    .preview-compact-list-label,
    .preview-compact-list-marker {
        line-height: 0.45;
    }

    """)

    private var baseDirectory: URL?
    private weak var window: ApplicationWindow?

    init() {
        _ = Self.previewCSS
        container = Box(orientation: .vertical, spacing: 20)
        container.setMargins(20)
        container.vexpand = true

        rootScroll = ScrolledWindow(child: container)
        rootScroll.setPolicy(horizontal: .never, vertical: .automatic)
        rootScroll.kineticScrolling = true
        rootScroll.minContentWidth = MainWindow.minimumPreviewWidth
    }

    var plainText: String {
        container.children()
            .compactMap(Self.extractPlainText(from:))
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func extractPlainText(from widget: Widget) -> String? {
        let instance = widget.pointer.assumingMemoryBound(to: GTypeInstance.self)
        if g_type_check_instance_is_a(instance, gtk_label_get_type()) != 0 {
            return Label(borrowing: widget.pointer).text
        }
        if g_type_check_instance_is_a(instance, gtk_picture_get_type()) != 0 {
            return Picture(borrowing: widget.pointer).alternativeText
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
            return makeHeading(level: level, text: text)
        case let .paragraph(text):
            return makeParagraph(text: text)
        case let .codeBlock(code, language):
            return makeCodeBlock(code: code, language: language)
        case let .blockquote(text):
            return makeBlockquote(text: text)
        case .listItem:
            return Box()
        case .thematicBreak:
            return makeSeparator()
        case let .table(headers, rows, alignments):
            return makeTable(headers: headers, rows: rows, alignments: alignments)
        case let .image(alt, source, title):
            return makeImageBlock(alt: alt, source: source, title: title)
        }
    }

    private func clear() {
        for child in container.children() {
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
        label.selectable = true
        return label
    }

    private func makeCodeBlock(code: String, language: String?) -> Widget {
        let outer = Box(orientation: .vertical, spacing: 0)
        outer.addCSSClass("card")

        let inner = Box(orientation: .vertical, spacing: 10)
        inner.setMargins(14)

        if let language, !language.isEmpty {
            let badge = Label(language.uppercased())
            badge.addCSSClass(.dimLabel)
            badge.addCSSClass("monospace")
            badge.xalign = 0
            inner.append(badge)
        }

        let codeLabel = Label(code)
        codeLabel.selectable = true
        codeLabel.wrap = true
        codeLabel.xalign = 0
        codeLabel.addCSSClass("monospace")
        inner.append(codeLabel)

        outer.append(inner)
        return outer
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
        label.addCSSClass(.dimLabel)
        label.selectable = true
        content.append(label)

        row.append(accent)
        row.append(content)
        return row
    }

    private func makeList(_ items: [(text: RenderedText, depth: Int, marker: String)]) -> Widget {
        guard let first = items.first else { return Box() }
        var index = 0
        return makeListLevel(items, index: &index, depth: first.depth)
    }

    private func makeListItem(text: RenderedText, depth: Int, marker: String, compact: Bool) -> Widget {
        let row = Box(orientation: .horizontal, spacing: 8)
        row.marginStart = 16 * depth
        row.addCSSClass("preview-list-row")

        let markerLabel = Label(displayMarker(for: marker, depth: depth))
        markerLabel.xalign = 0
        markerLabel.yalign = 0
        markerLabel.valign = .start
        markerLabel.addCSSClass(.dimLabel)
        markerLabel.addCSSClass(compact ? "preview-compact-list-marker" : "preview-task-list-marker")
        markerLabel.widthChars = max(marker.count, 2)

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

    private func makeListLevel(
        _ items: [(text: RenderedText, depth: Int, marker: String)],
        index: inout Int,
        depth: Int
    ) -> Box {
        let list = Box(orientation: .vertical, spacing: 0)

        while index < items.count {
            let item = items[index]
            if item.depth < depth {
                break
            }
            if item.depth > depth {
                let nested = makeListLevel(items, index: &index, depth: item.depth)
                nested.marginTop = 0
                nested.marginBottom = 0
                list.append(nested)
                continue
            }

            let itemContainer = Box(orientation: .vertical, spacing: 0)
            itemContainer.marginTop = 0
            itemContainer.marginBottom = 0
            itemContainer.append(makeListItem(
                text: item.text,
                depth: item.depth,
                marker: item.marker,
                compact: !isTaskListMarker(item.marker)
            ))
            index += 1

            if index < items.count, items[index].depth > depth {
                let nested = makeListLevel(items, index: &index, depth: items[index].depth)
                nested.marginTop = 0
                nested.marginBottom = 8
                itemContainer.append(nested)
            }

            list.append(itemContainer)
        }

        return list
    }

    private func displayMarker(for marker: String, depth: Int) -> String {
        switch marker {
        case "[x]":
            return "☑"
        case "[ ]":
            return "☐"
        case "-":
            return depth == 0 ? "•" : "◦"
        default:
            return marker
        }
    }

    private func isTaskListMarker(_ marker: String) -> Bool {
        marker == "[x]" || marker == "[ ]"
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

        let inner = Box(orientation: .vertical, spacing: 10)
        inner.setMargins(14)

        let grid = Grid(columnSpacing: 18, rowSpacing: 10)
        grid.columnHomogeneous = false

        for (column, header) in headers.enumerated() {
            let label = makeMarkupLabel("<b>\(header.markup)</b>")
            applyAlignment(label, alignments: alignments, column: column)
            grid.attach(label, column: column, row: 0)
        }

        for (rowIndex, row) in rows.enumerated() {
            for (column, cell) in row.enumerated() {
                let label = makeMarkupLabel(cell.markup)
                label.selectable = true
                applyAlignment(label, alignments: alignments, column: column)
                grid.attach(label, column: column, row: rowIndex + 1)
            }
        }

        inner.append(grid)
        wrapper.append(inner)
        return wrapper
    }

    private func makeImageBlock(alt: String, source: String?, title: String?) -> Widget {
        let wrapper = Box(orientation: .vertical, spacing: 0)
        wrapper.addCSSClass("card")

        let inner = Box(orientation: .vertical, spacing: 10)
        inner.setMargins(14)

        let description = [alt, title, source].compactMap { value -> String? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }.joined(separator: " — ")

        if let source,
           let resolved = resolveImageSource(source),
           let texture = Texture(filename: resolved.path) {
            let picture = Picture()
            picture.setPaintable(texture)
            picture.alternativeText = alt.isEmpty ? (title ?? source) : alt
            picture.canShrink = true
            picture.contentFit = .contain
            picture.setSizeRequest(height: 260)
            inner.append(picture)
        }

        let label = Label(description.isEmpty ? "Image" : description)
        label.wrap = true
        label.xalign = 0
        label.addCSSClass(.dimLabel)
        inner.append(label)

        wrapper.append(inner)
        return wrapper
    }

    private func makeMarkupLabel(_ markup: String) -> Label {
        let label = Label("")
        label.markup = markup
        label.wrap = true
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

    private func resolveImageSource(_ source: String) -> URL? {
        if source.hasPrefix("http://") || source.hasPrefix("https://") {
            return nil
        }
        let expanded = (source as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        if let baseDirectory {
            return baseDirectory.appendingPathComponent(expanded)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded)
    }
}
