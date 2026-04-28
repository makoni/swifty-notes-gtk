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
            var notes = try repository.loadNotes()
            if notes.isEmpty {
                _ = try repository.seedDefaultNotesIfNeeded()
                notes = try repository.loadNotes()
            }
            state.setNotes(notes)
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
        }
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
        presentDeleteConfirmation(for: selected)
    }

    func presentDeleteConfirmation(for note: Note) {
        let dialog = AlertDialog(
            heading: "Delete note?",
            body: "\"\(note.title)\" will be permanently removed.",
        )
        dialog.addResponse("cancel", label: "Cancel")
        dialog.addResponse("delete", label: "Delete")
        dialog.defaultResponse = "cancel"
        dialog.closeResponse = "cancel"
        dialog.setResponseAppearance("delete", appearance: .destructive)
        dialog.onResponse { [weak self] response in
            guard let self, response == "delete" else { return }
            delete(note: note)
        }
        dialog.present(window)
    }

    func delete(note: Note) {
        do {
            try repository.delete(note: note)
            let notes = try repository.loadNotes()
            state.setNotes(notes)
            refreshFolderList()
            refreshDirectorySnapshot()
            renderSelection()
            persistWorkspaceState()
            toastOverlay.showToast("Note deleted")
        } catch {
            presentError(
                heading: "Could not delete note",
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
            }
        }
        attachSidebarDnD()
    }
}
