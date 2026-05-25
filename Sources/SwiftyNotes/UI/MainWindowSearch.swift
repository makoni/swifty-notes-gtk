import Adwaita
import Foundation

@MainActor
extension MainWindow {
    /// Lazily builds the editor search controller. Called on first
    /// `openFindBar` that lands on the editor pane.
    func wireEditorFindReplaceBar() {
        guard editorSearchController == nil else { return }
        let controller = EditorSearchController(
            bar: findReplaceBar,
            view: editor.view,
            buffer: editor.buffer,
        )
        controller.onReplaceAllCompleted = { [weak self] count in
            let message: String
            switch count {
            case 0:
                message = "No matches to replace."
            case 1:
                message = "Replaced 1 occurrence."
            default:
                message = "Replaced \(count) occurrences."
            }
            self?.toastOverlay.addToast(Toast(title: message))
        }
        editorSearchController = controller

        // Wire AdwSearchBar's built-in key capture so Esc closes the
        // bar from anywhere in the window — without this, Esc only
        // works when focus is already on the bar's own widgets.
        findReplaceBar.root.setKeyCaptureWidget(window)

        // When the bar closes, return focus to the editor cursor —
        // GNOME convention. (Esc inside the bar already does this;
        // this covers programmatic close + the close-button path.)
        let existingOnClose = findReplaceBar.onClose
        findReplaceBar.onClose = { [weak self] in
            existingOnClose?()
            self?.editor.focus()
        }
    }

    /// Lazily builds the preview-side search controller. Replace
    /// mode is locked off by ``PreviewSearchController``'s
    /// constructor — replacing inside a rendered view doesn't make
    /// sense.
    func wirePreviewFindBar() {
        guard previewSearchController == nil else { return }
        previewSearchController = PreviewSearchController(
            bar: previewFindReplaceBar,
            preview: preview,
        )
        previewFindReplaceBar.root.setKeyCaptureWidget(window)
        let existingOnClose = previewFindReplaceBar.onClose
        previewFindReplaceBar.onClose = { [weak self] in
            existingOnClose?()
            // Returning focus to the preview "container" doesn't
            // make sense (it isn't a focusable widget by default),
            // so we drop focus on the source view — the user's
            // implicit "I'm done searching this rendered view, let
            // me edit again" affordance.
            self?.editor.focus()
        }
    }

    /// Open the find / replace bar in the requested mode. The
    /// active pane (editor vs preview) is decided by which one had
    /// focus most recently — same affordance GNOME Builder uses
    /// in split mode (find runs against the file you were just
    /// looking at). In `.replace` mode we always land in the
    /// editor pane because the preview bar is read-only.
    func openFindBar(mode: FindReplaceBar.Mode) {
        let target: FocusedPane = mode == .replace ? .editor : lastFocusedPane
        switch target {
        case .editor:
            wireEditorFindReplaceBar()
            prefillBarFromSelection()
            findReplaceBar.setVisible(true, mode: mode)
            // Pre-fill is silent (programmatic setter doesn't fire
            // onQueryChanged) — so explicitly notify so the
            // controller computes match count + auto-steps on
            // first display.
            findReplaceBar.notifyQueryChanged()
        case .preview:
            wirePreviewFindBar()
            previewFindReplaceBar.setVisible(true, mode: .find)
            previewFindReplaceBar.notifyQueryChanged()
        }
    }

    /// Called after every preview re-render so the preview's
    /// search controller (if active) can refresh its match cache
    /// against the new block list.
    func refreshPreviewSearchAfterRerender() {
        previewSearchController?.onPreviewRerendered()
    }

    private func prefillBarFromSelection() {
        let selection = editor.buffer.selectedRange
        // Only adopt the selection if it's a single-line range —
        // multi-line selections rarely encode a meaningful query
        // and they'd populate the find entry with a line break.
        guard !selection.isEmpty else { return }
        let text = editor.buffer.text
        let startOffset = selection.lowerBound
        let endOffset = selection.upperBound
        guard startOffset <= endOffset, endOffset <= text.count else { return }
        let startIndex = text.index(text.startIndex, offsetBy: startOffset)
        let endIndex = text.index(text.startIndex, offsetBy: endOffset)
        let selected = String(text[startIndex..<endIndex])
        if selected.contains("\n") { return }
        findReplaceBar.query = selected
    }
}
