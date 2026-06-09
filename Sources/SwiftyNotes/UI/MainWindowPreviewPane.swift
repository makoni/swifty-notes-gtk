import Adwaita
import Foundation

@MainActor
extension MainWindow {
    func refreshPreview() {
        guard let selected = state.selectedNote else {
            schedulePreviewRefresh(blocks: [], baseDirectory: repository.notesDirectoryURL)
            refreshOutline(markdown: "", blocks: [])
            return
        }
        let blocks = buildPreviewBlocks(for: selected.content)
        schedulePreviewRefresh(blocks: blocks, baseDirectory: repository.noteContentBaseDirectoryURL(for: selected))
        refreshOutline(markdown: selected.content, blocks: blocks)
    }

    func scheduleTypingPreviewRefresh() {
        guard let selected = state.selectedNote else {
            schedulePreviewRefresh(blocks: [], baseDirectory: repository.notesDirectoryURL)
            return
        }
        let content = selected.content
        let baseDirectory = repository.noteContentBaseDirectoryURL(for: selected)
        previewRefreshScheduler.scheduleDeferred(baseDirectory: baseDirectory) { [weak self] in
            self?.buildPreviewBlocks(for: content) ?? []
        }
    }

    private func buildPreviewBlocks(for markdown: String) -> [RenderedBlock] {
#if DEBUG
        previewBlockBuildCount += 1
#endif
        return previewBlockBuilder.blocks(
            for: markdown,
            darkAppearance: StyleManager.default.dark,
            renderEmojiShortcodes: appSettings.renderEmojiShortcodes,
        )
    }

    func scheduleDebugLaunchEditIfRequested() {
        guard !hasScheduledDebugLaunchEdit else { return }
        let suffix = ProcessInfo.processInfo.environment["SWIFTY_NOTES_DEBUG_APPEND_TEXT_ON_LAUNCH"]?
            .trimmingCharacters(in: .newlines)
        guard let suffix, !suffix.isEmpty else { return }

        hasScheduledDebugLaunchEdit = true
        let delayMilliseconds = ProcessInfo.processInfo.environment["SWIFTY_NOTES_DEBUG_EDIT_DELAY_MS"]
            .flatMap(Int.init) ?? 800
        scheduleDebugLaunchEdit(suffix: suffix, after: max(delayMilliseconds, 0), remainingAttempts: 25)
    }

    private func scheduleDebugLaunchEdit(suffix: String, after delayMilliseconds: Int, remainingAttempts: Int) {
        MainContext.delay(for: .milliseconds(delayMilliseconds)) { [weak self] in
            guard let self else { return }
            guard state.selectedNote != nil else {
                guard remainingAttempts > 0 else { return }
                scheduleDebugLaunchEdit(
                    suffix: suffix,
                    after: 200,
                    remainingAttempts: remainingAttempts - 1,
                )
                return
            }
            FileHandle.standardError.write(Data("SwiftyNotes debug launch edit: \(suffix)\n".utf8))
            editor.buffer.text += "\n\n\(suffix)"
        }
    }

    func scheduleDebugTypingBurstIfRequested() {
        guard !hasScheduledDebugTypingBurst else { return }
        let text = ProcessInfo.processInfo.environment["SWIFTY_NOTES_DEBUG_TYPE_TEXT_ON_LAUNCH"]?
            .trimmingCharacters(in: .newlines)
        guard let text, !text.isEmpty else { return }

        hasScheduledDebugTypingBurst = true
        let delayMilliseconds = debugEnvironmentInt(named: "SWIFTY_NOTES_DEBUG_TYPE_DELAY_MS") ?? 800
        let intervalMilliseconds = max(debugEnvironmentInt(named: "SWIFTY_NOTES_DEBUG_TYPE_INTERVAL_MS") ?? 16, 1)
        scheduleDebugTypingBurst(
            characters: Array(text),
            after: max(delayMilliseconds, 0),
            intervalMilliseconds: intervalMilliseconds,
            remainingAttempts: 25,
        )
    }

    private func scheduleDebugTypingBurst(
        characters: [Character],
        after delayMilliseconds: Int,
        intervalMilliseconds: Int,
        remainingAttempts: Int,
    ) {
        MainContext.delay(for: .milliseconds(delayMilliseconds)) { [weak self] in
            guard let self else { return }
            guard state.selectedNote != nil else {
                guard remainingAttempts > 0 else { return }
                scheduleDebugTypingBurst(
                    characters: characters,
                    after: 200,
                    intervalMilliseconds: intervalMilliseconds,
                    remainingAttempts: remainingAttempts - 1,
                )
                return
            }
            editor.buffer.placeCursor(at: editor.buffer.text.count)
            FileHandle.standardError.write(
                Data(
                    "SwiftyNotes debug typing burst starting: characters=\(characters.count) intervalMs=\(intervalMilliseconds)\n".utf8,
                ),
            )
            runDebugTypingBurst(
                characters: characters,
                index: 0,
                intervalMilliseconds: intervalMilliseconds,
            )
        }
    }

    private func runDebugTypingBurst(
        characters: [Character],
        index: Int,
        intervalMilliseconds: Int,
    ) {
        guard index < characters.count else {
            FileHandle.standardError.write(
                Data("SwiftyNotes debug typing burst completed: characters=\(characters.count)\n".utf8),
            )
            quitAfterDebugTypingIfRequested()
            return
        }

        editor.buffer.insertAtCursor(String(characters[index]))
        MainContext.delay(for: .milliseconds(intervalMilliseconds)) { [weak self] in
            self?.runDebugTypingBurst(
                characters: characters,
                index: index + 1,
                intervalMilliseconds: intervalMilliseconds,
            )
        }
    }

    // This autopilot drives the preview-highlight path via
    // `FindReplaceBar.debugTypeQuery`, which is itself `#if DEBUG`-only —
    // so the whole hook (and its call site in MainWindow) must be gated
    // too, or the release build fails to compile.
    #if DEBUG
    /// Debug autopilot: switch to preview-only, open the find bar, and
    /// type a query, so a screenshot can confirm the preview highlight
    /// overlay actually paints. Set
    /// SWIFTY_NOTES_DEBUG_PREVIEW_SEARCH_ON_LAUNCH=<query>.
    func scheduleDebugPreviewSearchIfRequested() {
        guard !hasScheduledDebugPreviewSearch else { return }
        let query = ProcessInfo.processInfo.environment["SWIFTY_NOTES_DEBUG_PREVIEW_SEARCH_ON_LAUNCH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let query, !query.isEmpty else { return }

        hasScheduledDebugPreviewSearch = true
        let delayMilliseconds = debugEnvironmentInt(named: "SWIFTY_NOTES_DEBUG_PREVIEW_SEARCH_DELAY_MS") ?? 1200
        scheduleDebugPreviewSearch(query: query, after: max(delayMilliseconds, 0), remainingAttempts: 40)
    }

    private func scheduleDebugPreviewSearch(query: String, after delayMilliseconds: Int, remainingAttempts: Int) {
        MainContext.delay(for: .milliseconds(delayMilliseconds)) { [weak self] in
            guard let self else { return }
            guard state.selectedNote != nil else {
                guard remainingAttempts > 0 else { return }
                scheduleDebugPreviewSearch(query: query, after: 200, remainingAttempts: remainingAttempts - 1)
                return
            }
            FileHandle.standardError.write(Data("SwiftyNotes debug preview search: \(query)\n".utf8))
            setViewMode(.preview, animated: false)
            openFindBar(mode: .find)
            previewFindReplaceBar.debugTypeQuery(query)
            // Optional follow-up queries (comma-separated in *_THEN) typed in
            // sequence to exercise the highlight-replacement path across
            // multiple query switches.
            let followUps = (ProcessInfo.processInfo.environment["SWIFTY_NOTES_DEBUG_PREVIEW_SEARCH_THEN"] ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            typeDebugFollowUpQueries(followUps)
        }
    }

    private func typeDebugFollowUpQueries(_ queries: [String]) {
        guard let next = queries.first else { return }
        let rest = Array(queries.dropFirst())
        MainContext.delay(for: .milliseconds(400)) { [weak self] in
            guard let self else { return }
            previewFindReplaceBar.debugTypeQuery(next)
            FileHandle.standardError.write(Data("SwiftyNotes debug preview search follow-up: \(next)\n".utf8))
            typeDebugFollowUpQueries(rest)
        }
    }
    #endif

    func scheduleDebugHeaderSubtitleLogIfRequested() {
        let delayMilliseconds = ProcessInfo.processInfo.environment["SWIFTY_NOTES_DEBUG_LOG_HEADER_SUBTITLE_DELAY_MS"]
            .flatMap(Int.init)
        guard let delayMilliseconds else { return }

        MainContext.delay(for: .milliseconds(max(delayMilliseconds, 0))) { [weak self] in
            guard let self else { return }
            FileHandle.standardError.write(
                Data("SwiftyNotes debug header subtitle: \(headerTitle.subtitle)\n".utf8),
            )
        }
    }

    func scheduleDebugSettingsOpenIfRequested() {
        guard !hasScheduledDebugSettingsOpen else { return }
        let shouldOpen = ProcessInfo.processInfo.environment["SWIFTY_NOTES_DEBUG_OPEN_SETTINGS_ON_LAUNCH"]
            .map { ["1", "true", "yes"].contains($0.lowercased()) } ?? false
        guard shouldOpen else { return }

        hasScheduledDebugSettingsOpen = true
        let delayMilliseconds = ProcessInfo.processInfo.environment["SWIFTY_NOTES_DEBUG_OPEN_SETTINGS_DELAY_MS"]
            .flatMap(Int.init) ?? 500
        MainContext.delay(for: .milliseconds(max(delayMilliseconds, 0))) { [weak self] in
            self?.presentSettingsWindow()
        }
    }

    func scheduleDebugCreateNoteIfRequested() {
        guard !hasScheduledDebugCreateNote else { return }
        let shouldCreate = ProcessInfo.processInfo.environment["SWIFTY_NOTES_DEBUG_CREATE_NOTE_ON_LAUNCH"]
            .map { ["1", "true", "yes"].contains($0.lowercased()) } ?? false
        guard shouldCreate else { return }

        hasScheduledDebugCreateNote = true
        let delayMilliseconds = ProcessInfo.processInfo.environment["SWIFTY_NOTES_DEBUG_CREATE_NOTE_DELAY_MS"]
            .flatMap(Int.init) ?? 500
        MainContext.delay(for: .milliseconds(max(delayMilliseconds, 0))) { [weak self] in
            self?.requestCreateNote()
        }
    }

    func scheduleDebugSelectionSwitchIfRequested() {
        guard let targetIndex = ProcessInfo.processInfo.environment["SWIFTY_NOTES_DEBUG_SELECT_NOTE_INDEX_ON_LAUNCH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let index = Int(targetIndex)
        else {
            return
        }

        let delayMilliseconds = ProcessInfo.processInfo.environment["SWIFTY_NOTES_DEBUG_SELECT_NOTE_DELAY_MS"]
            .flatMap(Int.init) ?? 500
        MainContext.delay(for: .milliseconds(max(delayMilliseconds, 0))) { [weak self] in
            guard let self else { return }
            FileHandle.standardError.write(Data("SwiftyNotes debug launch select note: \(index)\n".utf8))
            requestSelectNote(at: index)
        }
    }

    func scheduleDebugScrollSweepIfRequested() {
        guard !hasScheduledDebugScrollSweep, debugEnvironmentFlag(named: "SWIFTY_NOTES_DEBUG_SCROLL_SWEEP_ON_LAUNCH") else { return }

        hasScheduledDebugScrollSweep = true
        let delayMilliseconds = debugEnvironmentInt(named: "SWIFTY_NOTES_DEBUG_SCROLL_DELAY_MS") ?? 900
        scheduleDebugScrollSweep(after: max(delayMilliseconds, 0), remainingAttempts: 40)
    }

    private func scheduleDebugScrollSweep(after delayMilliseconds: Int, remainingAttempts: Int) {
        MainContext.delay(for: .milliseconds(delayMilliseconds)) { [weak self] in
            guard let self else { return }

            setViewMode(.split, animated: false)
            refreshPreview()
            flushPendingPreviewRefresh()

            let adjustment = editorScroll.verticalAdjustment
            let maxScroll = max(adjustment.upper - adjustment.pageSize - adjustment.lower, 0)
            guard state.selectedNote != nil, isPreviewPaneAttached, maxScroll > 0 else {
                guard remainingAttempts > 0 else {
                    FileHandle.standardError.write(Data("SwiftyNotes debug scroll sweep failed to start\n".utf8))
                    quitAfterDebugScrollSweepIfRequested()
                    return
                }
                scheduleDebugScrollSweep(after: 200, remainingAttempts: remainingAttempts - 1)
                return
            }

            let durationMilliseconds = max(debugEnvironmentInt(named: "SWIFTY_NOTES_DEBUG_SCROLL_DURATION_MS") ?? 10_000, 100)
            let stepMilliseconds = max(debugEnvironmentInt(named: "SWIFTY_NOTES_DEBUG_SCROLL_STEP_MS") ?? 50, 1)
            let oneWayStepCount = max(durationMilliseconds / stepMilliseconds, 1)
            let totalStepCount = max(oneWayStepCount * 2, 2)

            FileHandle.standardError.write(
                Data(
                    "SwiftyNotes debug scroll sweep starting: maxScroll=\(Int(maxScroll.rounded())) durationMs=\(durationMilliseconds) stepMs=\(stepMilliseconds)\n".utf8,
                ),
            )
            runDebugScrollSweep(
                adjustment: adjustment,
                maxScroll: maxScroll,
                stepIndex: 0,
                totalStepCount: totalStepCount,
                stepMilliseconds: stepMilliseconds,
            )
        }
    }

    private func runDebugScrollSweep(
        adjustment: Adjustment,
        maxScroll: Double,
        stepIndex: Int,
        totalStepCount: Int,
        stepMilliseconds: Int,
    ) {
        let denominator = Double(max(totalStepCount - 1, 1))
        let progress = Double(stepIndex) / denominator
        let triangleProgress = progress <= 0.5 ? progress * 2 : (1 - progress) * 2
        adjustment.value = adjustment.lower + (maxScroll * triangleProgress)
        syncPreviewScroll()

        guard stepIndex + 1 < totalStepCount else {
            FileHandle.standardError.write(
                Data(
                    "SwiftyNotes debug scroll sweep completed: steps=\(totalStepCount) maxScroll=\(Int(maxScroll.rounded()))\n".utf8,
                ),
            )
            quitAfterDebugScrollSweepIfRequested()
            return
        }

        MainContext.delay(for: .milliseconds(stepMilliseconds)) { [weak self] in
            self?.runDebugScrollSweep(
                adjustment: adjustment,
                maxScroll: maxScroll,
                stepIndex: stepIndex + 1,
                totalStepCount: totalStepCount,
                stepMilliseconds: stepMilliseconds,
            )
        }
    }

    private func quitAfterDebugScrollSweepIfRequested() {
        guard debugEnvironmentFlag(named: "SWIFTY_NOTES_DEBUG_QUIT_AFTER_SCROLL") else { return }
        MainContext.idle {
            Application.current?.quit()
        }
    }

    private func quitAfterDebugTypingIfRequested() {
        guard debugEnvironmentFlag(named: "SWIFTY_NOTES_DEBUG_QUIT_AFTER_TYPING") else { return }
        MainContext.idle {
            Application.current?.quit()
        }
    }

    private func debugEnvironmentFlag(named name: String) -> Bool {
        ProcessInfo.processInfo.environment[name]
            .map { ["1", "true", "yes"].contains($0.lowercased()) } ?? false
    }

    private func debugEnvironmentInt(named name: String) -> Int? {
        ProcessInfo.processInfo.environment[name].flatMap(Int.init)
    }

    func schedulePreviewRefresh(blocks: [RenderedBlock], baseDirectory: URL) {
        previewRefreshScheduler.schedule(blocks: blocks, baseDirectory: baseDirectory)
    }

    func flushPendingPreviewRefresh() {
        previewRefreshScheduler.flush()
    }

    func shouldDeferPreviewRender() -> Bool {
        Self.shouldDeferPreviewRender(
            isPreviewPresented: state.isPreviewVisible,
            windowWidth: window.width,
            windowHeight: window.height,
            hasParent: preview.rootScroll.parent != nil,
            hasRoot: preview.rootScroll.root != nil,
            width: preview.rootScroll.width,
            height: preview.rootScroll.height,
        )
    }

    nonisolated static func shouldDeferPreviewRender(
        isPreviewPresented: Bool,
        windowWidth: Int,
        windowHeight: Int,
        hasParent: Bool,
        hasRoot: Bool,
        width: Int,
        height: Int,
    ) -> Bool {
        guard isPreviewPresented, hasParent else { return false }
        guard windowWidth > 0, windowHeight > 0 else { return false }
        guard hasRoot else { return false }
        return width <= 0 || height <= 0
    }

    func syncPreviewScroll() {
        guard state.viewMode == .split, isPreviewPaneAttached else { return }
        PreviewScrollSync.sync(editor: editorScroll, preview: preview.rootScroll)
    }

    func configureActionsAndMenu() {
        window.addAction(renameAction)
        window.addAction(duplicateAction)
        window.addAction(deleteAction)
        window.addAction(copyNoteIDAction)
        window.addAction(exportAction)
        window.addAction(openMarkdownFileAction)
        window.addAction(importAction)
        window.addAction(openNotesFolderAction)
        window.addAction(reloadAction)
        window.addAction(settingsAction)
        window.addAction(aboutAction)
        window.addAction(checkForUpdatesAction)

        let libraryItems: [(label: String, action: String)] = [
            ("Settings", "win.settings"),
            ("Open Markdown File…", "win.open-markdown-file"),
            ("Import into Library…", "win.import-note"),
            ("Reload from disk", "win.reload-notes"),
            ("Open notes folder", "win.open-notes-folder"),
        ]
        let helpItems: [(label: String, action: String)] = [
            ("Check for Updates…", "win.check-for-updates"),
            ("About Swifty Notes", "win.about"),
        ]

        #if os(macOS)
        // Hand-built popover (not GMenu/setMenuModel) so the items
        // themselves are explicit `Button`s routed through
        // `MacOSClickWorkaround.onClick`. The auto-built PopoverMenu
        // that `setMenuModel` produces is composed of widgets we don't
        // have references to, so its items suffer the same Quartz
        // drag-detection regression — sub-pixel motion between press
        // and release silently eats the click. Linux doesn't have this
        // bug and keeps the native GMenu look-and-feel below.
        let library: [(label: String, handler: @MainActor () -> Void)] = [
            ("Settings", { [weak self] in self?.presentSettingsWindow() }),
            ("Open Markdown File…", { [weak self] in self?.openMarkdownFile() }),
            ("Import into Library…", { [weak self] in self?.importNote() }),
            ("Reload from disk", { [weak self] in self?.reloadFromDisk(announce: true) }),
            ("Open notes folder", { [weak self] in self?.openNotesFolder() }),
        ]
        let help: [(label: String, handler: @MainActor () -> Void)] = [
            ("Check for Updates…", { [weak self] in self?.checkForUpdates(manual: true) }),
            ("About Swifty Notes", { [weak self] in self?.presentAboutDialog() }),
        ]

        let popover = Popover()
        popover.hasArrow = true
        popover.position = .bottom
        popover.autohide = true
        let content = Box(orientation: .vertical, spacing: 2)
        content.setMargins(4)
        for (label, handler) in library {
            content.append(makeMenuItemButton(label: label, popover: popover, handler: handler))
        }
        content.append(Separator(orientation: .horizontal))
        for (label, handler) in help {
            content.append(makeMenuItemButton(label: label, popover: popover, handler: handler))
        }
        popover.child = content
        menuButton.setPopover(popover)
        #else
        let librarySection = GMenuRef()
        for item in libraryItems {
            librarySection.append(item.label, action: item.action)
        }
        let helpSection = GMenuRef()
        for item in helpItems {
            helpSection.append(item.label, action: item.action)
        }
        let menu = GMenuRef()
        menu.appendSection("Library", section: librarySection)
        menu.appendSection("Help", section: helpSection)
        menuButton.setMenuModel(menu)
        #endif

        overflowMenuSectionTitles = ["Library", "Help"]
        overflowMenuItemsBySection = [
            "Library": libraryItems.map(\.label),
            "Help": helpItems.map(\.label),
        ]
        updateActionAvailability()
    }

    #if os(macOS)
    private func makeMenuItemButton(
        label: String,
        popover: Popover,
        handler: @escaping @MainActor () -> Void,
    ) -> Button {
        let button = Button()
        button.addCSSClass(.flat)
        button.hexpand = true
        button.halign = .fill
        let title = Label(label)
        title.xalign = 0
        title.hexpand = true
        let row = Box(orientation: .horizontal, spacing: 8)
        row.hexpand = true
        row.halign = .fill
        row.append(title)
        button.child = row
        MacOSClickWorkaround.onClick(button) { [weak popover] in
            popover?.popdown()
            handler()
        }
        return button
    }
    #endif

    func configureToolbarAccessibility() {
        sidebarToggle.setAccessibleLabel(state.isSidebarVisible ? "Hide Notes Sidebar" : "Show Notes Sidebar")
        newNoteButton.setAccessibleLabel("New Note")
        newFolderButton.setAccessibleLabel("New Folder")
        saveNoteButton.setAccessibleLabel("Save Note")
        deleteNoteButton.setAccessibleLabel("Delete Note")
        menuButton.setAccessibleLabel("Main Menu")
        editorModeToggle.setAccessibleLabel("Editor")
        splitModeToggle.setAccessibleLabel("Split")
        previewModeToggle.setAccessibleLabel("Preview")
        updateViewModeToggleState()
    }

    func configureToolbarTooltips() {
        sidebarToggle.tooltipText = state.isSidebarVisible ? "Hide Notes Sidebar" : "Show Notes Sidebar"
        newNoteButton.tooltipText = "New Note"
        newFolderButton.tooltipText = "New Folder"
        saveNoteButton.tooltipText = "Save Note"
        deleteNoteButton.tooltipText = "Delete Note"
        menuButton.tooltipText = "Main Menu"
        editorModeToggle.tooltipText = "Editor only"
        splitModeToggle.tooltipText = "Split view"
        previewModeToggle.tooltipText = "Preview only"
        updateViewModeToggleState()
    }

    func updateSidebarToggleAccessibility() {
        sidebarToggle.setAccessibleLabel(state.isSidebarVisible ? "Hide Notes Sidebar" : "Show Notes Sidebar")
    }

    func updateSidebarToggleTooltip() {
        sidebarToggle.tooltipText = state.isSidebarVisible ? "Hide Notes Sidebar" : "Show Notes Sidebar"
    }

    func updateActionAvailability() {
        let hasSelection = state.selectedNote != nil
        renameAction.enabled = hasSelection
        duplicateAction.enabled = hasSelection
        deleteAction.enabled = hasSelection
        copyNoteIDAction.enabled = hasSelection
        exportAction.enabled = hasSelection
        for button in editorFormattingButtons.values {
            button.sensitive = hasSelection
        }
    }

    func updateViewModeToggleState() {
        suppressViewModeToggleChange = true
        editorModeToggle.active = state.viewMode == .editor
        splitModeToggle.active = state.viewMode == .split
        previewModeToggle.active = state.viewMode == .preview
        suppressViewModeToggleChange = false
    }

    func setViewMode(_ mode: EditorViewMode, animated: Bool) {
        guard state.viewMode != mode else {
            updateViewModeToggleState()
            return
        }
        state.viewMode = mode
        applyViewMode(animated: animated)
        if state.isEditorVisible {
            MainContext.idle { [weak self] in
                self?.focusPrimaryContentIfNeeded()
            }
        }
        persistWorkspaceState()
    }

    func toggleEditorAndSplitModes() {
        let nextMode: EditorViewMode = state.viewMode == .editor ? .split : .editor
        setViewMode(nextMode, animated: true)
    }

    func toggleSidebarVisibility() {
        state.isSidebarVisible.toggle()
        applySidebarVisibility()
        persistWorkspaceState()
    }

    func applySidebarVisibility() {
        splitView.showSidebar = state.isSidebarVisible
        updateSidebarToggleAccessibility()
        updateSidebarToggleTooltip()
        refreshEditorFormattingToolbarLayout()
    }

    func applyViewMode(animated: Bool) {
        updateViewModeToggleState()
        stopPreviewAnimation()
        switch state.viewMode {
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
        outlineScrollSpyDriver?.rebind(mode: state.viewMode)
    }

    func showEditorContent() {
        guard splitView.content?.opaquePointer != editorPreviewPane.opaquePointer else { return }
        splitView.content = editorPreviewPane
    }

    func showPreviewOnlyContent() {
        stopPreviewAnimation()
        // Install the SAME wrapper (`previewPaneContent`, which holds the
        // preview-side find bar above `preview.rootScroll`) that split mode
        // attaches to the Paned — NOT `rootScroll` directly. `rootScroll`
        // is always a child of `previewPaneContent`, so setting it as the
        // split content while it's still parented makes
        // `adw_overlay_split_view_set_content` reject the reparent
        // (`gtk_widget_get_parent(content) == NULL` fails) and the editor
        // stays on screen. detachPreviewPane() first frees the wrapper from
        // the Paned so it's unparented when it becomes the split content,
        // and the preview-side find bar stays available in preview-only mode.
        detachPreviewPane()
        guard splitView.content?.opaquePointer != previewPaneContent.opaquePointer else { return }
        splitView.content = previewPaneContent
        refreshPreview()
    }

    func focusPrimaryContentIfNeeded() {
        guard state.isEditorVisible else { return }
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
        guard state.viewMode == .split else { return }
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
            if state.viewMode != .split {
                schedulePreviewDetachIfNeeded()
            }
            return
        }

        isRestoringPreviewPaneLayout = true
        let startedAt = Date()
        let duration = Double(Self.previewAnimationDuration) / 1000
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
            if state.viewMode != .split {
                schedulePreviewDetachIfNeeded()
            }
            return false
        }
    }

    func schedulePreviewDetachIfNeeded() {
        MainContext.delay(for: .milliseconds(1)) { [weak self] in
            guard let self, state.viewMode != .split else { return }
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
            window.width > 0 ? window.width - currentSidebarWidth : 0,
            window.defaultWidth - 280,
            state.preferredWindowWidth - 280,
        )
    }

    var canAnimatePreviewPane: Bool {
        editorPreviewPane.parent != nil && editorPreviewPane.width > 0 && editorPreviewPane.height > 0
    }

    func resolvedVisiblePreviewPosition(totalWidth: Int) -> Int {
        let previewWidth = Self.resolvedPreviewWidth(
            storedWidth: state.preferredPreviewWidth,
            availableWidth: totalWidth,
        )
        if state.preferredPreviewWidth == WorkspaceState.legacyDefaultPreviewWidth,
           previewWidth > state.preferredPreviewWidth
        {
            state.setPreferredPreviewWidth(previewWidth)
        }
        preview.rootScroll.minContentWidth = Self.minimumPreviewWidth
        return max(totalWidth - previewWidth, Self.minimumEditorWidth)
    }

    func handlePreviewPaneMoved() {
        guard state.viewMode == .split, isPreviewPaneAttached, !isRestoringPreviewPaneLayout else { return }
        let totalWidth = max(editorPreviewPane.width, window.width - currentSidebarWidth, window.defaultWidth - 280)
        guard totalWidth >= Self.minimumPreviewWidth + Self.minimumEditorWidth else { return }
        let previewWidth = totalWidth - editorPreviewPane.position
        guard previewWidth >= Self.minimumPreviewWidth else { return }
        state.setPreferredPreviewWidth(previewWidth)
        updateEditorFormattingToolbarLayout(forWidth: editorPreviewPane.position)
    }

    var currentSidebarWidth: Int {
        splitView.showSidebar ? sidebar.root.width : 0
    }
}
