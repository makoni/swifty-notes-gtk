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
        // Remember the user's query so the next Ctrl+F (without a
        // selection to prefer over it) restores it. Empty queries
        // are kept as a deliberate clear — we don't overwrite the
        // memory with empty.
        let existingOnQuery = findReplaceBar.onQueryChanged
        findReplaceBar.onQueryChanged = { [weak self] query, options in
            if !query.isEmpty { self?.lastFindQuery = query }
            existingOnQuery?(query, options)
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
        let existingOnQuery = previewFindReplaceBar.onQueryChanged
        previewFindReplaceBar.onQueryChanged = { [weak self] query, options in
            if !query.isEmpty { self?.lastFindQuery = query }
            existingOnQuery?(query, options)
        }
    }

    /// Attaches focus event controllers to the editor and the
    /// preview-pane root so `lastFocusedPane` tracks the user's
    /// attention. Called lazily on first `openFindBar` — focus
    /// tracking is only meaningful once the find feature is in
    /// play, so paying the controller installation cost up front
    /// would be wasted on users who never search.
    func wirePaneFocusTracking() {
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
        // The preview pane root isn't itself focusable, but the
        // Labels and SourceView code blocks inside it bubble focus
        // up to the scroll container. EventControllerFocus reports
        // `enter` whenever any descendant gains focus, which is
        // exactly what we want here.
        preview.rootScroll.addController(previewFocus)
    }

    /// Open the find / replace bar in the requested mode. In split
    /// mode the target pane (editor vs preview) is whichever had focus
    /// most recently — the affordance GNOME Builder uses (find runs
    /// against the pane you were just looking at). In single-pane modes
    /// the target is unambiguous: editor-only → editor, preview-only →
    /// preview, regardless of `lastFocusedPane` (preview labels aren't
    /// focusable, so switching to preview-only never flips the tracked
    /// pane — routing by view mode is what makes Ctrl+F hit the visible
    /// pane). In `.replace` mode we always land in the editor pane
    /// because the preview bar is read-only.
    func openFindBar(mode: FindReplaceBar.Mode) {
        wirePaneFocusTracking()
        let target: FocusedPane
        if mode == .replace {
            target = .editor
        } else {
            switch state.viewMode {
            case .editor: target = .editor
            case .preview: target = .preview
            case .split: target = lastFocusedPane
            }
        }
        switch target {
        case .editor:
            wireEditorFindReplaceBar()
            prefillBarFromSelection(target: findReplaceBar)
            findReplaceBar.setVisible(true, mode: mode)
            // Pre-fill is silent (programmatic setter doesn't fire
            // onQueryChanged) — so explicitly notify so the
            // controller computes match count + auto-steps on
            // first display.
            findReplaceBar.notifyQueryChanged()
        case .preview:
            wirePreviewFindBar()
            prefillBarFromLastQuery(target: previewFindReplaceBar)
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

    /// Editor-pane pre-fill: selection > remembered query > leave
    /// whatever's already in the field. Selection wins per GNOME
    /// Text Editor's behaviour ("I just highlighted this, search
    /// for it").
    private func prefillBarFromSelection(target bar: FindReplaceBar) {
        let selection = editor.buffer.selectedRange
        if !selection.isEmpty {
            let text = editor.buffer.text
            let startOffset = selection.lowerBound
            let endOffset = selection.upperBound
            if startOffset <= endOffset, endOffset <= text.count {
                let startIndex = text.index(text.startIndex, offsetBy: startOffset)
                let endIndex = text.index(text.startIndex, offsetBy: endOffset)
                let selected = String(text[startIndex..<endIndex])
                if !selected.contains("\n") {
                    bar.query = selected
                    return
                }
            }
        }
        prefillBarFromLastQuery(target: bar)
    }

    /// Pre-fill from the in-session remembered query. Used by the
    /// preview pane (no buffer selection to read from) and as a
    /// fallback for the editor pane when there's no selection.
    private func prefillBarFromLastQuery(target bar: FindReplaceBar) {
        guard bar.query.isEmpty, !lastFindQuery.isEmpty else { return }
        bar.query = lastFindQuery
    }
}
