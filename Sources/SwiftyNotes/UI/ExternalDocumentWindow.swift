import Adwaita
import Foundation

private struct ExternalDocumentFileSnapshot: Equatable {
    let modifiedAt: TimeInterval
    let fileSize: UInt64
}

private struct ExternalMarkdownDocument {
    let url: URL
    let content: String
    let snapshot: ExternalDocumentFileSnapshot
}

private enum ExternalMarkdownDocumentStore {
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
        let attributes = try fileManager.attributesOfItem(atPath: standardizedURL.path())
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
    let editorModeToggle = ToggleButton(label: "Editor")
    let splitModeToggle = ToggleButton(label: "Split")
    let previewModeToggle = ToggleButton(label: "Preview")
    let viewModeSwitcher = Box(orientation: .horizontal, spacing: 0)
    let contentHost = Box(orientation: .vertical, spacing: 0)
    let editorContent = Box(orientation: .vertical, spacing: 0)
    let editorFormattingToolbar = EditorFormattingToolbar()
    let saveButton = Button(icon: .custom("document-save-symbolic"))
    let menuButton = MenuButton(icon: .custom("open-menu-symbolic"))
    let toastOverlay = ToastOverlay()
    let editorPreviewPane = Paned(orientation: .horizontal)
    let editorScroll = ScrolledWindow()

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
            self?.preview.render(blocks: blocks, baseDirectory: baseDirectory)
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
    private var viewMode: EditorViewMode = .split
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
        header.packEnd(viewModeSwitcher)

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
        editorContent.append(editorScroll)
        editorPreviewPane.startChild = editorContent
        editorPreviewPane.resizeStartChild = true
        editorPreviewPane.resizeEndChild = false
        editorPreviewPane.shrinkStartChild = false
        editorPreviewPane.shrinkEndChild = true
        editorPreviewPane.wideHandle = true
        contentHost.append(editorPreviewPane)

        let toolbar = ToolbarView()
        toolbar.addTopBar(header)
        toolbar.content = contentHost

        toastOverlay.child = toolbar
        window.setContent(toastOverlay)
        applyViewMode(animated: false)
    }

    func wireSignals() {
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



        saveButton.onClicked { [weak self] in
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
        window.addKeyboardShortcut("F9") { [weak self] in
            self?.toggleEditorAndSplitModes()
            return true
        }
    }

    func configureActionsAndMenu() {
        window.addAction(saveAsAction)
        window.addAction(importIntoLibraryAction)
        window.addAction(revealInFolderAction)
        window.addAction(reloadAction)

        let documentSection = GMenuRef()
        documentSection.append("Save As…", action: "win.save-document-as")
        documentSection.append("Import into Library…", action: "win.import-document-into-library")
        documentSection.append("Reveal in Folder", action: "win.reveal-document-folder")

        let menu = GMenuRef()
        menu.appendSection("Document", section: documentSection)
        overflowMenuSectionTitles = ["Document"]
        overflowMenuItemsBySection = [
            "Document": [
                "Save As…",
                "Import into Library…",
                "Reveal in Folder",
            ],
        ]
        menuButton.setMenuModel(menu)
    }

    func configureToolbarAccessibility() {
        saveButton.setAccessibleLabel("Save File")
        menuButton.setAccessibleLabel("Document Menu")
        editorModeToggle.setAccessibleLabel("Editor")
        splitModeToggle.setAccessibleLabel("Split")
        previewModeToggle.setAccessibleLabel("Preview")
        updateViewModeToggleState()
    }

    func configureToolbarTooltips() {
        saveButton.tooltipText = "Save File"
        menuButton.tooltipText = "Document Menu"
        editorModeToggle.tooltipText = "Editor only"
        splitModeToggle.tooltipText = "Split view"
        previewModeToggle.tooltipText = "Preview only"
        updateViewModeToggleState()
    }

    func applyRuntimeSettings(_ settings: AppSettings, shouldRefreshPreview: Bool = true) {
        editor.applySettings(settings)
        autosaveDelay = autosaveDelayOverride ?? .seconds(settings.autosaveDelaySeconds)

        let styleManager = StyleManager.default
        styleManager.colorScheme = settings.appearanceMode.externalDocumentColorScheme
        editor.applyAutomaticStyleScheme(styleManager: styleManager)

        guard shouldRefreshPreview else { return }
        refreshPreview()
    }

    func updateWindowIdentity() {
        window.title = fileURL.lastPathComponent
        headerTitle.title = fileURL.lastPathComponent
    }

    func updateHeaderSubtitle() {
        let wordCount = editor.buffer.text.split(whereSeparator: \.isWhitespace).count
        let saveState = editor.buffer.modified ? "Unsaved changes" : "Saved"
        let wordLabel = wordCount == 1 ? "word" : "words"
        headerTitle.subtitle = "\(fileURL.path()) • \(saveState) • \(wordCount) \(wordLabel)"
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
private extension ExternalDocumentWindow {
    func refreshPreview() {
        let blocks = buildPreviewBlocks(for: editor.buffer.text)
        let baseDirectory = fileURL.deletingLastPathComponent()
        guard preview.rootScroll.root != nil else {
            previewRefreshScheduler.cancel()
            preview.render(blocks: blocks, baseDirectory: baseDirectory)
            return
        }
        schedulePreviewRefresh(blocks: blocks, baseDirectory: baseDirectory)
    }

    func scheduleTypingPreviewRefresh() {
        let text = editor.buffer.text
        let baseDirectory = fileURL.deletingLastPathComponent()
        guard preview.rootScroll.root != nil else {
            previewRefreshScheduler.cancel()
            preview.render(blocks: buildPreviewBlocks(for: text), baseDirectory: baseDirectory)
            return
        }
        previewRefreshScheduler.scheduleDeferred(baseDirectory: baseDirectory) { [weak self] in
            self?.buildPreviewBlocks(for: text) ?? []
        }
    }

    func buildPreviewBlocks(for markdown: String) -> [RenderedBlock] {
#if DEBUG
        previewBlockBuildCount += 1
#endif
        return previewBlockBuilder.blocks(for: markdown, darkAppearance: StyleManager.default.dark)
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
        guard contentHost.children().first?.opaquePointer != preview.rootScroll.opaquePointer else { return }
        if let currentChild = contentHost.children().first {
            contentHost.remove(currentChild)
        }
        contentHost.append(preview.rootScroll)
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
        editorPreviewPane.endChild = preview.rootScroll
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
            label: "Editor",
            iconName: "document-edit-symbolic",
        )
        setToggleContent(
            splitModeToggle,
            label: "Split",
            iconName: "view-dual-symbolic",
        )
        setToggleContent(
            previewModeToggle,
            label: "Preview",
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
        toastOverlay.showToast("Could not save file: \(error.localizedDescription)")
        updateHeaderSubtitle()
    }

    func saveDocumentAs() {
        let dialog = FileDialog()
        dialog.title = "Save Markdown File As"
        dialog.modal = true
        dialog.acceptLabel = "Save"
        dialog.initialName = fileURL.lastPathComponent
        dialog.setFilters([
            FileFilter(name: "Markdown", suffixes: ["md", "markdown", "txt"]),
            FileFilter(name: "All files", patterns: ["*"]),
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
                    heading: "Could not open save dialog",
                    body: error.message,
                )
                return
            }
            guard let path else { return }
            let savedURL = URL(fileURLWithPath: path)
            if saveDocument(
                to: savedURL,
                successMessage: "Saved as \(savedURL.lastPathComponent)",
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
            toastOverlay.showToast("Imported \(importedNote.title) into library")
        } catch {
            presentError(
                heading: "Could not import file into library",
                body: error.localizedDescription,
            )
        }
    }

    func revealDocumentInFolder() {
        do {
            try directoryOpener(fileURL.deletingLastPathComponent())
        } catch {
            presentError(
                heading: "Could not open containing folder",
                body: error.localizedDescription,
            )
        }
    }

    func reloadFromDisk(announce: Bool, forceDiscardingUnsavedChanges: Bool = false) {
        if editor.buffer.modified, !forceDiscardingUnsavedChanges {
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

        do {
            let document = try ExternalMarkdownDocumentStore.load(from: fileURL)
            loadDocument(document)
            if announce {
                toastOverlay.showToast("File reloaded from disk")
            }
        } catch {
            presentError(
                heading: "Could not reload file",
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
            toastOverlay.showToast("Could not inspect markdown file")
        }
    }

    func applyDeferredExternalReloadIfPossible() {
        guard deferredExternalSnapshot != nil, !editor.buffer.modified else { return }
        reloadFromDisk(announce: true, forceDiscardingUnsavedChanges: true)
    }

    func presentError(heading: String, body: String) {
        let dialog = AlertDialog(heading: heading, body: body)
        dialog.addResponse("ok", label: "OK")
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
                preview.render(blocks: blocks, baseDirectory: fileURL.deletingLastPathComponent())
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
