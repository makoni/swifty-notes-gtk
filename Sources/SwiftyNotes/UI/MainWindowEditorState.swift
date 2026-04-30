import Adwaita
import Foundation

@MainActor
extension MainWindow {
    func setSortMode(_ sortMode: NotesSortMode) {
        state.setSortMode(sortMode)
        refreshSidebar()
        persistWorkspaceState()
        toastOverlay.dismissAll()
        toastOverlay.showToast("Sorting by \(sortMode.displayName.lowercased())")
    }

    func focusSearch() {
        _ = sidebar.searchEntry.grabFocus()
    }

    func clearSearchIfNeeded() {
        guard !state.searchQuery.isEmpty else { return }
        state.setSearchQuery("")
        sidebar.searchEntry.text = ""
    }

    func updateHeaderSubtitle() {
        guard let selected = state.selectedNote else {
            headerTitle.subtitle = "Markdown notes"
            return
        }
        let wordCount = editor.buffer.text.split(whereSeparator: \.isWhitespace).count
        let saveState = editor.buffer.modified ? "Unsaved changes" : "Saved"
        headerTitle.subtitle = "\(selected.title) • \(saveState) • \(wordCount) words"
    }

    func saveSelectedNoteNow() {
        saveCurrentEditedNote(announceSuccess: true)
        autosave.cancel()
    }

    /// Invoked from the preview when the user clicks a task-list
    /// checkbox glyph (`☐` / `☑`). Flips the corresponding `[ ]`
    /// ↔ `[x]` in the editor buffer and persists the change.
    /// `taskIndex` is the 0-based document-order index the renderer
    /// stamped on each task item.
    func handleTaskCheckboxToggle(at taskIndex: Int) {
        // Trash-preview keeps `state.selectedNoteID` pinned to the
        // previously-active regular note, so a checkbox click in the
        // preview of a trashed note would otherwise rewrite the
        // visible buffer (which holds the trashed note's content)
        // and save it back into the regular note's file.
        guard previewedTrashedNoteID == nil else { return }
        guard state.selectedNote != nil else { return }
        let original = editor.buffer.text
        let toggled = TaskListToggle.toggle(in: original, atTaskIndex: taskIndex)
        guard toggled != original else { return }
        suppressEditorChange = true
        editor.buffer.text = toggled
        suppressEditorChange = false
        editor.buffer.modified = true
        saveCurrentEditedNote(announceSuccess: false)
        autosave.cancel()
    }

    func currentEditedNoteSnapshot() -> Note? {
        guard var selected = state.selectedNote else { return nil }
        selected.content = editor.buffer.text
        return selected
    }

    func saveCurrentEditedNote(announceSuccess: Bool) {
        guard let noteToSave = currentEditedNoteSnapshot() else { return }
        state.upsert(noteToSave)
        refreshSidebar()
        refreshPreview()
        do {
            let savedNote = try repository.save(note: noteToSave)
            handleSaveSuccess(savedNote, announceSuccess: announceSuccess)
        } catch {
            handleSaveFailure(error)
        }
    }

    func handleSaveSuccess(_ savedNote: Note, announceSuccess: Bool) {
        state.upsert(savedNote)
        editor.buffer.modified = false
        refreshDirectorySnapshot()
        refreshSidebar()
        refreshPreview()
        updateHeaderSubtitle()
        if announceSuccess {
            toastOverlay.showToast("Note saved")
        }
        applyDeferredExternalReloadIfPossible()
    }

    func handleSaveFailure(_ error: Error) {
        toastOverlay.showToast("Could not save note: \(error.localizedDescription)")
        updateHeaderSubtitle()
    }

    func presentRenameDialogForSelectedNote() {
        guard let selected = state.selectedNote else { return }

        let entry = Entry()
        entry.placeholderText = "Title"
        entry.text = selected.title
        entry.activatesDefault = true

        let dialog = AlertDialog(
            heading: "Rename note",
            body: "The note title is derived from the first meaningful line.",
        )
        dialog.extraChild = entry
        dialog.addResponse("cancel", label: "Cancel")
        dialog.addResponse("rename", label: "Rename")
        dialog.defaultResponse = "rename"
        dialog.closeResponse = "cancel"
        dialog.setResponseAppearance("rename", appearance: .suggested)
        dialog.setResponseEnabled("rename", enabled: !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        entry.onChanged {
            dialog.setResponseEnabled(
                "rename",
                enabled: !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            )
        }
        dialog.onResponse { [weak self] response in
            guard let self, response == "rename" else { return }
            renameSelectedNote(to: entry.text)
        }
        dialog.present(window)
        MainContext.idle {
            _ = entry.grabFocus()
            entry.selectAll()
        }
    }

    func renameSelectedNote(to newTitle: String) {
        guard let selected = state.selectedNote else { return }
        let renamed = selected.retitled(newTitle)
        do {
            let saved = try repository.save(note: renamed)
            state.upsert(saved)
            refreshDirectorySnapshot()
            renderSelection()
            persistWorkspaceState()
            toastOverlay.showToast("Note renamed")
        } catch {
            presentError(
                heading: "Could not rename note",
                body: error.localizedDescription,
            )
        }
    }
}
