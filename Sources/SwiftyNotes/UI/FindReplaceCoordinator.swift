import Adwaita
import Foundation

/// Shared find/replace glue used by both ``MainWindow`` and
/// ``ExternalDocumentWindow``. Owns the lazily-built search
/// controllers, the in-session query memory, and the pane-focus
/// tracking; the windows own the bars (they live in the window
/// layouts) and hand them in at construction.
///
/// Extracted because the two windows' search plumbing was a verbatim
/// copy — every routing rule and the selection-prefill offset math
/// must behave identically in a library note and a standalone file.
@MainActor
final class FindReplaceCoordinator {
    enum FocusedPane { case editor, preview }

    private let editorBar: FindReplaceBar
    private let previewBar: FindReplaceBar
    private let editor: MarkdownEditor
    private let preview: MarkdownPreview
    private let keyCaptureWindow: GtkWindow
    private let viewMode: () -> EditorViewMode
    private let presentToast: (String) -> Void

    private(set) var editorSearchController: EditorSearchController?
    private(set) var previewSearchController: PreviewSearchController?
    /// Remembered across bar opens; empty queries never overwrite it
    /// (clearing the field is deliberate, forgetting isn't).
    var lastFindQuery: String = ""
    var lastFocusedPane: FocusedPane = .editor
    private var paneFocusTrackingWired = false

    init(
        editorBar: FindReplaceBar,
        previewBar: FindReplaceBar,
        editor: MarkdownEditor,
        preview: MarkdownPreview,
        keyCaptureWindow: GtkWindow,
        viewMode: @escaping () -> EditorViewMode,
        presentToast: @escaping (String) -> Void,
    ) {
        self.editorBar = editorBar
        self.previewBar = previewBar
        self.editor = editor
        self.preview = preview
        self.keyCaptureWindow = keyCaptureWindow
        self.viewMode = viewMode
        self.presentToast = presentToast
        previewBar.isReadOnly = true
    }

    /// Re-reads the strings on both bars after a language change.
    func retranslate() {
        editorBar.retranslate()
        previewBar.retranslate()
    }

    /// Open the find / replace bar in the requested mode. In split
    /// mode the target pane (editor vs preview) is whichever had focus
    /// most recently — the affordance GNOME Builder uses. In
    /// single-pane modes the target is unambiguous: editor-only →
    /// editor, preview-only → preview (preview labels aren't
    /// focusable, so routing by view mode is what makes Ctrl+F hit the
    /// visible pane). `.replace` always lands in the editor pane
    /// because the preview bar is read-only.
    func openFindBar(mode: FindReplaceBar.Mode) {
        wirePaneFocusTracking()
        let target: FocusedPane
        if mode == .replace {
            target = .editor
        } else {
            switch viewMode() {
            case .editor: target = .editor
            case .preview: target = .preview
            case .split: target = lastFocusedPane
            }
        }
        switch target {
        case .editor:
            wireEditorFindReplaceBar()
            prefillBarFromSelection(target: editorBar)
            editorBar.setVisible(true, mode: mode)
            // Pre-fill is silent (programmatic setter doesn't fire
            // onQueryChanged) — notify so the controller computes the
            // match count + auto-steps on first display.
            editorBar.notifyQueryChanged()
        case .preview:
            wirePreviewFindBar()
            prefillBarFromLastQuery(target: previewBar)
            previewBar.setVisible(true, mode: .find)
            previewBar.notifyQueryChanged()
        }
    }

    /// Called after every preview re-render so the preview's search
    /// controller (if active) can refresh its match cache against the
    /// new block list.
    func onPreviewRerendered() {
        previewSearchController?.onPreviewRerendered()
    }

    /// Lazily builds the editor search controller on the first
    /// `openFindBar` that lands on the editor pane.
    private func wireEditorFindReplaceBar() {
        guard editorSearchController == nil else { return }
        let controller = EditorSearchController(
            bar: editorBar,
            view: editor.view,
            buffer: editor.buffer,
        )
        controller.onReplaceAllCompleted = { [weak self] count in
            let message = switch count {
            case 0: "No matches to replace.".localized
            default: String(format: nlocalized("Replaced %d occurrence.", "Replaced %d occurrences.", count: UInt(count)), count)
            }
            self?.presentToast(message)
        }
        editorSearchController = controller

        // AdwSearchBar's key capture makes Esc close the bar from
        // anywhere in the window, not just from the bar's own widgets.
        editorBar.root.setKeyCaptureWidget(keyCaptureWindow)

        // When the bar closes, return focus to the editor cursor —
        // GNOME convention. (Esc inside the bar already does this;
        // this covers programmatic close + the close-button path.)
        let existingOnClose = editorBar.onClose
        editorBar.onClose = { [weak self] in
            existingOnClose?()
            self?.editor.focus()
        }
        let existingOnQuery = editorBar.onQueryChanged
        editorBar.onQueryChanged = { [weak self] query, options in
            if !query.isEmpty { self?.lastFindQuery = query }
            existingOnQuery?(query, options)
        }
    }

    /// Lazily builds the preview-side controller. Replace mode is
    /// locked off by ``PreviewSearchController`` — replacing inside a
    /// rendered view doesn't make sense.
    private func wirePreviewFindBar() {
        guard previewSearchController == nil else { return }
        previewSearchController = PreviewSearchController(
            bar: previewBar,
            preview: preview,
        )
        previewBar.root.setKeyCaptureWidget(keyCaptureWindow)
        let existingOnClose = previewBar.onClose
        previewBar.onClose = { [weak self] in
            existingOnClose?()
            // The preview isn't focusable; dropping focus on the
            // source view is the "I'm done searching, let me edit"
            // affordance.
            self?.editor.focus()
        }
        let existingOnQuery = previewBar.onQueryChanged
        previewBar.onQueryChanged = { [weak self] query, options in
            if !query.isEmpty { self?.lastFindQuery = query }
            existingOnQuery?(query, options)
        }
    }

    /// Focus controllers on both panes keep `lastFocusedPane` current.
    /// Installed lazily on the first `openFindBar` — the tracking only
    /// matters once find is in play.
    private func wirePaneFocusTracking() {
        guard !paneFocusTrackingWired else { return }
        paneFocusTrackingWired = true

        let editorFocus = EventControllerFocus()
        editorFocus.onEnter { [weak self] in
            self?.lastFocusedPane = .editor
        }
        editor.view.addController(editorFocus)

        let previewFocus = EventControllerFocus()
        previewFocus.onEnter { [weak self] in
            self?.lastFocusedPane = .preview
        }
        // EventControllerFocus reports `enter` whenever any descendant
        // gains focus (labels / code blocks inside the scroll).
        preview.rootScroll.addController(previewFocus)
    }

    /// Editor-pane pre-fill: selection > remembered query > leave the
    /// field alone. Selection wins per GNOME Text Editor's behaviour.
    private func prefillBarFromSelection(target bar: FindReplaceBar) {
        let selection = editor.buffer.selectedRange
        if !selection.isEmpty,
           let selected = Self.substring(of: editor.buffer.text, scalarOffsets: selection),
           !selected.contains("\n") {
            bar.query = selected
            return
        }
        prefillBarFromLastQuery(target: bar)
    }

    private func prefillBarFromLastQuery(target bar: FindReplaceBar) {
        guard bar.query.isEmpty, !lastFindQuery.isEmpty else { return }
        bar.query = lastFindQuery
    }

    /// Slice `text` by GTK text-buffer offsets. GtkTextIter offsets
    /// count Unicode scalars (gunichars), NOT Swift Characters — a
    /// grapheme cluster like 🇷🇺 is one Character but two scalars, so
    /// slicing with `String.index(_:offsetBy:)` drifts after any
    /// multi-scalar emoji. Convert through the unicodeScalars view.
    static func substring(of text: String, scalarOffsets range: Range<Int>) -> String? {
        let scalars = text.unicodeScalars
        guard range.lowerBound >= 0, range.upperBound <= scalars.count else { return nil }
        let start = scalars.index(scalars.startIndex, offsetBy: range.lowerBound)
        let end = scalars.index(start, offsetBy: range.count)
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }
}
