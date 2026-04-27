import Adwaita
import Foundation

@MainActor
struct MarkdownEditor {
    let view: SourceView
    let buffer: SourceBuffer
    private let fontCSSProvider = CSSProvider()
    private let fontCSSClass = "markdown-editor-font-\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
    private(set) var currentFontSize = AppSettings.defaultEditorFontSize
    /// `nil` if libspelling-1 reports no spell-check provider on this
    /// system (no Enchant backends, no dictionaries) — the editor still
    /// works, it just won't underline misspellings.
    private let spellChecking: SpellChecking?

    init() {
        if let language = SourceLanguageManager.default.language(id: .markdown) {
            buffer = SourceBuffer(language: language)
        } else {
            buffer = SourceBuffer()
        }
        buffer.highlightSyntax = true
        buffer.highlightMatchingBrackets = true
        buffer.enableUndo = true
        buffer.styleScheme = SourceStyleSchemeManager.default.preferredScheme()

        view = SourceView(buffer: buffer)
        view.showLineNumbers = true
        view.highlightCurrentLine = true
        view.autoIndent = true
        view.insertSpacesInsteadOfTabs = true
        view.showRightMargin = true
        view.rightMarginPosition = 80
        view.tabWidth = 4
        view.wrapMode = .wordChar
        view.monospace = true
        view.leftMargin = 8
        view.rightMargin = 8
        view.topMargin = 8
        view.bottomMargin = 8
        view.setAccessibleLabel("Markdown Editor")
        view.addCSSClass(fontCSSClass)
        fontCSSProvider.addToDefaultDisplay()
        spellChecking = SpellChecking(view: view, buffer: buffer)
        applySettings(.default)
    }

    func setText(_ text: String) {
        if buffer.text != text {
            buffer.text = text
            buffer.modified = false
        }
    }

    func focus() {
        _ = view.grabFocus()
    }

    mutating func applySettings(_ settings: AppSettings) {
        view.wrapMode = settings.wrapsEditorLines ? .wordChar : .none
        view.tabWidth = settings.editorTabWidth
        view.insertSpacesInsteadOfTabs = settings.editorIndentStyle == .spaces
        currentFontSize = settings.editorFontSize
        fontCSSProvider.loadFromString(
            ".\(fontCSSClass) { font-size: \(currentFontSize)pt; }",
        )
    }

    func applyAutomaticStyleScheme(styleManager: StyleManager = .default) {
        buffer.styleScheme = SourceStyleSchemeManager.default.preferredScheme(dark: styleManager.dark)
    }
}
