import Adwaita

@MainActor
struct MarkdownEditor {
    let view: SourceView
    let buffer: SourceBuffer

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

    func applyAutomaticStyleScheme(styleManager: StyleManager = .default) {
        buffer.styleScheme = SourceStyleSchemeManager.default.preferredScheme(dark: styleManager.dark)
    }
}
