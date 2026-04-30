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
            try? repository.pruneTrashIfNeeded(retention: state.trashRetention, now: Date())

            var notes = try repository.loadNotes()
            if notes.isEmpty {
                _ = try repository.seedDefaultNotesIfNeeded()
                notes = try repository.loadNotes()
            }
            state.setNotes(notes)
            state.setTrashedNotes(try repository.trashedNotes())
            state.setFolders(try repository.listFolders())
            directorySnapshot = try repository.directorySnapshot()
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
            state.select(noteID: noteItem.note.id)
            renderSelection()
            persistWorkspaceState()
        case .trashHeader:
            isTrashExpanded.toggle()
            refreshSidebar()
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
        suppressEditorChange = true
        editor.setText(note.content)
        suppressEditorChange = false
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: note.content)
        schedulePreviewRefresh(blocks: blocks, baseDirectory: repository.notesDirectoryURL)
        saveNoteButton.visible = false
        deleteNoteButton.visible = false
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
            trashExpanded: isTrashExpanded,
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
        }
        attachSidebarDnD()
    }
}
