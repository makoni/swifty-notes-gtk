import Adwaita
import Foundation

@MainActor
final class MainWindow {
    let window: ApplicationWindow

    let state: AppState
    let stateStore: WorkspaceStateStore
    let appSettingsStore: AppSettingsStore
    var appSettings: AppSettings
    var repository: NotesRepository
    let renderer: MarkdownRenderer
    let autosave: AutosaveCoordinator

    let sidebar = NotesSidebar()
    var editor = MarkdownEditor()
    let preview = MarkdownPreview()
    let headerTitle = WindowTitle(title: "Swifty Notes", subtitle: "Markdown notes")
    let sidebarToggle = Button(iconName: "sidebar-show-symbolic")
    let editorModeToggle = ToggleButton(label: "Editor")
    let splitModeToggle = ToggleButton(label: "Split")
    let previewModeToggle = ToggleButton(label: "Preview")
    let viewModeSwitcher = Box(orientation: .horizontal, spacing: 0)
    let editorContent = Box(orientation: .vertical, spacing: 0)
    let editorFormattingToolbar = EditorFormattingToolbar()
    let newNoteButton = Button(icon: .custom("list-add-symbolic"))
    let saveNoteButton = Button(icon: .custom("document-save-symbolic"))
    let deleteNoteButton = Button(icon: .userTrash)
    let menuButton = MenuButton(icon: .custom("open-menu-symbolic"))
    let toastOverlay = ToastOverlay()
    let splitView = OverlaySplitView()
    let editorPreviewPane = Paned(orientation: .horizontal)
    let editorScroll = ScrolledWindow()
    let autosaveDelayOverride: Duration?
    var autosaveDelay: Duration
    let openExternalDocumentHandler: (URL) throws -> Void
    let directoryOpener: (URL) throws -> Void
    let deferredUIActionScheduler: (@escaping @MainActor () -> Void) -> Void

    lazy var renameAction = SimpleAction(name: "rename-note") { [weak self] in
        self?.presentRenameDialogForSelectedNote()
    }

    lazy var duplicateAction = SimpleAction(name: "duplicate-note") { [weak self] in
        self?.duplicateSelectedNote()
    }

    lazy var deleteAction = SimpleAction(name: "delete-note") { [weak self] in
        self?.presentDeleteConfirmationForSelectedNote()
    }

    lazy var copyNoteIDAction = SimpleAction(name: "copy-note-id") { [weak self] in
        self?.copySelectedNoteID()
    }

    lazy var exportAction = SimpleAction(name: "export-note") { [weak self] in
        self?.exportSelectedNote()
    }

    lazy var openMarkdownFileAction = SimpleAction(name: "open-markdown-file") { [weak self] in
        self?.openMarkdownFile()
    }

    lazy var importAction = SimpleAction(name: "import-note") { [weak self] in
        self?.importNote()
    }

    lazy var openNotesFolderAction = SimpleAction(name: "open-notes-folder") { [weak self] in
        self?.openNotesFolder()
    }

    lazy var reloadAction = SimpleAction(name: "reload-notes") { [weak self] in
        self?.reloadFromDisk(announce: true)
    }

    lazy var settingsAction = SimpleAction(name: "settings") { [weak self] in
        self?.presentSettingsWindow()
    }

    lazy var aboutAction = SimpleAction(name: "about") { [weak self] in
        self?.presentAboutDialog()
    }

    var displayedNotes: [Note] = []
    var directorySnapshot = NotesDirectorySnapshot()
    var deferredExternalSnapshot: NotesDirectorySnapshot?
    var externalChangeMonitorID: SourceID?
    var externalReloadDeferred = false
    var suppressEditorChange = false
    lazy var previewRefreshScheduler = PreviewRefreshScheduler(
        render: { [weak self] blocks, baseDirectory in
            self?.preview.render(blocks: blocks, baseDirectory: baseDirectory)
        },
        fallbackBaseDirectory: { [weak self] in
            self?.repository.notesDirectoryURL ?? FileManager.default.temporaryDirectory
        },
        shouldDeferRender: { [weak self] in
            self?.shouldDeferPreviewRender() ?? false
        },
        onRendered: { [weak self] in
            self?.syncPreviewScroll()
        },
    )
    var isRestoringPreviewPaneLayout = false
    var previewAnimationID: SourceID?
    var isPreviewPaneAttached = false
    var suppressViewModeToggleChange = false
    /// Convenience accessor used by debug tests; delegates to the toolbar.
    var editorFormattingButtons: [MarkdownFormattingAction: Button] {
        editorFormattingToolbar.buttons
    }
    var isEditorFormattingToolbarCompact: Bool {
        editorFormattingToolbar.isCompact
    }
    var isEditorFormattingToolbarUsingTwoRows: Bool {
        editorFormattingToolbar.isUsingTwoRows
    }
    /// Lazily built on first table-button click; re-used across the
    /// window's lifetime so the popover's widget tree doesn't churn.
    var tableSizePicker: TableSizePicker?
    var noteContextMenu: Popover?
    var noteContextMenuRequestID: UInt = 0
    var noteContextHandlers: [String: @MainActor () -> Void] = [:]
    var noteContextDeferredAction: (@MainActor () -> Void)?
    var activeFileDialog: FileDialog?
    var activeAboutDialog: AboutDialog?
    var activeSettingsWindow: SettingsWindow?
    var overflowMenuSectionTitles: [String] = []
    var overflowMenuItemsBySection: [String: [String]] = [:]
    var noteContextMenuLabels: [String] = []
    var lastCopiedNoteID: String?
    var hasScheduledDebugLaunchEdit = false
    var hasScheduledDebugSettingsOpen = false
    var hasScheduledDebugCreateNote = false

    init(
        application: Application,
        state: AppState,
        stateStore: WorkspaceStateStore,
        repository: NotesRepository,
        renderer: MarkdownRenderer,
        autosave: AutosaveCoordinator,
        appSettingsStore: AppSettingsStore = AppSettingsStore(),
        appSettings: AppSettings = .default,
        autosaveDelay: Duration? = nil,
        openExternalDocumentHandler: @escaping (URL) throws -> Void = { _ in },
        directoryOpener: @escaping (URL) throws -> Void = MainWindow.openDirectoryInSystemFileManager,
        deferredUIActionScheduler: @escaping (@escaping @MainActor () -> Void) -> Void = { action in
            MainContext.idle { action() }
        },
    ) {
        self.state = state
        self.stateStore = stateStore
        self.appSettingsStore = appSettingsStore
        self.appSettings = appSettings
        self.repository = repository
        self.renderer = renderer
        self.autosave = autosave
        autosaveDelayOverride = autosaveDelay
        self.autosaveDelay = autosaveDelay ?? .seconds(appSettings.autosaveDelaySeconds)
        self.openExternalDocumentHandler = openExternalDocumentHandler
        self.directoryOpener = directoryOpener
        self.deferredUIActionScheduler = deferredUIActionScheduler

        window = ApplicationWindow(application: application)
        window.title = "Swifty Notes"
        window.iconName = AppIdentity.identifier
        let preferredSize = Self.clampedWindowSize(
            width: state.preferredWindowWidth,
            height: state.preferredWindowHeight,
        )
        window.setDefaultSize(width: preferredSize.width, height: preferredSize.height)

        buildUI()
        applyRuntimeSettings(appSettings, shouldRefreshPreview: false)
        preview.attach(to: window)
        configureActionsAndMenu()
        wireSignals()
    }

    func present() {
        window.present()
        restorePreviewPaneLayout()
        loadInitialNotes()
        startExternalChangeMonitor()
        scheduleDebugLaunchEditIfRequested()
        scheduleDebugHeaderSubtitleLogIfRequested()
        scheduleDebugSettingsOpenIfRequested()
        scheduleDebugCreateNoteIfRequested()
        scheduleDebugSelectionSwitchIfRequested()
        MainContext.idle { [weak self] in
            self?.refreshPreview()
            self?.applyViewMode(animated: false)
            self?.focusPrimaryContentIfNeeded()
        }
    }

    func buildUI() {
        sidebarToggle.addCSSClass(.flat)
        newNoteButton.addCSSClass(.flat)
        saveNoteButton.addCSSClass(.flat)
        deleteNoteButton.addCSSClass(.flat)
        menuButton.addCSSClass(.flat)
        menuButton.hasFrame = false
        configureViewModeToggleContent()
        splitModeToggle.setGroup(editorModeToggle)
        previewModeToggle.setGroup(editorModeToggle)
        viewModeSwitcher.addCSSClass("linked")
        viewModeSwitcher.append(editorModeToggle)
        viewModeSwitcher.append(splitModeToggle)
        viewModeSwitcher.append(previewModeToggle)
        editorFormattingToolbar.onAction = { [weak self] action in
            self?.applyEditorFormatting(action)
        }
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
        header.packEnd(viewModeSwitcher)

        editorScroll.child = editor.view
        editorScroll.setPolicy(horizontal: .automatic, vertical: .automatic)
        editorScroll.hexpand = true
        editorScroll.vexpand = true
        editorScroll.overlayScrolling = false
        editorContent.hexpand = true
        editorContent.vexpand = true
        installEditorImageDropTarget()

        editorContent.append(editorFormattingToolbar.scrolled)
        editorContent.append(Separator())
        editorContent.append(editorScroll)
        editorPreviewPane.startChild = editorContent
        editorPreviewPane.resizeStartChild = true
        editorPreviewPane.resizeEndChild = false
        editorPreviewPane.shrinkStartChild = false
        editorPreviewPane.shrinkEndChild = true
        editorPreviewPane.wideHandle = true

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
        applyViewMode(animated: false)
    }

    func wireSignals() {
        sidebar.list.onRowActivated { [weak self] row in
            self?.requestSelectNote(at: Int(row.index))
        }

        sidebar.searchEntry.onSearchChanged { [weak self] in
            guard let self else { return }
            state.setSearchQuery(sidebar.searchEntry.text)
            refreshSidebar()
            persistWorkspaceState()
        }

        sidebar.onSortModeChanged { [weak self] sortMode in
            guard let self else { return }
            guard sortMode != state.sortMode else { return }
            setSortMode(sortMode)
        }

        sidebarToggle.onClicked { [weak self] in
            self?.toggleSidebarVisibility()
        }

        editorModeToggle.onToggled { [weak self] in
            guard let self, !self.suppressViewModeToggleChange, editorModeToggle.active else { return }
            setViewMode(.editor, animated: false)
        }

        splitModeToggle.onToggled { [weak self] in
            guard let self, !self.suppressViewModeToggleChange, splitModeToggle.active else { return }
            setViewMode(.split, animated: false)
        }

        previewModeToggle.onToggled { [weak self] in
            guard let self, !self.suppressViewModeToggleChange, previewModeToggle.active else { return }
            setViewMode(.preview, animated: false)
        }
        newNoteButton.onClicked { [weak self] in
            self?.requestCreateNote()
        }

        saveNoteButton.onClicked { [weak self] in
            self?.saveSelectedNoteNow()
        }

        deleteNoteButton.onClicked { [weak self] in
            self?.presentDeleteConfirmationForSelectedNote()
        }

        editor.view.onChanged { [weak self] in
            guard let self, !self.suppressEditorChange, let noteToSave = currentEditedNoteSnapshot() else { return }
            state.upsert(noteToSave)
            refreshSidebar()
            refreshPreview()
            updateHeaderSubtitle()
            autosave.scheduleSave(after: autosaveDelay) { [weak self] in
                self?.saveCurrentEditedNote(announceSuccess: false)
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

        editorFormattingToolbar.scrolled.onSizeAllocate { [weak self] width, _ in
            self?.updateEditorFormattingToolbarLayout(forWidth: width)
        }

        editorScroll.verticalAdjustment.onValueChanged { [weak self] in
            guard let self else { return }
            syncPreviewScroll()
        }

        window.onCloseRequest { [weak self] in
            self?.saveCurrentEditedNote(announceSuccess: false)
            self?.persistWorkspaceState()
            self?.stopExternalChangeMonitor()
            self?.autosave.cancel()
            return false
        }

        window.addKeyboardShortcut("<Ctrl>n") { [weak self] in
            self?.requestCreateNote()
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
            self?.openMarkdownFile()
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
            self?.toggleEditorAndSplitModes()
            return true
        }
    }

    static func clampedWindowSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard let monitor = Display.default?.monitors.first?.geometry else {
            return (width, height)
        }
        return (
            max(900, min(width, monitor.width - 80)),
            max(700, min(height, monitor.height - 80)),
        )
    }

    static let minimumPreviewWidth = 400
    static let minimumEditorWidth = 360
    static let editorFormattingCompactWidthThreshold = 520
    static let previewAnimationDuration = 220

    /// Returns the on-disk path to a bundled icon SVG (e.g. `table-symbolic`)
    /// shipped under the resource bundle's `Icons/` directory. Used for
    /// custom icons that don't ship in the system Adwaita theme. Returns
    /// `nil` when the file isn't present.
    static func bundledIconFilePath(for iconName: String) -> String? {
        guard let iconsURL = Bundle.module.resourceURL?
            .appendingPathComponent("Icons", isDirectory: true)
        else { return nil }
        let fileURL = iconsURL.appendingPathComponent("\(iconName).svg")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return fileURL.path
    }

    struct DirectoryOpenFailure: LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }
    }

    nonisolated static func openDirectoryInSystemFileManager(_ folderURL: URL) throws {
        try openDirectoryInSystemFileManager(
            folderURL,
            launchDefaultForURI: MainWindow.launchDefaultForURI,
            fallbackOpenURI: MainWindow.fallbackOpenURI,
        )
    }

    nonisolated static func openDirectoryInSystemFileManager(
        _ folderURL: URL,
        launchDefaultForURI: (String) throws -> Void,
        fallbackOpenURI: (String) throws -> Void,
    ) throws {
        let uri = folderURL.standardizedFileURL.absoluteString
        do {
            try launchDefaultForURI(uri)
        } catch let primaryError {
            do {
                try fallbackOpenURI(uri)
            } catch let fallbackError {
                throw DirectoryOpenFailure(
                    message: [
                        primaryError.localizedDescription,
                        fallbackError.localizedDescription,
                    ]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n"),
                )
            }
        }
    }

    nonisolated static func launchDefaultForURI(_ uri: String) throws {
        do {
            try AppLauncher.launchDefault(forURI: uri)
        } catch let error as GLibError {
            throw DirectoryOpenFailure(message: error.message)
        }
    }

    nonisolated static func fallbackOpenURI(_ uri: String) throws {
        let executablePath = "/usr/bin/xdg-open"
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw DirectoryOpenFailure(message: "\(executablePath) is not available.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [uri]
        try process.run()
    }

    static func resolvedPreviewWidth(storedWidth: Int, availableWidth: Int) -> Int {
        let boundedAvailableWidth = max(availableWidth, minimumPreviewWidth + minimumEditorWidth)
        let maximumPreviewWidth = max(boundedAvailableWidth - minimumEditorWidth, minimumPreviewWidth)
        let comfortablePreviewWidth = min(
            max(Int(Double(boundedAvailableWidth) * 0.34), WorkspaceState.defaultPreviewWidth),
            maximumPreviewWidth,
        )
        let requestedWidth: Int = if storedWidth == WorkspaceState.legacyDefaultPreviewWidth {
            max(storedWidth, comfortablePreviewWidth)
        } else {
            storedWidth
        }
        return min(max(requestedWidth, minimumPreviewWidth), maximumPreviewWidth)
    }
}
