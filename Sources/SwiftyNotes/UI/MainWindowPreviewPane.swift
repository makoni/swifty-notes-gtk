import Adwaita
import Foundation

@MainActor
extension MainWindow {
    func refreshPreview() {
        guard let selected = state.selectedNote else {
            schedulePreviewRefresh(blocks: [], baseDirectory: repository.notesDirectoryURL)
            return
        }
        let blocks = renderer.blocks(for: selected.content)
        schedulePreviewRefresh(blocks: blocks, baseDirectory: repository.noteContentBaseDirectoryURL(for: selected))
    }

    func scheduleDebugLaunchEditIfRequested() {
        guard !hasScheduledDebugLaunchEdit else { return }
        let suffix = ProcessInfo.processInfo.environment["SWIFTY_NOTES_DEBUG_APPEND_TEXT_ON_LAUNCH"]?
            .trimmingCharacters(in: .newlines)
        guard let suffix, !suffix.isEmpty else { return }

        hasScheduledDebugLaunchEdit = true
        let delayMilliseconds = ProcessInfo.processInfo.environment["SWIFTY_NOTES_DEBUG_EDIT_DELAY_MS"]
            .flatMap(Int.init) ?? 800
        MainContext.delay(ms: UInt32(max(delayMilliseconds, 0))) { [weak self] in
            guard let self, self.state.selectedNote != nil else { return }
            FileHandle.standardError.write(Data("SwiftyNotes debug launch edit: \(suffix)\n".utf8))
            self.editor.buffer.text += "\n\n\(suffix)"
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
        MainContext.delay(ms: UInt32(max(delayMilliseconds, 0))) { [weak self] in
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
        MainContext.delay(ms: UInt32(max(delayMilliseconds, 0))) { [weak self] in
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
        MainContext.delay(ms: UInt32(max(delayMilliseconds, 0))) { [weak self] in
            guard let self else { return }
            FileHandle.standardError.write(Data("SwiftyNotes debug launch select note: \(index)\n".utf8))
            self.requestSelectNote(at: index)
        }
    }

    func schedulePreviewRefresh(blocks: [RenderedBlock], baseDirectory: URL) {
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
                previewRefreshRetryID = MainContext.timeout(intervalMs: 16) { [weak self] in
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
        let baseDirectory = pendingPreviewBaseDirectory ?? repository.notesDirectoryURL
        pendingPreviewBlocks = nil
        pendingPreviewBaseDirectory = nil
        preview.render(blocks: blocks, baseDirectory: baseDirectory)
        MainContext.idle { [weak self] in
            self?.syncPreviewScroll()
        }
    }

    func shouldDeferPreviewRender() -> Bool {
        Self.shouldDeferPreviewRender(
            isPreviewAttached: isPreviewPaneAttached,
            isPreviewVisible: state.isPreviewVisible,
            windowWidth: window.width,
            windowHeight: window.height,
            hasParent: preview.rootScroll.parent != nil,
            hasRoot: preview.rootScroll.root != nil,
            width: preview.rootScroll.width,
            height: preview.rootScroll.height
        )
    }

    nonisolated static func shouldDeferPreviewRender(
        isPreviewAttached: Bool,
        isPreviewVisible: Bool,
        windowWidth: Int,
        windowHeight: Int,
        hasParent: Bool,
        hasRoot: Bool,
        width: Int,
        height: Int
    ) -> Bool {
        guard isPreviewAttached, isPreviewVisible, hasParent else { return false }
        guard windowWidth > 0, windowHeight > 0 else { return false }
        guard hasRoot else { return false }
        return width <= 0 || height <= 0
    }

    func syncPreviewScroll() {
        guard state.isPreviewVisible, isPreviewPaneAttached else { return }
        guard preview.rootScroll.parent != nil, preview.rootScroll.width > 0, preview.rootScroll.height > 0 else { return }
        let source = editorScroll.verticalAdjustment
        let destination = preview.rootScroll.verticalAdjustment
        let sourceMax = max(source.upper - source.pageSize - source.lower, 0)
        let destinationMax = max(destination.upper - destination.pageSize - destination.lower, 0)
        let progress = sourceMax > 0 ? (source.value - source.lower) / sourceMax : 0
        destination.value = destination.lower + (destinationMax * progress)
    }

    func configureActionsAndMenu() {
        window.addAction(renameAction)
        window.addAction(duplicateAction)
        window.addAction(deleteAction)
        window.addAction(copyNoteIDAction)
        window.addAction(exportAction)
        window.addAction(importAction)
        window.addAction(openNotesFolderAction)
        window.addAction(reloadAction)
        window.addAction(settingsAction)
        window.addAction(aboutAction)

        let librarySection = GMenuRef()
        librarySection.append("Settings", action: "win.settings")
        librarySection.append("Import markdown…", action: "win.import-note")
        librarySection.append("Reload from disk", action: "win.reload-notes")
        librarySection.append("Open notes folder", action: "win.open-notes-folder")

        let helpSection = GMenuRef()
        helpSection.append("About Swifty Notes", action: "win.about")

        let menu = GMenuRef()
        menu.appendSection("Library", section: librarySection)
        menu.appendSection("Help", section: helpSection)
        overflowMenuSectionTitles = ["Library", "Help"]
        overflowMenuItemsBySection = [
            "Library": [
                "Settings",
                "Import markdown…",
                "Reload from disk",
                "Open notes folder"
            ],
            "Help": [
                "About Swifty Notes"
            ]
        ]
        menuButton.setMenuModel(menu)
        updateActionAvailability()
    }

    func configureToolbarAccessibility() {
        sidebarToggle.setAccessibleLabel(state.isSidebarVisible ? "Hide Notes Sidebar" : "Show Notes Sidebar")
        newNoteButton.setAccessibleLabel("New Note")
        saveNoteButton.setAccessibleLabel("Save Note")
        deleteNoteButton.setAccessibleLabel("Delete Note")
        menuButton.setAccessibleLabel("Main Menu")
        updatePreviewToggleAccessibility()
    }

    func configureToolbarTooltips() {
        sidebarToggle.tooltipText = state.isSidebarVisible ? "Hide Notes Sidebar" : "Show Notes Sidebar"
        newNoteButton.tooltipText = "New Note"
        saveNoteButton.tooltipText = "Save Note"
        deleteNoteButton.tooltipText = "Delete Note"
        menuButton.tooltipText = "Main Menu"
        updatePreviewToggleTooltip()
    }

    func updatePreviewToggleAccessibility() {
        previewToggle.setAccessibleLabel(state.isPreviewVisible ? "Hide Preview" : "Show Preview")
    }

    func updatePreviewToggleTooltip() {
        previewToggle.tooltipText = state.isPreviewVisible ? "Hide Preview" : "Show Preview"
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
    }

    func togglePreviewVisibility() {
        state.isPreviewVisible.toggle()
        applyPreviewVisibility(animated: true)
        persistWorkspaceState()
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
    }

    func applyPreviewVisibility(animated: Bool) {
        stopPreviewAnimation()
        if state.isPreviewVisible {
            showPreviewPane(animated: animated)
        } else {
            hidePreviewPane(animated: animated)
        }
        updatePreviewToggleAccessibility()
        updatePreviewToggleTooltip()
    }

    func showPreviewPane(animated: Bool) {
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
        guard isPreviewPaneAttached else { return }
        guard animated, canAnimatePreviewPane else {
            detachPreviewPane()
            return
        }
        animatePreviewPane(to: currentPreviewContainerWidth)
    }

    func restorePreviewPaneLayout() {
        guard state.isPreviewVisible else { return }
        let totalWidth = currentPreviewContainerWidth
        isRestoringPreviewPaneLayout = true
        editorPreviewPane.position = resolvedVisiblePreviewPosition(totalWidth: totalWidth)
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

    func schedulePreviewDetachIfHidden() {
        MainContext.delay(ms: 1) { [weak self] in
            guard let self, !self.state.isPreviewVisible else { return }
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
            window.width > 0 ? window.width - currentSidebarWidth : 0,
            window.defaultWidth - 280,
            state.preferredWindowWidth - 280
        )
    }

    var canAnimatePreviewPane: Bool {
        editorPreviewPane.parent != nil && editorPreviewPane.width > 0 && editorPreviewPane.height > 0
    }

    func resolvedVisiblePreviewPosition(totalWidth: Int) -> Int {
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

    func handlePreviewPaneMoved() {
        guard state.isPreviewVisible, isPreviewPaneAttached, !isRestoringPreviewPaneLayout else { return }
        let totalWidth = max(editorPreviewPane.width, window.width - currentSidebarWidth, window.defaultWidth - 280)
        guard totalWidth >= Self.minimumPreviewWidth + Self.minimumEditorWidth else { return }
        let previewWidth = totalWidth - editorPreviewPane.position
        guard previewWidth >= Self.minimumPreviewWidth else { return }
        state.setPreferredPreviewWidth(previewWidth)
    }

    var currentSidebarWidth: Int {
        splitView.showSidebar ? sidebar.root.width : 0
    }
}
