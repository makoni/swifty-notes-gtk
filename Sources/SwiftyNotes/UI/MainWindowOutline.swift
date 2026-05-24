import Adwaita
import Foundation

extension MainWindow {
    /// F9 + headerbar handler. Mirrors ``toggleSidebarVisibility`` in
    /// shape so the persisted state, the AppState mirror, and the GTK
    /// widget stay in lockstep.
    func toggleOutlineVisibility() {
        let next = !state.isOutlineVisible
        state.isOutlineVisible = next
        applyOutlineVisibility()
        persistStateBestEffort()
    }

    /// Idempotent — call after touching ``AppState.isOutlineVisible`` to
    /// sync the outer ``outlineSplitView`` and the headerbar toggle
    /// button's active CSS class.
    func applyOutlineVisibility() {
        outlineSplitView.showSidebar = state.isOutlineVisible
        if state.isOutlineVisible {
            outlineToggleButton.addCSSClass(.activeCSSClass)
        } else {
            outlineToggleButton.removeCSSClass(.activeCSSClass)
        }
        outlineToggleButton.tooltipText = state.isOutlineVisible ? "Hide outline (F9)" : "Show outline (F9)"
        quickJumpButton.tooltipText = "Quick jump… (Ctrl+G)"
    }

    /// Opens the Ctrl+G command palette. Stub for Phase 1 — Phase 5
    /// brings the actual ``CommandPaletteWindow``.
    func openCommandPalette() {
        // Phase 5 placeholder. Surfaced as a toast for now so the
        // wiring (button + Ctrl+G + lupa) is testable end-to-end before
        // the palette UI lands.
        toastOverlay.addToast(Toast(title: "Command palette coming in Phase 5."))
    }

    /// Re-extracts the outline for the current note and pushes the
    /// resulting headings into ``outlineSidebar``. Called from
    /// ``refreshPreview`` so the panel stays in lockstep with the
    /// preview's view of the document.
    func refreshOutline(markdown: String, blocks: [RenderedBlock]) {
        let headings = MarkdownOutlineExtractor.extract(markdown: markdown, blocks: blocks)
        outlineSidebar.render(headings: headings)
    }

    /// Click / Ctrl+G handler. Scrolls both the editor and the preview
    /// to the heading and records it as the current scroll-spy anchor
    /// so the outline highlight matches the click immediately (without
    /// waiting for the next scroll-spy tick).
    func scrollToHeading(_ heading: Heading) {
        OutlineNavigation.scrollEditor(view: editor.view, buffer: editor.buffer, toLine: heading.line)
        // Defer the preview alignment a frame — the editor's scroll
        // adjustment updates on the next GLib main-loop iteration, and
        // the proportional preview sync needs the post-jump `source.value`
        // to read the right progress.
        MainContext.idle { [weak self] in
            guard let self else { return }
            OutlineNavigation.scrollPreview(editorScroll: editorScroll, previewScroll: preview.rootScroll)
        }
        outlineSidebar.setActiveHeading(heading.id)
    }
}

extension MainWindow {
    /// Best-effort persist; mirrors the small "fire and forget" save
    /// helpers used elsewhere in MainWindow (the sidebar visibility
    /// toggle uses the same pattern). Failures stay silent — we just
    /// lose the last toggle across an unclean shutdown.
    fileprivate func persistStateBestEffort() {
        let snapshot = state.persistedState(
            windowWidth: max(state.preferredWindowWidth, 1),
            windowHeight: max(state.preferredWindowHeight, 1),
        )
        try? stateStore.save(snapshot)
    }
}

private extension String {
    /// GTK CSS class libadwaita uses to highlight a "currently active"
    /// flat button. Same class the sidebar toggle uses when the side
    /// pane is visible.
    static let activeCSSClass = "active"
}

#if DEBUG
extension MainWindow {
    var debugIsOutlineVisible: Bool { outlineSplitView.showSidebar }
    var debugAppStateIsOutlineVisible: Bool { state.isOutlineVisible }
    func debugToggleOutline() { toggleOutlineVisibility() }
}
#endif
