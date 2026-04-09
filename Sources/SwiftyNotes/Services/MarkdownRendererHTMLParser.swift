import Adwaita
import Foundation
import Markdown

struct HTMLSubsetParser {
    let supportedTags: Set<String> = [
        "a", "aside", "blockquote", "br", "code", "del", "em", "h1", "h2", "h3", "h4", "h5", "h6",
        "hr", "img", "input", "li", "ol", "p", "pre", "span", "strong", "table", "tbody", "td",
        "th", "thead", "tr", "ul"
    ]

    func parse(_ html: String) -> [HTMLNode] {
        let root = HTMLNode.element(name: "root", attributes: [:])
        var stack: [HTMLNode] = [root]
        var index = html.startIndex

        while index < html.endIndex {
            if html[index] == "<" {
                if let tagRange = html[index...].firstIndex(of: ">") {
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

                stack[stack.count - 1].children.append(.text("<"))
                index = html.index(after: index)
                continue
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

    func parseTag(_ token: String) -> ParsedTag? {
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

    func parseAttributes(_ input: String) -> [String: String] {
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

struct ParsedTag {
    enum Kind {
        case opening
        case closing
    }

    let name: String
    let attributes: [String: String]
    let kind: Kind
    let selfClosing: Bool
}

final class HTMLNode {
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

func pangoEscape(_ text: String) -> String {
    text
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

func pangoEscapeAttribute(_ text: String) -> String {
    pangoEscape(text).replacingOccurrences(of: "\"", with: "&quot;")
}
