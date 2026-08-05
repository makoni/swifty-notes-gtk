import Adwaita
import Foundation

// `internal` (not `private`) so the test suite can exercise
// `ExternalMarkdownDocumentStore.load` directly — regression tests
// for the "spaces in path" class of bug (issues #2, #3, #24) need
// to call into the store with a temp file whose name contains a
// space, and that's not reachable via the public `MainWindow` or
// `ExternalDocumentWindow` surface without standing up an entire
// GTK application context.
struct ExternalDocumentFileSnapshot: Equatable {
    let modifiedAt: TimeInterval
    let fileSize: UInt64
}

struct ExternalMarkdownDocument {
    let url: URL
    let content: String
    let snapshot: ExternalDocumentFileSnapshot
}

enum ExternalMarkdownDocumentStore {
    static func load(from fileURL: URL, fileManager: FileManager = .default) throws -> ExternalMarkdownDocument {
        let standardizedURL = fileURL.standardizedFileURL
        let content = try String(contentsOf: standardizedURL, encoding: .utf8)
        let snapshot = try snapshot(of: standardizedURL, fileManager: fileManager)
        return .init(url: standardizedURL, content: content, snapshot: snapshot)
    }

    static func save(content: String, to fileURL: URL, fileManager: FileManager = .default) throws -> ExternalMarkdownDocument {
        let standardizedURL = fileURL.standardizedFileURL
        let directoryURL = standardizedURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard let data = content.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: standardizedURL, options: .atomic)
        return try load(from: standardizedURL, fileManager: fileManager)
    }

    static func snapshot(of fileURL: URL, fileManager: FileManager = .default) throws -> ExternalDocumentFileSnapshot {
        let standardizedURL = fileURL.standardizedFileURL
        // `URL.path()` on Swift 6 returns a percent-encoded path
        // (`/Users/me/My%20Notes/foo.md`), but FileManager expects
        // a decoded native path. Without `percentEncoded: false`
        // every file whose name or any ancestor folder contains a
        // space silently fails to open — the same class of bug as
        // issues #2 and #3 that 1cb8e41 fixed in storage / CLI /
        // settings code. Regression covered by issue #24.
        let attributes = try fileManager.attributesOfItem(atPath: standardizedURL.path(percentEncoded: false))
        return .init(
            modifiedAt: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            fileSize: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
        )
    }
}

private extension AppearanceMode {
    var externalDocumentColorScheme: AdwColorScheme {
        switch self {
        case .system:
            .default
        case .light:
            .forceLight
        case .dark:
            .forceDark
        }
    }
}

@MainActor
final class ExternalDocumentWindow {
    let window: ApplicationWindow

    let renderer: MarkdownRenderer
    let autosave: AutosaveCoordinator
    private let autosaveDelayOverride: Duration?
    private(set) var autosaveDelay: Duration
    private let directoryOpener: (URL) throws -> Void
    private let importIntoLibrary: (URL) throws -> Note

    let preview = MarkdownPreview()
    var editor = MarkdownEditor()
    let headerTitle = WindowTitle(title: "", subtitle: "")
    let editorModeToggle = ToggleButton(label: "Editor".localized)
    let splitModeToggle = ToggleButton(label: "Split".localized)
    let previewModeToggle = ToggleButton(label: "Preview".localized)
    let viewModeSwitcher = Box(orientation: .horizontal, spacing: 0)
    let contentHost = Box(orientation: .vertical, spacing: 0)
    let editorContent = Box(orientation: .vertical, spacing: 0)
    let editorFormattingToolbar = EditorFormattingToolbar()
    let saveButton = Button(icon: .custom("document-save-symbolic"))
    let menuButton = MenuButton(icon: .custom("open-menu-symbolic"))
    let toastOverlay = ToastOverlay()
    let editorPreviewPane = Paned(orientation: .horizontal)
    let editorScroll = ScrolledWindow()

    /// Whether this window is the focused toplevel — the launcher's
    /// app-level actions (F9 / Ctrl+F / …) route here when true.
    var isWindowActive: Bool {
        window.isActive
    }

    // Outline panel
    let outlineSidebar = OutlineSidebar()
    let outlineToggleButton = MainWindow.iconButton(named: "view-list-bullet-symbolic")
    let quickJumpButton = MainWindow.iconButton(named: "system-search-symbolic")
    let outlineSplitView = OverlaySplitView()
    var currentHeadings: [Heading] = []
    var isOutlineVisible = false
    var outlineScrollSpyDriver: OutlineScrollSpyDriver?
    var outlineRecentJumps = RecentJumps()
    var activeCommandPalette: CommandPaletteWindow?

    // Find / Replace
    let findReplaceBar = FindReplaceBar()
    let previewFindReplaceBar = FindReplaceBar()
    let previewPaneContent = Box(orientation: .vertical, spacing: 0)
    /// Shared find/replace plumbing — the same coordinator
    /// ``MainWindow`` uses, so the two windows can never drift.
    lazy var findReplace = FindReplaceCoordinator(
        editorBar: findReplaceBar,
        previewBar: previewFindReplaceBar,
        editor: editor,
        preview: preview,
        keyCaptureWindow: window,
        viewMode: { [weak self] in self?.viewMode ?? .split },
        presentToast: { [weak self] message in
            self?.toastOverlay.addToast(Toast(title: message))
        },
    )

    lazy var saveAsAction = SimpleAction(name: "save-document-as") { [weak self] in
        self?.saveDocumentAs()
    }

    lazy var importIntoLibraryAction = SimpleAction(name: "import-document-into-library") { [weak self] in
        self?.importCurrentDocumentIntoLibrary()
    }

    lazy var revealInFolderAction = SimpleAction(name: "reveal-document-folder") { [weak self] in
        self?.revealDocumentInFolder()
    }

    lazy var reloadAction = SimpleAction(name: "reload-document") { [weak self] in
        self?.reloadFromDisk(announce: true)
    }

    private(set) var fileURL: URL
    private var fileSnapshot: ExternalDocumentFileSnapshot
    private var deferredExternalSnapshot: ExternalDocumentFileSnapshot?
    private var externalChangeMonitorID: SourceID?
    private var externalReloadDeferred = false
    private var activeFileDialog: FileDialog?
    private lazy var previewRefreshScheduler = PreviewRefreshScheduler(
        render: { [weak self] blocks, baseDirectory in
            self?.renderPreviewNow(blocks: blocks, baseDirectory: baseDirectory)
        },
        fallbackBaseDirectory: { [weak self] in
            self?.fileURL.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
        },
        shouldDeferRender: { [weak self] in
            self?.shouldDeferPreviewRender() ?? false
        },
        onRendered: { [weak self] in
            self?.syncPreviewScroll()
        },
    )
    private lazy var previewScrollSyncScheduler = PreviewScrollSyncScheduler(
        sync: { [weak self] in
            self?.syncPreviewScroll()
        },
    )
    private var previewAnimationID: SourceID?
    private var isPreviewPaneAttached = false
    private var isRestoringPreviewPaneLayout = false
    private var suppressEditorChange = false
    private var suppressViewModeToggleChange = false
    private var hasPresented = false
    // Internal getter for the find/replace routing; setting must go
    // through the view-mode transition (see `applyViewMode`) so the
    // pane reparenting, toggle state, and scroll-spy rebind stay in
    // sync — hence private(set).
    private(set) var viewMode: EditorViewMode = .split
    private var preferredPreviewWidth = WorkspaceState.defaultPreviewWidth
    private var editorFormattingButtons: [MarkdownFormattingAction: Button] {
        editorFormattingToolbar.buttons
    }
    private var isEditorFormattingToolbarCompact: Bool {
        editorFormattingToolbar.isCompact
    }
    private var isEditorFormattingToolbarUsingTwoRows: Bool {
        editorFormattingToolbar.isUsingTwoRows
    }
    private var tableSizePicker: TableSizePicker?
    private(set) var overflowMenuSectionTitles: [String] = []
    private(set) var overflowMenuItemsBySection: [String: [String]] = [:]
#if DEBUG
    private var previewBlockBuildCount = 0
#endif
    private var previewBlockBuilder = IncrementalPreviewBlockBuilder()
    /// Mirrors `AppSettings.renderEmojiShortcodes`; refreshed in
    /// `applyRuntimeSettings` and fed to the preview block builder.
    private var renderEmojiShortcodes = true

    init(
        application: Application,
        fileURL: URL,
        renderer: MarkdownRenderer,
        autosave: AutosaveCoordinator,
        appSettings: AppSettings = .default,
        autosaveDelay: Duration? = nil,
        directoryOpener: @escaping (URL) throws -> Void = MainWindow.openDirectoryInSystemFileManager,
        importIntoLibrary: @escaping (URL) throws -> Note = { fileURL in
            try NotesRepository(notesDirectory: NotesRepository.fallbackNotesDirectory()).importNote(from: fileURL)
        },
    ) throws {
        let loadedDocument = try ExternalMarkdownDocumentStore.load(from: fileURL)
        self.renderer = renderer
        self.autosave = autosave
        autosaveDelayOverride = autosaveDelay
        self.autosaveDelay = autosaveDelay ?? .seconds(appSettings.autosaveDelaySeconds)
        self.directoryOpener = directoryOpener
        self.importIntoLibrary = importIntoLibrary
        self.fileURL = loadedDocument.url
        fileSnapshot = loadedDocument.snapshot

        window = ApplicationWindow(application: application)
        window.iconName = AppIdentity.identifier
        let preferredSize = MainWindow.clampedWindowSize(width: 1100, height: 760)
        window.setDefaultSize(width: preferredSize.width, height: preferredSize.height)

        buildUI()
        applyRuntimeSettings(appSettings, shouldRefreshPreview: false)
        preview.attach(to: window)
        configureActionsAndMenu()
        wireSignals()
        loadDocument(loadedDocument)
    }

    func present() {
        window.present()
        guard !hasPresented else { return }
        hasPresented = true
        startExternalChangeMonitor()
        MainContext.idle { [weak self] in
            self?.refreshPreview()
            self?.applyViewMode(animated: false)
            self?.focusPrimaryContentIfNeeded()
        }
    }
}

@MainActor
private extension ExternalDocumentWindow {
    func buildUI() {
        saveButton.addCSSClass(.flat)
        menuButton.addCSSClass(.flat)
        menuButton.hasFrame = false
        configureViewModeToggleContent()
        #if os(macOS)
        // Same live-theme-refresh hook as MainWindow — see
        // BundledIconRefreshRegistry for rationale.
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
            self?.applyEditorFormatting(action)
        }
        configureToolbarAccessibility()
        configureToolbarTooltips()

        let header = HeaderBar()
        header.titleWidget = headerTitle
        header.packStart(saveButton)
        header.packEnd(menuButton)
        header.packEnd(outlineToggleButton)
        header.packEnd(quickJumpButton)
        header.packEnd(viewModeSwitcher)

        outlineToggleButton.addCSSClass(.flat)
        outlineToggleButton.setAccessibleLabel("Toggle Outline".localized)
        outlineToggleButton.tooltipText = "Show outline (F9)".localized
        quickJumpButton.addCSSClass(.flat)
        quickJumpButton.setAccessibleLabel("Quick Jump".localized)
        quickJumpButton.tooltipText = "Quick jump… (Ctrl+G)".localized

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
        contentHost.hexpand = true
        contentHost.vexpand = true

        editorContent.append(editorFormattingToolbar.scrolled)
        editorContent.append(Separator())
        editorContent.append(findReplaceBar.root)
        editorContent.append(editorScroll)

        previewFindReplaceBar.isReadOnly = true
        previewPaneContent.hexpand = true
        previewPaneContent.vexpand = true
        previewPaneContent.append(previewFindReplaceBar.root)
        previewPaneContent.append(preview.rootScroll)

        editorPreviewPane.startChild = editorContent
        editorPreviewPane.resizeStartChild = true
        editorPreviewPane.resizeEndChild = false
        editorPreviewPane.shrinkStartChild = false
        editorPreviewPane.shrinkEndChild = true
        editorPreviewPane.wideHandle = true
        contentHost.append(editorPreviewPane)

        let toolbar = ToolbarView()
        toolbar.addTopBar(header)

        outlineSplitView.pinSidebar = true
        outlineSplitView.sidebarPosition = .end
        outlineSplitView.enableShowGesture = false
        outlineSplitView.enableHideGesture = false
        outlineSplitView.minSidebarWidth = 220
        outlineSplitView.maxSidebarWidth = 320
        outlineSplitView.sidebarWidthFraction = 0.18
        outlineSplitView.sidebar = outlineSidebar.root
        outlineSplitView.content = contentHost
        outlineSplitView.showSidebar = false

        toolbar.content = outlineSplitView

        toastOverlay.child = toolbar
        window.setContent(toastOverlay)
        applyViewMode(animated: false)
    }

    func wireSignals() {
        MacOSClickWorkaround.onToggle(editorModeToggle, togglesActive: false) { [weak self] in
            guard let self, !self.suppressViewModeToggleChange, editorModeToggle.active else { return }
            setViewMode(.editor, animated: false)
        }
        MacOSClickWorkaround.onToggle(splitModeToggle, togglesActive: false) { [weak self] in
            guard let self, !self.suppressViewModeToggleChange, splitModeToggle.active else { return }
            setViewMode(.split, animated: false)
        }
        MacOSClickWorkaround.onToggle(previewModeToggle, togglesActive: false) { [weak self] in
            guard let self, !self.suppressViewModeToggleChange, previewModeToggle.active else { return }
            setViewMode(.preview, animated: false)
        }

        MacOSClickWorkaround.onClick(saveButton) { [weak self] in
            self?.saveDocumentNow()
        }

        editor.view.onChanged { [weak self] in
            guard let self, !self.suppressEditorChange else { return }
            scheduleTypingPreviewRefresh()
            updateHeaderSubtitle()
            autosave.scheduleSave(after: autosaveDelay) { [weak self] in
                self?.saveCurrentDocument(announceSuccess: false)
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
            self?.previewScrollSyncScheduler.requestSync()
        }

        window.onCloseRequest { [weak self] in
            self?.saveCurrentDocument(announceSuccess: false)
            self?.stopExternalChangeMonitor()
            self?.previewScrollSyncScheduler.cancel()
            self?.autosave.cancel()
            return false
        }

        window.addKeyboardShortcut("<Ctrl>s") { [weak self] in
            self?.saveDocumentNow()
            return true
        }
        window.addKeyboardShortcut("<Ctrl><Shift>s") { [weak self] in
            self?.saveDocumentAs()
            return true
        }
        window.addKeyboardShortcut("F5") { [weak self] in
            self?.reloadFromDisk(announce: true)
            return true
        }
        // F9 / Ctrl+F / Ctrl+H / Ctrl+G are NOT wired here: they are
        // application-level actions (see SwiftyNotesLauncher's
        // installOutlineActions) that route to the focused external
        // window via AppController.focusedExternalDocumentWindow.
        // Registering them per-window too would duplicate the app
        // accelerators. F10 stays per-window because Editor↔Split is a
        // single-window concern, mirroring MainWindow.
        window.addKeyboardShortcut("F10") { [weak self] in
            self?.toggleEditorAndSplitModes()
            return true
        }

        outlineSidebar.onInsertHeadingRequest { [weak self] in
            self?.insertStarterHeadingIntoEditor()
        }
        outlineSidebar.list.onRowActivated { [weak self] row in
            guard let self else { return }
            let index = Int(row.index)
            guard let heading = outlineSidebar.heading(at: index) else { return }
            scrollToHeading(heading)
        }
        outlineSidebar.searchEntry.onSearchChanged { [weak self] in
            guard let self else { return }
            outlineSidebar.setQuery(outlineSidebar.searchEntry.text)
        }
        outlineSidebar.onToggleCollapsed { [weak self] id in
            guard let self else { return }
            outlineSidebar.toggleCollapsed(id)
            applyEditorFolding()
        }
        outlineSidebar.onDropReorder { [weak self] droppedID, targetID in
            self?.reorderOutlineSection(movingID: droppedID, beforeTargetID: targetID)
        }

        MacOSClickWorkaround.onClick(outlineToggleButton) { [weak self] in
            self?.toggleOutlineVisibility()
        }
        MacOSClickWorkaround.onClick(quickJumpButton) { [weak self] in
            self?.openCommandPalette()
        }

        if outlineScrollSpyDriver == nil {
            outlineScrollSpyDriver = makeOutlineScrollSpyDriver(onActive: { [weak self] activeID in
                self?.outlineSidebar.setActiveHeading(activeID)
            })
        }
        outlineScrollSpyDriver?.rebind(mode: viewMode)
    }

    func configureActionsAndMenu() {
        window.addAction(saveAsAction)
        window.addAction(importIntoLibraryAction)
        window.addAction(revealInFolderAction)
        window.addAction(reloadAction)

        let documentSection = GMenuRef()
        documentSection.append("Save As…".localized, action: "win.save-document-as")
        documentSection.append("Import into Library…".localized, action: "win.import-document-into-library")
        documentSection.append("Reveal in Folder".localized, action: "win.reveal-document-folder")

        let menu = GMenuRef()
        menu.appendSection("Document".localized, section: documentSection)
        overflowMenuSectionTitles = ["Document".localized]
        overflowMenuItemsBySection = [
            "Document": [
                "Save As…".localized,
                "Import into Library…".localized,
                "Reveal in Folder".localized,
            ],
        ]
        menuButton.setMenuModel(menu)
    }

    func configureToolbarAccessibility() {
        saveButton.setAccessibleLabel("Save File".localized)
        menuButton.setAccessibleLabel("Document Menu".localized)
        editorModeToggle.setAccessibleLabel("Editor".localized)
        splitModeToggle.setAccessibleLabel("Split".localized)
        previewModeToggle.setAccessibleLabel("Preview".localized)
        updateViewModeToggleState()
    }

    func configureToolbarTooltips() {
        saveButton.tooltipText = "Save File".localized
        menuButton.tooltipText = "Document Menu".localized
        editorModeToggle.tooltipText = "Editor only".localized
        splitModeToggle.tooltipText = "Split view".localized
        previewModeToggle.tooltipText = "Preview only".localized
        updateViewModeToggleState()
    }

    func updateWindowIdentity() {
        window.title = fileURL.lastPathComponent
        headerTitle.title = fileURL.lastPathComponent
    }

    func updateHeaderSubtitle() {
        let wordCount = editor.buffer.text.split(whereSeparator: \.isWhitespace).count
        let saveState = editor.buffer.modified ? "Unsaved changes" : "Saved"
        let wordLabel = wordCount == 1 ? "word" : "words"
        // `percentEncoded: false` so the header reads
        // "/Users/me/My Notes/foo.md" instead of the URL-encoded
        // "/Users/me/My%20Notes/foo.md" when the path contains
        // spaces or other reserved characters.
        headerTitle.subtitle = String(format: "%@ • %@ • %d %@".localized, fileURL.path(percentEncoded: false), saveState, wordCount, wordLabel)
    }

    func loadDocument(_ document: ExternalMarkdownDocument) {
        autosave.cancel()
        fileURL = document.url
        fileSnapshot = document.snapshot
        deferredExternalSnapshot = nil
        externalReloadDeferred = false
        updateWindowIdentity()
        suppressEditorChange = true
        editor.setText(document.content)
        editor.buffer.modified = false
        suppressEditorChange = false
        refreshPreview()
        applyViewMode(animated: false)
        updateHeaderSubtitle()
    }
}

@MainActor
extension ExternalDocumentWindow {
    // Internal (not fileprivate like most window plumbing): mirrors
    // MainWindow.applyRuntimeSettings so a future settings fan-out can
    // push live changes into open standalone windows, and tests can
    // exercise the outline-tweaks path.
    func applyRuntimeSettings(_ settings: AppSettings, shouldRefreshPreview: Bool = true) {
        editor.applySettings(settings)
        renderEmojiShortcodes = settings.renderEmojiShortcodes
        outlineSidebar.applyTweaks(
            density: settings.outlineDensity,
            treeLines: settings.outlineTreeLines,
            dragHandles: settings.outlineDragHandles,
        )
        autosaveDelay = autosaveDelayOverride ?? .seconds(settings.autosaveDelaySeconds)

        let styleManager = StyleManager.default
        styleManager.colorScheme = settings.appearanceMode.externalDocumentColorScheme
        editor.applyAutomaticStyleScheme(styleManager: styleManager)

        guard shouldRefreshPreview else { return }
        refreshPreview()
    }
}

@MainActor
private extension ExternalDocumentWindow {
    /// Single immediate-render path: every preview paint — scheduled or
    /// direct — must also refresh the outline and the preview-search
    /// overlay, or the sidebar shows stale (or, on first load, no)
    /// headings until the next edit.
    func renderPreviewNow(blocks: [RenderedBlock], baseDirectory: URL) {
        preview.render(blocks: blocks, baseDirectory: baseDirectory)
        refreshOutline(markdown: editor.buffer.text, blocks: blocks)
        refreshPreviewSearchAfterRerender()
    }

    func refreshPreview() {
        let blocks = buildPreviewBlocks(for: editor.buffer.text)
        let baseDirectory = fileURL.deletingLastPathComponent()
        guard preview.rootScroll.root != nil else {
            previewRefreshScheduler.cancel()
            renderPreviewNow(blocks: blocks, baseDirectory: baseDirectory)
            return
        }
        schedulePreviewRefresh(blocks: blocks, baseDirectory: baseDirectory)
    }

    func scheduleTypingPreviewRefresh() {
        let text = editor.buffer.text
        let baseDirectory = fileURL.deletingLastPathComponent()
        // Always debounce through the scheduler — even in editor-only
        // mode (preview unmounted), because the render closure also
        // re-extracts the outline, and doing that synchronously per
        // keystroke is user-visible typing work. Mirrors MainWindow.
        previewRefreshScheduler.scheduleDeferred(baseDirectory: baseDirectory) { [weak self] in
            self?.buildPreviewBlocks(for: text) ?? []
        }
    }

    func buildPreviewBlocks(for markdown: String) -> [RenderedBlock] {
#if DEBUG
        previewBlockBuildCount += 1
#endif
        return previewBlockBuilder.blocks(
            for: markdown,
            darkAppearance: StyleManager.default.dark,
            renderEmojiShortcodes: renderEmojiShortcodes,
        )
    }

    func schedulePreviewRefresh(blocks: [RenderedBlock], baseDirectory: URL) {
        previewRefreshScheduler.schedule(blocks: blocks, baseDirectory: baseDirectory)
    }

    func flushPendingPreviewRefresh() {
        previewRefreshScheduler.flush()
    }

    func shouldDeferPreviewRender() -> Bool {
        MainWindow.shouldDeferPreviewRender(
            isPreviewPresented: viewMode != .editor,
            windowWidth: window.width,
            windowHeight: window.height,
            hasParent: preview.rootScroll.parent != nil,
            hasRoot: preview.rootScroll.root != nil,
            width: preview.rootScroll.width,
            height: preview.rootScroll.height,
        )
    }

    func syncPreviewScroll() {
        guard viewMode == .split, isPreviewPaneAttached else { return }
        PreviewScrollSync.sync(editor: editorScroll, preview: preview.rootScroll)
    }
}

@MainActor
private extension ExternalDocumentWindow {
    func updateViewModeToggleState() {
        suppressViewModeToggleChange = true
        editorModeToggle.active = viewMode == .editor
        splitModeToggle.active = viewMode == .split
        previewModeToggle.active = viewMode == .preview
        suppressViewModeToggleChange = false
    }

    func setViewMode(_ mode: EditorViewMode, animated: Bool) {
        guard viewMode != mode else {
            updateViewModeToggleState()
            return
        }
        viewMode = mode
        applyViewMode(animated: animated)
        if viewMode != .preview {
            MainContext.idle { [weak self] in
                self?.focusPrimaryContentIfNeeded()
            }
        }
    }

    func toggleEditorAndSplitModes() {
        let nextMode: EditorViewMode = viewMode == .editor ? .split : .editor
        setViewMode(nextMode, animated: true)
    }

    func applyViewMode(animated: Bool) {
        updateViewModeToggleState()
        stopPreviewAnimation()
        switch viewMode {
        case .editor:
            showEditorContent()
            hidePreviewPane(animated: animated)
        case .split:
            showEditorContent()
            showPreviewPane(animated: animated)
        case .preview:
            showPreviewOnlyContent()
        }
        refreshEditorFormattingToolbarLayout()
        outlineScrollSpyDriver?.rebind(mode: viewMode)
    }

    func showEditorContent() {
        guard contentHost.children().first?.opaquePointer != editorPreviewPane.opaquePointer else { return }
        if let currentChild = contentHost.children().first {
            contentHost.remove(currentChild)
        }
        contentHost.append(editorPreviewPane)
    }

    func showPreviewOnlyContent() {
        stopPreviewAnimation()
        detachPreviewPane()
        guard contentHost.children().first?.opaquePointer != previewPaneContent.opaquePointer else { return }
        if let currentChild = contentHost.children().first {
            contentHost.remove(currentChild)
        }
        contentHost.append(previewPaneContent)
        refreshPreview()
    }

    func focusPrimaryContentIfNeeded() {
        guard viewMode != .preview else { return }
        editor.focus()
    }

    func showPreviewPane(animated: Bool) {
        showEditorContent()
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

    func hidePreviewPane(animated: Bool) {
        showEditorContent()
        guard isPreviewPaneAttached else { return }
        guard animated, canAnimatePreviewPane else {
            detachPreviewPane()
            return
        }
        animatePreviewPane(to: currentPreviewContainerWidth)
    }

    func restorePreviewPaneLayout() {
        guard viewMode == .split else { return }
        let totalWidth = currentPreviewContainerWidth
        isRestoringPreviewPaneLayout = true
        editorPreviewPane.position = resolvedVisiblePreviewPosition(totalWidth: totalWidth)
        refreshEditorFormattingToolbarLayout()
        MainContext.idle { [weak self] in
            self?.isRestoringPreviewPaneLayout = false
        }
    }

    func attachPreviewPane() {
        guard !isPreviewPaneAttached else { return }
        editorPreviewPane.endChild = previewPaneContent
        isPreviewPaneAttached = true
    }

    func detachPreviewPane() {
        guard isPreviewPaneAttached else { return }
        stopPreviewAnimation()
        editorPreviewPane.endChild = nil
        isPreviewPaneAttached = false
    }

    func animatePreviewPane(to targetPosition: Int) {
        stopPreviewAnimation()
        let startPosition = editorPreviewPane.position
        guard startPosition != targetPosition else {
            isRestoringPreviewPaneLayout = false
            if viewMode != .split {
                schedulePreviewDetachIfNeeded()
            }
            return
        }

        isRestoringPreviewPaneLayout = true
        let startedAt = Date()
        let duration = Double(MainWindow.previewAnimationDuration) / 1000
        previewAnimationID = MainContext.timeout(every: .milliseconds(16)) { [weak self] in
            guard let self else { return false }
            let elapsed = Date().timeIntervalSince(startedAt)
            let progress = min(max(elapsed / duration, 0), 1)
            let easedProgress = 1 - pow(1 - progress, 3)
            let position = Double(startPosition) + (Double(targetPosition - startPosition) * easedProgress)
            editorPreviewPane.position = Int(position.rounded())
            if progress < 1 {
                return true
            }

            previewAnimationID = nil
            isRestoringPreviewPaneLayout = false
            if viewMode != .split {
                schedulePreviewDetachIfNeeded()
            }
            return false
        }
    }

    func schedulePreviewDetachIfNeeded() {
        MainContext.delay(for: .milliseconds(1)) { [weak self] in
            guard let self, viewMode != .split else { return }
            detachPreviewPane()
        }
    }

    func stopPreviewAnimation() {
        if let previewAnimationID {
            MainContext.cancel(sourceId: previewAnimationID)
            self.previewAnimationID = nil
        }
    }

    var currentPreviewContainerWidth: Int {
        max(
            editorPreviewPane.width,
            contentHost.width,
            window.width,
            window.defaultWidth,
        )
    }

    var canAnimatePreviewPane: Bool {
        editorPreviewPane.parent != nil && editorPreviewPane.width > 0 && editorPreviewPane.height > 0
    }

    func resolvedVisiblePreviewPosition(totalWidth: Int) -> Int {
        preview.rootScroll.minContentWidth = MainWindow.minimumPreviewWidth
        let previewWidth = MainWindow.resolvedPreviewWidth(
            storedWidth: preferredPreviewWidth,
            availableWidth: totalWidth,
        )
        return max(totalWidth - previewWidth, MainWindow.minimumEditorWidth)
    }

    func handlePreviewPaneMoved() {
        guard viewMode == .split, isPreviewPaneAttached, !isRestoringPreviewPaneLayout else { return }
        let totalWidth = max(editorPreviewPane.width, contentHost.width, window.width, window.defaultWidth)
        guard totalWidth >= MainWindow.minimumPreviewWidth + MainWindow.minimumEditorWidth else { return }
        let previewWidth = totalWidth - editorPreviewPane.position
        guard previewWidth >= MainWindow.minimumPreviewWidth else { return }
        preferredPreviewWidth = previewWidth
        updateEditorFormattingToolbarLayout(forWidth: editorPreviewPane.position)
    }
}

@MainActor
private extension ExternalDocumentWindow {
    func configureViewModeToggleContent() {
        setToggleContent(
            editorModeToggle,
            label: "Editor".localized,
            iconName: "document-edit-symbolic",
        )
        setToggleContent(
            splitModeToggle,
            label: "Split".localized,
            iconName: "view-dual-symbolic",
        )
        setToggleContent(
            previewModeToggle,
            label: "Preview".localized,
            iconName: "text-x-generic-symbolic",
        )
    }

    func applyEditorFormatting(_ action: MarkdownFormattingAction) {
        if action == .table {
            presentTableSizePicker()
            return
        }
        editor.applyFormatting(action)
    }

    private func presentTableSizePicker() {
        guard let button = editorFormattingToolbar.buttons[.table] else { return }
        let picker = ensureTableSizePicker()
        picker.popover.present(from: button)
    }

    private func ensureTableSizePicker() -> TableSizePicker {
        if let picker = tableSizePicker { return picker }
        let picker = TableSizePicker()
        picker.onSelect = { [weak self] rows, cols, alignments in
            self?.editor.insertTable(rows: rows, cols: cols, alignments: alignments)
        }
        tableSizePicker = picker
        return picker
    }

    func updateEditorFormattingToolbarLayout(forWidth width: Int) {
        editorFormattingToolbar.updateLayout(
            forWidth: width,
            fallbackThreshold: MainWindow.editorFormattingCompactWidthThreshold,
        )
    }

    func refreshEditorFormattingToolbarLayout() {
        updateEditorFormattingToolbarLayout(forWidth: resolvedEditorFormattingToolbarWidth())
    }

    private func setToggleContent(_ toggle: ToggleButton, label: String, iconName: String) {
        toggle.child = ToolbarButtonContent.make(
            configuration: ToolbarButtonContentConfiguration(
                primaryText: label,
                iconName: iconName,
                prefersCompactLabel: false,
                hidesLabelWhenCompact: false,
            ),
            isCompact: false,
        )
    }

    private func resolvedEditorFormattingToolbarWidth() -> Int {
        if viewMode == .split {
            let totalWidth = currentPreviewContainerWidth
            let previewWidth = MainWindow.resolvedPreviewWidth(
                storedWidth: preferredPreviewWidth,
                availableWidth: totalWidth,
            )
            return max(totalWidth - previewWidth, MainWindow.minimumEditorWidth)
        }

        let allocatedWidth = max(
            editorFormattingToolbar.scrolled.width,
            editorContent.width,
            editorPreviewPane.width,
            contentHost.width,
        )
        if allocatedWidth > 0 {
            return allocatedWidth
        }
        return currentPreviewContainerWidth
    }
}

@MainActor
private extension ExternalDocumentWindow {
    func saveDocumentNow() {
        saveCurrentDocument(announceSuccess: true)
        autosave.cancel()
    }

    func saveCurrentDocument(announceSuccess: Bool) {
        _ = saveDocument(
            to: fileURL,
            successMessage: announceSuccess ? "File saved" : nil,
        )
    }

    @discardableResult
    func saveDocument(to targetURL: URL, successMessage: String?) -> Bool {
        do {
            let savedDocument = try ExternalMarkdownDocumentStore.save(
                content: editor.buffer.text,
                to: targetURL,
            )
            fileURL = savedDocument.url
            fileSnapshot = savedDocument.snapshot
            deferredExternalSnapshot = nil
            externalReloadDeferred = false
            editor.buffer.modified = false
            updateWindowIdentity()
            refreshPreview()
            updateHeaderSubtitle()
            if let successMessage {
                toastOverlay.showToast(successMessage)
            }
            applyDeferredExternalReloadIfPossible()
            return true
        } catch {
            handleSaveFailure(error)
            return false
        }
    }

    func handleSaveFailure(_ error: Error) {
        toastOverlay.showToast(String(format: "Could not save file: %@".localized, error.localizedDescription))
        updateHeaderSubtitle()
    }

    func saveDocumentAs() {
        let dialog = FileDialog()
        dialog.title = "Save Markdown File As".localized
        dialog.modal = true
        dialog.acceptLabel = "Save".localized
        dialog.initialName = fileURL.lastPathComponent
        dialog.setFilters([
            FileFilter(name: "Markdown".localized, suffixes: ["md", "markdown", "txt"]),
            FileFilter(name: "All files".localized, patterns: ["*"]),
        ])
        activeFileDialog = dialog
        dialog.save(parent: window.root ?? window) { [weak self] result in
            guard let self else { return }
            activeFileDialog = nil
            let path: String?
            switch result {
            case let .success(value):
                path = value
            case let .failure(error):
                presentError(
                    heading: "Could not open save dialog".localized,
                    body: error.message,
                )
                return
            }
            guard let path else { return }
            let savedURL = URL(fileURLWithPath: path)
            if saveDocument(
                to: savedURL,
                successMessage: String(format: "Saved as %@".localized, savedURL.lastPathComponent),
            ) {
                autosave.cancel()
            }
        }
    }

    func importCurrentDocumentIntoLibrary() {
        if editor.buffer.modified {
            guard saveDocument(to: fileURL, successMessage: nil) else { return }
            autosave.cancel()
        }

        do {
            let importedNote = try importIntoLibrary(fileURL)
            toastOverlay.showToast(String(format: "Imported %@ into library".localized, importedNote.title))
        } catch {
            presentError(
                heading: "Could not import file into library".localized,
                body: error.localizedDescription,
            )
        }
    }

    func revealDocumentInFolder() {
        do {
            try directoryOpener(fileURL.deletingLastPathComponent())
        } catch {
            presentError(
                heading: "Could not open containing folder".localized,
                body: error.localizedDescription,
            )
        }
    }

    func reloadFromDisk(announce: Bool, forceDiscardingUnsavedChanges: Bool = false) {
        if editor.buffer.modified, !forceDiscardingUnsavedChanges {
            if !externalReloadDeferred {
                externalReloadDeferred = true
                toastOverlay.showToast(
                    "File changed on disk. Save or reload to sync.".localized,
                    button: "Reload".localized,
                ) { [weak self] in
                    self?.reloadFromDisk(announce: true, forceDiscardingUnsavedChanges: true)
                }
            }
            return
        }

        do {
            let document = try ExternalMarkdownDocumentStore.load(from: fileURL)
            loadDocument(document)
            if announce {
                toastOverlay.showToast("File reloaded from disk".localized)
            }
        } catch {
            presentError(
                heading: "Could not reload file".localized,
                body: error.localizedDescription,
            )
        }
    }

    func startExternalChangeMonitor() {
        stopExternalChangeMonitor()
        externalChangeMonitorID = MainContext.timeout(every: .milliseconds(1500)) { [weak self] in
            guard let self else { return false }
            pollForExternalChanges()
            return true
        }
    }

    func stopExternalChangeMonitor() {
        if let externalChangeMonitorID {
            MainContext.cancel(sourceId: externalChangeMonitorID)
            self.externalChangeMonitorID = nil
        }
        previewRefreshScheduler.cancel()
    }

    func pollForExternalChanges() {
        do {
            let latestSnapshot = try ExternalMarkdownDocumentStore.snapshot(of: fileURL)
            guard latestSnapshot != fileSnapshot else {
                applyDeferredExternalReloadIfPossible()
                return
            }

            if editor.buffer.modified {
                deferredExternalSnapshot = latestSnapshot
                if !externalReloadDeferred {
                    externalReloadDeferred = true
                    toastOverlay.showToast(
                        "File changed on disk. Save or reload to sync.",
                        button: "Reload",
                    ) { [weak self] in
                        self?.reloadFromDisk(announce: true, forceDiscardingUnsavedChanges: true)
                    }
                }
                return
            }

            reloadFromDisk(announce: true, forceDiscardingUnsavedChanges: true)
        } catch {
            toastOverlay.showToast("Could not inspect markdown file".localized)
        }
    }

    func applyDeferredExternalReloadIfPossible() {
        guard deferredExternalSnapshot != nil, !editor.buffer.modified else { return }
        reloadFromDisk(announce: true, forceDiscardingUnsavedChanges: true)
    }

    func presentError(heading: String, body: String) {
        let dialog = AlertDialog(heading: heading, body: body)
        dialog.addResponse("ok", label: "OK".localized)
        dialog.defaultResponse = "ok"
        dialog.closeResponse = "ok"
        dialog.present(window)
    }
}

#if DEBUG
    @MainActor
    extension ExternalDocumentWindow {
        var debugViewMode: EditorViewMode {
            viewMode
        }

        /// Routes through the real transition (`setViewMode`) so tests
        /// exercise pane reparenting, toggle sync, and the scroll-spy
        /// rebind — never the raw stored property.
        func debugSetViewMode(_ mode: EditorViewMode) {
            setViewMode(mode, animated: false)
        }

        var debugEditorText: String {
            editor.buffer.text
        }

        var debugEditorModified: Bool {
            editor.buffer.modified
        }

        var debugOverflowMenuSectionTitles: [String] {
            overflowMenuSectionTitles
        }

        var debugOverflowMenuItemsBySection: [String: [String]] {
            overflowMenuItemsBySection
        }

        var debugPreviewText: String {
            previewRefreshScheduler.flush()
            previewRefreshScheduler.cancel()
            if preview.debugTopLevelWidgetCount == 0 {
                let blocks = buildPreviewBlocks(for: editor.buffer.text)
                renderPreviewNow(blocks: blocks, baseDirectory: fileURL.deletingLastPathComponent())
            }
            return preview.plainText
        }

        var debugPreviewBlockBuildCount: Int {
            previewBlockBuildCount
        }

        func debugSetEditorText(_ text: String) {
            editor.buffer.text = text
        }

        func debugPollForExternalChanges() {
            pollForExternalChanges()
        }
    }
#endif
