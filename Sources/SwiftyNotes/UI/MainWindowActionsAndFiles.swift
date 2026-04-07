import Adwaita
import Foundation

@MainActor
extension MainWindow {
    func presentNoteContextMenu(forNoteID noteID: UUID, x: Int, y: Int) {
        noteContextDeferredAction = nil
        dismissNoteContextMenu()
        guard let rowIndex = displayedNotes.firstIndex(where: { $0.id == noteID }),
              let row = sidebar.list.rowAt(rowIndex),
              row.root != nil else {
            return
        }

        let popover = Popover()
        popover.hasArrow = true
        popover.position = .bottom
        popover.autohide = true
        popover.child = makeNoteContextPopoverContent()
        popover.onClosed { [weak self, weak popover] in
            guard let self, let popover else { return }
            if popover.parent != nil {
                popover.unparent()
            }
            if self.noteContextMenu === popover {
                self.noteContextMenu = nil
            }
            if let deferredAction = self.noteContextDeferredAction {
                self.noteContextDeferredAction = nil
                MainContext.idle(deferredAction)
            }
        }
        guard popover.present(from: row, x: x, y: y) else { return }
        noteContextMenu = popover
    }

    func dismissNoteContextMenu() {
        guard let noteContextMenu else { return }
        self.noteContextMenu = nil
        noteContextHandlers = [:]
        noteContextMenuLabels = []
        if noteContextMenu.parent != nil {
            noteContextMenu.popdown()
        }
    }

    func runAfterNoteContextMenuClosure(_ action: @escaping @MainActor () -> Void) {
        guard noteContextMenu != nil else {
            action()
            return
        }
        noteContextDeferredAction = action
        dismissNoteContextMenu()
    }

    func makeNoteContextPopoverContent() -> Widget {
        noteContextMenuLabels = [
            "Rename note…",
            "Duplicate note",
            "Export note…",
            "Copy note ID",
            "Delete…"
        ]

        let content = Box(orientation: .vertical, spacing: 2)
        content.setMargins(4)

        let renameAction: @MainActor () -> Void = { [weak self] in
            self?.presentRenameDialogForSelectedNote()
        }
        let duplicateAction: @MainActor () -> Void = { [weak self] in
            self?.duplicateSelectedNote()
        }
        let exportAction: @MainActor () -> Void = { [weak self] in
            self?.exportSelectedNote()
        }
        let copyIDAction: @MainActor () -> Void = { [weak self] in
            self?.copySelectedNoteID()
        }
        let deleteAction: @MainActor () -> Void = { [weak self] in
            self?.presentDeleteConfirmationForSelectedNote()
        }

        let renameButton = makeNoteContextButton(label: "Rename note…") { [weak self] in
            self?.runAfterNoteContextMenuClosure(renameAction)
        }
        let duplicateButton = makeNoteContextButton(label: "Duplicate note") { [weak self] in
            self?.runAfterNoteContextMenuClosure(duplicateAction)
        }
        let exportButton = makeNoteContextButton(label: "Export note…") { [weak self] in
            self?.runAfterNoteContextMenuClosure(exportAction)
        }
        let copyIDButton = makeNoteContextButton(label: "Copy note ID") { [weak self] in
            self?.runAfterNoteContextMenuClosure(copyIDAction)
        }
        let deleteButton = makeNoteContextButton(label: "Delete…", destructive: true) { [weak self] in
            self?.runAfterNoteContextMenuClosure(deleteAction)
        }

        [renameButton, duplicateButton, exportButton, copyIDButton, deleteButton].forEach(content.append)
        noteContextHandlers = [
            "Rename note…": renameAction,
            "Duplicate note": duplicateAction,
            "Export note…": exportAction,
            "Copy note ID": copyIDAction,
            "Delete…": deleteAction
        ]
        return content
    }

    func makeNoteContextButton(
        label: String,
        destructive: Bool = false,
        handler: @escaping @MainActor () -> Void
    ) -> Button {
        let button = Button()
        button.addCSSClass(.flat)
        button.hasFrame = false
        button.hexpand = true
        button.halign = .fill

        let title = Label(label)
        title.xalign = 0
        title.hexpand = true

        let row = Box(orientation: .horizontal, spacing: 0)
        row.hexpand = true
        row.halign = .fill
        row.append(title)
        button.child = row

        if destructive {
            button.addCSSClass(.destructiveAction)
        }
        button.onClicked(handler)
        return button
    }

    func copySelectedNoteID() {
        guard let selected = state.selectedNote else { return }
        copyNoteID(selected)
    }

    func copyNoteID(_ note: Note) {
        lastCopiedNoteID = note.stableID
        window.clipboard.setText(note.stableID)
        toastOverlay.showToast("Copied note ID")
    }

    func importNote() {
        let dialog = FileDialog()
        dialog.title = "Import Markdown"
        dialog.modal = true
        dialog.acceptLabel = "Import"
        dialog.setFilters([
            FileFilter(name: "Markdown", suffixes: ["md", "markdown", "txt"]),
            FileFilter(name: "All files", patterns: ["*"])
        ])
        activeFileDialog = dialog
        dialog.openThrowing(parent: window.root ?? window) { [weak self] result in
            guard let self else { return }
            self.activeFileDialog = nil
            switch result {
            case .success(nil):
                return
            case let .success(path?):
                do {
                    self.clearSearchIfNeeded()
                    let note = try self.repository.importNote(from: URL(fileURLWithPath: path))
                    self.state.upsert(note)
                    self.refreshDirectorySnapshot()
                    self.renderSelection()
                    self.persistWorkspaceState()
                    self.toastOverlay.showToast("Imported \(note.title)")
                } catch {
                    self.presentError(
                        heading: "Could not import note",
                        body: error.localizedDescription
                    )
                }
            case let .failure(error):
                self.presentError(
                    heading: "Could not open import dialog",
                    body: error.message
                )
            }
        }
    }

    func exportSelectedNote() {
        guard let selected = state.selectedNote else { return }
        let dialog = FileDialog()
        dialog.title = "Export Note"
        dialog.modal = true
        dialog.acceptLabel = "Export"
        dialog.initialName = selected.suggestedExportFilename
        dialog.setFilters([
            FileFilter(name: "Markdown", suffixes: ["md", "markdown", "txt"]),
            FileFilter(name: "All files", patterns: ["*"])
        ])
        activeFileDialog = dialog
        dialog.saveThrowing(parent: window.root ?? window) { [weak self] result in
            guard let self else { return }
            self.activeFileDialog = nil
            switch result {
            case .success(nil):
                return
            case let .success(path?):
                do {
                    try self.repository.export(note: selected, to: URL(fileURLWithPath: path))
                    self.toastOverlay.showToast("Exported \(selected.title)")
                } catch {
                    self.presentError(
                        heading: "Could not export note",
                        body: error.localizedDescription
                    )
                }
            case let .failure(error):
                self.presentError(
                    heading: "Could not open export dialog",
                    body: error.message
                )
            }
        }
    }

    func openNotesFolder() {
        do {
            let folderURL = try ensureNotesDirectoryExists()
            let directoryOpener = self.directoryOpener
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    try await directoryOpener(folderURL)
                } catch {
                    await MainActor.run { [weak self] in
                        self?.presentError(
                            heading: "Could not open notes folder",
                            body: error.localizedDescription
                        )
                    }
                }
            }
        } catch {
            presentError(
                heading: "Could not open notes folder",
                body: error.localizedDescription
            )
        }
    }

    func ensureNotesDirectoryExists() throws -> URL {
        let folderURL = repository.notesDirectoryURL.standardizedFileURL
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL
    }

    func presentAboutDialog() {
        let about = AboutDialog(
            appName: "Swifty Notes",
            version: "Development",
            developer: "Sergey Armodin",
            appIcon: AppIdentity.identifier,
            website: "https://github.com/makoni/swifty-notes-gtk",
            issueUrl: "https://github.com/makoni/swifty-notes-gtk/issues",
            copyright: "© 2026 Sergey Armodin",
            licenseType: .mit
        )
        about.comments = "A native GTK markdown notes app written in Swift using swift-adwaita."
        about.supportUrl = "https://github.com/makoni/swifty-notes-gtk"
        about.addLink("Source Code", url: "https://github.com/makoni/swifty-notes-gtk")
        about.onClosed { [weak self, weak about] in
            guard let self, let about, self.activeAboutDialog === about else { return }
            self.activeAboutDialog = nil
        }
        activeAboutDialog = about
        about.present(menuButton.root ?? window)
    }

    func reloadFromDisk(announce: Bool, forceDiscardingUnsavedChanges: Bool = false) {
        if editor.buffer.modified && !forceDiscardingUnsavedChanges {
            if !externalReloadDeferred {
                externalReloadDeferred = true
                toastOverlay.showToast(
                    "Notes changed on disk. Save or reload to sync.",
                    button: "Reload"
                ) { [weak self] in
                    self?.reloadFromDisk(announce: true, forceDiscardingUnsavedChanges: true)
                }
            }
            return
        }

        do {
            let notes = try repository.loadNotes()
            state.setNotes(notes)
            directorySnapshot = try repository.directorySnapshot()
            deferredExternalSnapshot = nil
            externalReloadDeferred = false
            renderSelection()
            persistWorkspaceState()
            if announce {
                toastOverlay.showToast("Notes reloaded from disk")
            }
        } catch {
            presentError(
                heading: "Could not reload notes",
                body: error.localizedDescription
            )
        }
    }

    func startExternalChangeMonitor() {
        stopExternalChangeMonitor()
        externalChangeMonitorID = MainContext.timeout(intervalMs: 1500) { [weak self] in
            guard let self else { return false }
            self.pollForExternalChanges()
            return true
        }
    }

    func stopExternalChangeMonitor() {
        if let externalChangeMonitorID {
            MainContext.cancel(sourceId: externalChangeMonitorID)
            self.externalChangeMonitorID = nil
        }
        if let previewRefreshID {
            MainContext.cancel(sourceId: previewRefreshID)
            self.previewRefreshID = nil
        }
        if let previewRefreshRetryID {
            MainContext.cancel(sourceId: previewRefreshRetryID)
            self.previewRefreshRetryID = nil
        }
        pendingPreviewBlocks = nil
        pendingPreviewBaseDirectory = nil
    }

    func pollForExternalChanges() {
        do {
            let latestSnapshot = try repository.directorySnapshot()
            guard latestSnapshot != directorySnapshot else {
                applyDeferredExternalReloadIfPossible()
                return
            }

            if editor.buffer.modified {
                deferredExternalSnapshot = latestSnapshot
                if !externalReloadDeferred {
                    externalReloadDeferred = true
                    toastOverlay.showToast(
                        "Notes changed on disk. Save or reload to sync.",
                        button: "Reload"
                    ) { [weak self] in
                        self?.reloadFromDisk(announce: true, forceDiscardingUnsavedChanges: true)
                    }
                }
                return
            }

            reloadFromDisk(announce: true, forceDiscardingUnsavedChanges: true)
        } catch {
            toastOverlay.showToast("Could not inspect notes directory")
        }
    }

    func applyDeferredExternalReloadIfPossible() {
        guard deferredExternalSnapshot != nil, !editor.buffer.modified else { return }
        reloadFromDisk(announce: true, forceDiscardingUnsavedChanges: true)
    }

    func refreshDirectorySnapshot() {
        do {
            directorySnapshot = try repository.directorySnapshot()
            deferredExternalSnapshot = nil
            externalReloadDeferred = false
        } catch {
            toastOverlay.showToast("Could not update notes index")
        }
    }

    func persistWorkspaceState() {
        let width = max(window.width, window.defaultWidth)
        let height = max(window.height, window.defaultHeight)
        do {
            try stateStore.save(state.persistedState(windowWidth: width, windowHeight: height))
        } catch {
            toastOverlay.showToast("Could not store workspace state")
        }
    }

    func presentError(heading: String, body: String) {
        let dialog = AlertDialog(heading: heading, body: body)
        dialog.addResponse("ok", label: "OK")
        dialog.defaultResponse = "ok"
        dialog.closeResponse = "ok"
        dialog.present(window)
    }

}
