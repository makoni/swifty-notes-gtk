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
