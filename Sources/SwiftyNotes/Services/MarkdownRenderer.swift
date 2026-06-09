import Adwaita
import Foundation
import Markdown

public struct MarkdownRenderer: Sendable {
    public init() {}

    @MainActor
    public func blocks(for markdown: String) -> [RenderedBlock] {
        blocks(for: markdown, darkAppearance: StyleManager.default.dark)
    }

    public func blocks(
        for markdown: String,
        darkAppearance: Bool,
        renderEmojiShortcodes: Bool = true,
    ) -> [RenderedBlock] {
        HTMLPreviewDocumentBuilder(darkAppearance: darkAppearance, renderEmojiShortcodes: renderEmojiShortcodes)
            .render(markdown: markdown)
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

public struct RenderedImageItem: Sendable, Equatable {
    public let alt: String
    public let source: String?
    public let title: String?
    public let linkDestination: String?

    public init(alt: String, source: String?, title: String?, linkDestination: String?) {
        self.alt = alt
        self.source = source
        self.title = title
        self.linkDestination = linkDestination
    }

    public var plainText: String {
        let description = [alt, title, source].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " — ")
        return description.isEmpty ? "Image" : "Image: \(description)"
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

/// Visual treatment for rendered images. Reflects the markdown author's
/// own framing of the image:
///
/// - ``card``: the markdown puts the image alone in a paragraph (i.e. the
///   author put blank lines around it). Renders as a featured block with
///   the standard libadwaita `.card` styling and a caption underneath.
/// - ``plain``: the image lives on its own line inside a mixed-content
///   paragraph (no blank lines). Renders as a flat block that flows in
///   with the surrounding prose — no card chrome, no caption.
public enum ImageBlockStyle: Sendable, Equatable {
    case card
    case plain
}

public enum RenderedBlock: Sendable, Equatable {
    case heading(level: Int, text: RenderedText)
    case paragraph(RenderedText)
    case codeBlock(code: String, language: String?)
    case blockquote(RenderedText)
    case listItem(text: RenderedText, depth: Int, marker: String, loose: Bool = false, taskIndex: Int? = nil)
    case thematicBreak
    case table(headers: [RenderedText], rows: [[RenderedText]], alignments: [RenderedTableAlignment])
    case image(alt: String, source: String?, title: String?, style: ImageBlockStyle = .card)
    case imageGroup(items: [RenderedImageItem], style: ImageBlockStyle = .card)

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
        case let .listItem(_, depth, _, _, _):
            .listItem(depth: depth)
        case .thematicBreak:
            .thematicBreak
        case .table:
            .table
        case .image, .imageGroup:
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
        case let .listItem(text, _, marker, _, _):
            return "\(marker) \(text.plainText)"
        case .thematicBreak:
            return "----------------"
        case let .table(headers, rows, _):
            let headerLine = headers.map(\.plainText).joined(separator: " | ")
            let rowLines = rows.map { $0.map(\.plainText).joined(separator: " | ") }
            return ([headerLine] + rowLines).joined(separator: "\n")
        case let .image(alt, source, title, _):
            let description = [alt, title, source].compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }.joined(separator: " — ")
            return description.isEmpty ? "Image" : "Image: \(description)"
        case let .imageGroup(items, _):
            return items.map(\.plainText).joined(separator: "\n")
        }
    }
}
