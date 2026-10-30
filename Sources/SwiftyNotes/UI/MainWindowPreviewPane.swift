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

    // This autopilot drives the settings window's language row via
    // `SettingsWindow.debugSetLanguage`, which is itself `#if DEBUG`-only —
    // so the whole hook (and its call site in MainWindow) must be gated too,
    // or the release build fails to compile.
    #if DEBUG
    /// Flips the Settings window's language row after launch, through the row's
    /// real `notify::selected` signal.
    ///
    /// Reaching this path by hand needs a mouse; reaching it headlessly does
    /// not reproduce, because the crash it exposed needs a running main loop.
    /// `SWIFTY_NOTES_DEBUG_SET_LANGUAGE_ON_LAUNCH=ru` alongside
    /// `SWIFTY_NOTES_DEBUG_OPEN_SETTINGS_ON_LAUNCH=1` drives it deterministically.
    ///
    /// `SWIFTY_NOTES_DEBUG_SET_LANGUAGE_THEN=en` adds further switches, applied
    /// in sequence a delay apart. One process can then go left-to-right,
    /// right-to-left and back — which is the interesting direction for layout,
    /// since a window that mirrors on the way out has to un-mirror on the way
    /// home, and only a live switch exercises that.
    func scheduleDebugLanguageSwitchIfRequested() {
        guard !hasScheduledDebugLanguageSwitch,
              let raw = ProcessInfo.processInfo.environment["SWIFTY_NOTES_DEBUG_SET_LANGUAGE_ON_LAUNCH"]?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let language = AppLanguage(rawValue: raw)
        else {
            return
        }

        hasScheduledDebugLanguageSwitch = true
        afterDebugLanguageSwitchGate { [weak self] in
            guard let self else { return }
            selectDebugLanguage(language)
            let followUps = (ProcessInfo.processInfo.environment["SWIFTY_NOTES_DEBUG_SET_LANGUAGE_THEN"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .compactMap(AppLanguage.init(rawValue:))
            selectDebugLanguagesInSequence(followUps)
        }
    }

    private var debugLanguageSwitchDelayMilliseconds: Int {
        let configured = ProcessInfo.processInfo.environment["SWIFTY_NOTES_DEBUG_SET_LANGUAGE_DELAY_MS"]
            .flatMap(Int.init) ?? 1500
        return max(configured, 0)
    }

    /// Both markers are printed because they answer different questions: the
    /// first says the switch was reached at all, the second that the process
    /// came back from assigning GTK's default direction.
    private func selectDebugLanguage(_ language: AppLanguage) {
        guard let settingsWindow = activeSettingsWindow else {
            FileHandle.standardError.write(Data("[debug-language] no settings window open\n".utf8))
            return
        }
        FileHandle.standardError.write(Data("[debug-language] selecting \(language.rawValue)\n".utf8))
        settingsWindow.debugSetLanguage(language)
        FileHandle.standardError.write(Data("[debug-language] survived the switch\n".utf8))
    }

    private func selectDebugLanguagesInSequence(_ languages: [AppLanguage]) {
        guard let next = languages.first else { return }
        let rest = Array(languages.dropFirst())
        afterDebugLanguageSwitchGate { [weak self] in
            guard let self else { return }
            selectDebugLanguage(next)
            selectDebugLanguagesInSequence(rest)
        }
    }

    /// Runs `switchLanguage` after the delay — or, with
    /// `SWIFTY_NOTES_DEBUG_SET_LANGUAGE_GATE=<name>`, once a file of that
    /// name appears in `$XDG_RUNTIME_DIR` (it is removed again): a test that
    /// reads the interface over AT-SPI says when it is done with a
    /// language, however slow the reading is.
    private func afterDebugLanguageSwitchGate(_ switchLanguage: @escaping @MainActor () -> Void) {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment["SWIFTY_NOTES_DEBUG_SET_LANGUAGE_GATE"], !name.isEmpty,
              let runtimeDirectory = environment["XDG_RUNTIME_DIR"]
        else {
            MainContext.delay(for: .milliseconds(debugLanguageSwitchDelayMilliseconds), switchLanguage)
            return
        }
        let gate = URL(fileURLWithPath: runtimeDirectory, isDirectory: true).appendingPathComponent(name)
        _ = MainContext.timeout(every: .milliseconds(100)) {
            guard FileManager.default.fileExists(atPath: gate.path) else { return true }
            try? FileManager.default.removeItem(at: gate)
            switchLanguage()
            return false
        }
    }
    #endif

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

        rebuildOverflowMenu()
    }

    /// (Re)composes the hamburger menu. Called once from
    /// ``configureActionsAndMenu()`` and again whenever the menu's
    /// composition changes at runtime — currently only when the
    /// launch-time update check proves the network is unreachable and
    /// "Check for Updates…" gets dropped (see ``handleUpdateCheckResult``).
    func rebuildOverflowMenu() {
        let libraryItems: [(label: String, action: String)] = [
            ("Settings".localized, "win.settings"),
            ("Open Markdown File…".localized, "win.open-markdown-file"),
            ("Import into Library…".localized, "win.import-note"),
            ("Reload from disk".localized, "win.reload-notes"),
            ("Open notes folder".localized, "win.open-notes-folder"),
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
            ("Settings".localized, { [weak self] in self?.presentSettingsWindow() }),
            ("Open Markdown File…".localized, { [weak self] in self?.openMarkdownFile() }),
            ("Import into Library…".localized, { [weak self] in self?.importNote() }),
            ("Reload from disk".localized, { [weak self] in self?.reloadFromDisk(announce: true) }),
            ("Open notes folder".localized, { [weak self] in self?.openNotesFolder() }),
        ]
        var help: [(label: String, handler: @MainActor () -> Void)] = []
        if !updateCheckMenuItemHidden {
            help.append(("Check for Updates…".localized, { [weak self] in self?.checkForUpdates(manual: true) }))
        }
        help.append(("About Swifty Notes".localized, { [weak self] in self?.presentAboutDialog() }))

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
        // Derive the introspection surface from the SAME list the popover
        // was built from, so a test failure is impossible to fake by
        // filtering only the bookkeeping array.
        let helpLabels = help.map(\.label)
        #else
        var helpItems: [(label: String, action: String)] = []
        if !updateCheckMenuItemHidden {
            helpItems.append(("Check for Updates…".localized, "win.check-for-updates"))
        }
        helpItems.append(("About Swifty Notes".localized, "win.about"))

        let librarySection = GMenuRef()
        for item in libraryItems {
            librarySection.append(item.label, action: item.action)
        }
        let helpSection = GMenuRef()
        for item in helpItems {
            helpSection.append(item.label, action: item.action)
        }
        let menu = GMenuRef()
        menu.appendSection("Library".localized, section: librarySection)
        menu.appendSection("Help".localized, section: helpSection)
        menuButton.setMenuModel(menu)
        let helpLabels = helpItems.map(\.label)
        #endif

        // Displayed titles are translated; the dictionary below stays keyed by
        // the canonical English section name, which is how the tests address it
        // and how it survives a language change. The two are deliberately not
        // the same list — do not index one with the other.
        overflowMenuSectionTitles = ["Library".localized, "Help".localized]
        overflowMenuItemsBySection = [
            "Library": libraryItems.map(\.label),
            "Help": helpLabels,
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
        sidebarToggle.setAccessibleLabel(state.isSidebarVisible ? "Hide Notes Sidebar".localized : "Show Notes Sidebar".localized)
        newNoteButton.setAccessibleLabel("New Note".localized)
        newFolderButton.setAccessibleLabel("New Folder".localized)
        saveNoteButton.setAccessibleLabel("Save Note".localized)
        deleteNoteButton.setAccessibleLabel("Delete Note".localized)
        menuButton.setAccessibleLabel("Main Menu".localized)
        editorModeToggle.setAccessibleLabel(EditorViewMode.editor.displayName)
        splitModeToggle.setAccessibleLabel(EditorViewMode.split.displayName)
        previewModeToggle.setAccessibleLabel(EditorViewMode.preview.displayName)
        updateViewModeToggleState()
    }

    func configureToolbarTooltips() {
        sidebarToggle.tooltipText = state.isSidebarVisible ? "Hide Notes Sidebar".localized : "Show Notes Sidebar".localized
        newNoteButton.tooltipText = "New Note".localized
        newFolderButton.tooltipText = "New Folder".localized
        saveNoteButton.tooltipText = "Save Note".localized
        deleteNoteButton.tooltipText = "Delete Note".localized
        menuButton.tooltipText = "Main Menu".localized
        editorModeToggle.tooltipText = "Editor only".localized
        splitModeToggle.tooltipText = "Split view".localized
        previewModeToggle.tooltipText = "Preview only".localized
        updateViewModeToggleState()
    }

    func updateSidebarToggleAccessibility() {
        sidebarToggle.setAccessibleLabel(state.isSidebarVisible ? "Hide Notes Sidebar".localized : "Show Notes Sidebar".localized)
    }

    func updateSidebarToggleTooltip() {
        sidebarToggle.tooltipText = state.isSidebarVisible ? "Hide Notes Sidebar".localized : "Show Notes Sidebar".localized
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
        previewPaneDivider.show(animated: animated)
    }

    func hidePreviewPane(animated: Bool) {
        showEditorContent()
        previewPaneDivider.hide(animated: animated)
    }

    func restorePreviewPaneLayout() {
        previewPaneDivider.restore()
    }

    func detachPreviewPane() {
        previewPaneDivider.detach()
    }

    func stopPreviewAnimation() {
        previewPaneDivider.stopAnimation()
    }

    var isPreviewPaneAttached: Bool {
        previewPaneDivider.isPreviewAttached
    }

    /// The room the editor and preview share (see
    /// ``PreviewPaneDivider/roomWidth``).
    var currentPreviewContainerWidth: Int {
        previewPaneDivider.roomWidth
    }

    /// That room estimated from the window: the window less the sidebar and
    /// the Outline beside them.
    var estimatedPreviewContainerWidth: Int {
        let outlineWidth = currentOutlineWidth
        return max(
            editorPreviewPane.width,
            window.width > 0 ? window.width - currentSidebarWidth - outlineWidth : 0,
            window.defaultWidth - 280 - outlineWidth,
            state.preferredWindowWidth - 280 - outlineWidth,
        )
    }

    var currentSidebarWidth: Int {
        splitView.showSidebar ? sidebar.root.width : 0
    }

    /// The Outline's width while shown — as allocated, or as the split view
    /// will size it before the first allocation.
    var currentOutlineWidth: Int {
        PaneLayout.outlineWidth(
            isShown: outlineSplitView.showSidebar,
            allocatedWidth: outlineSidebar.root.width,
            windowWidth: window.width > 0 ? window.width : max(window.defaultWidth, state.preferredWindowWidth),
        )
    }
}
