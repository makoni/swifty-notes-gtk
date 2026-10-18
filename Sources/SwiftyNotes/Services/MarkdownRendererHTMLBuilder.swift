import Adwaita
import Foundation
import Markdown

final class HTMLPreviewDocumentBuilder {
    let darkAppearance: Bool
    /// When true, `:shortcode:` emoji aliases are substituted in body text
    /// (never inside code spans / code blocks). Threaded down to the inline
    /// text builder so it can skip substitution while descending into code.
    let renderEmojiShortcodes: Bool

    /// Per-item metadata recovered from the source markdown in
    /// document order. Order matches `HTMLFormatter`'s depth-first
    /// `<li>` emission so the HTML processor can pop one entry per
    /// list item it walks.
    ///
    /// - `loose`: this specific item is preceded by a blank line in
    ///   its list, so the preview should add paragraph-style top
    ///   spacing. The flag is per-item — not per-list — so contiguous
    ///   tight runs stay together while only blank-separated items
    ///   push apart.
    /// - `ordinalRestart`: only set on ordered-list items that follow
    ///   a blank line and re-state an explicit number. CommonMark
    ///   merges `1. a\n2. b\n\n1. c` into one list with auto-numbered
    ///   `1, 2, 3` — but the author's `1.` after the blank is a clear
    ///   intent to start a fresh logical group, so we honour it by
    ///   resetting the visual ordinal to that value.
    private struct ListItemMeta {
        let loose: Bool
        let ordinalRestart: Int?
    }

    private var listItemMetadata: [ListItemMeta] = []
    private var listItemMetadataCursor = 0
    /// Math spans cut out of the source before parsing; the placeholders
    /// survive the HTML pass and are restored by ``restoringMathSpans``.
    private var mathSpans: [MathSpan] = []

    init(darkAppearance: Bool, renderEmojiShortcodes: Bool = true) {
        self.darkAppearance = darkAppearance
        self.renderEmojiShortcodes = renderEmojiShortcodes
    }

    func render(markdown: String) -> [RenderedBlock] {
        // Math must be cut out before any Markdown processing: CommonMark
        // mangles TeX (`$x^*$` emphasis, `\{` → `{`, `\\` → `\`). The
        // extracted source keeps its line structure, so the line-based
        // scanners below (task lists, list metadata) still line up.
        let extraction = MathSpanExtractor.extract(from: markdown)
        let source = extraction.markdown
        mathSpans = extraction.spans
        listItemMetadata = collectListItemMetadata(from: source)
        listItemMetadataCursor = 0
        let html = HTMLFormatter.format(source)
        let nodes = HTMLSubsetParser().parse(html)
        let rendered = assigningTaskIndices(
            in: restoringMathSpans(
                in: restoringImageMetadata(
                    in: restoringTaskListMarkers(in: blocks(from: nodes, listDepth: 0), markdown: source),
                    markdown: source,
                ),
            ),
        )
        if rendered.isEmpty, source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [.paragraph(.plain("Nothing to preview yet.".localized))]
        }
        return rendered
    }

    /// Walks the rendered blocks once and stamps a 0-based
    /// document-order index onto each task item (`[ ]` / `[x]`).
    /// The index is what the preview's checkbox click handler hands
    /// to ``TaskListToggle`` so the right `[ ]` ↔ `[x]` flips in the
    /// source. Non-task list items keep `taskIndex == nil`.
    private func assigningTaskIndices(in blocks: [RenderedBlock]) -> [RenderedBlock] {
        var counter = 0
        return blocks.map { block in
            guard case let .listItem(text, depth, marker, loose, _) = block,
                  marker == "[ ]" || marker == "[x]"
            else { return block }
            let stamped = RenderedBlock.listItem(
                text: text,
                depth: depth,
                marker: marker,
                loose: loose,
                taskIndex: counter,
            )
            counter += 1
            return stamped
        }
    }

    /// Walks the source markdown and emits one ``ListItemMeta`` per
    /// list item in document order. See ``listItemMetadata`` for what
    /// each field carries.
    private func collectListItemMetadata(from markdown: String) -> [ListItemMeta] {
        struct OpenList {
            let indent: Int
            var sawBlank: Bool
        }
        var results: [ListItemMeta] = []
        var stack: [OpenList] = []
        for line in markdown.components(separatedBy: "\n") {
            let leading = Self.leadingSpaceWidth(of: line)
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.isEmpty {
                for i in stack.indices {
                    stack[i].sawBlank = true
                }
                continue
            }
            if let marker = Self.parseListMarker(trimmed) {
                while let top = stack.last, top.indent > leading {
                    stack.removeLast()
                }
                if let top = stack.last, top.indent == leading {
                    let loose = top.sawBlank
                    let restart: Int? = {
                        // An explicit ordered marker after a blank
                        // line within the same list means the author
                        // is restarting the count — usually `1.`, but
                        // honour any explicit number they typed.
                        guard loose, case let .ordered(number) = marker else { return nil }
                        return number
                    }()
                    results.append(ListItemMeta(loose: loose, ordinalRestart: restart))
                    stack[stack.count - 1].sawBlank = false
                } else {
                    results.append(ListItemMeta(loose: false, ordinalRestart: nil))
                    stack.append(OpenList(indent: leading, sawBlank: false))
                }
            } else if leading <= (stack.last?.indent ?? Int.max) {
                while let top = stack.last, top.indent >= leading {
                    stack.removeLast()
                }
            }
        }
        return results
    }

    private static func leadingSpaceWidth(of line: String) -> Int {
        var count = 0
        for char in line {
            if char == " " {
                count += 1
            } else if char == "\t" {
                count += 4
            } else {
                break
            }
        }
        return count
    }

    private enum SourceListMarker {
        case bullet
        case ordered(Int)
    }

    private static func parseListMarker(_ trimmed: Substring) -> SourceListMarker? {
        if let first = trimmed.first, first == "-" || first == "*" || first == "+" {
            let next = trimmed.index(after: trimmed.startIndex)
            if next == trimmed.endIndex { return nil }
            return trimmed[next] == " " ? .bullet : nil
        }
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index].isNumber {
            index = trimmed.index(after: index)
        }
        guard index != trimmed.startIndex, index < trimmed.endIndex else { return nil }
        let punct = trimmed[index]
        guard punct == "." || punct == ")" else { return nil }
        let afterPunct = trimmed.index(after: index)
        guard afterPunct < trimmed.endIndex, trimmed[afterPunct] == " " else { return nil }
        return Int(String(trimmed[trimmed.startIndex..<index])).map { .ordered($0) }
    }

    private func consumeNextListItemMetadata() -> ListItemMeta {
        guard listItemMetadataCursor < listItemMetadata.count else {
            return ListItemMeta(loose: false, ordinalRestart: nil)
        }
        let value = listItemMetadata[listItemMetadataCursor]
        listItemMetadataCursor += 1
        return value
    }

    func blocks(from nodes: [HTMLNode], listDepth: Int) -> [RenderedBlock] {
        nodes.flatMap { block(from: $0, listDepth: listDepth) }
    }

    func block(from node: HTMLNode, listDepth: Int) -> [RenderedBlock] {
        switch node.kind {
        case let .text(text):
            let rendered = renderEmojiShortcodes ? EmojiShortcodes.render(text) : text
            return rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.paragraph(.plain(rendered))]
        case let .element(name, attributes, children):
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(String(name.dropFirst())) ?? 1
                return [.heading(level: level, text: inlineText(from: children))]
            case "p":
                // Pure-image paragraphs (the author put blank lines around
                // the image / image group): keep the existing card styling.
                if let imageGroup = standaloneImageGroup(from: children) {
                    if imageGroup.count == 1, imageGroup[0].linkDestination == nil {
                        let image = imageGroup[0]
                        return [.image(alt: image.alt, source: image.source, title: image.title, style: .card)]
                    }
                    return [.imageGroup(items: imageGroup, style: .card)]
                }
                if let image = standaloneImage(from: children) {
                    return [.image(alt: image.alt, source: image.source, title: image.title, style: .card)]
                }
                // Mixed content: an image-only line glued onto a paragraph
                // (no blank line) is parsed by CommonMark as inline. Promote
                // each image-only line into its own plain block image so it
                // renders properly instead of falling back to the
                // [Image: …] placeholder. Surrounding text lines coalesce
                // back into paragraphs.
                if let segmented = segmentParagraphIfImagesPresent(children: children) {
                    return segmented
                }
                let text = inlineText(from: children)
                return text.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.paragraph(text)]
            case "blockquote", "aside":
                let nestedBlocks = blocks(from: children, listDepth: listDepth)
                let quoteText = blockText(from: nestedBlocks)
                return quoteText.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.blockquote(quoteText)]
            case "pre":
                let codeNode = children.first(where: { $0.name == "code" })
                let code = textContent(of: codeNode?.children ?? children)
                let language = codeNode?.attributes["class"]?
                    .split(separator: " ")
                    .first(where: { $0.hasPrefix("language-") })
                    .map { String($0.dropFirst("language-".count)) }
                return [.codeBlock(code: code, language: language)]
            case "ul":
                return listBlocks(from: children, listDepth: listDepth, ordered: false, startIndex: 1)
            case "ol":
                let start = Int(attributes["start"] ?? "") ?? 1
                return listBlocks(from: children, listDepth: listDepth, ordered: true, startIndex: start)
            case "table":
                return tableBlock(from: children)
            case "hr":
                return [.thematicBreak]
            case "img":
                return [.image(
                    alt: attributes["alt"] ?? "",
                    source: attributes["src"],
                    title: attributes["title"],
                )]
            case "a":
                if let linkedImage = renderedImageItem(from: node) {
                    return [.imageGroup(items: [linkedImage])]
                }
                return blocks(from: children, listDepth: listDepth)
            default:
                return blocks(from: children, listDepth: listDepth)
            }
        }
    }

    func listBlocks(from nodes: [HTMLNode], listDepth: Int, ordered: Bool, startIndex: Int) -> [RenderedBlock] {
        var output: [RenderedBlock] = []
        var ordinal = startIndex

        for node in nodes where node.name == "li" {
            // Pop the per-item metadata in source order so each
            // `<li>` emitted by HTMLFormatter aligns with the
            // corresponding line in the source scan.
            let meta = consumeNextListItemMetadata()
            if let restart = meta.ordinalRestart {
                ordinal = restart
            }
            let itemIsLoose = meta.loose
            let checkboxNode = firstCheckboxNode(in: node.children)

            let checkboxMarker: String? = if let checkboxNode {
                checkboxNode.attributes.keys.contains("checked") ? "[x]" : "[ ]"
            } else {
                nil
            }

            let contentNodes = node.children.filter { child in
                !(child.name == "input" && child.attributes["type"] == "checkbox")
            }

            var inlineNodes: [HTMLNode] = []
            var nestedBlocks: [RenderedBlock] = []

            for child in contentNodes {
                switch child.name {
                case "p":
                    if inlineNodes.isEmpty {
                        inlineNodes = child.children
                    } else {
                        nestedBlocks.append(contentsOf: block(from: child, listDepth: listDepth + 1))
                    }
                case "ul":
                    nestedBlocks.append(contentsOf: listBlocks(from: child.children, listDepth: listDepth + 1, ordered: false, startIndex: 1))
                case "ol":
                    let nestedStart = Int(child.attributes["start"] ?? "") ?? 1
                    nestedBlocks.append(contentsOf: listBlocks(from: child.children, listDepth: listDepth + 1, ordered: true, startIndex: nestedStart))
                case nil:
                    // Skip pure-whitespace text nodes between sibling
                    // elements (e.g. the space `<input/>` inserts after
                    // itself in a task-list `<li>`). Letting them into
                    // inlineNodes blocks the `<p>`-as-first-paragraph
                    // shortcut above and pushes task-item content into
                    // the nested-block path, which loses the per-item
                    // `loose` flag.
                    if case let .text(text) = child.kind,
                       text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        break
                    }
                    inlineNodes.append(child)
                default:
                    if nestedBlocks.isEmpty, inlineNodes.isEmpty {
                        nestedBlocks.append(contentsOf: block(from: child, listDepth: listDepth + 1))
                    } else {
                        nestedBlocks.append(contentsOf: block(from: child, listDepth: listDepth + 1))
                    }
                }
            }

            if inlineNodes.isEmpty, nestedBlocks.isEmpty {
                inlineNodes = contentNodes
            }

            let marker: String = if let checkboxMarker {
                checkboxMarker
            } else if ordered {
                "\(ordinal)."
            } else {
                "-"
            }

            // Trim the trailing whitespace/newline that swift-markdown's
            // HTMLFormatter leaves on tight `<li>foo\n</li>` text nodes —
            // an unstripped `\n` makes a wrapping Pango label render a
            // spurious empty second line, which doubles the row height
            // and is what made every bullet list look "loose" in the
            // preview. List item text is always inline content, so a
            // bilateral whitespace trim is safe here.
            let rawText = inlineText(from: inlineNodes)
            let trimmed = RenderedText(
                markup: rawText.markup.trimmingCharacters(in: .whitespacesAndNewlines),
                plainText: rawText.plainText.trimmingCharacters(in: .whitespacesAndNewlines),
            )
            if !trimmed.plainText.isEmpty {
                output.append(.listItem(text: trimmed, depth: listDepth, marker: marker, loose: itemIsLoose))
            }
            output.append(contentsOf: nestedBlocks)
            ordinal += 1
        }

        return output
    }

    func tableBlock(from nodes: [HTMLNode]) -> [RenderedBlock] {
        guard let headNode = nodes.first(where: { $0.name == "thead" }) else { return [] }
        let bodyNode = nodes.first(where: { $0.name == "tbody" })
        let headRow = headNode.children.first(where: { $0.name == "tr" })
        let headerCells = headRow?.children.filter { $0.name == "th" || $0.name == "td" } ?? []
        let headers = headerCells.map { inlineText(from: $0.children) }
        let alignments = headerCells.map { cell -> RenderedTableAlignment in
            switch cell.attributes["align"]?.lowercased() {
            case "right":
                .trailing
            case "center":
                .center
            default:
                .leading
            }
        }

        let rows: [[RenderedText]] = (bodyNode?.children ?? [])
            .filter { $0.name == "tr" }
            .map { row in
                row.children
                    .filter { $0.name == "th" || $0.name == "td" }
                    .map { inlineText(from: $0.children) }
            }

        return headers.isEmpty && rows.isEmpty ? [] : [.table(headers: headers, rows: rows, alignments: alignments)]
    }

    /// Splits a paragraph's children into a heterogeneous block sequence
    /// when it contains any image. Pango can't draw images inside a Label
    /// run, so an image embedded in a paragraph would otherwise fall back
    /// to a `[Image: …]` placeholder. This routine pulls every image (or
    /// run of consecutive images) out into its own block and renders the
    /// surrounding text as paragraphs.
    ///
    /// Two layers of segmentation:
    /// 1. The paragraph is first split by `\n` into visible lines, so an
    ///    image that lives on its own line in the source markdown stays a
    ///    standalone block — never merged with images on a different line.
    /// 2. Inside each line we then walk node-by-node, splitting into
    ///    text-runs and image-runs. Consecutive images (separated only by
    ///    whitespace) coalesce into a single `.imageGroup` so badge rows
    ///    stay laid out horizontally instead of stacking vertically.
    ///
    /// Returns `nil` for paragraphs that contain no images at all — the
    /// caller falls back to the standard text-paragraph rendering.
    func segmentParagraphIfImagesPresent(children: [HTMLNode]) -> [RenderedBlock]? {
        let lines = paragraphLines(from: children)
        let hasImage = lines.contains { line in
            line.contains { renderedImageItem(from: $0) != nil }
        }
        guard hasImage else { return nil }

        var result: [RenderedBlock] = []
        var textBuffer: [HTMLNode] = []

        func flushText() {
            guard !textBuffer.isEmpty else { return }
            let text = inlineText(from: textBuffer)
            textBuffer.removeAll(keepingCapacity: true)
            if !text.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.paragraph(text))
            }
        }

        for (lineIndex, line) in lines.enumerated() {
            for run in splitLineByImageRuns(line) {
                switch run {
                case let .text(nodes):
                    if !textBuffer.isEmpty, lineIndex > 0 {
                        textBuffer.append(.text("\n"))
                    }
                    textBuffer.append(contentsOf: nodes)
                case let .images(items):
                    flushText()
                    if items.count == 1, items[0].linkDestination == nil {
                        let item = items[0]
                        result.append(.image(
                            alt: item.alt,
                            source: item.source,
                            title: item.title,
                            style: .plain,
                        ))
                    } else {
                        result.append(.imageGroup(items: items, style: .plain))
                    }
                }
            }
        }
        flushText()

        return result
    }

    private enum LineRun {
        case text(nodes: [HTMLNode])
        case images(items: [RenderedImageItem])
    }

    /// Walks the nodes of a single line and groups them into runs of
    /// either consecutive text (+ non-image inline elements like `<strong>`)
    /// or consecutive images. Whitespace text nodes that sit *between
    /// images* are treated as inter-image padding and dropped, so badge
    /// rows like `<a><img></a> <a><img></a>` form one image-run instead
    /// of being torn apart by the literal space between them.
    private func splitLineByImageRuns(_ line: [HTMLNode]) -> [LineRun] {
        var runs: [LineRun] = []
        var textNodes: [HTMLNode] = []
        var imageItems: [RenderedImageItem] = []
        var pendingWhitespace: [HTMLNode] = []

        func flushText() {
            guard !textNodes.isEmpty else { return }
            runs.append(.text(nodes: textNodes))
            textNodes.removeAll(keepingCapacity: true)
        }

        func flushImages() {
            guard !imageItems.isEmpty else { return }
            runs.append(.images(items: imageItems))
            imageItems.removeAll(keepingCapacity: true)
        }

        for node in line {
            if let item = renderedImageItem(from: node) {
                flushText()
                pendingWhitespace.removeAll(keepingCapacity: true)
                imageItems.append(item)
            } else if case let .text(text) = node.kind,
                      text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                pendingWhitespace.append(node)
            } else {
                flushImages()
                textNodes.append(contentsOf: pendingWhitespace)
                pendingWhitespace.removeAll(keepingCapacity: true)
                textNodes.append(node)
            }
        }
        if !textNodes.isEmpty {
            textNodes.append(contentsOf: pendingWhitespace)
        }
        flushText()
        flushImages()
        return runs
    }

    /// Walks `<p>`'s children and returns them grouped by visual line —
    /// every `\n` inside a text node terminates the current line.
    /// Whitespace-only lines (no nodes after the split) are dropped.
    private func paragraphLines(from children: [HTMLNode]) -> [[HTMLNode]] {
        var lines: [[HTMLNode]] = [[]]
        for child in children {
            switch child.kind {
            case let .text(text):
                let parts = text.components(separatedBy: "\n")
                for (index, piece) in parts.enumerated() {
                    if index > 0 {
                        lines.append([])
                    }
                    if !piece.isEmpty {
                        lines[lines.count - 1].append(.text(piece))
                    }
                }
            case .element:
                lines[lines.count - 1].append(child)
            }
        }
        return lines.filter { !$0.isEmpty }
    }

    /// Returns a `RenderedImageItem` if `nodes` represents exactly one
    /// image (or an `<a>` wrapping a single image), surrounded only by
    /// whitespace text. Otherwise returns `nil` — used to decide whether
    /// a `<p>`-line is an image-only line that deserves its own block.
    private func extractSingleImage(from nodes: [HTMLNode]) -> RenderedImageItem? {
        let meaningful = nodes.compactMap { node -> HTMLNode? in
            switch node.kind {
            case let .text(text):
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : node
            case .element:
                return node
            }
        }
        guard meaningful.count == 1 else { return nil }
        return renderedImageItem(from: meaningful[0])
    }

    func standaloneImage(from nodes: [HTMLNode]) -> (alt: String, source: String?, title: String?)? {
        let meaningfulNodes = nodes.compactMap { node -> HTMLNode? in
            switch node.kind {
            case let .text(text):
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : node
            case .element:
                return node
            }
        }

        guard meaningfulNodes.count == 1,
              case let .element(name, attributes, _) = meaningfulNodes[0].kind,
              name == "img"
        else {
            return nil
        }

        return (
            alt: attributes["alt"] ?? "",
            source: attributes["src"],
            title: attributes["title"],
        )
    }

    func standaloneImageGroup(from nodes: [HTMLNode]) -> [RenderedImageItem]? {
        var images: [RenderedImageItem] = []

        for node in nodes {
            switch node.kind {
            case let .text(text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return nil
                }
            case .element:
                guard let image = renderedImageItem(from: node) else {
                    return nil
                }
                images.append(image)
            }
        }

        return images.isEmpty ? nil : images
    }

    func renderedImageItem(from node: HTMLNode) -> RenderedImageItem? {
        switch node.kind {
        case .text:
            return nil
        case let .element(name, attributes, children):
            switch name {
            case "img":
                return .init(
                    alt: attributes["alt"] ?? "",
                    source: attributes["src"],
                    title: attributes["title"],
                    linkDestination: nil,
                )
            case "a":
                guard let image = standaloneImageGroup(from: children)?.only else {
                    return nil
                }
                return .init(
                    alt: image.alt,
                    source: image.source,
                    title: image.title,
                    linkDestination: attributes["href"],
                )
            default:
                return nil
            }
        }
    }

    /// - Parameter insideCode: true while descending into an inline `<code>`
    ///   element, so emoji shortcodes inside code spans (e.g. `` `:rocket:` ``)
    ///   are left literal. Block code (`<pre>`) never reaches here — it is
    ///   handled via `textContent(of:)` in `block(from:)`.
    func inlineText(from nodes: [HTMLNode], insideCode: Bool = false) -> RenderedText {
        var markup = ""
        var plainText = ""

        for node in nodes {
            switch node.kind {
            case let .text(text):
                let rendered = (renderEmojiShortcodes && !insideCode) ? EmojiShortcodes.render(text) : text
                markup += pangoEscape(rendered)
                plainText += rendered
            case let .element(name, attributes, children):
                let childText = inlineText(from: children, insideCode: insideCode || name == "code")
                switch name {
                case "strong":
                    markup += "<b>\(childText.markup)</b>"
                    plainText += childText.plainText
                case "em":
                    markup += "<i>\(childText.markup)</i>"
                    plainText += childText.plainText
                case "del":
                    markup += "<span strikethrough=\"true\">\(childText.markup)</span>"
                    plainText += childText.plainText
                case "code":
                    let escaped = pangoEscape(childText.plainText)
                    markup += inlineCodeMarkup(escaped)
                    plainText += childText.plainText
                case "a":
                    let escapedHref = pangoEscapeAttribute(attributes["href"] ?? "")
                    let contentMarkup = childText.markup.isEmpty ? pangoEscape(childText.plainText) : childText.markup
                    if escapedHref.isEmpty {
                        markup += contentMarkup
                    } else {
                        markup += "<a href=\"\(escapedHref)\">\(contentMarkup)</a>"
                    }
                    plainText += childText.plainText
                case "br":
                    markup += "\n"
                    plainText += "\n"
                case "img":
                    let alt = attributes["alt"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let source = attributes["src"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let fallback = alt?.isEmpty == false ? alt! : (source?.isEmpty == false ? source! : "Image")
                    let placeholder = "[Image: \(fallback)]"
                    markup += "<span foreground=\"#77767b\">\(pangoEscape(placeholder))</span>"
                    plainText += placeholder
                default:
                    markup += childText.markup
                    plainText += childText.plainText
                }
            }
        }

        return .init(markup: markup, plainText: plainText)
    }

    func blockText(from blocks: [RenderedBlock]) -> RenderedText {
        let nonEmpty = blocks.map(\.plainText).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let combined = nonEmpty.joined(separator: "\n")
        return .plain(combined)
    }

    func textContent(of nodes: [HTMLNode]) -> String {
        nodes.map { node in
            switch node.kind {
            case let .text(text):
                text
            case let .element(_, _, children):
                textContent(of: children)
            }
        }.joined()
    }

    func restoringTaskListMarkers(in blocks: [RenderedBlock], markdown: String) -> [RenderedBlock] {
        let taskItems = taskListItems(from: markdown)
        guard !taskItems.isEmpty else { return blocks }

        var restored: [RenderedBlock] = []
        var nextTaskIndex = 0

        for block in blocks {
            guard nextTaskIndex < taskItems.count else {
                restored.append(block)
                continue
            }

            let taskItem = taskItems[nextTaskIndex]
            switch block {
            case let .paragraph(text)
                where text.plainText.trimmingCharacters(in: .whitespacesAndNewlines) == taskItem.text:
                restored.append(.listItem(
                    text: text,
                    depth: taskItem.depth,
                    marker: taskItem.checked ? "[x]" : "[ ]",
                ))
                nextTaskIndex += 1
            default:
                restored.append(block)
            }
        }

        return restored
    }

    func taskListItems(from markdown: String) -> [TaskListItem] {
        markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> TaskListItem? in
                let indentation = line.prefix { $0 == " " || $0 == "\t" }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let match = trimmed.wholeMatch(of: /^(?:[-+*]|\d+\.)\s+\[([xX ])\]\s+(.+)$/) else {
                    return nil
                }

                let checked = match.1.lowercased() == "x"
                let text = normalizedTaskListText(from: String(match.2))
                let depth = indentation.reduce(into: 0) { partial, character in
                    partial += character == "\t" ? 1 : 0
                    if character == " " {
                        partial += 1
                    }
                } / 2

                return TaskListItem(
                    depth: depth,
                    checked: checked,
                    text: text,
                )
            }
    }

    func normalizedTaskListText(from markdown: String) -> String {
        let html = HTMLFormatter.format(markdown)
        let nodes = HTMLSubsetParser().parse(html)
        return blockText(from: blocks(from: nodes, listDepth: 0))
            .plainText
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func restoringImageMetadata(in blocks: [RenderedBlock], markdown: String) -> [RenderedBlock] {
        let images = markdownImages(from: markdown)
        guard !images.isEmpty else { return blocks }

        var restored: [RenderedBlock] = []
        var nextImageIndex = 0

        for block in blocks {
            switch block {
            case let .image(alt, source, title, style) where nextImageIndex < images.count:
                let markdownImage = images[nextImageIndex]
                restored.append(.image(
                    alt: alt.isEmpty ? markdownImage.alt : alt,
                    source: source ?? markdownImage.source,
                    title: title ?? markdownImage.title,
                    style: style,
                ))
                nextImageIndex += 1
            case let .imageGroup(items, style):
                var restoredItems: [RenderedImageItem] = []
                restoredItems.reserveCapacity(items.count)

                for item in items {
                    guard nextImageIndex < images.count else {
                        restoredItems.append(item)
                        continue
                    }

                    let markdownImage = images[nextImageIndex]
                    restoredItems.append(.init(
                        alt: item.alt.isEmpty ? markdownImage.alt : item.alt,
                        source: item.source ?? markdownImage.source,
                        title: item.title ?? markdownImage.title,
                        linkDestination: item.linkDestination,
                    ))
                    nextImageIndex += 1
                }

                restored.append(.imageGroup(items: restoredItems, style: style))
            default:
                restored.append(block)
            }
        }

        return restored
    }

    /// Puts the extracted math back where the text landed.
    ///
    /// - A paragraph whose plain text is *exactly* one display span's
    ///   placeholder becomes a `.math` block.
    /// - Every other placeholder is restored inline: `$tex$` in
    ///   `plainText` (search, outline and copy see the source), and one
    ///   U+FFFC in `markup` that the preview draws the formula over, with
    ///   the span listed in `mathSpans` in the same order. Display
    ///   placeholders that ended up inline (e.g. `a $$b$$ c`) keep
    ///   `isDisplay == true`.
    /// - Table cells keep the TeX source (`$tex$`) in their markup: the
    ///   table lays its columns out in monospace characters, which a drawn
    ///   formula would break.
    private func restoringMathSpans(in blocks: [RenderedBlock]) -> [RenderedBlock] {
        guard !mathSpans.isEmpty else { return blocks }
        return blocks.map { restoreMathSpans(in: $0) }
    }

    private func restoreMathSpans(in block: RenderedBlock) -> RenderedBlock {
        switch block {
        case let .paragraph(text):
            if let span = displayMathSpan(for: text) {
                return .math(tex: span.tex)
            }
            return .paragraph(restoredMathText(text))
        case let .heading(level, text):
            return .heading(level: level, text: restoredMathText(text))
        case let .blockquote(text):
            return .blockquote(restoredMathText(text))
        case let .listItem(text, depth, marker, loose, taskIndex):
            return .listItem(
                text: restoredMathText(text),
                depth: depth,
                marker: marker,
                loose: loose,
                taskIndex: taskIndex,
            )
        case let .table(headers, rows, alignments):
            return .table(
                headers: headers.map { restoredMathText($0, drawsFormulas: false) },
                rows: rows.map { row in row.map { restoredMathText($0, drawsFormulas: false) } },
                alignments: alignments,
            )
        case let .image(alt, source, title, style):
            return .image(
                alt: restoredMathSource(alt),
                source: source.map(restoredMathSource),
                title: title.map(restoredMathSource),
                style: style,
            )
        case let .imageGroup(items, style):
            return .imageGroup(
                items: items.map { item in
                    RenderedImageItem(
                        alt: restoredMathSource(item.alt),
                        source: item.source.map(restoredMathSource),
                        title: item.title.map(restoredMathSource),
                        linkDestination: item.linkDestination.map(restoredMathSource),
                    )
                },
                style: style,
            )
        case .math, .codeBlock, .thematicBreak:
            return block
        }
    }

    /// `text` with every placeholder put back as its source, for places
    /// that show no formulas (image alt text, titles, URLs).
    private func restoredMathSource(_ text: String) -> String {
        MathSpanExtractor.replacingPlaceholders(in: text) { index in
            index < mathSpans.count ? delimitedSource(of: mathSpans[index]) : nil
        }
    }

    /// The span as it was written: `$$tex$$` for display math, `$tex$`
    /// otherwise.
    private func delimitedSource(of span: MathSpan) -> String {
        span.isDisplay ? "$$\(span.tex)$$" : "$\(span.tex)$"
    }

    /// Like ``MathSpanExtractor/replacingPlaceholders(in:with:)`` for Pango markup: the
    /// replacement also learns whether the placeholder sits inside a tag
    /// (`<a href="…">`) rather than in the text. Text in markup has its `<`
    /// and `>` escaped, so every literal `<` opens a tag.
    private func replacingPlaceholders(inMarkup markup: String, with replacement: (_ index: Int, _ insideTag: Bool) -> String?) -> String {
        let occurrences = MathSpanExtractor.spanIndices(in: markup)
        guard !occurrences.isEmpty else { return markup }
        let scalars = Array(markup.unicodeScalars)
        var insideTag = false
        var scanned = 0
        var next = 0
        return MathSpanExtractor.replacingPlaceholders(in: markup) { index in
            let start = occurrences[next].range.lowerBound
            next += 1
            for scalar in scalars[scanned..<start] {
                if scalar == "<" { insideTag = true } else if scalar == ">" { insideTag = false }
            }
            scanned = start
            return replacement(index, insideTag)
        }
    }

    private func displayMathSpan(for text: RenderedText) -> MathSpan? {
        let trimmed = text.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        let occurrences = MathSpanExtractor.spanIndices(in: trimmed)
        guard occurrences.count == 1, let only = occurrences.first,
              only.range == 0..<trimmed.unicodeScalars.count,
              only.index < mathSpans.count, mathSpans[only.index].isDisplay
        else { return nil }
        return mathSpans[only.index]
    }

    private func restoredMathText(_ text: RenderedText) -> RenderedText {
        restoredMathText(text, drawsFormulas: true)
    }

    private func restoredMathText(_ text: RenderedText, drawsFormulas: Bool) -> RenderedText {
        guard !mathSpans.isEmpty else { return text }
        var found: [MathSpan] = []

        func replacePlaceholders(in string: String, replacement: (MathSpan) -> String) -> String {
            MathSpanExtractor.replacingPlaceholders(in: string) { index in
                index < mathSpans.count ? replacement(mathSpans[index]) : nil
            }
        }

        // Drawn formulas are spelled `$tex$` (search offsets count on it);
        // ones shown as source, as written.
        let plainText = replacePlaceholders(in: text.plainText) { span in
            drawsFormulas ? "$\(span.tex)$" : delimitedSource(of: span)
        }
        // A placeholder inside a tag (a link's href) is put back as source;
        // only those in the text get a marker, so the markers and
        // `mathSpans` stay in step.
        // A U+FFFC written in the note, or decoded from an entity
        // (`&#xFFFC;`), becomes U+FFFD: only a formula may own a marker.
        let markerFree = String(String.UnicodeScalarView(text.markup.unicodeScalars.map {
            $0 == MathSpanExtractor.formulaMarker ? "\u{FFFD}" : $0
        }))
        let markup = replacingPlaceholders(inMarkup: markerFree) { index, insideTag in
            guard index < mathSpans.count else { return nil }
            let span = mathSpans[index]
            if insideTag { return pangoEscapeAttribute(delimitedSource(of: span)) }
            guard drawsFormulas else { return pangoEscape(delimitedSource(of: span)) }
            found.append(span)
            return String(MathSpanExtractor.formulaMarker)
        }
        return RenderedText(markup: markup, plainText: plainText, mathSpans: found)
    }

    func markdownImages(from markdown: String) -> [MarkdownImageMetadata] {
        var collector = MarkdownImageCollector()
        collector.visit(Document(parsing: markdown))
        return collector.images
    }

    func firstCheckboxNode(in nodes: [HTMLNode]) -> HTMLNode? {
        for node in nodes {
            if node.name == "input", node.attributes["type"] == "checkbox" {
                return node
            }
            if let nested = firstCheckboxNode(in: node.children) {
                return nested
            }
        }
        return nil
    }

    func inlineCodeMarkup(_ escapedText: String) -> String {
        let background = darkAppearance ? "#3b3644" : "#f6f5f4"
        let foreground = darkAppearance ? "#f8f7f7" : "#241f31"
        return "<span font_family=\"monospace\" background=\"\(background)\" foreground=\"\(foreground)\">\(escapedText)</span>"
    }

    struct TaskListItem {
        let depth: Int
        let checked: Bool
        let text: String
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}

struct MarkdownImageMetadata {
    let alt: String
    let source: String?
    let title: String?
}

struct MarkdownImageCollector: MarkupWalker {
    var images: [MarkdownImageMetadata] = []

    mutating func visitImage(_ image: Markdown.Image) {
        images.append(.init(
            alt: image.plainText,
            source: image.source,
            title: image.title,
        ))
        descendInto(image)
    }
}
