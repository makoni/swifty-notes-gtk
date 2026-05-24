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

    /// Opens the Ctrl+G command palette. Headings + recents + current
    /// scroll-spy anchor are snapshotted at open time so the palette
    /// state doesn't churn under the user if the editor changes
    /// underneath them.
    func openCommandPalette() {
        guard !currentHeadings.isEmpty else {
            toastOverlay.addToast(Toast(title: "No headings to jump to."))
            return
        }
        let palette = CommandPaletteWindow(
            transientFor: window,
            headings: currentHeadings,
            currentID: outlineSidebar.activeHeadingID,
            recents: outlineRecentJumps.ids,
            onPick: { [weak self] id in
                guard let self else { return }
                outlineRecentJumps.record(id)
                if let heading = currentHeadings.first(where: { $0.id == id }) {
                    scrollToHeading(heading)
                }
            },
        )
        palette.present()
    }

    /// Re-extracts the outline for the current note and pushes the
    /// resulting headings into ``outlineSidebar``. Called from
    /// ``refreshPreview`` so the panel stays in lockstep with the
    /// preview's view of the document.
    func refreshOutline(markdown: String, blocks: [RenderedBlock]) {
        let headings = MarkdownOutlineExtractor.extract(markdown: markdown, blocks: blocks)
        outlineSidebar.render(headings: headings)
        currentHeadings = headings
        // Reset the breadcrumb to the doc title with no active section
        // until the next scroll-spy tick decides what's currently in view.
        refreshBreadcrumb()
    }

    /// Sync the breadcrumb's three segments with the current heading
    /// list + active id. Pulls the doc title from the selected note
    /// (falls back to "Swifty Notes" so a heading-less note doesn't
    /// flash an empty strip).
    func refreshBreadcrumb() {
        let title = state.selectedNote?.title ?? ""
        breadcrumb.update(
            docTitle: title,
            headings: currentHeadings,
            activeID: outlineSidebar.activeHeadingID,
        )
    }

    /// Lazy-built scroll-spy driver. Hooked once in `wireSignals` and
    /// rebound from `applyViewMode` whenever the view mode flips so the
    /// driver follows the visually dominant scroll target.
    func makeOutlineScrollSpyDriver() -> OutlineScrollSpyDriver {
        OutlineScrollSpyDriver(
            editorScroll: editorScroll,
            previewScroll: preview.rootScroll,
            resolveHeadings: { [weak self] in self?.currentHeadings ?? [] },
            previewPositionsFor: { [weak self] heading in
                guard let self else { return nil }
                return OutlinePositions.previewY(for: heading, in: preview.container)
            },
            editorPositionsFor: { [weak self] heading in
                guard let self else { return nil }
                return OutlinePositions.editorY(
                    for: heading,
                    view: editor.view,
                    buffer: editor.buffer,
                    scroll: editorScroll,
                )
            },
            onActive: { [weak self] activeID in
                guard let self else { return }
                outlineSidebar.setActiveHeading(activeID)
                refreshBreadcrumb()
            },
        )
    }

    /// Click / Ctrl+G handler. Scrolls both the editor and the preview
    /// to the heading and records it as the current scroll-spy anchor
    /// so the outline highlight matches the click immediately (without
    /// waiting for the next scroll-spy tick).
    func scrollToHeading(_ heading: Heading) {
        OutlineNavigation.scrollEditor(
            view: editor.view,
            buffer: editor.buffer,
            scroll: editorScroll,
            toLine: heading.line,
        )
        OutlineNavigation.scrollPreview(
            heading: heading,
            preview: preview,
            editorScroll: editorScroll,
        )
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
