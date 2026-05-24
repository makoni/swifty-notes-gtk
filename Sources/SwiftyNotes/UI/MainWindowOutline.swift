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
                persistOutlineStateForCurrentNote()
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
    }

    private func persistOutgoingOutlineState() {
        guard let noteID = currentOutlineNoteID else { return }
        state.collapsedOutlineSections[noteID] = outlineSidebar.collapsedSections
        state.recentOutlineJumps[noteID] = outlineRecentJumps.ids
        persistStateBestEffort()
    }

    /// Inserts a starter `## Heading` at the cursor in the editor and
    /// focuses the editor. Wired to the empty-state "Add `## Heading`"
    /// link in the outline panel — clicking it scaffolds the section
    /// the panel is asking for and drops the user into the right
    /// place to keep typing.
    func insertStarterHeadingIntoEditor() {
        // Pad the heading line so it doesn't jam against whatever is
        // before / after the cursor. The trailing `\n\n` leaves the
        // editor focused on the line *after* the heading where prose
        // typically goes.
        let snippet: String
        let bufferText = editor.buffer.text
        if bufferText.isEmpty {
            snippet = "## Heading\n\n"
        } else {
            snippet = "\n\n## Heading\n\n"
        }
        editor.buffer.insertAtCursor(snippet)
        editor.focus()
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
    var debugAppState: AppState { state }
    var debugSelectedNoteID: UUID? { state.selectedNote?.id }
    var debugOutlineRecentIDs: [String] { outlineRecentJumps.ids }
    func debugResetOutlineNoteID() { currentOutlineNoteID = nil }
}
#endif
