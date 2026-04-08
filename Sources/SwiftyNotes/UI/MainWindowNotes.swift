import Adwaita
import Foundation

@MainActor
extension MainWindow {
    func requestCreateNote() {
        MainContext.idle { [weak self] in
            self?.createNote()
        }
    }

    func loadInitialNotes() {
        do {
            var notes = try repository.loadNotes()
            if notes.isEmpty {
                _ = try repository.seedMarkdownShowcaseIfNeeded()
                notes = try repository.loadNotes()
            }
            state.setNotes(notes)
            directorySnapshot = try repository.directorySnapshot()
            renderSelection()
            flushPendingPreviewRefresh()
            updateHeaderSubtitle()
            persistWorkspaceState()
        } catch {
            presentError(
                heading: "Could not load notes",
                body: error.localizedDescription
            )
        }
    }

    func selectNote(at index: Int) {
        guard displayedNotes.indices.contains(index) else { return }
        state.select(noteID: displayedNotes[index].id)
        renderSelection()
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
                self?.editor.focus()
            }
        } catch {
            presentError(
                heading: "Could not create note",
                body: error.localizedDescription
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
                body: error.localizedDescription
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
            body: "\"\(note.title)\" will be permanently removed."
        )
        dialog.addResponse("cancel", label: "Cancel")
        dialog.addResponse("delete", label: "Delete")
        dialog.defaultResponse = "cancel"
        dialog.closeResponse = "cancel"
        dialog.setResponseAppearance("delete", appearance: .destructive)
        dialog.onResponse { [weak self] response in
            guard let self, response == "delete" else { return }
            self.delete(note: note)
        }
        dialog.present(window)
    }

    func delete(note: Note) {
        do {
            try repository.delete(note: note)
            let notes = try repository.loadNotes()
            state.setNotes(notes)
            refreshDirectorySnapshot()
            renderSelection()
            persistWorkspaceState()
            toastOverlay.showToast("Note deleted")
        } catch {
            presentError(
                heading: "Could not delete note",
                body: error.localizedDescription
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
        applyPreviewVisibility(animated: false)
        updateHeaderSubtitle()
    }

    func refreshSidebar() {
        displayedNotes = state.sortMode.sort(notes: state.notes.filter { $0.matches(searchQuery: state.searchQuery) })
        sidebar.render(
            notes: displayedNotes,
            selectedID: state.selectedNoteID,
            totalCount: state.notes.count,
            searchQuery: state.searchQuery,
            sortMode: state.sortMode
        )
        for (index, note) in displayedNotes.enumerated() {
            guard let row = sidebar.list.rowAt(index) else { continue }
            row.onRightClick { [weak self] x, y in
                guard let self else { return }
                self.state.select(noteID: note.id)
                self.renderSelection()
                self.persistWorkspaceState()
                self.presentNoteContextMenu(forNoteID: note.id, x: Int(x), y: Int(y))
            }
        }
    }
}
