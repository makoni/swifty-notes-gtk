import Adwaita
import Foundation

@MainActor
final class MainWindow {
    let window: ApplicationWindow

    private let state: AppState
    private let stateStore: WorkspaceStateStore
    private let repository: NotesRepository
    private let renderer: MarkdownRenderer
    private let autosave: AutosaveCoordinator

    private let sidebar = NotesSidebar()
    private let editor = MarkdownEditor()
    private let preview = MarkdownPreview()
    private let headerTitle = WindowTitle(title: "Swifty Notes", subtitle: "Markdown notes")
    private let previewToggle = Button(icon: .custom("sidebar-show-right-symbolic"))
    private let newNoteButton = Button(icon: .custom("list-add-symbolic"))
    private let saveNoteButton = Button(icon: .custom("document-save-symbolic"))
    private let deleteNoteButton = Button(icon: .userTrash)
    private let menuButton = MenuButton(icon: .custom("open-menu-symbolic"))
    private let toastOverlay = ToastOverlay()
    private let editorPreviewPane = Paned(orientation: .horizontal)
    private let editorScroll = ScrolledWindow()

    private lazy var renameAction = SimpleAction(name: "rename-note") { [weak self] in
        self?.presentRenameDialogForSelectedNote()
    }
    private lazy var duplicateAction = SimpleAction(name: "duplicate-note") { [weak self] in
        self?.duplicateSelectedNote()
    }
    private lazy var deleteAction = SimpleAction(name: "delete-note") { [weak self] in
        self?.presentDeleteConfirmationForSelectedNote()
    }
    private lazy var copyNoteIDAction = SimpleAction(name: "copy-note-id") { [weak self] in
        self?.copySelectedNoteID()
    }
    private lazy var exportAction = SimpleAction(name: "export-note") { [weak self] in
        self?.exportSelectedNote()
    }
    private lazy var importAction = SimpleAction(name: "import-note") { [weak self] in
        self?.importNote()
    }
    private lazy var openNotesFolderAction = SimpleAction(name: "open-notes-folder") { [weak self] in
        self?.openNotesFolder()
    }
    private lazy var reloadAction = SimpleAction(name: "reload-notes") { [weak self] in
        self?.reloadFromDisk(announce: true)
    }
    private lazy var saveAction = SimpleAction(name: "save-note") { [weak self] in
        self?.saveSelectedNoteNow()
    }
    private lazy var togglePreviewAction = SimpleAction(name: "toggle-preview") { [weak self] in
        self?.togglePreviewVisibility()
    }
    private lazy var sortNewestAction = SimpleAction(name: "sort-newest") { [weak self] in
        self?.setSortMode(.newestFirst)
    }
    private lazy var sortOldestAction = SimpleAction(name: "sort-oldest") { [weak self] in
        self?.setSortMode(.oldestFirst)
    }
    private lazy var sortTitleAction = SimpleAction(name: "sort-title") { [weak self] in
        self?.setSortMode(.title)
    }
    private lazy var noteContextCopyIDAction = SimpleAction(name: "context-copy-note-id") { [weak self] in
        self?.copySelectedNoteID()
        self?.dismissNoteContextMenu()
    }
    private lazy var noteContextDeleteAction = SimpleAction(name: "context-delete-note") { [weak self] in
        self?.dismissNoteContextMenu()
        self?.presentDeleteConfirmationForSelectedNote()
    }

    private var displayedNotes: [Note] = []
    private var directorySnapshot = NotesDirectorySnapshot()
    private var deferredExternalSnapshot: NotesDirectorySnapshot?
    private var externalChangeMonitorID: SourceID?
    private var externalReloadDeferred = false
    private var suppressEditorChange = false
    private var isRestoringPreviewPaneLayout = false
    private let noteContextActionGroup = SimpleActionGroup()
    private var noteContextMenu: PopoverMenu?

    init(
        application: Application,
        state: AppState,
        stateStore: WorkspaceStateStore,
        repository: NotesRepository,
        renderer: MarkdownRenderer,
        autosave: AutosaveCoordinator
    ) {
        self.state = state
        self.stateStore = stateStore
        self.repository = repository
        self.renderer = renderer
        self.autosave = autosave

        window = ApplicationWindow(application: application)
        window.title = "Swifty Notes"
        let preferredSize = Self.clampedWindowSize(
            width: state.preferredWindowWidth,
            height: state.preferredWindowHeight
        )
        window.defaultWidth = preferredSize.width
        window.defaultHeight = preferredSize.height

        buildUI()
        preview.attach(to: window)
        configureActionsAndMenu()
        wireSignals()
    }

    func present() {
        window.present()
        restorePreviewPaneLayout()
        loadInitialNotes()
        startExternalChangeMonitor()
        MainContext.idle { [weak self] in
            self?.restorePreviewPaneLayout()
            self?.editor.focus()
        }
    }

    private func buildUI() {
        previewToggle.addCSSClass(.flat)
        newNoteButton.addCSSClass(.flat)
        saveNoteButton.addCSSClass(.flat)
        deleteNoteButton.addCSSClass(.flat)
        menuButton.addCSSClass(.flat)
        menuButton.hasFrame = false

        sidebar.searchEntry.text = state.searchQuery

        let header = HeaderBar()
        header.titleWidget = headerTitle
        header.packStart(newNoteButton)
        header.packStart(saveNoteButton)
        header.packStart(deleteNoteButton)
        header.packEnd(menuButton)
        header.packEnd(previewToggle)

        editorScroll.child = editor.view
        editorScroll.setPolicy(horizontal: .automatic, vertical: .automatic)

        editorPreviewPane.startChild = editorScroll
        editorPreviewPane.endChild = preview.rootScroll
        editorPreviewPane.resizeStartChild = true
        editorPreviewPane.resizeEndChild = false
        editorPreviewPane.shrinkStartChild = false
        editorPreviewPane.shrinkEndChild = true
        editorPreviewPane.wideHandle = true
        applyPreviewVisibility()

        let contentPage = NavigationPage(child: editorPreviewPane, title: "Editor")
        let sidebarPage = NavigationPage(child: sidebar.root, title: "Notes")
        let navigation = NavigationSplitView()
        navigation.sidebarWidthFraction = 0.26
        navigation.setSidebar(sidebarPage)
        navigation.setContent(contentPage)

        let toolbar = ToolbarView()
        toolbar.addTopBar(header)
        toolbar.content = navigation

        toastOverlay.child = toolbar
        window.setContent(toastOverlay)
    }

    private func wireSignals() {
        sidebar.list.onRowActivated { [weak self] row in
            self?.selectNote(at: Int(row.index))
        }

        sidebar.searchEntry.onSearchChanged { [weak self] in
            guard let self else { return }
            self.state.setSearchQuery(self.sidebar.searchEntry.text)
            self.refreshSidebar()
            self.persistWorkspaceState()
        }

        previewToggle.onClicked { [weak self] in
            self?.togglePreviewVisibility()
        }

        newNoteButton.onClicked { [weak self] in
            self?.createNote()
        }

        saveNoteButton.onClicked { [weak self] in
            self?.saveSelectedNoteNow()
        }

        deleteNoteButton.onClicked { [weak self] in
            self?.presentDeleteConfirmationForSelectedNote()
        }

        editor.view.onChanged { [weak self] in
            guard let self, !self.suppressEditorChange, var selected = self.state.selectedNote else { return }
            selected.content = self.editor.buffer.text
            self.state.upsert(selected)
            self.refreshSidebar()
            self.refreshPreview()
            self.updateHeaderSubtitle()
            let noteToSave = selected
            Task {
                await self.autosave.scheduleSave {
                    await self.performSave(note: noteToSave, announceSuccess: false)
                }
            }
        }

        editor.buffer.onModifiedChanged { [weak self] in
            self?.updateHeaderSubtitle()
        }

        StyleManager.default.onDarkChanged { [weak self] in
            self?.editor.applyAutomaticStyleScheme()
            self?.refreshPreview()
        }

        editorPreviewPane.onPositionChanged { [weak self] in
            self?.handlePreviewPaneMoved()
        }

        editorScroll.verticalAdjustment.onValueChanged { [weak self] in
            guard let self else { return }
            self.syncPreviewScroll()
        }

        window.onCloseRequest { [weak self] in
            self?.persistWorkspaceState()
            self?.stopExternalChangeMonitor()
            Task { [weak self] in
                await self?.autosave.cancel()
            }
            return false
        }

        window.addKeyboardShortcut("<Ctrl>n") { [weak self] in
            self?.createNote()
            return true
        }
        window.addKeyboardShortcut("<Ctrl>s") { [weak self] in
            self?.saveSelectedNoteNow()
            return true
        }
        window.addKeyboardShortcut("<Ctrl>f") { [weak self] in
            self?.focusSearch()
            return true
        }
        window.addKeyboardShortcut("<Ctrl>o") { [weak self] in
            self?.importNote()
            return true
        }
        window.addKeyboardShortcut("<Ctrl><Shift>s") { [weak self] in
            self?.exportSelectedNote()
            return true
        }
        window.addKeyboardShortcut("<Ctrl><Shift>d") { [weak self] in
            self?.duplicateSelectedNote()
            return true
        }
        window.addKeyboardShortcut("F2") { [weak self] in
            self?.presentRenameDialogForSelectedNote()
            return true
        }
        window.addKeyboardShortcut("F5") { [weak self] in
            self?.reloadFromDisk(announce: true)
            return true
        }
        window.addKeyboardShortcut("F9") { [weak self] in
            self?.togglePreviewVisibility()
            return true
        }
    }

    private func loadInitialNotes() {
        do {
            let notes = try repository.loadNotes()
            if notes.isEmpty {
                let note = try repository.createNote()
                state.setNotes([note])
            } else {
                state.setNotes(notes)
            }
            directorySnapshot = try repository.directorySnapshot()
            renderSelection()
            updateHeaderSubtitle()
            persistWorkspaceState()
        } catch {
            presentError(
                heading: "Could not load notes",
                body: error.localizedDescription
            )
        }
    }

    private func selectNote(at index: Int) {
        guard displayedNotes.indices.contains(index) else { return }
        state.select(noteID: displayedNotes[index].id)
        renderSelection()
        persistWorkspaceState()
    }

    private func createNote() {
        do {
            clearSearchIfNeeded()
            let note = try repository.createNote()
            state.upsert(note)
            refreshDirectorySnapshot()
            renderSelection()
            persistWorkspaceState()
            editor.focus()
        } catch {
            presentError(
                heading: "Could not create note",
                body: error.localizedDescription
            )
        }
    }

    private func duplicateSelectedNote() {
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

    private func presentDeleteConfirmationForSelectedNote() {
        guard let selected = state.selectedNote else { return }
        presentDeleteConfirmation(for: selected)
    }

    private func presentDeleteConfirmation(for note: Note) {
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

    private func delete(note: Note) {
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

    private func renderSelection() {
        refreshSidebar()
        updateActionAvailability()
        guard let selected = state.selectedNote else {
            suppressEditorChange = true
            editor.setText("")
            suppressEditorChange = false
            preview.render(blocks: [], baseDirectory: repository.notesDirectoryURL)
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
        applyPreviewVisibility()
        updateHeaderSubtitle()
    }

    private func refreshSidebar() {
        displayedNotes = state.sortMode.sort(notes: state.notes.filter { $0.matches(searchQuery: state.searchQuery) })
        sidebar.render(
            notes: displayedNotes,
            selectedID: state.selectedNoteID,
            totalCount: state.notes.count,
            searchQuery: state.searchQuery
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

    private func refreshPreview() {
        guard let selected = state.selectedNote else {
            preview.render(blocks: [], baseDirectory: repository.notesDirectoryURL)
            return
        }
        let blocks = renderer.blocks(for: selected.content)
        preview.render(blocks: blocks, baseDirectory: repository.notesDirectoryURL)
        syncPreviewScroll()
    }

    private func syncPreviewScroll() {
        guard state.isPreviewVisible else { return }
        let source = editorScroll.verticalAdjustment
        let destination = preview.rootScroll.verticalAdjustment
        let sourceMax = max(source.upper - source.pageSize - source.lower, 0)
        let destinationMax = max(destination.upper - destination.pageSize - destination.lower, 0)
        let progress = sourceMax > 0 ? (source.value - source.lower) / sourceMax : 0
        destination.value = destination.lower + (destinationMax * progress)
    }

    private func configureActionsAndMenu() {
        window.addAction(renameAction)
        window.addAction(duplicateAction)
        window.addAction(deleteAction)
        window.addAction(copyNoteIDAction)
        window.addAction(exportAction)
        window.addAction(importAction)
        window.addAction(openNotesFolderAction)
        window.addAction(reloadAction)
        window.addAction(saveAction)
        window.addAction(togglePreviewAction)
        window.addAction(sortNewestAction)
        window.addAction(sortOldestAction)
        window.addAction(sortTitleAction)
        noteContextActionGroup.addAction(noteContextCopyIDAction)
        noteContextActionGroup.addAction(noteContextDeleteAction)
        window.insertActionGroup("notecontext", noteContextActionGroup)

        let noteSection = GMenuRef()
        noteSection.append("Copy note ID", action: "win.copy-note-id")
        noteSection.append("Rename note…", action: "win.rename-note")
        noteSection.append("Duplicate note", action: "win.duplicate-note")
        noteSection.append("Export note…", action: "win.export-note")
        noteSection.append("Delete note", action: "win.delete-note")

        let librarySection = GMenuRef()
        librarySection.append("Import markdown…", action: "win.import-note")
        librarySection.append("Reload from disk", action: "win.reload-notes")
        librarySection.append("Open notes folder", action: "win.open-notes-folder")

        let sortSection = GMenuRef()
        sortSection.append("Sort by newest", action: "win.sort-newest")
        sortSection.append("Sort by oldest", action: "win.sort-oldest")
        sortSection.append("Sort by title", action: "win.sort-title")

        let viewSection = GMenuRef()
        viewSection.append("Save now", action: "win.save-note")
        viewSection.append("Toggle preview", action: "win.toggle-preview")

        let menu = GMenuRef()
        menu.appendSection("Note", section: noteSection)
        menu.appendSection("Library", section: librarySection)
        menu.appendSection("Sort", section: sortSection)
        menu.appendSection("View", section: viewSection)
        menuButton.setMenuModel(menu)
        updateActionAvailability()
    }

    private func updateActionAvailability() {
        let hasSelection = state.selectedNote != nil
        renameAction.enabled = hasSelection
        duplicateAction.enabled = hasSelection
        deleteAction.enabled = hasSelection
        copyNoteIDAction.enabled = hasSelection
        exportAction.enabled = hasSelection
        saveAction.enabled = hasSelection
    }

    private func togglePreviewVisibility() {
        state.isPreviewVisible.toggle()
        applyPreviewVisibility()
        persistWorkspaceState()
    }

    private func applyPreviewVisibility() {
        if state.isPreviewVisible {
            editorPreviewPane.endChild = preview.rootScroll
            restorePreviewPaneLayout()
        } else {
            editorPreviewPane.endChild = nil
        }
    }

    private func restorePreviewPaneLayout() {
        guard state.isPreviewVisible else { return }
        let totalWidth = max(
            editorPreviewPane.width,
            window.width > 0 ? window.width - sidebar.root.width : 0,
            window.defaultWidth - 280,
            state.preferredWindowWidth - 280
        )
        let previewWidth = Self.resolvedPreviewWidth(
            storedWidth: state.preferredPreviewWidth,
            availableWidth: totalWidth
        )
        if state.preferredPreviewWidth == WorkspaceState.legacyDefaultPreviewWidth,
           previewWidth > state.preferredPreviewWidth {
            state.setPreferredPreviewWidth(previewWidth)
        }

        preview.rootScroll.minContentWidth = Self.minimumPreviewWidth

        isRestoringPreviewPaneLayout = true
        editorPreviewPane.position = max(totalWidth - previewWidth, Self.minimumEditorWidth)
        MainContext.idle { [weak self] in
            self?.isRestoringPreviewPaneLayout = false
        }
    }

    private func handlePreviewPaneMoved() {
        guard state.isPreviewVisible, editorPreviewPane.endChild != nil, !isRestoringPreviewPaneLayout else { return }
        let totalWidth = max(editorPreviewPane.width, window.width - sidebar.root.width, window.defaultWidth - 280)
        guard totalWidth >= Self.minimumPreviewWidth + Self.minimumEditorWidth else { return }
        let previewWidth = totalWidth - editorPreviewPane.position
        guard previewWidth >= Self.minimumPreviewWidth else { return }
        state.setPreferredPreviewWidth(previewWidth)
    }

    private func setSortMode(_ sortMode: NotesSortMode) {
        state.setSortMode(sortMode)
        refreshSidebar()
        persistWorkspaceState()
        toastOverlay.showToast("Sorting by \(sortMode.displayName.lowercased())")
    }

    private func focusSearch() {
        _ = sidebar.searchEntry.grabFocus()
    }

    private func clearSearchIfNeeded() {
        guard !state.searchQuery.isEmpty else { return }
        state.setSearchQuery("")
        sidebar.searchEntry.text = ""
    }

    private func updateHeaderSubtitle() {
        guard let selected = state.selectedNote else {
            headerTitle.subtitle = "Markdown notes"
            return
        }
        let wordCount = editor.buffer.text.split(whereSeparator: \.isWhitespace).count
        let saveState = editor.buffer.modified ? "Unsaved changes" : "Saved"
        headerTitle.subtitle = "\(selected.title) • \(saveState) • \(wordCount) words"
    }

    private func saveSelectedNoteNow() {
        guard let selected = state.selectedNote else { return }
        Task {
            await autosave.cancel()
            await performSave(note: selected, announceSuccess: true)
        }
    }

    private func performSave(note: Note, announceSuccess: Bool) async {
        let result = Result { try repository.save(note: note) }
        await MainActor.run { [weak self] in
            guard let self else { return }
            switch result {
            case let .success(savedNote):
                self.handleSaveSuccess(savedNote, expectedContent: note.content, announceSuccess: announceSuccess)
            case let .failure(error):
                self.handleSaveFailure(error)
            }
        }
    }

    private func handleSaveSuccess(_ savedNote: Note, expectedContent: String, announceSuccess: Bool) {
        _ = state.replace(savedNote, ifCurrentContentMatches: expectedContent)
        if state.selectedNoteID == savedNote.id, editor.buffer.text == savedNote.content {
            editor.buffer.modified = false
        }
        refreshDirectorySnapshot()
        refreshSidebar()
        updateHeaderSubtitle()
        if announceSuccess {
            toastOverlay.showToast("Note saved")
        }
        applyDeferredExternalReloadIfPossible()
    }

    private func handleSaveFailure(_ error: Error) {
        toastOverlay.showToast("Could not save note: \(error.localizedDescription)")
        updateHeaderSubtitle()
    }

    private func presentRenameDialogForSelectedNote() {
        guard let selected = state.selectedNote else { return }

        let entry = Entry()
        entry.placeholderText = "Title"
        entry.text = selected.title
        entry.activatesDefault = true

        let dialog = AlertDialog(
            heading: "Rename note",
            body: "The note title is derived from the first meaningful line."
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
                enabled: !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        dialog.onResponse { [weak self] response in
            guard let self, response == "rename" else { return }
            self.renameSelectedNote(to: entry.text)
        }
        dialog.present(window)
        MainContext.idle {
            _ = entry.grabFocus()
            entry.selectAll()
        }
    }

    private func renameSelectedNote(to newTitle: String) {
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
                body: error.localizedDescription
            )
        }
    }

    private func presentNoteContextMenu(forNoteID noteID: UUID, x: Int, y: Int) {
        dismissNoteContextMenu()
        guard let rowIndex = displayedNotes.firstIndex(where: { $0.id == noteID }),
              let row = sidebar.list.rowAt(rowIndex),
              row.root != nil else {
            return
        }

        let menu = GMenuRef()
        menu.append("Copy note ID", action: "notecontext.context-copy-note-id")
        menu.append("Delete…", action: "notecontext.context-delete-note")

        let popover = PopoverMenu(model: menu)
        popover.hasArrow = true
        popover.position = .bottom
        popover.onClosed { [weak self, weak popover] in
            guard let self, let popover else { return }
            if self.noteContextMenu === popover {
                self.noteContextMenu = nil
            }
            if popover.parent != nil {
                popover.unparent()
            }
        }
        guard popover.present(from: row, x: x, y: y) else { return }
        noteContextMenu = popover
    }

    private func dismissNoteContextMenu() {
        guard let noteContextMenu else { return }
        self.noteContextMenu = nil
        noteContextMenu.popdown()
        if noteContextMenu.parent != nil {
            noteContextMenu.unparent()
        }
    }

    private func copySelectedNoteID() {
        guard let selected = state.selectedNote else { return }
        copyNoteID(selected)
    }

    private func copyNoteID(_ note: Note) {
        window.clipboard.setText(note.stableID)
        toastOverlay.showToast("Copied note ID")
    }

    private func importNote() {
        let dialog = FileDialog()
        dialog.title = "Import Markdown"
        dialog.acceptLabel = "Import"
        dialog.setFilters([
            FileFilter(name: "Markdown", suffixes: ["md", "markdown", "txt"]),
            FileFilter(name: "All files", patterns: ["*"])
        ])
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let path = await dialog.open(parent: self.window) else { return }
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
        }
    }

    private func exportSelectedNote() {
        guard let selected = state.selectedNote else { return }
        let dialog = FileDialog()
        dialog.title = "Export Note"
        dialog.acceptLabel = "Export"
        dialog.initialName = selected.suggestedExportFilename
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let path = await dialog.save(parent: self.window) else { return }
            do {
                try self.repository.export(note: selected, to: URL(fileURLWithPath: path))
                self.toastOverlay.showToast("Exported \(selected.title)")
            } catch {
                self.presentError(
                    heading: "Could not export note",
                    body: error.localizedDescription
                )
            }
        }
    }

    private func openNotesFolder() {
        let launcher = UriLauncher(uri: repository.notesDirectoryURL.absoluteString)
        launcher.launch(parent: window)
    }

    private func reloadFromDisk(announce: Bool, forceDiscardingUnsavedChanges: Bool = false) {
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

    private func startExternalChangeMonitor() {
        stopExternalChangeMonitor()
        externalChangeMonitorID = MainContext.timeout(intervalMs: 1500) { [weak self] in
            guard let self else { return false }
            self.pollForExternalChanges()
            return true
        }
    }

    private func stopExternalChangeMonitor() {
        if let externalChangeMonitorID {
            MainContext.cancel(sourceId: externalChangeMonitorID)
            self.externalChangeMonitorID = nil
        }
    }

    private func pollForExternalChanges() {
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

    private func applyDeferredExternalReloadIfPossible() {
        guard deferredExternalSnapshot != nil, !editor.buffer.modified else { return }
        reloadFromDisk(announce: true, forceDiscardingUnsavedChanges: true)
    }

    private func refreshDirectorySnapshot() {
        do {
            directorySnapshot = try repository.directorySnapshot()
            deferredExternalSnapshot = nil
            externalReloadDeferred = false
        } catch {
            toastOverlay.showToast("Could not update notes index")
        }
    }

    private func persistWorkspaceState() {
        let width = max(window.width, window.defaultWidth)
        let height = max(window.height, window.defaultHeight)
        do {
            try stateStore.save(state.persistedState(windowWidth: width, windowHeight: height))
        } catch {
            toastOverlay.showToast("Could not store workspace state")
        }
    }

    private func presentError(heading: String, body: String) {
        let dialog = AlertDialog(heading: heading, body: body)
        dialog.addResponse("ok", label: "OK")
        dialog.defaultResponse = "ok"
        dialog.closeResponse = "ok"
        dialog.present(window)
    }

    private static func clampedWindowSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard let monitor = Display.default?.monitors.first?.geometry else {
            return (width, height)
        }
        return (
            max(900, min(width, monitor.width - 80)),
            max(700, min(height, monitor.height - 80))
        )
    }

    static let minimumPreviewWidth = 400
    private static let minimumEditorWidth = 420

    static func resolvedPreviewWidth(storedWidth: Int, availableWidth: Int) -> Int {
        let boundedAvailableWidth = max(availableWidth, minimumPreviewWidth + minimumEditorWidth)
        let maximumPreviewWidth = max(boundedAvailableWidth - minimumEditorWidth, minimumPreviewWidth)
        let comfortablePreviewWidth = min(
            max(Int(Double(boundedAvailableWidth) * 0.34), WorkspaceState.defaultPreviewWidth),
            maximumPreviewWidth
        )
        let requestedWidth: Int
        if storedWidth == WorkspaceState.legacyDefaultPreviewWidth {
            requestedWidth = max(storedWidth, comfortablePreviewWidth)
        } else {
            requestedWidth = storedWidth
        }
        return min(max(requestedWidth, minimumPreviewWidth), maximumPreviewWidth)
    }

    #if DEBUG
    func debugLoadInitialNotes() {
        loadInitialNotes()
    }

    func debugCreateNote() {
        createNote()
    }

    func debugEmitNewNoteClicked() {
        g_signal_emit_by_name_no_args(UnsafeMutableRawPointer(newNoteButton.opaquePointer), "clicked")
    }

    func debugSetEditorText(_ text: String) {
        editor.buffer.text = text
    }

    var debugNotesCount: Int {
        state.notes.count
    }

    var debugSelectedNoteContent: String? {
        state.selectedNote?.content
    }

    var debugPreviewText: String {
        preview.plainText
    }

    var debugDisplayedNotesCount: Int {
        displayedNotes.count
    }

    func debugOpenContextMenuForDisplayedNote(at index: Int) {
        guard displayedNotes.indices.contains(index) else { return }
        let note = displayedNotes[index]
        state.select(noteID: note.id)
        renderSelection()
        presentNoteContextMenu(forNoteID: note.id, x: 8, y: 8)
    }

    func debugDismissContextMenu() {
        dismissNoteContextMenu()
    }

    var debugHasContextMenu: Bool {
        noteContextMenu != nil
    }

    func debugPollForExternalChanges() {
        pollForExternalChanges()
    }

    var debugPreferredPreviewWidth: Int {
        state.preferredPreviewWidth
    }
    #endif
}
