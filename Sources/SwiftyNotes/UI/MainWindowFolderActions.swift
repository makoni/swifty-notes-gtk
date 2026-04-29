import Adwaita
import Foundation

@MainActor
extension MainWindow {
    func presentFolderContextMenu(forFolderPath folderPath: String, x: Int, y: Int) {
        // Both context menus dismiss as soon as either opens so a stale
        // popover never lingers across re-renders.
        dismissNoteContextMenu()
        dismissFolderContextMenu()

        let folderRowIndex = sidebar.renderedItems.firstIndex { item in
            if case let .folder(folder) = item { return folder.path == folderPath }
            return false
        }
        guard let rowIndex = folderRowIndex,
              let row = sidebar.list.rowAt(rowIndex)
        else { return }
        guard row.root != nil else { return }

        let popover = Popover()
        popover.hasArrow = true
        popover.position = .bottom
        popover.autohide = true
        popover.child = makeFolderContextPopoverContent(forFolderPath: folderPath)
        popover.onClosed { [weak self, weak popover] in
            guard let popover else { return }
            if popover.root != nil {
                popover.unparent()
            }
            if self?.folderContextMenu === popover {
                self?.folderContextMenu = nil
            }
        }
        guard popover.present(from: row, x: x, y: y) else { return }
        folderContextMenu = popover
    }

    func dismissFolderContextMenu() {
        guard let popover = folderContextMenu else { return }
        folderContextMenu = nil
        popover.popdown()
        if popover.root != nil {
            popover.unparent()
        }
    }

    private func makeFolderContextPopoverContent(forFolderPath folderPath: String) -> Widget {
        let content = Box(orientation: .vertical, spacing: 2)
        content.setMargins(4)

        let createNoteButton = makeFolderContextButton(label: "New note here") { [weak self] in
            self?.createNote(in: folderPath)
        }
        let createSubfolderButton = makeFolderContextButton(label: "New subfolder…") { [weak self] in
            self?.presentNewFolderDialog(parentPath: folderPath)
        }
        let renameButton = makeFolderContextButton(label: "Rename folder…") { [weak self] in
            self?.presentRenameFolderDialog(at: folderPath)
        }
        let deleteButton = makeFolderContextButton(label: "Delete folder…", destructive: true) { [weak self] in
            self?.presentDeleteFolderConfirmation(at: folderPath)
        }

        [createNoteButton, createSubfolderButton, renameButton, deleteButton].forEach(content.append)
        return content
    }

    private func makeFolderContextButton(
        label: String,
        destructive: Bool = false,
        handler: @escaping @MainActor () -> Void,
    ) -> Button {
        let button = Button()
        let row = Box(orientation: .horizontal, spacing: 8)
        row.hexpand = true
        row.halign = .fill
        let titleLabel = Label(label)
        titleLabel.xalign = 0
        titleLabel.hexpand = true
        row.append(titleLabel)
        button.child = row
        button.addCSSClass("flat")
        if destructive {
            button.addCSSClass(.destructiveAction)
        }
        button.halign = .fill
        button.hexpand = true
        button.onClicked { [weak self] in
            self?.runAfterFolderContextMenuClosure(handler)
        }
        return button
    }

    private func runAfterFolderContextMenuClosure(_ action: @escaping @MainActor () -> Void) {
        // Tear the popover down before the action runs so refreshSidebar
        // (which the action may trigger) doesn't have to walk over a row
        // that still owns a parented popover. Deferring through MainContext.idle
        // also lets the click-release transition complete first.
        dismissFolderContextMenu()
        MainContext.idle(action)
    }

    /// Creates a note inside `folderPath`, expanding the folder so the new
    /// note is visible right away.
    func createNote(in folderPath: String) {
        do {
            clearSearchIfNeeded()
            let note = try repository.createNote(in: folderPath)
            state.upsert(note)
            if !folderPath.isEmpty {
                state.setFolderExpanded(folderPath, expanded: true)
            }
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

    func presentNewFolderDialog(parentPath: String) {
        let dialog = AlertDialog(
            heading: parentPath.isEmpty ? "New folder" : "New subfolder in \"\(parentPath)\"",
            body: "Use / to create nested folders in one step, e.g. Work/Drafts.",
        )
        let entry = Entry()
        entry.placeholderText = parentPath.isEmpty ? "Folder name or Work/Drafts" : "Folder name"
        entry.activatesDefault = true
        dialog.extraChild = entry
        dialog.addResponse("cancel", label: "Cancel")
        dialog.addResponse("create", label: "Create")
        dialog.defaultResponse = "create"
        dialog.closeResponse = "cancel"
        dialog.setResponseAppearance("create", appearance: .suggested)
        dialog.setResponseEnabled("create", enabled: false)
        entry.onChanged {
            dialog.setResponseEnabled("create", enabled: FolderNameValidation.isAcceptablePath(entry.text))
        }
        dialog.onResponse { [weak self] response in
            guard let self, response == "create" else { return }
            guard FolderNameValidation.isAcceptablePath(entry.text) else { return }
            // Normalize so each component has no surrounding whitespace —
            // user-typed "Work / Drafts" lands on disk as "Work/Drafts".
            let typed = FolderNameValidation.normalizePath(entry.text)
            guard !typed.isEmpty else { return }
            let path = parentPath.isEmpty ? typed : "\(parentPath)/\(typed)"
            createFolder(at: path, expandAfter: parentPath)
        }
        dialog.present(window)
        _ = entry.grabFocus()
    }

    func createFolder(at path: String, expandAfter parentPath: String?) {
        do {
            try repository.createFolder(at: path)
            refreshFolderList()
            if let parentPath, !parentPath.isEmpty {
                state.setFolderExpanded(parentPath, expanded: true)
            }
            refreshSidebar()
            refreshDirectorySnapshot()
            persistWorkspaceState()
        } catch {
            presentError(
                heading: "Could not create folder",
                body: error.localizedDescription,
            )
        }
    }

    func presentRenameFolderDialog(at folderPath: String) {
        let currentName = (folderPath as NSString).lastPathComponent
        let dialog = AlertDialog(
            heading: "Rename folder",
            body: "Renaming \"\(folderPath)\". Folder names cannot contain slashes (/).",
        )
        let entry = Entry()
        entry.text = currentName
        entry.activatesDefault = true
        entry.selectAll()
        dialog.extraChild = entry
        dialog.addResponse("cancel", label: "Cancel")
        dialog.addResponse("rename", label: "Rename")
        dialog.defaultResponse = "rename"
        dialog.closeResponse = "cancel"
        dialog.setResponseAppearance("rename", appearance: .suggested)
        // Same name as the current one is a no-op, so keep Rename disabled
        // until the user actually types something different.
        dialog.setResponseEnabled("rename", enabled: false)
        entry.onChanged {
            dialog.setResponseEnabled(
                "rename",
                enabled: FolderNameValidation.isAcceptableName(entry.text, currentName: currentName),
            )
        }
        dialog.onResponse { [weak self] response in
            guard let self, response == "rename" else { return }
            guard FolderNameValidation.isAcceptableName(entry.text, currentName: currentName) else { return }
            let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            renameFolder(at: folderPath, to: trimmed)
        }
        dialog.present(window)
        _ = entry.grabFocus()
    }

    func renameFolder(at folderPath: String, to newName: String) {
        do {
            try repository.renameFolder(at: folderPath, to: newName)
            // Re-load notes — a folder rename moves every nested note's
            // folderPath on disk, and the in-memory copies need to follow.
            let notes = try repository.loadNotes()
            state.setNotes(notes)
            refreshFolderList()
            // Expanded set: rewrite any path that started with the old prefix
            // so users don't have to re-expand the renamed branch.
            let parent = NotesRepository.parentFolderPath(of: folderPath)
            let newPath = parent.isEmpty ? newName : "\(parent)/\(newName)"
            let migrated = state.expandedFolders.map { entry -> String in
                if entry == folderPath { return newPath }
                if entry.hasPrefix("\(folderPath)/") {
                    return newPath + entry.dropFirst(folderPath.count)
                }
                return entry
            }
            state.setExpandedFolders(Set(migrated))
            refreshSidebar()
            refreshDirectorySnapshot()
            persistWorkspaceState()
            toastOverlay.showToast("Folder renamed")
        } catch {
            presentError(
                heading: "Could not rename folder",
                body: error.localizedDescription,
            )
        }
    }

    func presentDeleteFolderConfirmation(at folderPath: String) {
        let nestedNotes = state.notes.filter { note in
            note.folderPath == folderPath || note.folderPath.hasPrefix("\(folderPath)/")
        }.count
        let nestedFolders = state.folders.filter { entry in
            entry != folderPath && entry.hasPrefix("\(folderPath)/")
        }.count

        let summary: String = {
            if nestedNotes == 0, nestedFolders == 0 {
                return "\"\(folderPath)\" is empty."
            }
            var parts: [String] = []
            if nestedNotes > 0 {
                parts.append(nestedNotes == 1 ? "1 note" : "\(nestedNotes) notes")
            }
            if nestedFolders > 0 {
                parts.append(nestedFolders == 1 ? "1 subfolder" : "\(nestedFolders) subfolders")
            }
            return "\"\(folderPath)\" contains \(parts.joined(separator: " and ")). They will be permanently deleted."
        }()

        let dialog = AlertDialog(
            heading: "Delete folder?",
            body: summary,
        )
        dialog.addResponse("cancel", label: "Cancel")
        dialog.addResponse("delete", label: "Delete")
        dialog.defaultResponse = "cancel"
        dialog.closeResponse = "cancel"
        dialog.setResponseAppearance("delete", appearance: .destructive)
        dialog.onResponse { [weak self] response in
            guard let self, response == "delete" else { return }
            deleteFolder(at: folderPath)
        }
        dialog.present(window)
    }

    func presentMoveNoteDialogForSelectedNote() {
        guard let note = state.selectedNote else { return }
        presentMoveNoteDialog(for: note)
    }

    func presentMoveNoteDialog(for note: Note) {
        let availableTargets = ["" /* root */] + state.folders.sorted()
        let targetsExceptCurrent = availableTargets.filter { $0 != note.folderPath }
        guard !targetsExceptCurrent.isEmpty else {
            toastOverlay.showToast("No other folders to move into")
            return
        }

        let dialog = AlertDialog(
            heading: "Move note",
            body: "Choose a destination folder for \"\(note.title)\".",
        )

        let listBox = ListBox()
        listBox.selectionMode = .single
        listBox.addCSSClass(.boxedList)
        for target in targetsExceptCurrent {
            let row = ListBoxRow()
            row.activatable = true
            let label = Label(target.isEmpty ? "(Root)" : target)
            label.xalign = 0
            label.setMargins(8)
            row.child = label
            listBox.append(row)
        }
        listBox.selectRow(at: 0)

        let scroll = ScrolledWindow(child: listBox)
        scroll.setPolicy(horizontal: .never, vertical: .automatic)
        scroll.minContentHeight = 220
        scroll.hexpand = true
        scroll.vexpand = false

        dialog.extraChild = scroll
        dialog.addResponse("cancel", label: "Cancel")
        dialog.addResponse("move", label: "Move")
        dialog.defaultResponse = "move"
        dialog.closeResponse = "cancel"
        dialog.setResponseAppearance("move", appearance: .suggested)
        dialog.onResponse { [weak self] response in
            guard let self, response == "move" else { return }
            guard let selectedRow = listBox.selectedRow else { return }
            let selectedIndex = Int(selectedRow.index)
            guard targetsExceptCurrent.indices.contains(selectedIndex) else { return }
            moveNote(note, to: targetsExceptCurrent[selectedIndex])
        }
        dialog.present(window)
    }

    func moveNote(_ note: Note, to folderPath: String) {
        do {
            let moved = try repository.move(note: note, to: folderPath)
            state.upsert(moved)
            // Re-load to keep ordering aligned with on-disk layout —
            // upsert sorts by createdAt only, but a moved note is identical
            // and gets re-pinned at top, which would lie about recency.
            let notes = try repository.loadNotes()
            state.setNotes(notes)
            if !folderPath.isEmpty {
                state.setFolderExpanded(folderPath, expanded: true)
            }
            refreshDirectorySnapshot()
            renderSelection()
            persistWorkspaceState()
            toastOverlay.showToast("Note moved")
        } catch {
            presentError(
                heading: "Could not move note",
                body: error.localizedDescription,
            )
        }
    }

    func deleteFolder(at folderPath: String) {
        do {
            try repository.deleteFolderRecursively(at: folderPath)
            let notes = try repository.loadNotes()
            state.setNotes(notes)
            refreshFolderList()
            // Drop any expanded entries that pointed inside the removed branch.
            let surviving = state.expandedFolders.filter { entry in
                entry != folderPath && !entry.hasPrefix("\(folderPath)/")
            }
            state.setExpandedFolders(surviving)
            refreshDirectorySnapshot()
            renderSelection()
            persistWorkspaceState()
            toastOverlay.showToast("Folder deleted")
        } catch {
            presentError(
                heading: "Could not delete folder",
                body: error.localizedDescription,
            )
        }
    }
}
