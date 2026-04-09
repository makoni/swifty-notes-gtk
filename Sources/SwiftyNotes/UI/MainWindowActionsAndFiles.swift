import Adwaita
import Foundation

private enum DroppedImageImportError: LocalizedError {
    case noSelectedNote
    case unsupportedFile(String)

    var errorDescription: String? {
        switch self {
        case .noSelectedNote:
            return "Open or create a note before dropping images."
        case let .unsupportedFile(filename):
            return "Unsupported image type for \(filename)."
        }
    }
}

@MainActor
extension MainWindow {
    func presentNoteContextMenu(forNoteID noteID: UUID, x: Int, y: Int) {
        noteContextDeferredAction = nil
        noteContextMenuRequestID &+= 1
        let requestID = noteContextMenuRequestID
        dismissNoteContextMenu(cancelPendingPresentation: false)
        presentNoteContextMenuIfReady(forNoteID: noteID, x: x, y: y, requestID: requestID)
    }

    func presentNoteContextMenuIfReady(
        forNoteID noteID: UUID,
        x: Int,
        y: Int,
        requestID: UInt,
        remainingAttempts: Int = 20
    ) {
        guard requestID == noteContextMenuRequestID,
              let rowIndex = displayedNotes.firstIndex(where: { $0.id == noteID }),
              let row = sidebar.list.rowAt(rowIndex) else {
            return
        }
        guard row.root != nil, row.width > 0, row.height > 0 else {
            guard remainingAttempts > 0 else { return }
            MainContext.delay(for: .milliseconds(10)) { [weak self] in
                self?.presentNoteContextMenuIfReady(
                    forNoteID: noteID,
                    x: x,
                    y: y,
                    requestID: requestID,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }

        let popover = Popover()
        popover.hasArrow = true
        popover.position = .bottom
        popover.autohide = true
        popover.child = makeNoteContextPopoverContent()
        popover.onClosed { [weak self, weak popover] in
            guard let self, let popover else { return }
            if popover.root != nil {
                popover.unparent()
            }
            if self.noteContextMenu === popover {
                self.noteContextMenu = nil
            }
            self.noteContextHandlers = [:]
            self.noteContextMenuLabels = []
        }
        guard popover.present(from: row, x: x, y: y) else {
            guard remainingAttempts > 0 else { return }
            MainContext.delay(for: .milliseconds(10)) { [weak self] in
                self?.presentNoteContextMenuIfReady(
                    forNoteID: noteID,
                    x: x,
                    y: y,
                    requestID: requestID,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }
        noteContextMenu = popover
    }

    func dismissNoteContextMenu(cancelPendingPresentation: Bool = true) {
        if cancelPendingPresentation {
            noteContextMenuRequestID &+= 1
        }
        guard let noteContextMenu else { return }
        self.noteContextMenu = nil
        noteContextHandlers = [:]
        noteContextMenuLabels = []
        let deferredAction = noteContextDeferredAction
        noteContextDeferredAction = nil
        noteContextMenu.popdown()
        if noteContextMenu.root != nil {
            noteContextMenu.unparent()
        }
        if let deferredAction {
            MainContext.idle(deferredAction)
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

    func installEditorImageDropTarget() {
        let dropTarget = DropTarget.forFiles()
        dropTarget.onDropFiles { [weak self] urls in
            guard let self, !urls.isEmpty else { return false }
            do {
                try self.importDroppedImages(from: urls)
                return true
            } catch {
                self.presentError(
                    heading: "Could not add image",
                    body: error.localizedDescription
                )
                return false
            }
        }
        editor.view.addController(dropTarget)
    }

    func importDroppedImages(from sourceURLs: [URL]) throws {
        guard let selected = currentEditedNoteSnapshot() else {
            throw DroppedImageImportError.noSelectedNote
        }
        if let unsupported = sourceURLs.first(where: { !NotesRepository.supportsImageAssetImport(from: $0) }) {
            throw DroppedImageImportError.unsupportedFile(unsupported.lastPathComponent)
        }

        let snippets = try sourceURLs.map { sourceURL in
            let relativePath = try repository.importImageAsset(from: sourceURL, for: selected)
            return "![\(Self.droppedImageAltText(for: sourceURL))](\(relativePath))"
        }

        refreshDirectorySnapshot()
        editor.buffer.insertAtCursor(snippets.joined(separator: "\n"))
        toastOverlay.showToast(sourceURLs.count == 1 ? "Image added to note" : "Images added to note")
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
            try directoryOpener(folderURL)
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
            version: BuildInfo.version,
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

    func presentSettingsWindow() {
        if let activeSettingsWindow {
            activeSettingsWindow.present()
            return
        }
        guard let application = Application.current else {
            presentError(
                heading: "Could not open settings",
                body: "The application instance is not available."
            )
            return
        }

        let settingsWindow = SettingsWindow(
            application: application,
            parentWindow: window,
            currentSettings: appSettings,
            currentNotesDirectory: repository.notesDirectoryURL,
            defaultNotesDirectory: NotesRepository.fallbackNotesDirectory(),
            applyNotesDirectoryChange: { [weak self] directory in
                guard let self else {
                    throw CocoaError(.userCancelled)
                }
                return try self.changeNotesDirectory(to: directory)
            },
            applySettingsChange: { [weak self] settings in
                guard let self else {
                    throw CocoaError(.userCancelled)
                }
                return try self.updateAppSettings(settings)
            },
            openDirectory: { [weak self] url in
                guard let self else {
                    throw CocoaError(.userCancelled)
                }
                try self.openDirectoryFromSettings(url)
            }
        )
        settingsWindow.window.onDestroy { [weak self, weak settingsWindow] in
            guard let self, let settingsWindow, self.activeSettingsWindow === settingsWindow else { return }
            self.activeSettingsWindow = nil
        }
        activeSettingsWindow = settingsWindow
        settingsWindow.present()
    }

    func openDirectoryFromSettings(_ folderURL: URL) throws {
        try MainWindow.openDirectoryInSystemFileManager(folderURL)
    }

    func changeNotesDirectory(
        to directory: URL,
        targetSettings explicitTargetSettings: AppSettings? = nil
    ) throws -> URL {
        let defaultDirectory = NotesRepository.fallbackNotesDirectory()
        let targetSettings = (
            explicitTargetSettings
            ?? appSettings.updatingNotesDirectory(
                directory.standardizedFileURL,
                defaultDirectory: defaultDirectory
            )
        ).normalized(defaultDirectory: defaultDirectory)
        let targetDirectory = targetSettings.resolvedNotesDirectory(defaultDirectory: defaultDirectory)
        let currentDirectory = repository.notesDirectoryURL.standardizedFileURL
        guard targetDirectory != currentDirectory else { return currentDirectory }

        try saveModifiedNoteBeforeStorageMove()
        stopExternalChangeMonitor()
        do {
            try repository.ensureNotesDirectory()
            try NotesDirectoryRelocator.relocate(from: currentDirectory, to: targetDirectory)
            do {
                try appSettingsStore.save(targetSettings)
            } catch {
                do {
                    try NotesDirectoryRelocator.relocate(from: targetDirectory, to: currentDirectory)
                } catch let rollbackError {
                    throw MainWindow.DirectoryOpenFailure(
                        message: [
                            error.localizedDescription,
                            "Rollback failed: \(rollbackError.localizedDescription)"
                        ].joined(separator: "\n")
                    )
                }
                throw error
            }

            repository = NotesRepository(notesDirectory: targetDirectory)
            let notes = try repository.loadNotes()
            state.setNotes(notes)
            directorySnapshot = try repository.directorySnapshot()
            deferredExternalSnapshot = nil
            externalReloadDeferred = false
            applyRuntimeSettings(targetSettings, shouldRefreshPreview: false)
            renderSelection()
            persistWorkspaceState()
            startExternalChangeMonitor()
            toastOverlay.showToast("Notes folder updated")
            return targetDirectory
        } catch {
            startExternalChangeMonitor()
            throw error
        }
    }

    func saveModifiedNoteBeforeStorageMove() throws {
        guard editor.buffer.modified, let noteToSave = currentEditedNoteSnapshot() else { return }
        state.upsert(noteToSave)
        let savedNote = try repository.save(note: noteToSave)
        handleSaveSuccess(savedNote, announceSuccess: false)
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
        externalChangeMonitorID = MainContext.timeout(every: .milliseconds(1500)) { [weak self] in
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

    private static func droppedImageAltText(for sourceURL: URL) -> String {
        let raw = sourceURL.deletingPathExtension().lastPathComponent
        let normalized = raw
            .replacingOccurrences(of: #"[_-]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "Image" : normalized
    }

}
