import Adwaita
import CSpelling
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
    /// Pointer to the GtkTextTag that libspelling treats as "skip these
    /// ranges". We apply it to fenced code blocks and inline backtick
    /// spans so the spell-checker leaves them alone. `nil` when no
    /// spell-checker is available — there's no point maintaining the
    /// tag in that case. Stored as a raw pointer because creating /
    /// applying the tag goes through a CSpelling C helper to dodge the
    /// duplicate-`GtkTextTag` issue we have between CAdwaita and
    /// CSpelling Clang modules.
    private let noSpellTagPointer: UnsafeMutableRawPointer?

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
        let checker = SpellChecking(view: view, buffer: buffer)
        spellChecking = checker
        if checker != nil {
            // libspelling treats any text inside this tag's ranges as
            // off-limits for spell-check. Markdown grammars don't apply
            // the tag themselves, so we maintain it ourselves on every
            // buffer change. Capture local references so the onChanged
            // closure doesn't try to escape `self` (this is a struct).
            let scopedBuffer = buffer
            let bufferPointer = UnsafeMutableRawPointer(scopedBuffer.opaquePointer)
            let tagPointer = swifty_notes_spelling_create_no_spell_tag(bufferPointer)
            noSpellTagPointer = tagPointer
            scopedBuffer.onChanged {
                Self.refreshNoSpellTags(buffer: scopedBuffer, bufferPointer: bufferPointer, tagPointer: tagPointer)
            }
        } else {
            noSpellTagPointer = nil
        }
        applySettings(.default)
    }

    private static func refreshNoSpellTags(
        buffer: SourceBuffer,
        bufferPointer: UnsafeMutableRawPointer,
        tagPointer: UnsafeMutableRawPointer?,
    ) {
        guard let tagPointer else { return }
        let text = buffer.text
        let totalLength = text.count
        guard totalLength > 0 else { return }
        swifty_notes_spelling_remove_no_spell_tag(
            bufferPointer,
            tagPointer,
            0,
            Int32(totalLength),
        )
        for range in MarkdownNoSpellRanges.ranges(in: text) {
            swifty_notes_spelling_apply_no_spell_tag(
                bufferPointer,
                tagPointer,
                Int32(range.lowerBound),
                Int32(range.upperBound),
            )
        }
    }

    func setText(_ text: String) {
        if buffer.text != text {
            buffer.text = text
            buffer.modified = false
            // Replacing the buffer text wholesale doesn't trigger
            // libspelling's incremental scanner — invalidate so the new
            // content actually gets checked.
            spellChecking?.invalidateAll()
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
        if let spellChecking {
            spellChecking.isEnabled = settings.spellCheckEnabled
            // Only push an explicit language when the user has chosen
            // one — libspelling's default keeps the system locale, and
            // overwriting it with nil drops the dictionary entirely on
            // some setups.
            if let language = settings.spellCheckLanguage {
                spellChecking.language = language
            }
        }
    }

    func applyAutomaticStyleScheme(styleManager: StyleManager = .default) {
        buffer.styleScheme = SourceStyleSchemeManager.default.preferredScheme(dark: styleManager.dark)
    }
}
