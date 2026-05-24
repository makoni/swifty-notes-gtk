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
    let outlineSidebar = OutlineSidebar()
    let breadcrumb = BreadcrumbStrip()
    /// Latest extraction result. Cached so the scroll-spy driver and
    /// the breadcrumb don't have to re-parse the markdown on every
    /// scroll tick. Refreshed by ``refreshOutline(markdown:blocks:)``.
    var currentHeadings: [Heading] = []
    /// Recent-jumps in-memory store backing the Ctrl+G palette.
    /// Reset to the per-note persisted history whenever the active
    /// note changes.
    var outlineRecentJumps = RecentJumps()
    /// Tracks the active note across `refreshOutline` calls so we
    /// know when to hydrate the panel from the persisted per-note
    /// state. `nil` until the first refresh after a note is selected.
    var currentOutlineNoteID: UUID?
    /// Built lazily in `wireSignals` (deferred so the editor / preview
    /// widget trees are constructed before we connect signals to them).
    var outlineScrollSpyDriver: OutlineScrollSpyDriver?
    var editor = MarkdownEditor()
    let preview = MarkdownPreview()
    let headerTitle = WindowTitle(title: "Swifty Notes", subtitle: "Markdown notes")
    let sidebarToggle = MainWindow.iconButton(named: "sidebar-show-symbolic")
    /// Toggles the right-hand Outline panel. Active state CSS tracks
    /// ``AppState.isOutlineVisible``. Bound to F9 in `wireKeyboardShortcuts`.
    let outlineToggleButton = MainWindow.iconButton(named: "view-list-bullet-symbolic")
    /// Opens the Ctrl+G command palette. Stub-only in Phase 1 — wired
    /// in Phase 5.
    let quickJumpButton = MainWindow.iconButton(named: "system-search-symbolic")
    let editorModeToggle = ToggleButton(label: "Editor")
    let splitModeToggle = ToggleButton(label: "Split")
    let previewModeToggle = ToggleButton(label: "Preview")
    let viewModeSwitcher = Box(orientation: .horizontal, spacing: 0)
    let editorContent = Box(orientation: .vertical, spacing: 0)
    let editorFormattingToolbar = EditorFormattingToolbar()
    let newNoteButton = Button(icon: .custom("list-add-symbolic"))
    let newFolderButton = Button(icon: .custom("folder-new-symbolic"))
    let saveNoteButton = Button(icon: .custom("document-save-symbolic"))
    let deleteNoteButton = Button(icon: .userTrash)
    let menuButton = MenuButton(icon: .custom("open-menu-symbolic"))
    let toastOverlay = ToastOverlay()
    let splitView = OverlaySplitView()
    /// Wraps ``splitView`` to place the Outline panel on the right-hand
    /// side. We need a second OverlaySplitView because AdwOverlaySplitView
    /// is single-sidebar — to get a left + right shell (the GNOME
    /// Builder / Apostrophe layout) we nest them. Inner = notes sidebar,
    /// outer = outline sidebar with `sidebarPosition: .end`.
    let outlineSplitView = OverlaySplitView()
    let editorPreviewPane = Paned(orientation: .horizontal)
    let editorScroll = ScrolledWindow()
    /// Banner shown above the editor when the user is previewing a
    /// note from the Trash. Carries a Restore action and signals that
    /// editing is disabled until the note is restored — without it
    /// edits to a "previewed" trashed note silently saved into the
    /// previously-active regular note instead.
    let trashedNoteBanner = Banner(title: "This note is in the Trash")
    /// Banner shown above the editor when the launch-time update check
    /// finds a newer GitHub release than the running build. Carries an
    /// "Update" button that opens the release page, plus a dismiss
    /// button — the user explicitly wants the banner to stay visible
    /// until they act on it.
    let updateBanner = UpdateBanner()
    /// `html_url` from the latest GitHub release payload — remembered
    /// here so the banner's Update button can hand it to the OS URL
    /// opener. Set by ``checkForUpdates(manual:)``.
    var pendingUpdateReleaseURL: URL?
    /// `--force-update-available` launch flag. When set, the update
    /// checker reports `updateAvailable` even if the running build is
    /// already at or ahead of the latest release — purely a manual-QA
    /// affordance so we can verify the banner without shipping a new
    /// release first.
    let forceUpdateAvailable: Bool
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

    lazy var checkForUpdatesAction = SimpleAction(name: "check-for-updates") { [weak self] in
        self?.checkForUpdates(manual: true)
    }

    var displayedNotes: [Note] = []
    var directorySnapshot = NotesDirectorySnapshot()
    var trashContextMenu: Popover?
    /// Non-nil while the user is previewing a note from the Trash.
    /// Used to gate the read-only-editor + banner state and to wire
    /// the banner's Restore button back to the right note.
    var previewedTrashedNoteID: UUID?
    var sidebarHoverExpandTimer: SourceID?
    var sidebarHoverExpandFolder: String?
    var folderContextMenu: Popover?
    var deferredExternalSnapshot: NotesDirectorySnapshot?
    var externalChangeMonitorID: SourceID?
    var externalReloadDeferred = false
    var suppressEditorChange = false
    lazy var previewRefreshScheduler = PreviewRefreshScheduler(
        render: { [weak self] blocks, baseDirectory in
            guard let self else { return }
            preview.render(blocks: blocks, baseDirectory: baseDirectory)
            // Keep the outline in sync with whatever the preview just
            // committed. Reading the buffer here (rather than threading
            // markdown through the scheduler) means deferred typing
            // refreshes also update the outline.
            refreshOutline(markdown: editor.buffer.text, blocks: blocks)
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
    lazy var previewScrollSyncScheduler = PreviewScrollSyncScheduler(
        schedule: deferredUIActionScheduler,
        sync: { [weak self] in
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
    var hasScheduledDebugTypingBurst = false
    var hasScheduledDebugSettingsOpen = false
    var hasScheduledDebugCreateNote = false
    var hasScheduledDebugScrollSweep = false
#if DEBUG
    var previewBlockBuildCount = 0
#endif
    var previewBlockBuilder = IncrementalPreviewBlockBuilder()

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
        forceUpdateAvailable: Bool = false,
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
        self.forceUpdateAvailable = forceUpdateAvailable
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
        preview.taskCheckboxToggleHandler = { [weak self] taskIndex in
            self?.handleTaskCheckboxToggle(at: taskIndex)
        }
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
        scheduleDebugTypingBurstIfRequested()
        scheduleDebugScrollSweepIfRequested()
        MainContext.idle { [weak self] in
            self?.refreshPreview()
            self?.applyViewMode(animated: false)
            self?.focusPrimaryContentIfNeeded()
            self?.checkForUpdates(manual: false)
        }
    }

    func buildUI() {
        registerBundledIconSearchPathIfNeeded()
        sidebarToggle.addCSSClass(.flat)
        newNoteButton.addCSSClass(.flat)
        saveNoteButton.addCSSClass(.flat)
        deleteNoteButton.addCSSClass(.flat)
        menuButton.addCSSClass(.flat)
        menuButton.hasFrame = false
        configureViewModeToggleContent()
        #if os(macOS)
        // Live theme refresh for the Editor/Split/Preview toggles. They
        // render their icons through bundled SVGs the same way the
        // formatting toolbar does, so they need the same refresh hook.
        BundledIconRefreshRegistry.shared.register { [weak self] in
            guard let self else { return false }
            self.configureViewModeToggleContent()
            return true
        }
        #endif
        splitModeToggle.setGroup(editorModeToggle)
        previewModeToggle.setGroup(editorModeToggle)
        viewModeSwitcher.addCSSClass("linked")
        viewModeSwitcher.append(editorModeToggle)
        viewModeSwitcher.append(splitModeToggle)
        viewModeSwitcher.append(previewModeToggle)
        editorFormattingToolbar.onAction = { [weak self] action in
            // Block formatting toolbar input while a trashed note
            // is being previewed read-only — otherwise toolbar
            // buttons end-run around `editor.view.editable = false`
            // and silently rewrite the previously-active regular
            // note's content.
            guard self?.previewedTrashedNoteID == nil else { return }
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
        header.packStart(newFolderButton)
        header.packStart(saveNoteButton)
        header.packStart(deleteNoteButton)
        header.packEnd(menuButton)
        header.packEnd(viewModeSwitcher)
        header.packEnd(outlineToggleButton)
        header.packEnd(quickJumpButton)

        editorScroll.child = editor.view
        editorScroll.setPolicy(horizontal: .automatic, vertical: .automatic)
        editorScroll.hexpand = true
        editorScroll.vexpand = true
        editorScroll.overlayScrolling = false
        #if os(macOS)
        editorScroll.kineticScrolling = false
        #endif
        editorContent.hexpand = true
        editorContent.vexpand = true
        installEditorImageDropTarget()
        installEditorClipboardImagePaste()

        trashedNoteBanner.buttonLabel = "Restore"
        trashedNoteBanner.revealed = false
        trashedNoteBanner.onButtonClicked { [weak self] in
            guard let self, let id = previewedTrashedNoteID else { return }
            restoreFromTrash(noteID: id)
        }

        updateBanner.onUpdate { [weak self] in
            self?.openPendingUpdateReleasePage()
        }

        editorContent.append(trashedNoteBanner)
        updateBanner.attach(to: editorContent)
        // Breadcrumb sits between the trash/update banners and the
        // formatting toolbar so its 48 px height lines up exactly with
        // the toolbar's natural height — the design's `.sn-breadcrumb`
        // rule sets `height: 48px` to "start the doc content at the
        // same Y on both sides of the split."
        editorContent.append(breadcrumb.root)
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
        #if os(macOS)
        // GTK4 on Quartz routes the swipe-to-show / swipe-to-hide pan
        // gestures through the same pointer pipeline that drives row
        // activation, and any sub-pixel horizontal motion during a
        // click on a sidebar row is enough to make the pan detector
        // grab the press for drag-disambiguation. The row highlights
        // (the press IS observed) but never activates, until a
        // perfectly stationary second click slips past the gesture.
        // The sidebar is pinned anyway (`pinSidebar = true`), so the
        // gestures have no functional purpose here — disabling them
        // restores predictable single-click activation. Linux keeps
        // them enabled because the touchpad-swipe UX they enable on
        // GNOME is still useful when the sidebar collapses.
        splitView.enableShowGesture = false
        splitView.enableHideGesture = false
        #else
        splitView.enableShowGesture = true
        splitView.enableHideGesture = true
        #endif
        splitView.sidebarWidthFraction = 0.26
        splitView.minSidebarWidth = 240
        splitView.maxSidebarWidth = 380
        splitView.sidebar = sidebar.root
        splitView.content = editorPreviewPane
        applySidebarVisibility()

        // Outer split: notes-sidebar + content on the left, Outline
        // panel on the right. Keeping the Outline pinned and non-
        // collapsing means the toggle is purely show/hide chrome —
        // the content area never has to renegotiate width during a
        // collapse animation.
        outlineSplitView.pinSidebar = true
        outlineSplitView.sidebarPosition = .end
        outlineSplitView.enableShowGesture = false
        outlineSplitView.enableHideGesture = false
        outlineSplitView.minSidebarWidth = 240
        outlineSplitView.maxSidebarWidth = 360
        outlineSplitView.sidebarWidthFraction = 0.22
        outlineSplitView.sidebar = outlineSidebar.root
        outlineSplitView.content = splitView
        outlineSplitView.showSidebar = state.isOutlineVisible

        let toolbar = ToolbarView()
        toolbar.addTopBar(header)
        toolbar.content = outlineSplitView

        toastOverlay.child = toolbar
        window.setContent(toastOverlay)
        applyViewMode(animated: false)
    }

    func wireSignals() {
        sidebar.list.onRowActivated { [weak self] row in
            self?.requestActivateSidebarRow(at: Int(row.index))
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

        MacOSClickWorkaround.onClick(sidebarToggle, label: "SidebarToggle") { [weak self] in
            self?.toggleSidebarVisibility()
        }

        MacOSClickWorkaround.onClick(outlineToggleButton, label: "OutlineToggle") { [weak self] in
            self?.toggleOutlineVisibility()
        }
        MacOSClickWorkaround.onClick(quickJumpButton, label: "QuickJump") { [weak self] in
            self?.openCommandPalette()
        }
        outlineSidebar.list.onRowActivated { [weak self] row in
            guard let self else { return }
            let index = Int(row.index)
            guard let heading = outlineSidebar.heading(at: index) else { return }
            scrollToHeading(heading)
        }
        // Search filter — SearchEntry already debounces per its
        // `searchDelay` setting, so we don't need to add another layer
        // on top.
        outlineSidebar.searchEntry.onSearchChanged { [weak self] in
            guard let self else { return }
            outlineSidebar.setQuery(outlineSidebar.searchEntry.text)
        }
        // H2 chevron click — re-renders the visible row list, then
        // mirrors the new collapsed set into AppState so it survives
        // a note switch + relaunch.
        outlineSidebar.onToggleCollapsed { [weak self] id in
            guard let self else { return }
            outlineSidebar.toggleCollapsed(id)
            persistOutlineStateForCurrentNote()
        }
        // Empty-state "Add ## Heading" link: insert a starter heading
        // at the current cursor position and focus the editor so the
        // user can keep typing.
        outlineSidebar.onInsertHeadingRequest { [weak self] in
            self?.insertStarterHeadingIntoEditor()
        }

        // Lazy scroll-spy bind. Done here (rather than in init) so the
        // editor / preview widget trees are fully constructed before
        // we wire signals to their adjustments.
        if outlineScrollSpyDriver == nil {
            outlineScrollSpyDriver = makeOutlineScrollSpyDriver()
        }
        outlineScrollSpyDriver?.rebind(mode: state.viewMode)

        // The view-mode switcher is a linked group: clicking one button
        // must end up with exactly that button active. Pass
        // `togglesActive: false` so the macOS path forces `active = true`
        // on release rather than flipping it; the `onToggled` handler
        // below stays the single source of truth for applying the mode.
        MacOSClickWorkaround.onToggle(editorModeToggle, togglesActive: false, label: "EditorModeToggle") { [weak self] in
            guard let self, !self.suppressViewModeToggleChange, editorModeToggle.active else { return }
            setViewMode(.editor, animated: false)
        }
        MacOSClickWorkaround.onToggle(splitModeToggle, togglesActive: false, label: "SplitModeToggle") { [weak self] in
            guard let self, !self.suppressViewModeToggleChange, splitModeToggle.active else { return }
            setViewMode(.split, animated: false)
        }
        MacOSClickWorkaround.onToggle(previewModeToggle, togglesActive: false, label: "PreviewModeToggle") { [weak self] in
            guard let self, !self.suppressViewModeToggleChange, previewModeToggle.active else { return }
            setViewMode(.preview, animated: false)
        }

        MacOSClickWorkaround.onClick(newNoteButton, label: "NewNote") { [weak self] in
            self?.requestCreateNote()
        }
        MacOSClickWorkaround.onClick(newFolderButton, label: "NewFolder") { [weak self] in
            self?.presentNewFolderDialog(parentPath: "")
        }
        MacOSClickWorkaround.onClick(saveNoteButton, label: "Save") { [weak self] in
            self?.saveSelectedNoteNow()
        }
        MacOSClickWorkaround.onClick(deleteNoteButton, label: "Delete") { [weak self] in
            self?.presentDeleteConfirmationForSelectedNote()
        }
        MacOSClickWorkaround.onMenuButtonPress(menuButton, label: "HamburgerMenu")

        editor.view.onChanged { [weak self] in
            guard let self, !self.suppressEditorChange else { return }
            // Belt-and-suspenders: every known buffer mutation in
            // trash-preview mode is gated upstream, but if a future
            // path adds a programmatic write we don't want it to
            // silently rewrite the wrong note via this autosave.
            guard self.previewedTrashedNoteID == nil else { return }
            guard let noteToSave = currentEditedNoteSnapshot() else { return }
            let previousTitle = state.selectedNote?.title
            state.upsert(noteToSave)
            if shouldRefreshSidebarDuringEditing(previousTitle: previousTitle, updatedNote: noteToSave) {
                refreshSidebar()
            }
            scheduleTypingPreviewRefresh()
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
            previewScrollSyncScheduler.requestSync()
        }

        window.onCloseRequest { [weak self] in
            self?.saveCurrentEditedNote(announceSuccess: false)
            self?.persistWorkspaceState()
            self?.stopExternalChangeMonitor()
            self?.previewScrollSyncScheduler.cancel()
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
        // F9 (outline toggle) and Ctrl+G (command palette) live on the
        // GApplication as `app.toggle-outline` / `app.quick-jump`. See
        // `SwiftyNotesLauncher.installOutlineActions` — that lift lets
        // macOS surface the shortcuts in the Apple menu and lets them
        // fire across every window without per-window re-registration.
        // F10 stays per-window because Editor↔Split is a single-window
        // concern.
        window.addKeyboardShortcut("F10") { [weak self] in
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
    ///
    /// **Theme-aware variant:** Adwaita's symbolic SVGs encode the
    /// foreground as a hardcoded dark grey (`#2e3436`). GTK's normal
    /// icon-theme pipeline (`GtkSymbolicPaintable`) re-tints that
    /// foreground at render time using the active theme's `@theme_fg_color`,
    /// so the same SVG looks dark on light and light on dark.
    ///
    /// We load these SVGs via `Image(filename:)` to bypass a brew
    /// libadwaita 1.9 / gtk4 4.22 bug in `GtkSymbolicPaintable` that
    /// drops `<g>` elements from some Adwaita 50 SVGs — but that path
    /// is `gtk_image_new_from_file`, which renders the file via
    /// librsvg with NO symbolic recolouring. The icons stay
    /// `#2e3436` forever, which is invisible against a dark-theme
    /// background.
    ///
    /// Workaround: when the app is currently in dark mode, materialise
    /// a per-icon recoloured copy under the user temp dir (fill swapped
    /// to a light grey) and hand back that path instead. Light mode
    /// uses the original SVG as-is.
    static func bundledIconFilePath(for iconName: String) -> String? {
        guard let iconsURL = Bundle.module.resourceURL?
            .appendingPathComponent("Icons", isDirectory: true)
        else { return nil }
        let originalURL = iconsURL.appendingPathComponent("\(iconName).svg")
        // Use `path(percentEncoded: false)` everywhere a path string
        // crosses the FileManager / GTK boundary — same regression
        // class as issue #24 (`URL.path()` is percent-encoded on
        // Swift 6, and consumers expect a decoded native path).
        guard FileManager.default.fileExists(atPath: originalURL.path(percentEncoded: false)) else {
            return nil
        }
        #if !os(macOS)
        // On Linux the bundled-icon workaround is only needed for the
        // icons that don't ship in the system Adwaita theme — at the
        // time of writing that's just `table-symbolic`. For every
        // other icon we ship a copy of, the Linux Adwaita theme has
        // the same SVG, and `Image(iconName:)` resolves it through
        // `GtkSymbolicPaintable` which handles dark/light recolouring
        // for free. Returning nil here lets the caller fall through
        // to that theme-aware path on Linux.
        let linuxOnlyBundled: Set<String> = ["table-symbolic"]
        guard linuxOnlyBundled.contains(iconName) else { return nil }
        return originalURL.path(percentEncoded: false)
        #else
        // Light mode: original SVG already encodes the foreground in a
        // dark shade that contrasts well against the light theme — use
        // it directly with no allocation.
        if !StyleManager.default.dark {
            return originalURL.path(percentEncoded: false)
        }
        // Dark mode: lazily produce a temp-dir copy with the foreground
        // recoloured. Cache by icon name + theme variant so repeated
        // lookups during one app run hit a single file write.
        return cachedDarkVariantPath(forBundledIcon: iconName, source: originalURL)
        #endif
    }

    /// Materialises a dark-theme-tinted copy of an Adwaita symbolic SVG
    /// at `<temp>/me.spaceinbox.swiftynotes-icons/<name>-dark.svg`. The
    /// recolouring is a single string substitution — Adwaita's hand-
    /// authored SVGs use exactly `fill="#2e3436"` on the foreground
    /// path, with no other occurrences of that hex in the file, so a
    /// blunt replace is safe across the whole icon set.
    ///
    /// Cache lifetime is "one process": the temp dir is recreated per
    /// app launch (good — picks up updated bundled icons after a
    /// version upgrade) and torn down by macOS housekeeping. We do
    /// NOT live-update widgets when the system colour scheme flips
    /// mid-session; that would require tracking every Image we've
    /// handed out and is a separate follow-up. Today the dark/light
    /// choice is taken at widget creation time.
    private static func cachedDarkVariantPath(forBundledIcon iconName: String, source: URL) -> String? {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("me.spaceinbox.swiftynotes-icons", isDirectory: true)
        let targetURL = cacheDir.appendingPathComponent("\(iconName)-dark.svg")
        let targetPath = targetURL.path(percentEncoded: false)

        // Fast path: the recoloured copy already exists in this
        // process's temp dir (we generated it earlier for another
        // widget that asked for the same icon name).
        if FileManager.default.fileExists(atPath: targetPath) {
            return targetPath
        }

        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let original = try String(contentsOf: source, encoding: .utf8)
            // libadwaita's dark `@theme_fg_color` is approximately
            // `rgb(255, 255, 255)` at 90%-ish opacity. `#ffffff` here
            // gives high contrast against the dark background without
            // needing to thread an alpha through the SVG, matching
            // what `GtkSymbolicPaintable` would otherwise paint.
            let recoloured = original.replacingOccurrences(of: "#2e3436", with: "#ffffff")
            try recoloured.write(to: targetURL, atomically: true, encoding: .utf8)
            return targetPath
        } catch {
            // Generation failed (filesystem error, permission, etc.).
            // Fall back to the un-tinted source SVG — the icon will
            // render too dark in dark mode but at least it's visible,
            // and a missing return value here would degrade the
            // button to the "image-missing" placeholder.
            return source.path
        }
    }

    /// Builds a `Button` whose icon comes from a bundled SVG when one is
    /// shipped under the resource bundle's `Icons/` directory, falling
    /// back to the GTK icon-theme lookup (`Button(iconName:)`) when not.
    ///
    /// Why bother: on macOS Quartz the GTK4 4.22 `GtkSymbolicPaintable`
    /// parser drops `<g>` group elements from symbolic SVGs ("Ignoring
    /// element in symbolic icon: <g>" debug messages), and several
    /// Adwaita-icon-theme 50.0 SVGs wrap their entire path content in
    /// such a `<g>` — `sidebar-show-symbolic` is the canonical
    /// example. The result is a button that renders as the
    /// "missing image" libadwaita placeholder despite the SVG file
    /// being present on disk and reachable by the theme. Routing
    /// these icons through `Image(filename:)` uses librsvg's full SVG
    /// renderer instead of `GtkSymbolicPaintable`, and librsvg handles
    /// `<g>` correctly.
    @MainActor
    static func iconButton(named iconName: String) -> Button {
        let button = Button()
        applyBundledIcon(named: iconName, to: button)
        #if os(macOS)
        // Live theme refresh: when the user toggles macOS Dark Mode
        // while the app is open, rebuild the Image-child with the
        // appropriate (light or dark) bundled variant. Without this
        // the bundled icons stay frozen on whichever theme was active
        // when the button was first created, while everything else
        // (text, backgrounds, theme-resolved icons) tracks the
        // change — visually broken.
        BundledIconRefreshRegistry.shared.register { [weak button] in
            guard let button else { return false }
            applyBundledIcon(named: iconName, to: button)
            return true
        }
        #endif
        return button
    }

    /// Sets `button.child` to a freshly-built `Image` loaded from the
    /// currently-resolved bundled-icon path. If no bundled SVG is
    /// available, falls back to `button.iconName = iconName` so the
    /// GTK icon theme can take over.
    @MainActor
    private static func applyBundledIcon(named iconName: String, to button: Button) {
        if let bundledPath = bundledIconFilePath(for: iconName) {
            let image = Image(filename: bundledPath)
            image.pixelSize = 16
            button.child = image
        } else {
            // Clear any stale custom child first — Button keeps the
            // previously set `.child` around and would render that
            // instead of the iconName we set below otherwise.
            button.child = nil
            button.iconName = iconName
        }
    }

    struct DirectoryOpenFailure: LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }
    }

    /// Tells GTK's icon theme to look inside the package's bundled
    /// `Resources/icons/` tree, so widgets that resolve an icon by name
    /// (most visibly `AdwAboutDialog`'s `appIcon`) can find our shipped
    /// `me.spaceinbox.swiftynotes.svg`. On Linux installs the icon
    /// lives under `/usr/share/icons/hicolor/...` via the .desktop +
    /// hicolor-theme XDG flow and resolves without us doing anything;
    /// the SwiftPM `swift run` build and the macOS bundle skip that
    /// install step, so without this registration the About dialog
    /// shows a missing-icon placeholder.
    func registerBundledIconSearchPathIfNeeded() {
        guard !Self.bundledIconSearchPathRegistered,
              let iconsURL = Bundle.module.resourceURL?
                .appendingPathComponent("AppIcons", isDirectory: true),
              FileManager.default.fileExists(atPath: iconsURL.path(percentEncoded: false)),
              let display = Display.default
        else { return }
        display.iconTheme.addSearchPath(iconsURL.path(percentEncoded: false))
        Self.bundledIconSearchPathRegistered = true
    }

    nonisolated(unsafe) private static var bundledIconSearchPathRegistered = false

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
