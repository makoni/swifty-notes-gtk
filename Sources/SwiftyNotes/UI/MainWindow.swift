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
    private let sidebarToggle = Button(iconName: "sidebar-show-symbolic")
    private let previewToggle = Button(icon: .custom("sidebar-show-right-symbolic"))
    private let newNoteButton = Button(icon: .custom("list-add-symbolic"))
    private let saveNoteButton = Button(icon: .custom("document-save-symbolic"))
    private let deleteNoteButton = Button(icon: .userTrash)
    private let menuButton = MenuButton(icon: .custom("open-menu-symbolic"))
    private let toastOverlay = ToastOverlay()
    private let splitView = OverlaySplitView()
    private let editorPreviewPane = Paned(orientation: .horizontal)
    private let editorScroll = ScrolledWindow()
    private let autosaveDelay: Duration
    private let directoryOpener: @Sendable (URL) async throws -> Void

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

    private var displayedNotes: [Note] = []
    private var directorySnapshot = NotesDirectorySnapshot()
    private var deferredExternalSnapshot: NotesDirectorySnapshot?
    private var externalChangeMonitorID: SourceID?
    private var externalReloadDeferred = false
    private var suppressEditorChange = false
    private var previewRefreshID: SourceID?
    private var pendingPreviewBlocks: [RenderedBlock]?
    private var pendingPreviewBaseDirectory: URL?
    private var isRestoringPreviewPaneLayout = false
    private var previewAnimationID: SourceID?
    private var isPreviewPaneAttached = false
    private var noteContextMenu: Popover?
    private var noteContextHandlers: [String: @MainActor () -> Void] = [:]
    private var noteContextDeferredAction: (@MainActor () -> Void)?
    private var activeFileDialog: FileDialog?
    private var overflowMenuSectionTitles: [String] = []
    private var noteContextMenuLabels: [String] = []
    private var lastCopiedNoteID: String?

    init(
        application: Application,
        state: AppState,
        stateStore: WorkspaceStateStore,
        repository: NotesRepository,
        renderer: MarkdownRenderer,
        autosave: AutosaveCoordinator,
        autosaveDelay: Duration = .seconds(2),
        directoryOpener: @escaping @Sendable (URL) async throws -> Void = MainWindow.openDirectoryInSystemFileManager
    ) {
        self.state = state
        self.stateStore = stateStore
        self.repository = repository
        self.renderer = renderer
        self.autosave = autosave
        self.autosaveDelay = autosaveDelay
        self.directoryOpener = directoryOpener

        window = ApplicationWindow(application: application)
        window.title = "Swifty Notes"
        let preferredSize = Self.clampedWindowSize(
            width: state.preferredWindowWidth,
            height: state.preferredWindowHeight
        )
        window.setDefaultSize(width: preferredSize.width, height: preferredSize.height)

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
            self?.refreshPreview()
            self?.restorePreviewPaneLayout()
            self?.editor.focus()
        }
    }

    private func buildUI() {
        sidebarToggle.addCSSClass(.flat)
        previewToggle.addCSSClass(.flat)
        newNoteButton.addCSSClass(.flat)
        saveNoteButton.addCSSClass(.flat)
        deleteNoteButton.addCSSClass(.flat)
        menuButton.addCSSClass(.flat)
        menuButton.hasFrame = false
        configureToolbarAccessibility()
        configureToolbarTooltips()

        sidebar.searchEntry.text = state.searchQuery
        sidebar.setSortMode(state.sortMode)

        let header = HeaderBar()
        header.titleWidget = headerTitle
        header.packStart(sidebarToggle)
        header.packStart(newNoteButton)
        header.packStart(saveNoteButton)
        header.packStart(deleteNoteButton)
        header.packEnd(menuButton)
        header.packEnd(previewToggle)

        editorScroll.child = editor.view
        editorScroll.setPolicy(horizontal: .automatic, vertical: .automatic)

        editorPreviewPane.startChild = editorScroll
        editorPreviewPane.resizeStartChild = true
        editorPreviewPane.resizeEndChild = false
        editorPreviewPane.shrinkStartChild = false
        editorPreviewPane.shrinkEndChild = true
        editorPreviewPane.wideHandle = true
        applyPreviewVisibility(animated: false)

        splitView.pinSidebar = true
        splitView.showSidebar = state.isSidebarVisible
        splitView.enableShowGesture = true
        splitView.enableHideGesture = true
        splitView.sidebarWidthFraction = 0.26
        splitView.minSidebarWidth = 240
        splitView.maxSidebarWidth = 380
        splitView.sidebar = sidebar.root
        splitView.content = editorPreviewPane
        applySidebarVisibility()

        let toolbar = ToolbarView()
        toolbar.addTopBar(header)
        toolbar.content = splitView

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

        sidebar.onSortModeChanged { [weak self] sortMode in
            guard let self else { return }
            guard sortMode != self.state.sortMode else { return }
            self.setSortMode(sortMode)
        }

        sidebarToggle.onClicked { [weak self] in
            self?.toggleSidebarVisibility()
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
            guard let self, !self.suppressEditorChange, let noteToSave = self.currentEditedNoteSnapshot() else { return }
            self.state.upsert(noteToSave)
            self.refreshSidebar()
            self.refreshPreview()
            self.updateHeaderSubtitle()
            Task { @MainActor in
                self.autosave.scheduleSave(after: self.autosaveDelay) {
                    await MainActor.run { [weak self] in
                        self?.saveCurrentEditedNote(announceSuccess: false)
                    }
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
            self?.saveCurrentEditedNote(announceSuccess: false)
            self?.persistWorkspaceState()
            self?.stopExternalChangeMonitor()
            Task { @MainActor [weak self] in
                self?.autosave.cancel()
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

    private func refreshSidebar() {
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

    private func refreshPreview() {
        guard let selected = state.selectedNote else {
            schedulePreviewRefresh(blocks: [], baseDirectory: repository.notesDirectoryURL)
            return
        }
        let blocks = renderer.blocks(for: selected.content)
        schedulePreviewRefresh(blocks: blocks, baseDirectory: repository.notesDirectoryURL)
    }

    private func schedulePreviewRefresh(blocks: [RenderedBlock], baseDirectory: URL) {
        if let previewRefreshID {
            MainContext.cancel(sourceId: previewRefreshID)
            self.previewRefreshID = nil
        }
        pendingPreviewBlocks = blocks
        pendingPreviewBaseDirectory = baseDirectory
        previewRefreshID = MainContext.timeout(intervalMs: 1) { [weak self] in
            guard let self else { return false }
            self.flushPendingPreviewRefresh()
            return false
        }
    }

    private func flushPendingPreviewRefresh() {
        guard previewRefreshID != nil || pendingPreviewBlocks != nil || pendingPreviewBaseDirectory != nil else {
            return
        }
        if let previewRefreshID {
            MainContext.cancel(sourceId: previewRefreshID)
            self.previewRefreshID = nil
        }
        let blocks = pendingPreviewBlocks ?? []
        let baseDirectory = pendingPreviewBaseDirectory ?? repository.notesDirectoryURL
        pendingPreviewBlocks = nil
        pendingPreviewBaseDirectory = nil
        preview.render(blocks: blocks, baseDirectory: baseDirectory)
        MainContext.idle { [weak self] in
            self?.syncPreviewScroll()
        }
    }

    private func syncPreviewScroll() {
        guard state.isPreviewVisible, isPreviewPaneAttached else { return }
        guard preview.rootScroll.parent != nil, preview.rootScroll.width > 0, preview.rootScroll.height > 0 else { return }
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

        let librarySection = GMenuRef()
        librarySection.append("Import markdown…", action: "win.import-note")
        librarySection.append("Reload from disk", action: "win.reload-notes")
        librarySection.append("Open notes folder", action: "win.open-notes-folder")

        let menu = GMenuRef()
        menu.appendSection("Library", section: librarySection)
        overflowMenuSectionTitles = ["Library"]
        menuButton.setMenuModel(menu)
        updateActionAvailability()
    }

    private func configureToolbarAccessibility() {
        sidebarToggle.setAccessibleLabel(state.isSidebarVisible ? "Hide Notes Sidebar" : "Show Notes Sidebar")
        newNoteButton.setAccessibleLabel("New Note")
        saveNoteButton.setAccessibleLabel("Save Note")
        deleteNoteButton.setAccessibleLabel("Delete Note")
        menuButton.setAccessibleLabel("Main Menu")
        updatePreviewToggleAccessibility()
    }

    private func configureToolbarTooltips() {
        sidebarToggle.tooltipText = state.isSidebarVisible ? "Hide Notes Sidebar" : "Show Notes Sidebar"
        newNoteButton.tooltipText = "New Note"
        saveNoteButton.tooltipText = "Save Note"
        deleteNoteButton.tooltipText = "Delete Note"
        menuButton.tooltipText = "Main Menu"
        updatePreviewToggleTooltip()
    }

    private func updatePreviewToggleAccessibility() {
        previewToggle.setAccessibleLabel(state.isPreviewVisible ? "Hide Preview" : "Show Preview")
    }

    private func updatePreviewToggleTooltip() {
        previewToggle.tooltipText = state.isPreviewVisible ? "Hide Preview" : "Show Preview"
    }

    private func updateSidebarToggleAccessibility() {
        sidebarToggle.setAccessibleLabel(state.isSidebarVisible ? "Hide Notes Sidebar" : "Show Notes Sidebar")
    }

    private func updateSidebarToggleTooltip() {
        sidebarToggle.tooltipText = state.isSidebarVisible ? "Hide Notes Sidebar" : "Show Notes Sidebar"
    }

    private func updateActionAvailability() {
        let hasSelection = state.selectedNote != nil
        renameAction.enabled = hasSelection
        duplicateAction.enabled = hasSelection
        deleteAction.enabled = hasSelection
        copyNoteIDAction.enabled = hasSelection
        exportAction.enabled = hasSelection
    }

    private func togglePreviewVisibility() {
        state.isPreviewVisible.toggle()
        applyPreviewVisibility(animated: true)
        persistWorkspaceState()
    }

    private func toggleSidebarVisibility() {
        state.isSidebarVisible.toggle()
        applySidebarVisibility()
        persistWorkspaceState()
    }

    private func applySidebarVisibility() {
        splitView.showSidebar = state.isSidebarVisible
        updateSidebarToggleAccessibility()
        updateSidebarToggleTooltip()
    }

    private func applyPreviewVisibility(animated: Bool) {
        stopPreviewAnimation()
        if state.isPreviewVisible {
            showPreviewPane(animated: animated)
        } else {
            hidePreviewPane(animated: animated)
        }
        updatePreviewToggleAccessibility()
        updatePreviewToggleTooltip()
    }

    private func showPreviewPane(animated: Bool) {
        attachPreviewPane()
        if animated, canAnimatePreviewPane {
            let totalWidth = currentPreviewContainerWidth
            let targetPosition = resolvedVisiblePreviewPosition(totalWidth: totalWidth)
            editorPreviewPane.position = totalWidth
            animatePreviewPane(to: targetPosition)
            return
        }
        restorePreviewPaneLayout()
    }

    private func hidePreviewPane(animated: Bool) {
        guard isPreviewPaneAttached else { return }
        guard animated, canAnimatePreviewPane else {
            detachPreviewPane()
            return
        }
        animatePreviewPane(to: currentPreviewContainerWidth)
    }

    private func restorePreviewPaneLayout() {
        guard state.isPreviewVisible else { return }
        let totalWidth = currentPreviewContainerWidth
        isRestoringPreviewPaneLayout = true
        editorPreviewPane.position = resolvedVisiblePreviewPosition(totalWidth: totalWidth)
        MainContext.idle { [weak self] in
            self?.isRestoringPreviewPaneLayout = false
        }
    }

    private func attachPreviewPane() {
        guard !isPreviewPaneAttached else { return }
        editorPreviewPane.endChild = preview.rootScroll
        isPreviewPaneAttached = true
    }

    private func detachPreviewPane() {
        guard isPreviewPaneAttached else { return }
        stopPreviewAnimation()
        editorPreviewPane.endChild = nil
        isPreviewPaneAttached = false
    }

    private func animatePreviewPane(to targetPosition: Int) {
        stopPreviewAnimation()
        let startPosition = editorPreviewPane.position
        guard startPosition != targetPosition else {
            isRestoringPreviewPaneLayout = false
            if !state.isPreviewVisible {
                schedulePreviewDetachIfHidden()
            }
            return
        }

        isRestoringPreviewPaneLayout = true
        let startedAt = Date()
        let duration = Double(Self.previewAnimationDuration) / 1000
        previewAnimationID = MainContext.timeout(intervalMs: 16) { [weak self] in
            guard let self else { return false }
            let elapsed = Date().timeIntervalSince(startedAt)
            let progress = min(max(elapsed / duration, 0), 1)
            let easedProgress = 1 - pow(1 - progress, 3)
            let position = Double(startPosition) + (Double(targetPosition - startPosition) * easedProgress)
            self.editorPreviewPane.position = Int(position.rounded())
            if progress < 1 {
                return true
            }

            self.previewAnimationID = nil
            self.isRestoringPreviewPaneLayout = false
            if !self.state.isPreviewVisible {
                self.schedulePreviewDetachIfHidden()
            }
            return false
        }
    }

    private func schedulePreviewDetachIfHidden() {
        MainContext.delay(ms: 1) { [weak self] in
            guard let self, !self.state.isPreviewVisible else { return }
            self.detachPreviewPane()
        }
    }

    private func stopPreviewAnimation() {
        if let previewAnimationID {
            MainContext.cancel(sourceId: previewAnimationID)
            self.previewAnimationID = nil
        }
    }

    private var currentPreviewContainerWidth: Int {
        max(
            editorPreviewPane.width,
            window.width > 0 ? window.width - currentSidebarWidth : 0,
            window.defaultWidth - 280,
            state.preferredWindowWidth - 280
        )
    }

    private var canAnimatePreviewPane: Bool {
        editorPreviewPane.parent != nil && editorPreviewPane.width > 0 && editorPreviewPane.height > 0
    }

    private func resolvedVisiblePreviewPosition(totalWidth: Int) -> Int {
        let previewWidth = Self.resolvedPreviewWidth(
            storedWidth: state.preferredPreviewWidth,
            availableWidth: totalWidth
        )
        if state.preferredPreviewWidth == WorkspaceState.legacyDefaultPreviewWidth,
           previewWidth > state.preferredPreviewWidth {
            state.setPreferredPreviewWidth(previewWidth)
        }
        preview.rootScroll.minContentWidth = Self.minimumPreviewWidth
        return max(totalWidth - previewWidth, Self.minimumEditorWidth)
    }

    private func handlePreviewPaneMoved() {
        guard state.isPreviewVisible, isPreviewPaneAttached, !isRestoringPreviewPaneLayout else { return }
        let totalWidth = max(editorPreviewPane.width, window.width - currentSidebarWidth, window.defaultWidth - 280)
        guard totalWidth >= Self.minimumPreviewWidth + Self.minimumEditorWidth else { return }
        let previewWidth = totalWidth - editorPreviewPane.position
        guard previewWidth >= Self.minimumPreviewWidth else { return }
        state.setPreferredPreviewWidth(previewWidth)
    }

    private var currentSidebarWidth: Int {
        splitView.showSidebar ? sidebar.root.width : 0
    }

    private func setSortMode(_ sortMode: NotesSortMode) {
        state.setSortMode(sortMode)
        refreshSidebar()
        persistWorkspaceState()
        toastOverlay.dismissAll()
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
        saveCurrentEditedNote(announceSuccess: true)
        Task { @MainActor in
            autosave.cancel()
        }
    }

    private func currentEditedNoteSnapshot() -> Note? {
        guard var selected = state.selectedNote else { return nil }
        selected.content = editor.buffer.text
        return selected
    }

    private func saveCurrentEditedNote(announceSuccess: Bool) {
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

    private func handleSaveSuccess(_ savedNote: Note, announceSuccess: Bool) {
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

    private func dismissNoteContextMenu() {
        guard let noteContextMenu else { return }
        self.noteContextMenu = nil
        noteContextHandlers = [:]
        noteContextMenuLabels = []
        if noteContextMenu.parent != nil {
            noteContextMenu.popdown()
        }
    }

    private func runAfterNoteContextMenuClosure(_ action: @escaping @MainActor () -> Void) {
        guard noteContextMenu != nil else {
            action()
            return
        }
        noteContextDeferredAction = action
        dismissNoteContextMenu()
    }

    private func makeNoteContextPopoverContent() -> Widget {
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

    private func makeNoteContextButton(
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

    private func copySelectedNoteID() {
        guard let selected = state.selectedNote else { return }
        copyNoteID(selected)
    }

    private func copyNoteID(_ note: Note) {
        lastCopiedNoteID = note.stableID
        window.clipboard.setText(note.stableID)
        toastOverlay.showToast("Copied note ID")
    }

    private func importNote() {
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

    private func exportSelectedNote() {
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

    private func openNotesFolder() {
        do {
            let folderURL = try ensureNotesDirectoryExists()
            Task { [weak self] in
                await self?.openNotesFolder(at: folderURL)
            }
        } catch {
            presentError(
                heading: "Could not open notes folder",
                body: error.localizedDescription
            )
        }
    }

    private func ensureNotesDirectoryExists() throws -> URL {
        let folderURL = repository.notesDirectoryURL.standardizedFileURL
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL
    }

    private func openNotesFolder(at folderURL: URL) async {
        do {
            try await directoryOpener(folderURL)
        } catch {
            presentError(
                heading: "Could not open notes folder",
                body: error.localizedDescription
            )
        }
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
        if let previewRefreshID {
            MainContext.cancel(sourceId: previewRefreshID)
            self.previewRefreshID = nil
        }
        pendingPreviewBlocks = nil
        pendingPreviewBaseDirectory = nil
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
    private static let previewAnimationDuration = 220

    private struct DirectoryOpenFailure: LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }
    }

    private static func openDirectoryInSystemFileManager(_ folderURL: URL) async throws {
        do {
            try await runDirectoryOpenCommand(
                executablePath: "/usr/bin/gio",
                arguments: ["open", folderURL.path()]
            )
            return
        } catch let gioError {
            do {
                try await runDirectoryOpenCommand(
                    executablePath: "/usr/bin/xdg-open",
                    arguments: [folderURL.path()]
                )
            } catch let xdgOpenError {
                throw DirectoryOpenFailure(
                    message: [
                        gioError.localizedDescription,
                        xdgOpenError.localizedDescription
                    ]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                )
            }
        }
    }

    private static func runDirectoryOpenCommand(
        executablePath: String,
        arguments: [String]
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard FileManager.default.isExecutableFile(atPath: executablePath) else {
                throw DirectoryOpenFailure(message: "\(executablePath) is not available.")
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                let message = [
                    String(data: errorData, encoding: .utf8),
                    String(data: outputData, encoding: .utf8)
                ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? "Exit status \(process.terminationStatus)."
                throw DirectoryOpenFailure(message: message)
            }
        }.value
    }

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

    func debugEmitSaveClicked() {
        g_signal_emit_by_name_no_args(UnsafeMutableRawPointer(saveNoteButton.opaquePointer), "clicked")
    }

    func debugEmitSidebarToggleClicked() {
        g_signal_emit_by_name_no_args(UnsafeMutableRawPointer(sidebarToggle.opaquePointer), "clicked")
    }

    func debugEmitPreviewToggleClicked() {
        g_signal_emit_by_name_no_args(UnsafeMutableRawPointer(previewToggle.opaquePointer), "clicked")
    }

    func debugEmitSortButtonClicked() {
        g_signal_emit_by_name_no_args(UnsafeMutableRawPointer(sidebar.sortButton.opaquePointer), "clicked")
    }

    func debugSetEditorText(_ text: String) {
        editor.buffer.text = text
    }

    func debugSetSearchQuery(_ text: String) {
        sidebar.searchEntry.text = text
        g_signal_emit_by_name_no_args(UnsafeMutableRawPointer(sidebar.searchEntry.opaquePointer), "search-changed")
    }

    var debugNotesCount: Int {
        state.notes.count
    }

    var debugSelectedNoteContent: String? {
        state.selectedNote?.content
    }

    var debugEditorModified: Bool {
        editor.buffer.modified
    }

    var debugPreviewText: String {
        flushPendingPreviewRefresh()
        return preview.plainText
    }

    var debugDisplayedNotesCount: Int {
        displayedNotes.count
    }

    var debugDisplayedNoteTitles: [String] {
        displayedNotes.map(\.title)
    }

    var debugSearchQuery: String {
        sidebar.searchEntry.text
    }

    var debugDisplayedNoteStableIDs: [String] {
        displayedNotes.map(\.stableID)
    }

    func debugSelectDisplayedNote(at index: Int) {
        selectNote(at: index)
    }

    func debugOpenContextMenuForDisplayedNote(at index: Int) {
        guard displayedNotes.indices.contains(index) else { return }
        let note = displayedNotes[index]
        state.select(noteID: note.id)
        renderSelection()
        noteContextDeferredAction = nil
        dismissNoteContextMenu()

        let popover = Popover()
        popover.hasArrow = true
        popover.position = .bottom
        popover.autohide = true
        popover.child = makeNoteContextPopoverContent()
        noteContextMenu = popover
    }

    func debugDismissContextMenu() {
        dismissNoteContextMenu()
    }

    var debugHasContextMenu: Bool {
        noteContextMenu != nil
    }

    var debugOverflowMenuSectionTitles: [String] {
        overflowMenuSectionTitles
    }

    var debugToolbarTooltips: [String: String?] {
        [
            "sidebar": sidebarToggle.tooltipText,
            "new": newNoteButton.tooltipText,
            "save": saveNoteButton.tooltipText,
            "delete": deleteNoteButton.tooltipText,
            "preview": previewToggle.tooltipText,
            "menu": menuButton.tooltipText
        ]
    }

    var debugNoteContextMenuLabels: [String] {
        noteContextMenuLabels
    }

    var debugSortMode: NotesSortMode {
        state.sortMode
    }

    var debugSidebarVisible: Bool {
        splitView.showSidebar
    }

    var debugSidebarSortSelection: Int {
        sidebar.selectedSortIndex
    }

    func debugSelectSidebarSort(at index: Int) {
        guard NotesSortMode.allCases.indices.contains(index) else { return }
        setSortMode(NotesSortMode.allCases[index])
    }

    @discardableResult
    func debugInvokeContextMenuAction(label: String) -> Bool {
        guard let handler = noteContextHandlers[label] else { return false }
        dismissNoteContextMenu()
        handler()
        return true
    }

    func debugSelectedNoteStableID() -> String? {
        state.selectedNote?.stableID
    }

    var debugLastCopiedNoteID: String? {
        lastCopiedNoteID
    }

    func debugPollForExternalChanges() {
        pollForExternalChanges()
    }

    func debugOpenNotesFolder() async {
        do {
            let folderURL = try ensureNotesDirectoryExists()
            try await directoryOpener(folderURL)
        } catch {
            presentError(
                heading: "Could not open notes folder",
                body: error.localizedDescription
            )
        }
    }

    var debugPreferredPreviewWidth: Int {
        state.preferredPreviewWidth
    }

    var debugIsPreviewPaneAttached: Bool {
        isPreviewPaneAttached
    }
    #endif
}
