import Adwaita
import Foundation
import Markdown

public struct MarkdownRenderer: Sendable {
    public init() {}

    @MainActor
    public func blocks(for markdown: String) -> [RenderedBlock] {
        blocks(for: markdown, darkAppearance: StyleManager.default.dark)
    }

    public func blocks(for markdown: String, darkAppearance: Bool) -> [RenderedBlock] {
        HTMLPreviewDocumentBuilder(darkAppearance: darkAppearance).render(markdown: markdown)
    }
}

public struct RenderedText: Sendable, Equatable {
    public let markup: String
    public let plainText: String

    public init(markup: String, plainText: String) {
        self.markup = markup
        self.plainText = plainText
    }

    public static func plain(_ text: String) -> Self {
        .init(markup: pangoEscape(text), plainText: text)
    }
}

public enum RenderedTableAlignment: Sendable, Equatable {
    case leading
    case center
    case trailing
}

public enum RenderedBlockStyle: Sendable, Equatable {
    case heading(level: Int)
    case paragraph
    case codeBlock(language: String?)
    case blockquote
    case listItem(depth: Int)
    case thematicBreak
    case table
    case image
}

public enum RenderedBlock: Sendable, Equatable {
    case heading(level: Int, text: RenderedText)
    case paragraph(RenderedText)
    case codeBlock(code: String, language: String?)
    case blockquote(RenderedText)
    case listItem(text: RenderedText, depth: Int, marker: String)
    case thematicBreak
    case table(headers: [RenderedText], rows: [[RenderedText]], alignments: [RenderedTableAlignment])
    case image(alt: String, source: String?, title: String?)

    public var style: RenderedBlockStyle {
        switch self {
        case let .heading(level, _):
            .heading(level: level)
        case .paragraph:
            .paragraph
        case let .codeBlock(_, language):
            .codeBlock(language: language)
        case .blockquote:
            .blockquote
        case let .listItem(_, depth, _):
            .listItem(depth: depth)
        case .thematicBreak:
            .thematicBreak
        case .table:
            .table
        case .image:
            .image
        }
    }

    public var text: String {
        plainText
    }

    public var plainText: String {
        switch self {
        case let .heading(_, text),
             let .paragraph(text),
             let .blockquote(text):
            return text.plainText
        case let .codeBlock(code, language):
            if let language, !language.isEmpty {
                return "\(language)\n\(code)"
            }
            return code
        case let .listItem(text, _, marker):
            return "\(marker) \(text.plainText)"
        case .thematicBreak:
            return "----------------"
        case let .table(headers, rows, _):
            let headerLine = headers.map(\.plainText).joined(separator: " | ")
            let rowLines = rows.map { $0.map(\.plainText).joined(separator: " | ") }
            return ([headerLine] + rowLines).joined(separator: "\n")
        case let .image(alt, source, title):
            let description = [alt, title, source].compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }.joined(separator: " — ")
            return description.isEmpty ? "Image" : "Image: \(description)"
        }
    }
}

private struct HTMLPreviewDocumentBuilder {
    private let darkAppearance: Bool

    init(darkAppearance: Bool) {
        self.darkAppearance = darkAppearance
    }

    func render(markdown: String) -> [RenderedBlock] {
        let html = HTMLFormatter.format(markdown)
        let nodes = HTMLSubsetParser().parse(html)
        let rendered = restoringTaskListMarkers(in: blocks(from: nodes, listDepth: 0), markdown: markdown)
        if rendered.isEmpty, markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [.paragraph(.plain("Nothing to preview yet."))]
        }
        return rendered
    }

    private func blocks(from nodes: [HTMLNode], listDepth: Int) -> [RenderedBlock] {
        nodes.flatMap { block(from: $0, listDepth: listDepth) }
    }

    private func block(from node: HTMLNode, listDepth: Int) -> [RenderedBlock] {
        switch node.kind {
        case let .text(text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.paragraph(.plain(text))]
        case let .element(name, attributes, children):
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(String(name.dropFirst())) ?? 1
                return [.heading(level: level, text: inlineText(from: children))]
            case "p":
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
            default:
                return blocks(from: children, listDepth: listDepth)
            }
        }
    }

    private func listBlocks(from nodes: [HTMLNode], listDepth: Int, ordered: Bool, startIndex: Int) -> [RenderedBlock] {
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

    private func tableBlock(from nodes: [HTMLNode]) -> [RenderedBlock] {
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

    private func inlineText(from nodes: [HTMLNode]) -> RenderedText {
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

    private func blockText(from blocks: [RenderedBlock]) -> RenderedText {
        let nonEmpty = blocks.map(\.plainText).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let combined = nonEmpty.joined(separator: "\n")
        return .plain(combined)
    }

    private func textContent(of nodes: [HTMLNode]) -> String {
        nodes.map { node in
            switch node.kind {
            case let .text(text):
                text
            case let .element(_, _, children):
                textContent(of: children)
            }
        }.joined()
    }

    private func restoringTaskListMarkers(in blocks: [RenderedBlock], markdown: String) -> [RenderedBlock] {
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

    private func taskListItems(from markdown: String) -> [TaskListItem] {
        markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> TaskListItem? in
                let indentation = line.prefix { $0 == " " || $0 == "\t" }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let match = trimmed.wholeMatch(of: /^(?:[-+*]|\d+\.)\s+\[([xX ])\]\s+(.+)$/) else {
                    return nil
                }

                let checked = match.1.lowercased() == "x"
                let text = String(match.2)
                let depth = indentation.reduce(into: 0) { partial, character in
                    partial += character == "\t" ? 1 : 0
                    if character == " " {
                        partial += 1
                    }
                } / 2

                return TaskListItem(
                    depth: depth,
                    checked: checked,
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
    }

    private func firstCheckboxNode(in nodes: [HTMLNode]) -> HTMLNode? {
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

    private func inlineCodeMarkup(_ escapedText: String) -> String {
        let background = darkAppearance ? "#3b3644" : "#f6f5f4"
        let foreground = darkAppearance ? "#f8f7f7" : "#241f31"
        return "<span font_family=\"monospace\" background=\"\(background)\" foreground=\"\(foreground)\">\(escapedText)</span>"
    }

    private struct TaskListItem {
        let depth: Int
        let checked: Bool
        let text: String
    }
}

private struct HTMLSubsetParser {
    private let supportedTags: Set<String> = [
        "a", "aside", "blockquote", "br", "code", "del", "em", "h1", "h2", "h3", "h4", "h5", "h6",
        "hr", "img", "input", "li", "ol", "p", "pre", "span", "strong", "table", "tbody", "td",
        "th", "thead", "tr", "ul"
    ]

    func parse(_ html: String) -> [HTMLNode] {
        let root = HTMLNode.element(name: "root", attributes: [:])
        var stack: [HTMLNode] = [root]
        var index = html.startIndex

        while index < html.endIndex {
            if html[index] == "<", let tagRange = html[index...].firstIndex(of: ">") {
                let end = html.index(after: tagRange)
                let token = String(html[index..<end])
                if let tag = parseTag(token) {
                    switch tag.kind {
                    case .opening:
                        let node = HTMLNode.element(name: tag.name, attributes: tag.attributes)
                        stack[stack.count - 1].children.append(node)
                        if !tag.selfClosing {
                            stack.append(node)
                        }
                    case .closing:
                        if let matchedIndex = stack.lastIndex(where: { $0.name == tag.name }) {
                            stack.removeSubrange((matchedIndex + 1)..<stack.count)
                            stack.removeLast()
                        }
                    }
                    index = end
                    continue
                }
            }

            let nextTag = html[index...].firstIndex(of: "<") ?? html.endIndex
            let text = String(html[index..<nextTag])
            if !text.isEmpty {
                stack[stack.count - 1].children.append(.text(text))
            }
            index = nextTag
        }

        return root.children
    }

    private func parseTag(_ token: String) -> ParsedTag? {
        guard token.first == "<", token.last == ">" else { return nil }
        var content = String(token.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !content.hasPrefix("!") else { return nil }

        let kind: ParsedTag.Kind
        if content.hasPrefix("/") {
            kind = .closing
            content.removeFirst()
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            kind = .opening
        }

        var selfClosing = false
        if content.hasSuffix("/") {
            selfClosing = true
            content.removeLast()
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let parts = content.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let rawName = parts.first else { return nil }
        let name = rawName.lowercased()
        guard supportedTags.contains(name) else { return nil }

        let attributes = parts.count > 1 ? parseAttributes(String(parts[1])) : [:]
        return .init(name: name, attributes: attributes, kind: kind, selfClosing: selfClosing || name == "img" || name == "hr" || name == "br" || name == "input")
    }

    private func parseAttributes(_ input: String) -> [String: String] {
        let pattern = #"""
        ([A-Za-z_:][A-Za-z0-9:._-]*)
        (?:="([^"]*)")?
        """#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.allowCommentsAndWhitespace]) else {
            return [:]
        }

        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        var attributes: [String: String] = [:]
        regex.enumerateMatches(in: input, options: [], range: range) { match, _, _ in
            guard let match,
                  let keyRange = Range(match.range(at: 1), in: input) else { return }
            let key = String(input[keyRange]).lowercased()
            let value: String
            if let valueRange = Range(match.range(at: 2), in: input) {
                value = String(input[valueRange])
            } else {
                value = ""
            }
            attributes[key] = value
        }
        return attributes
    }
}

private struct ParsedTag {
    enum Kind {
        case opening
        case closing
    }

    let name: String
    let attributes: [String: String]
    let kind: Kind
    let selfClosing: Bool
}

private final class HTMLNode {
    enum Kind {
        case text(String)
        case element(name: String, attributes: [String: String], children: [HTMLNode])
    }

    var kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }

    static func text(_ text: String) -> HTMLNode {
        HTMLNode(kind: .text(text))
    }

    static func element(name: String, attributes: [String: String]) -> HTMLNode {
        HTMLNode(kind: .element(name: name, attributes: attributes, children: []))
    }

    var name: String? {
        switch kind {
        case .text:
            nil
        case let .element(name, _, _):
            name
        }
    }

    var attributes: [String: String] {
        switch kind {
        case .text:
            [:]
        case let .element(_, attributes, _):
            attributes
        }
    }

    var children: [HTMLNode] {
        get {
            switch kind {
            case .text:
                []
            case let .element(_, _, children):
                children
            }
        }
        set {
            guard case let .element(name, attributes, _) = kind else { return }
            kind = .element(name: name, attributes: attributes, children: newValue)
        }
    }
}

private func pangoEscape(_ text: String) -> String {
    text
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private func pangoEscapeAttribute(_ text: String) -> String {
    pangoEscape(text).replacingOccurrences(of: "\"", with: "&quot;")
}
