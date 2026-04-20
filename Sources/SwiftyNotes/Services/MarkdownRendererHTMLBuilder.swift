import Adwaita
import Foundation
import Markdown

struct HTMLPreviewDocumentBuilder {
    let darkAppearance: Bool

    init(darkAppearance: Bool) {
        self.darkAppearance = darkAppearance
    }

    func render(markdown: String) -> [RenderedBlock] {
        let html = HTMLFormatter.format(markdown)
        let nodes = HTMLSubsetParser().parse(html)
        let rendered = restoringImageMetadata(
            in: restoringTaskListMarkers(in: blocks(from: nodes, listDepth: 0), markdown: markdown),
            markdown: markdown
        )
        if rendered.isEmpty, markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [.paragraph(.plain("Nothing to preview yet."))]
        }
        return rendered
    }

    func blocks(from nodes: [HTMLNode], listDepth: Int) -> [RenderedBlock] {
        nodes.flatMap { block(from: $0, listDepth: listDepth) }
    }

    func block(from node: HTMLNode, listDepth: Int) -> [RenderedBlock] {
        switch node.kind {
        case let .text(text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.paragraph(.plain(text))]
        case let .element(name, attributes, children):
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(String(name.dropFirst())) ?? 1
                return [.heading(level: level, text: inlineText(from: children))]
            case "p":
                if let imageGroup = standaloneImageGroup(from: children) {
                    if imageGroup.count == 1, imageGroup[0].linkDestination == nil {
                        let image = imageGroup[0]
                        return [.image(alt: image.alt, source: image.source, title: image.title)]
                    }
                    return [.imageGroup(items: imageGroup)]
                }
                if let image = standaloneImage(from: children) {
                    return [.image(alt: image.alt, source: image.source, title: image.title)]
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
                    title: attributes["title"]
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
                    inlineNodes.append(child)
                default:
                    if nestedBlocks.isEmpty && inlineNodes.isEmpty {
                        nestedBlocks.append(contentsOf: block(from: child, listDepth: listDepth + 1))
                    } else {
                        nestedBlocks.append(contentsOf: block(from: child, listDepth: listDepth + 1))
                    }
                }
            }

            if inlineNodes.isEmpty && nestedBlocks.isEmpty {
                inlineNodes = contentNodes
            }

            let marker: String = if let checkboxMarker {
                checkboxMarker
            } else if ordered {
                "\(ordinal)."
            } else {
                "-"
            }

            let text = inlineText(from: inlineNodes)
            if !text.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output.append(.listItem(text: text, depth: listDepth, marker: marker))
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
              name == "img" else {
            return nil
        }

        return (
            alt: attributes["alt"] ?? "",
            source: attributes["src"],
            title: attributes["title"]
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
                    linkDestination: nil
                )
            case "a":
                guard let image = standaloneImageGroup(from: children)?.only else {
                    return nil
                }
                return .init(
                    alt: image.alt,
                    source: image.source,
                    title: image.title,
                    linkDestination: attributes["href"]
                )
            default:
                return nil
            }
        }
    }

    func inlineText(from nodes: [HTMLNode]) -> RenderedText {
        var markup = ""
        var plainText = ""

        for node in nodes {
            switch node.kind {
            case let .text(text):
                markup += pangoEscape(text)
                plainText += text
            case let .element(name, attributes, children):
                let childText = inlineText(from: children)
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
                    marker: taskItem.checked ? "[x]" : "[ ]"
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
                    text: text
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
            case let .image(alt, source, title) where nextImageIndex < images.count:
                let markdownImage = images[nextImageIndex]
                restored.append(.image(
                    alt: alt.isEmpty ? markdownImage.alt : alt,
                    source: source ?? markdownImage.source,
                    title: title ?? markdownImage.title
                ))
                nextImageIndex += 1
            case let .imageGroup(items):
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
                        linkDestination: item.linkDestination
                    ))
                    nextImageIndex += 1
                }

                restored.append(.imageGroup(items: restoredItems))
            default:
                restored.append(block)
            }
        }

        return restored
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
            title: image.title
        ))
        descendInto(image)
    }
}
