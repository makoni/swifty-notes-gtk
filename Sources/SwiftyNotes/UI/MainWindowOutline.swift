import Adwaita
import Foundation

// Shared navigation (scroll-to-heading, scroll-spy plumbing, reorder,
// folding, starter heading) comes from ``OutlineHosting``; this file
// keeps the MainWindow-only layers — persisted visibility, per-note
// collapse/recents hydration, and the breadcrumb.
extension MainWindow: OutlineHosting, GlobalShortcutHost {}

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
        outlineToggleButton.tooltipText = state.isOutlineVisible ? "Hide outline (F9)".localized : "Show outline (F9)".localized
        quickJumpButton.tooltipText = "Quick jump… (Ctrl+G)".localized
    }

    /// Opens the Ctrl+G command palette. Headings + recents + current
    /// scroll-spy anchor are snapshotted at open time so the palette
    /// state doesn't churn under the user if the editor changes
    /// underneath them.
    func openCommandPalette() {
        guard !currentHeadings.isEmpty else {
            toastOverlay.addToast(Toast(title: "No headings to jump to.".localized))
            return
        }
        // If a palette is already showing (rapid double-press of
        // Ctrl+G), drop the old wrapper — its dialog will be closed
        // by GTK as soon as we present a new one over the top.
        activeCommandPalette = nil
        let palette = CommandPaletteWindow(
            transientFor: window,
            headings: currentHeadings,
            currentID: outlineSidebar.activeHeadingID,
            recents: outlineRecentJumps.ids,
            onPick: { [weak self] id in
                guard let self else { return }
                outlineRecentJumps.record(id)
                persistOutlineStateForCurrentNote()
                if let heading = currentHeadings.first(where: { $0.id == id }) {
                    scrollToHeading(heading)
                }
            },
            onClosed: { [weak self] in
                self?.activeCommandPalette = nil
            },
        )
        activeCommandPalette = palette
        palette.present()
    }

    /// Re-extracts the outline for the current note and pushes the
    /// resulting headings into ``outlineSidebar``. Called from
    /// ``refreshPreview`` so the panel stays in lockstep with the
    /// preview's view of the document. When the active note changes,
    /// hydrates per-note collapse + recent-jumps state from
    /// ``AppState`` so the user's last-session structure survives a
    /// note switch.
    func refreshOutline(markdown: String, blocks: [RenderedBlock]) {
        let activeNoteID = state.selectedNote?.id
        if activeNoteID != currentOutlineNoteID {
            // Note transition. Persist any in-memory state from the
            // outgoing note (in case the user collapsed something
            // moments before switching), then hydrate the incoming
            // one from `AppState`.
            persistOutgoingOutlineState()
            currentOutlineNoteID = activeNoteID
            hydrateOutlineForCurrentNote()
        }

        let headings = MarkdownOutlineExtractor.extract(markdown: markdown, blocks: blocks)
        outlineSidebar.setHeadings(headings)
        currentHeadings = headings
        refreshBreadcrumb()
        applyEditorFolding()
    }

    private func persistOutgoingOutlineState() {
        guard let noteID = currentOutlineNoteID else { return }
        state.collapsedOutlineSections[noteID] = outlineSidebar.collapsedSections
        state.recentOutlineJumps[noteID] = outlineRecentJumps.ids
        persistStateBestEffort()
    }

    /// Same shape as ``persistOutgoingOutlineState`` but for the
    /// currently active note. Called from chevron-toggle / palette
    /// pick handlers so the JSON on disk catches the change before
    /// the user switches notes / quits the app.
    func persistOutlineStateForCurrentNote() {
        guard let noteID = state.selectedNote?.id else { return }
        state.collapsedOutlineSections[noteID] = outlineSidebar.collapsedSections
        state.recentOutlineJumps[noteID] = outlineRecentJumps.ids
        persistStateBestEffort()
    }

    private func hydrateOutlineForCurrentNote() {
        guard let noteID = currentOutlineNoteID else {
            outlineSidebar.setCollapsedSections([])
            outlineRecentJumps = RecentJumps()
            return
        }
        let collapsed = state.collapsedOutlineSections[noteID] ?? []
        outlineSidebar.setCollapsedSections(collapsed)
        let recentIDs = state.recentOutlineJumps[noteID] ?? []
        outlineRecentJumps = RecentJumps(ids: recentIDs)
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

    /// The scroll-spy hook layered on top of the shared driver
    /// plumbing: highlight the sidebar row AND refresh the breadcrumb.
    /// Hot path (fires ~60/s during a kinetic scroll) — both branches
    /// early-exit on an unchanged active id, and the breadcrumb skip
    /// avoids 3 Pango layout invalidations per tick.
    func handleOutlineActiveHeadingChange(_ activeID: String?) {
        let changed = outlineSidebar.activeHeadingID != activeID
        outlineSidebar.setActiveHeading(activeID)
        if changed { refreshBreadcrumb() }
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
    var debugAppState: AppState { state }
    var debugSelectedNoteID: UUID? { state.selectedNote?.id }
    var debugOutlineRecentIDs: [String] { outlineRecentJumps.ids }
    func debugResetOutlineNoteID() { currentOutlineNoteID = nil }
}
#endif
