import Adwaita
import Foundation

@MainActor
extension MainWindow {
    func requestCreateNote() {
        deferredUIActionScheduler { [weak self] in
            self?.createNote()
        }
    }

    func requestSelectNote(at index: Int) {
        deferredUIActionScheduler { [weak self] in
            self?.selectNote(at: index)
        }
    }

    func requestActivateSidebarRow(at index: Int) {
        deferredUIActionScheduler { [weak self] in
            self?.activateSidebarRow(at: index)
        }
    }

    func loadInitialNotes() {
        do {
            // Run the trash auto-prune sweep before loading notes so
            // the next user-visible state is already cleaned up.
            // Errors here are non-fatal — a stale entry sticks
            // around until the next launch.
            try? repository.pruneTrashIfNeeded(retention: appSettings.trashRetention, now: Date())

            var notes = try repository.loadNotes()
            var seededOnboarding = false
            if notes.isEmpty {
                let seeded = try repository.seedDefaultNotesIfNeeded()
                seededOnboarding = !seeded.isEmpty
                notes = try repository.loadNotes()
            }
            state.setNotes(notes)
            state.setTrashedNotes(try repository.trashedNotes())
            state.setFolders(try repository.listFolders())
            if seededOnboarding {
                // Expand the seeded "Guides" folder on first launch
                // so the onboarding notes are immediately visible
                // and folders are discovered as a feature instead of
                // a hidden surprise.
                state.setFolderExpanded(NotesRepository.defaultSeedGuidesFolder, expanded: true)
            }
            directorySnapshot = try repository.directoryMonitorSnapshot()
            renderSelection()
            flushPendingPreviewRefresh()
            updateHeaderSubtitle()
            persistWorkspaceState()
        } catch {
            presentError(
                heading: "Could not load notes",
                body: error.localizedDescription,
            )
        }
    }

    /// Reloads the folder list from disk. Call after any folder mutation
    /// (create / rename / delete / move) so the sidebar's `state.folders`
    /// matches the on-disk truth. Errors are suppressed here — load
    /// failures show up as a stale tree that the next load picks up.
    func refreshFolderList() {
        if let folders = try? repository.listFolders() {
            state.setFolders(folders)
        }
    }

    func selectNote(at index: Int) {
        guard displayedNotes.indices.contains(index) else { return }
        state.select(noteID: displayedNotes[index].id)
        renderSelection()
        persistWorkspaceState()
    }

    /// Routed from the sidebar's `row-activated` signal. The row may be a
    /// folder (toggle expand) or a note (select it).
    func activateSidebarRow(at index: Int) {
        guard let item = sidebar.item(at: index) else { return }
        switch item {
        case let .folder(folder):
            toggleFolder(at: folder.path)
        case let .note(noteItem):
            // Coming back to a regular note ends any trash-preview
            // mode that may have been active so the editor goes
            // editable again and the banner hides.
            clearTrashedNotePreviewMode()
            state.select(noteID: noteItem.note.id)
            renderSelection()
            persistWorkspaceState()
        case .trashHeader:
            state.isTrashExpanded.toggle()
            refreshSidebar()
            persistWorkspaceState()
        case let .trashedNote(trashedNote):
            // Show the trashed note read-only without touching the
            // selectedNoteID — the user is browsing the bin, not
            // re-opening a note for editing. Keeping `selectedNoteID`
            // pinned to the previously-active note also stops
            // ListBox from re-asserting selection on the first row
            // after the next refresh.
            previewTrashedNote(trashedNote.note)
        }
    }

    func previewTrashedNote(_ note: Note) {
        // Flush any pending unsaved edits in the previously-active
        // regular note BEFORE we swap the editor buffer. Without
        // this, a scheduled autosave timer would fire after the
        // swap, snapshot the now-trashed-content from the buffer,
        // and write it back into `state.selectedNote` (the regular
        // note) — the same data-loss bug `editable = false` closes
        // for keystrokes, just arriving via the timer instead.
        if editor.buffer.modified, currentEditedNoteSnapshot() != nil {
            saveCurrentEditedNote(announceSuccess: false)
        }
        autosave.cancel()

        // Mark the editor as showing a trashed note. Four knobs
        // make this safe:
        //   1. `previewedTrashedNoteID` flags trash-preview mode
        //      so any subsequent code path (renderSelection,
        //      external-reload, formatting toolbar, change handler)
        //      can refuse to overwrite the editor buffer.
        //   2. `editor.view.editable = false` blocks keystrokes —
        //      typing into a soft-deleted note would silently
        //      rewrite a different note's content.
        //   3. Toolbar `sensitive = false` and the action guard
        //      block formatting input, which would otherwise route
        //      around the `editable` flag.
        //   4. Banner above the editor announces the read-only
        //      state and offers a Restore action.
        previewedTrashedNoteID = note.id
        suppressEditorChange = true
        editor.setText(note.content)
        suppressEditorChange = false
        editor.view.editable = false
        editor.view.opacity = 0.85
        editorFormattingToolbar.scrolled.sensitive = false
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(
            for: note.content,
            darkAppearance: StyleManager.default.dark,
            renderEmojiShortcodes: appSettings.renderEmojiShortcodes,
        )
        schedulePreviewRefresh(blocks: blocks, baseDirectory: repository.notesDirectoryURL)
        saveNoteButton.visible = false
        deleteNoteButton.visible = false
        trashedNoteBanner.title = "“\(note.title)” is in the Trash"
        trashedNoteBanner.revealed = true
    }

    func clearTrashedNotePreviewMode() {
        guard previewedTrashedNoteID != nil else { return }
        previewedTrashedNoteID = nil
        editor.view.editable = true
        editor.view.opacity = 1.0
        editorFormattingToolbar.scrolled.sensitive = true
        trashedNoteBanner.revealed = false
    }

    func toggleFolder(at path: String) {
        let isExpanded = state.expandedFolders.contains(path)
        state.setFolderExpanded(path, expanded: !isExpanded)
        refreshSidebar()
        persistWorkspaceState()
    }

    func createNote() {
        do {
            clearSearchIfNeeded()
            let note = try repository.createNote()
            state.upsert(note)
            refreshDirectorySnapshot()
            renderSelection()
            persistWorkspaceState()
            MainContext.idle { [weak self] in
                self?.focusPrimaryContentIfNeeded()
            }
        } catch {
            presentError(
                heading: "Could not create note",
                body: error.localizedDescription,
            )
        }
    }

    func duplicateSelectedNote() {
        guard let selected = state.selectedNote else { return }
        do {
            clearSearchIfNeeded()
            let duplicated = try repository.duplicate(note: selected)
            state.upsert(duplicated)
            refreshDirectorySnapshot()
            renderSelection()
            persistWorkspaceState()
            toastOverlay.showToast("Note duplicated")
        } catch {
            presentError(
                heading: "Could not duplicate note",
                body: error.localizedDescription,
            )
        }
    }

    func presentDeleteConfirmationForSelectedNote() {
        guard let selected = state.selectedNote else { return }
        // Soft-delete is reversible from the Trash, so don't gate it
        // on a confirmation dialog any more — the toast's Undo
        // action covers accidental clicks, and the user can always
        // restore from Trash if they miss the toast.
        delete(note: selected)
    }

    func delete(note: Note) {
        do {
            try repository.delete(note: note)
            let notes = try repository.loadNotes()
            state.setNotes(notes)
            state.setTrashedNotes(try repository.trashedNotes())
            refreshFolderList()
            refreshDirectorySnapshot()
            renderSelection()
            persistWorkspaceState()
            let toast = Toast(title: "Moved \"\(note.title)\" to Trash")
            toast.timeout = 5
            toast.buttonLabel = "Undo"
            toast.onButtonClicked { [weak self] in
                self?.restoreFromTrash(noteID: note.id)
            }
            toastOverlay.dismissAll()
            toastOverlay.addToast(toast)
        } catch {
            presentError(
                heading: "Could not delete note",
                body: error.localizedDescription,
            )
        }
    }

    func restoreFromTrash(noteID: UUID) {
        do {
            try repository.restore(noteWithID: noteID)
            state.setNotes(try repository.loadNotes())
            state.setTrashedNotes(try repository.trashedNotes())
            refreshFolderList()
            refreshDirectorySnapshot()
            // Open the restored note immediately — the user pressed
            // "Restore" with the intention of getting back to that
            // note, so jump them straight to it instead of leaving
            // whichever note was previously selected on screen.
            if state.notes.contains(where: { $0.id == noteID }) {
                state.select(noteID: noteID)
            }
            clearTrashedNotePreviewMode()
            renderSelection()
            persistWorkspaceState()
            toastOverlay.showToast("Note restored")
        } catch {
            presentError(
                heading: "Could not restore note",
                body: error.localizedDescription,
            )
        }
    }

    func presentPermanentDeleteConfirmation(forNoteID noteID: UUID) {
        guard let trashed = state.trashedNotes.first(where: { $0.id == noteID }) else { return }
        let dialog = AlertDialog(
            heading: "Delete “\(trashed.title)” forever?",
            body: "This permanently removes the note from disk. This action can't be undone.",
        )
        dialog.addResponse("cancel", label: "Cancel")
        dialog.addResponse("delete", label: "Delete forever")
        dialog.defaultResponse = "cancel"
        dialog.closeResponse = "cancel"
        dialog.setResponseAppearance("delete", appearance: .destructive)
        dialog.onResponse { [weak self] response in
            guard let self, response == "delete" else { return }
            permanentlyDeleteFromTrash(noteID: noteID)
        }
        dialog.present(window)
    }

    func permanentlyDeleteFromTrash(noteID: UUID) {
        do {
            try repository.permanentlyDelete(noteWithID: noteID)
            state.setTrashedNotes(try repository.trashedNotes())
            // If the user was previewing this exact note, drop back
            // to the regular editor view (the note is gone — there's
            // nothing to preview any more).
            if previewedTrashedNoteID == noteID {
                clearTrashedNotePreviewMode()
                renderSelection()
            }
            refreshSidebar()
            persistWorkspaceState()
            toastOverlay.showToast("Note permanently deleted")
        } catch {
            presentError(
                heading: "Could not permanently delete note",
                body: error.localizedDescription,
            )
        }
    }

    func presentEmptyTrashConfirmation() {
        let count = state.trashedNotes.count
        guard count > 0 else { return }
        let dialog = AlertDialog(
            heading: "Empty Trash?",
            body: count == 1
                ? "1 note will be permanently deleted. This action can't be undone."
                : "\(count) notes will be permanently deleted. This action can't be undone.",
        )
        dialog.addResponse("cancel", label: "Cancel")
        dialog.addResponse("empty", label: "Empty Trash")
        dialog.defaultResponse = "cancel"
        dialog.closeResponse = "cancel"
        dialog.setResponseAppearance("empty", appearance: .destructive)
        dialog.onResponse { [weak self] response in
            guard let self, response == "empty" else { return }
            emptyTrash()
        }
        dialog.present(window)
    }

    func presentTrashedNoteContextMenu(forNoteID noteID: UUID, x: Int, y: Int) {
        dismissNoteContextMenu()
        dismissFolderContextMenu()
        dismissTrashContextMenu()

        guard let rowIndex = sidebar.renderedItems.firstIndex(where: { item in
            if case let .trashedNote(trashedNote) = item { return trashedNote.note.id == noteID }
            return false
        }),
              let row = sidebar.list.rowAt(rowIndex)
        else { return }
        guard row.root != nil else { return }

        let popover = Popover()
        popover.hasArrow = true
        popover.position = .top
        popover.autohide = true

        let content = Box(orientation: .vertical, spacing: 2)
        content.setMargins(4)
        let restoreButton = makeNoteContextButton(label: "Restore") { [weak self] in
            self?.dismissTrashContextMenu()
            self?.restoreFromTrash(noteID: noteID)
        }
        let deleteButton = makeNoteContextButton(label: "Delete forever…", destructive: true) { [weak self] in
            self?.dismissTrashContextMenu()
            self?.presentPermanentDeleteConfirmation(forNoteID: noteID)
        }
        content.append(restoreButton)
        content.append(deleteButton)
        popover.child = content
        popover.onClosed { [weak self, weak popover] in
            guard let self, let popover else { return }
            if popover.root != nil { popover.unparent() }
            if trashContextMenu === popover { trashContextMenu = nil }
        }
        // Anchor at the click point with `position = .top` — the
        // popover lands above and its arrow points DOWN at the
        // exact spot the user right-clicked. Anchoring to the whole
        // row instead made the arrow point at the row's top edge,
        // which (with rows stacked flush) read as "the row above".
        guard popover.present(from: row, x: x, y: y) else { return }
        trashContextMenu = popover
    }

    func presentTrashHeaderContextMenu(x: Int, y: Int) {
        dismissNoteContextMenu()
        dismissFolderContextMenu()
        dismissTrashContextMenu()

        let count = state.trashedNotes.count
        guard count > 0 else { return }
        guard let rowIndex = sidebar.renderedItems.firstIndex(where: { item in
            if case .trashHeader = item { return true }
            return false
        }),
              let row = sidebar.list.rowAt(rowIndex)
        else { return }
        guard row.root != nil else { return }

        let popover = Popover()
        popover.hasArrow = true
        popover.position = .top
        popover.autohide = true

        let content = Box(orientation: .vertical, spacing: 2)
        content.setMargins(4)
        let label = count == 1 ? "Empty Trash (1 note)…" : "Empty Trash (\(count) notes)…"
        let emptyButton = makeNoteContextButton(label: label, destructive: true) { [weak self] in
            self?.dismissTrashContextMenu()
            self?.presentEmptyTrashConfirmation()
        }
        content.append(emptyButton)
        popover.child = content
        popover.onClosed { [weak self, weak popover] in
            guard let self, let popover else { return }
            if popover.root != nil { popover.unparent() }
            if trashContextMenu === popover { trashContextMenu = nil }
        }
        guard popover.present(from: row, x: x, y: y) else { return }
        trashContextMenu = popover
    }

    func dismissTrashContextMenu() {
        guard let popover = trashContextMenu else { return }
        trashContextMenu = nil
        popover.popdown()
        if popover.root != nil { popover.unparent() }
    }

    func emptyTrash() {
        do {
            try repository.emptyTrash()
            state.setTrashedNotes([])
            if previewedTrashedNoteID != nil {
                clearTrashedNotePreviewMode()
                renderSelection()
            }
            refreshSidebar()
            persistWorkspaceState()
            toastOverlay.showToast("Trash emptied")
        } catch {
            presentError(
                heading: "Could not empty Trash",
                body: error.localizedDescription,
            )
        }
    }

    func renderSelection() {
        refreshSidebar()
        updateActionAvailability()

        // While a trashed note is being previewed, leave the editor
        // / preview / banner state alone. `renderSelection` is
        // called from background paths (external-change reload,
        // post-save refresh, …) — without this guard those paths
        // would overwrite the trashed-note buffer with the
        // previously-active regular note's content, undoing the
        // trash-preview without disabling the read-only mode.
        if previewedTrashedNoteID != nil {
            updateHeaderSubtitle()
            return
        }

        guard let selected = state.selectedNote else {
            suppressEditorChange = true
            editor.setText("")
            suppressEditorChange = false
            schedulePreviewRefresh(blocks: [], baseDirectory: repository.notesDirectoryURL)
            saveNoteButton.visible = false
            deleteNoteButton.visible = false
            updateHeaderSubtitle()
            return
        }

        suppressEditorChange = true
        editor.setText(selected.content)
        suppressEditorChange = false
        refreshPreview()
        saveNoteButton.visible = true
        deleteNoteButton.visible = true
        applyViewMode(animated: false)
        updateHeaderSubtitle()
    }

    func refreshSidebar() {
        dismissNoteContextMenu()
        dismissFolderContextMenu()
        let items = SidebarTreeFlattener.flatten(
            notes: state.notes,
            folders: state.folders,
            expandedFolders: state.expandedFolders,
            searchQuery: state.searchQuery,
            sortMode: state.sortMode,
            trashedNotes: state.trashedNotes,
            trashExpanded: state.isTrashExpanded,
        )
        displayedNotes = items.compactMap { item in
            if case let .note(noteItem) = item { return noteItem.note }
            return nil
        }
        sidebar.render(
            items: items,
            selectedNoteID: state.selectedNoteID,
            totalCount: state.notes.count,
            searchQuery: state.searchQuery,
            sortMode: state.sortMode,
        )
        for (index, item) in items.enumerated() {
            guard let row = sidebar.list.rowAt(index) else { continue }
            switch item {
            case let .note(noteItem):
                row.onRightClick { [weak self] x, y in
                    guard let self else { return }
                    state.select(noteID: noteItem.note.id)
                    renderSelection()
                    persistWorkspaceState()
                    presentNoteContextMenu(forNoteID: noteItem.note.id, x: Int(x), y: Int(y))
                }
            case let .folder(folder):
                row.onRightClick { [weak self] x, y in
                    self?.presentFolderContextMenu(forFolderPath: folder.path, x: Int(x), y: Int(y))
                }
            case .trashHeader:
                row.onRightClick { [weak self] x, y in
                    self?.presentTrashHeaderContextMenu(x: Int(x), y: Int(y))
                }
            case let .trashedNote(trashedNote):
                let noteID = trashedNote.note.id
                row.onRightClick { [weak self] x, y in
                    self?.presentTrashedNoteContextMenu(forNoteID: noteID, x: Int(x), y: Int(y))
                }
            }

            #if os(macOS)
            // On macOS Quartz `GtkListBox.activate-on-single-click` is
            // unreliable: GTK's pointer pipeline treats *any* sub-pixel
            // motion during a press as a possible drag, claims the
            // press for drag-disambiguation, and never resolves it
            // back to a click — `row-activated` is never emitted. The
            // row highlights (selection still fires) but no signal
            // reaches our `onRowActivated` handler, so the note
            // doesn't open.
            //
            // Disabling DragSource on the row and pan-gestures on the
            // OverlaySplitView only narrows the problem — the drag
            // detector built into ListBox itself is still there. The
            // reliable workaround is to bypass `row-activated`
            // entirely: install an explicit `GestureClick(button=1)`
            // on each row.
            //
            // To make the click feel natural (activate on release, not
            // on press) without losing it to a competing claimant
            // mid-sequence, we copy the trick from the context-menu
            // buttons:
            //   1. Put the gesture on the CAPTURE phase — capture-phase
            //      controllers fire before any bubble-phase ones on
            //      the same widget, so we beat ListBox's internal
            //      activation gesture (and any drag claim) to the
            //      press.
            //   2. Call `gtk_gesture_set_state(..., CLAIMED)` from
            //      `onPressed` — that promotes our gesture to sole
            //      owner of the sequence, denying every other interested
            //      controller. With the sequence claimed, our
            //      `onReleased` actually fires on button-up; without
            //      the claim it would be cancelled when the drag
            //      detector grabbed the sequence on the first motion
            //      delta.
            //
            // `selectionMode = .single` stays on ListBox so the visual
            // selection highlight still happens through ListBox's own
            // machinery — we only override the activation half.
            // Row click pipeline: same CAPTURE-phase claim + 250 ms
            // watchdog the `MacOSClickWorkaround` button helper uses,
            // plus an `EventControllerMotion` that hands the
            // sequence back to DragSource when the cursor moves
            // past the drag threshold. Without that motion check,
            // the watchdog would fire before a drag could start —
            // every drag attempt would turn into a row activation,
            // which is what the original sidebar fix avoided by
            // gating DragSource off entirely on macOS.
            let rowLabel = "SidebarRow[\(index)]"
            attachDragAwareRowClick(
                to: row,
                label: rowLabel,
                onRelease: { [weak self] in
                    self?.requestActivateSidebarRow(at: index)
                },
            )
            #endif
        }
        attachSidebarDnD()
    }

    #if os(macOS)
    /// Like `MacOSClickWorkaround.attachReleaseHandler` (CAPTURE-phase
    /// gesture + CLAIM on press + watchdog) but additionally installs
    /// a parallel `EventControllerMotion` that hands the sequence
    /// back to DragSource the moment cursor motion exceeds the drag
    /// threshold. Used only for sidebar rows because they're the
    /// only widgets in the app that have a DragSource attached;
    /// regular toolbar / banner buttons keep the simpler
    /// click-only helper.
    private func attachDragAwareRowClick(
        to row: ListBoxRow,
        label: String,
        onRelease: @escaping @MainActor () -> Void,
    ) {
        let click = GestureClick()
        click.button = 1
        click.propagationPhase = .capture
        row.addController(click)

        let motion = EventControllerMotion()
        row.addController(motion)

        let state = SidebarRowClickState()

        click.onPressed { [weak row] _, x, y in
            MacOSClickWorkaround.debugLog(label: label, widget: row, event: "capture-pressed (\(x),\(y))")
            state.pressed = true
            state.fired = false
            state.dragging = false
            state.startX = x
            state.startY = y
            state.workItem?.cancel()
            let workItem = DispatchWorkItem {
                MainActor.assumeIsolated {
                    guard !state.fired, !state.dragging else { return }
                    state.fired = true
                    MacOSClickWorkaround.debugLog(label: label, widget: row, event: "WATCHDOG-FIRED")
                    onRelease()
                }
            }
            state.workItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
        }

        click.onReleased { [weak row] _, _, _ in
            state.pressed = false
            state.workItem?.cancel()
            guard !state.fired, !state.dragging else {
                MacOSClickWorkaround.debugLog(label: label, widget: row, event: "released ignored (fired=\(state.fired) dragging=\(state.dragging))")
                return
            }
            state.fired = true
            MacOSClickWorkaround.debugLog(label: label, widget: row, event: "capture-released")
            onRelease()
        }

        motion.onMotion { [weak row, click] x, y in
            guard state.pressed, !state.fired, !state.dragging else { return }
            let dx = x - state.startX
            let dy = y - state.startY
            // 16 px² = 4 px straight-line drift threshold. Matches
            // GTK's default `gtk-dnd-drag-threshold` (8 px) closely
            // enough that humans don't perceive a different feel,
            // and slightly tighter so we hand off to DragSource a
            // fraction of a millimetre earlier — giving the
            // drag-begin animation a touch more lead time.
            if dx * dx + dy * dy > 16 {
                state.dragging = true
                state.workItem?.cancel()
                // Explicitly DENY our gesture so DragSource picks up
                // the sequence cleanly. Without the prior CLAIM in
                // place this is mostly belt-and-suspenders, but it
                // does the right thing if GTK ever changes how it
                // resolves competing controllers.
                click.setState(.denied)
                MacOSClickWorkaround.debugLog(label: label, widget: row, event: "DRAG-DETECTED dx=\(dx) dy=\(dy) → DENIED")
            }
        }
    }

    @MainActor
    private final class SidebarRowClickState {
        var pressed = false
        var fired = false
        var dragging = false
        var startX: Double = 0
        var startY: Double = 0
        var workItem: DispatchWorkItem?
    }
    #endif
}
