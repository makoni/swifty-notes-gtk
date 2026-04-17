import Adwaita
import CAdwaita
import Foundation

private struct ExternalDocumentFileSnapshot: Equatable {
    let modifiedAt: TimeInterval
    let fileSize: UInt64
    let contentFingerprint: UInt64
}

private struct ExternalMarkdownDocument {
    let url: URL
    let content: String
    let snapshot: ExternalDocumentFileSnapshot
}

private enum ExternalMarkdownDocumentStore {
    private static let hashSeed: UInt64 = 14_695_981_039_346_656_037

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
        let data = try Data(contentsOf: standardizedURL)
        return .init(
            modifiedAt: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            fileSize: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            contentFingerprint: hashing(data, into: hashSeed)
        )
    }

    private static func hashing<S: Sequence>(_ bytes: S, into seed: UInt64) -> UInt64 where S.Element == UInt8 {
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
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
    let editorFormattingBar = Box(orientation: .vertical, spacing: 6)
    let editorFormattingBarScroll = ScrolledWindow()
    let editorFormattingPrimaryRow = Box(orientation: .horizontal, spacing: 8)
    let editorFormattingSecondaryRow = Box(orientation: .horizontal, spacing: 8)
    let editorInlineFormattingGroup = Box(orientation: .horizontal, spacing: 0)
    let editorBlockFormattingGroup = Box(orientation: .horizontal, spacing: 0)
    let editorFormattingGroupSeparator = Separator(orientation: .vertical)
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
    private var previewRefreshID: SourceID?
    private var previewRefreshRetryID: SourceID?
    private var pendingPreviewBlocks: [RenderedBlock]?
    private var pendingPreviewBaseDirectory: URL?
    private var previewAnimationID: SourceID?
    private var isPreviewPaneAttached = false
    private var isRestoringPreviewPaneLayout = false
    private var suppressEditorChange = false
    private var suppressViewModeToggleChange = false
    private var hasPresented = false
    private var viewMode: EditorViewMode = .split
    private var preferredPreviewWidth = WorkspaceState.defaultPreviewWidth
    private var editorFormattingButtons: [MarkdownFormattingAction: Button] = [:]
    private var editorFormattingButtonConfigurations: [MarkdownFormattingAction: ToolbarButtonContentConfiguration] = [:]
    private var isEditorFormattingToolbarCompact = false
    private var isEditorFormattingToolbarUsingTwoRows = false
    private(set) var overflowMenuSectionTitles: [String] = []
    private(set) var overflowMenuItemsBySection: [String: [String]] = [:]

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
        }
    ) throws {
        let loadedDocument = try ExternalMarkdownDocumentStore.load(from: fileURL)
        self.renderer = renderer
        self.autosave = autosave
        self.autosaveDelayOverride = autosaveDelay
        self.autosaveDelay = autosaveDelay ?? .seconds(appSettings.autosaveDelaySeconds)
        self.directoryOpener = directoryOpener
        self.importIntoLibrary = importIntoLibrary
        self.fileURL = loadedDocument.url
        self.fileSnapshot = loadedDocument.snapshot

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
        configureEditorFormattingToolbar()
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
        editorContent.hexpand = true
        editorContent.vexpand = true
        contentHost.hexpand = true
        contentHost.vexpand = true

        editorContent.append(editorFormattingBarScroll)
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
            guard let self, !self.suppressViewModeToggleChange, self.editorModeToggle.active else { return }
            self.setViewMode(.editor, animated: false)
        }

        splitModeToggle.onToggled { [weak self] in
            guard let self, !self.suppressViewModeToggleChange, self.splitModeToggle.active else { return }
            self.setViewMode(.split, animated: false)
        }

        previewModeToggle.onToggled { [weak self] in
            guard let self, !self.suppressViewModeToggleChange, self.previewModeToggle.active else { return }
            self.setViewMode(.preview, animated: false)
        }

        for (action, button) in editorFormattingButtons {
            button.onClicked { [weak self] in
                self?.applyEditorFormatting(action)
            }
        }

        saveButton.onClicked { [weak self] in
            self?.saveDocumentNow()
        }

        editor.view.onChanged { [weak self] in
            guard let self, !self.suppressEditorChange else { return }
            self.refreshPreview()
            self.updateHeaderSubtitle()
            self.autosave.scheduleSave(after: self.autosaveDelay) { [weak self] in
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

        editorFormattingBarScroll.onSizeAllocate { [weak self] width, _ in
            self?.updateEditorFormattingToolbarLayout(forWidth: width)
        }

        editorScroll.verticalAdjustment.onValueChanged { [weak self] in
            self?.syncPreviewScroll()
        }

        window.onCloseRequest { [weak self] in
            self?.saveCurrentDocument(announceSuccess: false)
            self?.stopExternalChangeMonitor()
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
                "Reveal in Folder"
            ]
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
        let blocks = renderer.blocks(for: editor.buffer.text)
        let baseDirectory = fileURL.deletingLastPathComponent()
        guard preview.rootScroll.root != nil else {
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
            preview.render(blocks: blocks, baseDirectory: baseDirectory)
            return
        }
        schedulePreviewRefresh(blocks: blocks, baseDirectory: baseDirectory)
    }

    func schedulePreviewRefresh(blocks: [RenderedBlock], baseDirectory: URL) {
        if let previewRefreshID {
            MainContext.cancel(sourceId: previewRefreshID)
            self.previewRefreshID = nil
        }
        pendingPreviewBlocks = blocks
        pendingPreviewBaseDirectory = baseDirectory
        previewRefreshID = MainContext.timeout(every: .milliseconds(1)) { [weak self] in
            guard let self else { return false }
            self.flushPendingPreviewRefresh()
            return false
        }
    }

    func flushPendingPreviewRefresh() {
        guard previewRefreshID != nil || pendingPreviewBlocks != nil || pendingPreviewBaseDirectory != nil else {
            return
        }
        if let previewRefreshID {
            MainContext.cancel(sourceId: previewRefreshID)
            self.previewRefreshID = nil
        }
        if shouldDeferPreviewRender() {
            if previewRefreshRetryID == nil {
                previewRefreshRetryID = MainContext.timeout(every: .milliseconds(16)) { [weak self] in
                    guard let self else { return false }
                    self.previewRefreshRetryID = nil
                    self.flushPendingPreviewRefresh()
                    return false
                }
            }
            return
        }
        if let previewRefreshRetryID {
            MainContext.cancel(sourceId: previewRefreshRetryID)
            self.previewRefreshRetryID = nil
        }
        let blocks = pendingPreviewBlocks ?? []
        let baseDirectory = pendingPreviewBaseDirectory ?? fileURL.deletingLastPathComponent()
        pendingPreviewBlocks = nil
        pendingPreviewBaseDirectory = nil
        preview.render(blocks: blocks, baseDirectory: baseDirectory)
        MainContext.idle { [weak self] in
            self?.syncPreviewScroll()
        }
    }

    func shouldDeferPreviewRender() -> Bool {
        MainWindow.shouldDeferPreviewRender(
            isPreviewPresented: viewMode != .editor,
            windowWidth: window.width,
            windowHeight: window.height,
            hasParent: preview.rootScroll.parent != nil,
            hasRoot: preview.rootScroll.root != nil,
            width: preview.rootScroll.width,
            height: preview.rootScroll.height
        )
    }

    func syncPreviewScroll() {
        guard viewMode == .split, isPreviewPaneAttached else { return }
        guard preview.rootScroll.parent != nil, preview.rootScroll.width > 0, preview.rootScroll.height > 0 else { return }
        let source = editorScroll.verticalAdjustment
        let destination = preview.rootScroll.verticalAdjustment
        let sourceMax = max(source.upper - source.pageSize - source.lower, 0)
        let destinationMax = max(destination.upper - destination.pageSize - destination.lower, 0)
        let progress = sourceMax > 0 ? (source.value - source.lower) / sourceMax : 0
        destination.value = destination.lower + (destinationMax * progress)
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
            self.editorPreviewPane.position = Int(position.rounded())
            if progress < 1 {
                return true
            }

            self.previewAnimationID = nil
            self.isRestoringPreviewPaneLayout = false
            if self.viewMode != .split {
                self.schedulePreviewDetachIfNeeded()
            }
            return false
        }
    }

    func schedulePreviewDetachIfNeeded() {
        MainContext.delay(for: .milliseconds(1)) { [weak self] in
            guard let self, self.viewMode != .split else { return }
            self.detachPreviewPane()
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
            window.defaultWidth
        )
    }

    var canAnimatePreviewPane: Bool {
        editorPreviewPane.parent != nil && editorPreviewPane.width > 0 && editorPreviewPane.height > 0
    }

    func resolvedVisiblePreviewPosition(totalWidth: Int) -> Int {
        preview.rootScroll.minContentWidth = MainWindow.minimumPreviewWidth
        let previewWidth = MainWindow.resolvedPreviewWidth(
            storedWidth: preferredPreviewWidth,
            availableWidth: totalWidth
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
            iconName: "document-edit-symbolic"
        )
        setToggleContent(
            splitModeToggle,
            label: "Split",
            iconName: "view-dual-symbolic"
        )
        setToggleContent(
            previewModeToggle,
            label: "Preview",
            iconName: "text-x-generic-symbolic"
        )
    }

    func configureEditorFormattingToolbar() {
        guard editorFormattingButtons.isEmpty else { return }

        editorFormattingBar.addCSSClass(.toolbar)
        editorFormattingBar.marginStart = 8
        editorFormattingBar.marginEnd = 8
        editorFormattingBar.marginTop = 8
        editorFormattingBar.marginBottom = 8
        editorFormattingBar.hexpand = false
        editorFormattingBar.halign = .start

        editorFormattingPrimaryRow.halign = .start
        editorFormattingSecondaryRow.halign = .start
        editorFormattingSecondaryRow.visible = false

        editorFormattingBar.append(editorFormattingPrimaryRow)
        editorFormattingBar.append(editorFormattingSecondaryRow)

        editorFormattingBarScroll.child = editorFormattingBar
        editorFormattingBarScroll.setPolicy(horizontal: .automatic, vertical: .never)
        editorFormattingBarScroll.hexpand = true
        editorFormattingBarScroll.minContentWidth = 0

        editorInlineFormattingGroup.addCSSClass("linked")
        editorBlockFormattingGroup.addCSSClass("linked")

        let inlineActions: [MarkdownFormattingAction] = [.heading, .bold, .italic, .code, .link]
        let blockActions: [MarkdownFormattingAction] = [.quote, .bulletList, .numberedList, .taskList]

        for action in inlineActions {
            let button = makeEditorFormattingButton(for: action)
            editorInlineFormattingGroup.append(button)
            editorFormattingButtons[action] = button
        }

        for action in blockActions {
            let button = makeEditorFormattingButton(for: action)
            editorBlockFormattingGroup.append(button)
            editorFormattingButtons[action] = button
        }

        layoutEditorFormattingRows(useTwoRows: false)
    }

    func applyEditorFormatting(_ action: MarkdownFormattingAction) {
        editor.applyFormatting(action)
    }

    func updateEditorFormattingToolbarLayout(forWidth width: Int) {
        guard width > 0 else { return }

        let shouldUseCompactMode = width <= MainWindow.editorFormattingCompactWidthThreshold
        if isEditorFormattingToolbarCompact != shouldUseCompactMode {
            isEditorFormattingToolbarCompact = shouldUseCompactMode
            refreshEditorFormattingToolbarButtons()
        }

        let shouldUseTwoRows: Bool
        if shouldUseCompactMode {
            layoutEditorFormattingRows(useTwoRows: false)
            shouldUseTwoRows = measuredNaturalWidth(of: editorFormattingBar) > width
        } else {
            shouldUseTwoRows = false
        }

        if isEditorFormattingToolbarUsingTwoRows != shouldUseTwoRows {
            isEditorFormattingToolbarUsingTwoRows = shouldUseTwoRows
        }
        layoutEditorFormattingRows(useTwoRows: shouldUseTwoRows)
        editorFormattingBarScroll.horizontalAdjustment.value = 0
    }

    func refreshEditorFormattingToolbarLayout() {
        updateEditorFormattingToolbarLayout(forWidth: resolvedEditorFormattingToolbarWidth())
    }

    private func makeEditorFormattingButton(for action: MarkdownFormattingAction) -> Button {
        let button = Button()
        button.tooltipText = action.tooltip
        button.setAccessibleLabel(action.accessibilityLabel)
        let configuration = ToolbarButtonContentConfiguration(
            primaryText: action.shortLabel ?? action.accessibilityLabel,
            iconName: action.iconName,
            prefersCompactLabel: action.iconName != nil && action.shortLabel == nil,
            hidesLabelWhenCompact: action.iconName != nil
        )
        editorFormattingButtonConfigurations[action] = configuration
        button.child = makeToolbarButtonContent(
            configuration: configuration,
            isCompact: isEditorFormattingToolbarCompact
        )
        return button
    }

    private func setToggleContent(_ toggle: ToggleButton, label: String, iconName: String) {
        toggle.child = makeToolbarButtonContent(
            configuration: ToolbarButtonContentConfiguration(
                primaryText: label,
                iconName: iconName,
                prefersCompactLabel: false,
                hidesLabelWhenCompact: false
            ),
            isCompact: false
        )
    }

    private func resolvedEditorFormattingToolbarWidth() -> Int {
        if viewMode == .split {
            let totalWidth = currentPreviewContainerWidth
            let previewWidth = MainWindow.resolvedPreviewWidth(
                storedWidth: preferredPreviewWidth,
                availableWidth: totalWidth
            )
            return max(totalWidth - previewWidth, MainWindow.minimumEditorWidth)
        }

        let allocatedWidth = max(
            editorFormattingBarScroll.width,
            editorContent.width,
            editorPreviewPane.width,
            contentHost.width
        )
        if allocatedWidth > 0 {
            return allocatedWidth
        }
        return currentPreviewContainerWidth
    }

    private func layoutEditorFormattingRows(useTwoRows: Bool) {
        detachEditorFormattingWidgetIfNeeded(editorInlineFormattingGroup)
        detachEditorFormattingWidgetIfNeeded(editorFormattingGroupSeparator)
        detachEditorFormattingWidgetIfNeeded(editorBlockFormattingGroup)

        editorFormattingPrimaryRow.append(editorInlineFormattingGroup)
        if useTwoRows {
            editorFormattingSecondaryRow.append(editorBlockFormattingGroup)
            editorFormattingSecondaryRow.visible = true
        } else {
            editorFormattingPrimaryRow.append(editorFormattingGroupSeparator)
            editorFormattingPrimaryRow.append(editorBlockFormattingGroup)
            editorFormattingSecondaryRow.visible = false
        }
    }

    private func refreshEditorFormattingToolbarButtons() {
        for (action, button) in editorFormattingButtons {
            guard let configuration = editorFormattingButtonConfigurations[action] else { continue }
            button.child = makeToolbarButtonContent(
                configuration: configuration,
                isCompact: isEditorFormattingToolbarCompact
            )
        }
    }

    private func detachEditorFormattingWidgetIfNeeded(_ widget: Widget) {
        if widget.parent?.opaquePointer == editorFormattingPrimaryRow.opaquePointer {
            editorFormattingPrimaryRow.remove(widget)
        } else if widget.parent?.opaquePointer == editorFormattingSecondaryRow.opaquePointer {
            editorFormattingSecondaryRow.remove(widget)
        }
    }

    private func measuredNaturalWidth(of widget: Widget) -> Int {
        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(
            widget.widgetPointer,
            GTK_ORIENTATION_HORIZONTAL,
            -1,
            &minimum,
            &natural,
            nil,
            nil
        )
        return Int(natural)
    }

    private func makeToolbarButtonContent(
        configuration: ToolbarButtonContentConfiguration,
        isCompact: Bool
    ) -> Widget {
        let labelText = configuration.displayedText(isCompact: isCompact)
        let showsLabel = labelText != nil
        let box = Box(orientation: .horizontal, spacing: showsLabel && configuration.iconName != nil ? 6 : 0)
        let horizontalMargin = showsLabel ? (configuration.prefersCompactLabel ? 2 : 4) : 6
        box.marginStart = horizontalMargin
        box.marginEnd = horizontalMargin

        if let iconName = configuration.iconName {
            let image = Image(iconName: iconName)
            image.pixelSize = 16
            box.append(image)
        }

        if let labelText {
            let label = Label(labelText)
            label.xalign = 0
            if configuration.prefersCompactLabel {
                label.addCSSClass(.caption)
            }
            box.append(label)
        }
        return box
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
            successMessage: announceSuccess ? "File saved" : nil
        )
    }

    @discardableResult
    func saveDocument(to targetURL: URL, successMessage: String?) -> Bool {
        do {
            let savedDocument = try ExternalMarkdownDocumentStore.save(
                content: editor.buffer.text,
                to: targetURL
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
            FileFilter(name: "All files", patterns: ["*"])
        ])
        activeFileDialog = dialog
        Task { @MainActor [weak self] in
            guard let self else { return }
            let path: String?
            do {
                path = try await dialog.saveThrowing(parent: self.window.root ?? self.window)
            } catch {
                self.activeFileDialog = nil
                self.presentError(
                    heading: "Could not open save dialog",
                    body: (error as? GLibError)?.message ?? error.localizedDescription
                )
                return
            }
            self.activeFileDialog = nil
            guard let path else { return }
            let savedURL = URL(fileURLWithPath: path)
            if self.saveDocument(
                to: savedURL,
                successMessage: "Saved as \(savedURL.lastPathComponent)"
            ) {
                self.autosave.cancel()
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
                body: error.localizedDescription
            )
        }
    }

    func revealDocumentInFolder() {
        do {
            try directoryOpener(fileURL.deletingLastPathComponent())
        } catch {
            presentError(
                heading: "Could not open containing folder",
                body: error.localizedDescription
            )
        }
    }

    func reloadFromDisk(announce: Bool, forceDiscardingUnsavedChanges: Bool = false) {
        if editor.buffer.modified && !forceDiscardingUnsavedChanges {
            if !externalReloadDeferred {
                externalReloadDeferred = true
                toastOverlay.showToast(
                    "File changed on disk. Save or reload to sync.",
                    button: "Reload"
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
                        button: "Reload"
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
        if let previewRefreshID {
            MainContext.cancel(sourceId: previewRefreshID)
            self.previewRefreshID = nil
        }
        if let previewRefreshRetryID {
            MainContext.cancel(sourceId: previewRefreshRetryID)
            self.previewRefreshRetryID = nil
        }
        let blocks = pendingPreviewBlocks ?? renderer.blocks(for: editor.buffer.text)
        let baseDirectory = pendingPreviewBaseDirectory ?? fileURL.deletingLastPathComponent()
        pendingPreviewBlocks = nil
        pendingPreviewBaseDirectory = nil
        preview.render(blocks: blocks, baseDirectory: baseDirectory)
        return preview.plainText
    }

    func debugSetEditorText(_ text: String) {
        editor.buffer.text = text
    }

    func debugPollForExternalChanges() {
        pollForExternalChanges()
    }
}
#endif
