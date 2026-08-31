import Adwaita
import Foundation

@MainActor
final class SettingsWindow {
    struct Snapshot: Equatable {
        let notesDirectoryPath: String
        let wrapsEditorLines: Bool
        let editorFontSize: Int
        let editorTabWidth: Int
        let editorIndentStyle: EditorIndentStyle
        let autosaveDelaySeconds: Int
        let appearanceMode: AppearanceMode
        let spellCheckEnabled: Bool
        let spellCheckLanguage: String?
    }

    let window: ApplicationWindow

    // Rows and groups are built untitled on purpose: every string they show
    // comes from ``applyTranslations()``, which is also what a language change
    // re-runs. Baking the text into these initializers would give the window
    // two sources for the same label, and only one of them would follow the
    // picker.
    private let windowTitle = WindowTitle(title: "", subtitle: "")
    private let notesFolderRow = ActionRow(title: "")
    private let resetToDefaultRow = ActionRow(title: "")
    private let openCurrentFolderRow = ActionRow(title: "")
    private let trashRetentionRow = ComboRow(title: "")
    private let wrapLinesRow = SwitchRow(title: "")
    private let fontSizeRow = SpinRow(title: "", min: 10, max: 32, step: 1)
    private let tabWidthRow = SpinRow(title: "", min: 1, max: 8, step: 1)
    private let indentStyleRow = ComboRow(title: "")
    private let autosaveDelayRow = SpinRow(title: "", min: 1, max: 60, step: 1)
    private let appearanceRow = ComboRow(title: "")
    private let languageRow = ComboRow(title: "")
    private let spellCheckEnabledRow = SwitchRow(title: "")
    private let spellCheckLanguageRow = ComboRow(title: "")
    private let spellCheckLanguages: [SpellChecking.LanguageOption]
    private let outlineDensityRow = ComboRow(title: "")
    private let outlineTreeLinesRow = SwitchRow(title: "")
    private let outlineDragHandlesRow = SwitchRow(title: "")
    private let outlineBreadcrumbRow = SwitchRow(title: "")
    private let renderEmojiRow = SwitchRow(title: "")
    private let storageGroup = PreferencesGroup(title: "")
    private let editorGroup = PreferencesGroup(title: "")
    private let previewGroup = PreferencesGroup(title: "")
    private let savingGroup = PreferencesGroup(title: "")
    private let appearanceGroup = PreferencesGroup(title: "")
    private let languageGroup = PreferencesGroup(title: "")
    private let spellCheckGroup = PreferencesGroup(title: "")
    private let outlineGroup = PreferencesGroup(title: "")
    /// Computed, not stored: the names are translated, so a stored array
    /// would keep the language the window was opened in.
    private var trashRetentionOptions: [(retention: TrashRetention, displayName: String)] {
        [
            (.never, "Never".localized),
            (.days(7), "After 7 days".localized),
            (.days(30), "After 30 days".localized),
            (.days(90), "After 90 days".localized),
            (.days(365), "After a year".localized),
        ]
    }
    private static let languageValues = AppLanguage.allCases
    private let browseButton = Button(label: "")
    private let resetButton = Button(label: "")
    private let openButton = Button(label: "")
    private var defaultNotesDirectory: URL
    private let applyNotesDirectoryChange: (URL) throws -> URL
    private let applySettingsChange: (AppSettings) throws -> AppSettings
    private let openDirectory: (URL) throws -> Void
    private var activeFileDialog: FileDialog?
    private var isUpdatingControls = false
    private(set) var currentNotesDirectory: URL
    private(set) var currentSettings: AppSettings

    init(
        application: Application,
        parentWindow: GtkWindow,
        currentSettings: AppSettings,
        currentNotesDirectory: URL,
        defaultNotesDirectory: URL,
        applyNotesDirectoryChange: @escaping (URL) throws -> URL,
        applySettingsChange: @escaping (AppSettings) throws -> AppSettings,
        openDirectory: @escaping (URL) throws -> Void,
    ) {
        window = ApplicationWindow(application: application)
        self.currentSettings = currentSettings
        self.currentNotesDirectory = currentNotesDirectory.standardizedFileURL
        self.defaultNotesDirectory = defaultNotesDirectory.standardizedFileURL
        self.applyNotesDirectoryChange = applyNotesDirectoryChange
        self.applySettingsChange = applySettingsChange
        self.openDirectory = openDirectory
        spellCheckLanguages = SpellChecking.availableLanguages()

        window.iconName = AppIdentity.identifier
        window.setDefaultSize(width: 640, height: 546)
        window.transientFor = parentWindow
        window.destroyWithParent = true

        buildUI()
        update(settings: currentSettings, currentNotesDirectory: self.currentNotesDirectory, defaultNotesDirectory: self.defaultNotesDirectory)
    }

    var displayedNotesDirectoryPath: String {
        currentNotesDirectory.path(percentEncoded: false)
    }

    var snapshot: Snapshot {
        .init(
            notesDirectoryPath: displayedNotesDirectoryPath,
            wrapsEditorLines: currentSettings.wrapsEditorLines,
            editorFontSize: currentSettings.editorFontSize,
            editorTabWidth: currentSettings.editorTabWidth,
            editorIndentStyle: currentSettings.editorIndentStyle,
            autosaveDelaySeconds: currentSettings.autosaveDelaySeconds,
            appearanceMode: currentSettings.appearanceMode,
            spellCheckEnabled: currentSettings.spellCheckEnabled,
            spellCheckLanguage: currentSettings.spellCheckLanguage,
        )
    }

    func present() {
        window.present()
    }

    func update(settings: AppSettings, currentNotesDirectory: URL, defaultNotesDirectory: URL) {
        self.defaultNotesDirectory = defaultNotesDirectory.standardizedFileURL
        updateNotesDirectory(currentNotesDirectory)
        updateSettings(settings)
    }

    private func buildUI() {
        let headerBar = HeaderBar()
        headerBar.titleWidget = windowTitle

        notesFolderRow.subtitleSelectable = true
        notesFolderRow.subtitleLines = 3
        browseButton.valign = .center
        MacOSClickWorkaround.onClick(browseButton) { [weak self] in
            self?.chooseNotesFolder()
        }
        notesFolderRow.addSuffix(browseButton)
        notesFolderRow.activatableWidget = browseButton
        storageGroup.add(notesFolderRow)

        resetToDefaultRow.subtitleSelectable = true
        resetToDefaultRow.subtitleLines = 3
        resetButton.valign = .center
        MacOSClickWorkaround.onClick(resetButton) { [weak self] in
            self?.applyNotesFolderChange(self?.defaultNotesDirectory)
        }
        resetToDefaultRow.addSuffix(resetButton)
        resetToDefaultRow.activatableWidget = resetButton
        storageGroup.add(resetToDefaultRow)

        openButton.valign = .center
        MacOSClickWorkaround.onClick(openButton) { [weak self] in
            self?.openCurrentNotesFolder()
        }
        openCurrentFolderRow.addSuffix(openButton)
        openCurrentFolderRow.activatableWidget = openButton
        storageGroup.add(openCurrentFolderRow)

        trashRetentionRow.onNotify(.selected) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        storageGroup.add(trashRetentionRow)

        wrapLinesRow.onNotify(.active) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        editorGroup.add(wrapLinesRow)

        fontSizeRow.digits = 0
        fontSizeRow.numeric = true
        fontSizeRow.onNotify(.value) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        editorGroup.add(fontSizeRow)

        tabWidthRow.digits = 0
        tabWidthRow.numeric = true
        tabWidthRow.onNotify(.value) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        editorGroup.add(tabWidthRow)

        indentStyleRow.onNotify(.selected) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        editorGroup.add(indentStyleRow)

        renderEmojiRow.onNotify(.active) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        previewGroup.add(renderEmojiRow)

        autosaveDelayRow.digits = 0
        autosaveDelayRow.numeric = true
        autosaveDelayRow.onNotify(.value) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        savingGroup.add(autosaveDelayRow)

        appearanceRow.onNotify(.selected) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        appearanceGroup.add(appearanceRow)

        languageRow.onNotify(.selected) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        languageGroup.add(languageRow)

        spellCheckEnabledRow.onNotify(.active) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        spellCheckGroup.add(spellCheckEnabledRow)

        if !spellCheckLanguages.isEmpty {
            spellCheckLanguageRow.onNotify(.selected) { [weak self] in
                self?.handleInlinePreferenceChange()
            }
            spellCheckGroup.add(spellCheckLanguageRow)
        }

        outlineDensityRow.onNotify(.selected) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        outlineGroup.add(outlineDensityRow)
        outlineTreeLinesRow.onNotify(.active) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        outlineGroup.add(outlineTreeLinesRow)
        outlineDragHandlesRow.onNotify(.active) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        outlineGroup.add(outlineDragHandlesRow)
        outlineBreadcrumbRow.onNotify(.active) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        outlineGroup.add(outlineBreadcrumbRow)

        let content = Box(orientation: .vertical, spacing: 24)
        content.setMargins(24)
        content.append(storageGroup)
        content.append(editorGroup)
        content.append(previewGroup)
        content.append(savingGroup)
        content.append(appearanceGroup)
        content.append(languageGroup)
        content.append(spellCheckGroup)
        content.append(outlineGroup)

        let scrolled = ScrolledWindow(child: content)
        scrolled.setPolicy(horizontal: .never, vertical: .automatic)

        let toolbar = ToolbarView()
        toolbar.addTopBar(headerBar)
        toolbar.content = scrolled
        window.setContent(toolbar)
        applyTranslations()
    }

    /// Writes every user-visible string in the window.
    ///
    /// Called once from ``buildUI()`` and again from ``retranslate()`` after
    /// the interface language changes. Combo models are rebuilt here too,
    /// because the option names are translated — which resets the selected
    /// index, so ``retranslate()`` restores it with ``updateSettings(_:)``.
    private func applyTranslations() {
        // Replacing a ComboRow's model resets its selection to 0, and GTK
        // reports that as notify::selected — indistinguishable, from the
        // handler's side, from the user picking the first option. Without this
        // guard a language change silently rewrote the language, trash
        // retention, indent style, appearance, outline density and
        // spell-check dictionary back to their first entries.
        let wasUpdatingControls = isUpdatingControls
        isUpdatingControls = true
        defer { isUpdatingControls = wasUpdatingControls }

        window.title = "Settings".localized
        windowTitle.title = "Settings".localized
        windowTitle.subtitle = "Preferences".localized

        storageGroup.title = "Storage".localized
        storageGroup.description = "Choose where Swifty Notes stores markdown files and companion assets.".localized
        notesFolderRow.title = "Notes folder".localized
        browseButton.label = "Browse…".localized
        resetToDefaultRow.title = "Use default location".localized
        resetToDefaultRow.subtitle = defaultNotesDirectory.path(percentEncoded: false)
        resetButton.label = "Reset".localized
        openCurrentFolderRow.title = "Open current folder".localized
        openCurrentFolderRow.subtitle = "Reveal the active notes folder in your file manager.".localized
        openButton.label = "Open".localized
        trashRetentionRow.title = "Empty Trash automatically".localized
        trashRetentionRow.subtitle = "Permanently delete trashed notes after this much time has passed.".localized
        trashRetentionRow.setModel(StringList(trashRetentionOptions.map(\.displayName)))

        editorGroup.title = "Editor".localized
        editorGroup.description = "Control wrapping, indentation, and editor text size.".localized
        wrapLinesRow.title = "Wrap long lines".localized
        wrapLinesRow.subtitle = "Wrap markdown paragraphs instead of scrolling horizontally.".localized
        fontSizeRow.title = "Editor font size".localized
        fontSizeRow.subtitle = "Points".localized
        tabWidthRow.title = "Tab width".localized
        tabWidthRow.subtitle = "Columns".localized
        indentStyleRow.title = "Indent style".localized
        indentStyleRow.subtitle = "Choose whether Tab inserts spaces or hard tabs.".localized
        indentStyleRow.setModel(StringList(EditorIndentStyle.allCases.map(\.displayName)))

        previewGroup.title = "Preview".localized
        previewGroup.description = "Control how rendered Markdown appears in the preview.".localized
        renderEmojiRow.title = "Render emoji shortcodes".localized
        renderEmojiRow.subtitle = "Show :shortcode: aliases (e.g. :rocket:) as emoji. Source text and code are unchanged.".localized

        savingGroup.title = "Saving".localized
        savingGroup.description = "Autosave runs after the last edit using the configured delay.".localized
        autosaveDelayRow.title = "Autosave delay".localized
        autosaveDelayRow.subtitle = "Seconds".localized

        appearanceGroup.title = "Appearance".localized
        appearanceGroup.description = "Override the application theme or follow the system.".localized
        appearanceRow.title = "Appearance".localized
        appearanceRow.setModel(StringList(AppearanceMode.allCases.map(\.displayName)))

        languageGroup.title = "Language".localized
        // Only promise an instant switch where libintl exports the catalogue
        // cache counter that makes one possible.
        languageGroup.description = canSwitchLanguageAtRuntime()
            ? "Applies immediately — no restart.".localized
            : "Takes effect the next time the app starts.".localized
        languageRow.title = "Interface language".localized
        languageRow.subtitle = "Follow the system, or pin the language the interface uses.".localized
        languageRow.setModel(StringList(Self.languageValues.map(\.displayName)))

        spellCheckGroup.title = "Spell check".localized
        spellCheckGroup.description = "Underline misspellings while you type and offer corrections in the right-click menu.".localized
        spellCheckEnabledRow.title = "Enable spell-check".localized
        spellCheckEnabledRow.subtitle = "Highlight misspellings inline using libspelling and the system dictionaries.".localized
        if !spellCheckLanguages.isEmpty {
            spellCheckLanguageRow.title = "Spell-check language".localized
            spellCheckLanguageRow.subtitle = "Choose a dictionary, or follow the system locale.".localized
            let displayNames = ["Follow system locale".localized] + spellCheckLanguages.map(\.displayName)
            spellCheckLanguageRow.setModel(StringList(displayNames))
        }

        outlineGroup.title = "Outline".localized
        outlineGroup.description = "Tweak the right-hand outline panel and the breadcrumb strip above the editor.".localized
        outlineDensityRow.title = "Outline density".localized
        outlineDensityRow.subtitle = "Comfortable matches the default; Compact tightens row padding.".localized
        outlineDensityRow.setModel(StringList(OutlineDensity.allCases.map(\.displayName)))
        outlineTreeLinesRow.title = "Tree lines under H2 sections".localized
        outlineTreeLinesRow.subtitle = "Vertical guides linking H3+ subsections to their H2 parent.".localized
        outlineDragHandlesRow.title = "Drag handles on hover".localized
        outlineDragHandlesRow.subtitle = "Show the drag affordance on hover. Drag-to-reorder ships separately.".localized
        outlineBreadcrumbRow.title = "Breadcrumb strip above editor".localized
        outlineBreadcrumbRow.subtitle = "“You are here” strip above the editor toolbar.".localized
    }

    /// Re-reads every string in the window after the interface language
    /// changed, then restores the control values the rebuilt combo models
    /// dropped.
    func retranslate() {
        applyTranslations()
        updateSettings(currentSettings)
        updateNotesDirectory(currentNotesDirectory)
    }

    private func chooseNotesFolder() {
        let dialog = FileDialog()
        dialog.title = "Choose Notes Folder".localized
        dialog.modal = true
        activeFileDialog = dialog
        dialog.selectFolder(parent: window) { [weak self, weak dialog] result in
            guard let self, let dialog else { return }
            if activeFileDialog === dialog {
                activeFileDialog = nil
            }
            let path: String?
            switch result {
            case let .success(value):
                path = value
            case let .failure(error):
                presentError(
                    heading: "Could not choose a notes folder".localized,
                    body: error.message,
                )
                return
            }
            guard let path else { return }
            applyNotesFolderChange(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    private func applyNotesFolderChange(_ folderURL: URL?) {
        guard let folderURL else { return }
        do {
            let activeFolder = try applyNotesDirectoryChange(folderURL.standardizedFileURL)
            updateNotesDirectory(activeFolder)
            currentSettings = currentSettings.updatingNotesDirectory(
                activeFolder,
                defaultDirectory: defaultNotesDirectory,
            )
        } catch {
            presentError(
                heading: "Could not change the notes folder".localized,
                body: NotesDirectoryErrorMessage.userFriendly(for: error),
            )
        }
    }

    private func openCurrentNotesFolder() {
        do {
            try openDirectory(currentNotesDirectory)
        } catch {
            presentError(
                heading: "Could not open notes folder".localized,
                body: NotesDirectoryErrorMessage.userFriendly(for: error),
            )
        }
    }

    private func updateNotesDirectory(_ folderURL: URL) {
        currentNotesDirectory = folderURL.standardizedFileURL
        notesFolderRow.subtitle = currentNotesDirectory.path(percentEncoded: false)
        let usesDefaultLocation = currentNotesDirectory == defaultNotesDirectory
        resetButton.sensitive = !usesDefaultLocation
        resetToDefaultRow.sensitive = !usesDefaultLocation
    }

    private func updateSettings(_ settings: AppSettings) {
        isUpdatingControls = true
        currentSettings = settings.normalized(defaultDirectory: defaultNotesDirectory)
        wrapLinesRow.active = currentSettings.wrapsEditorLines
        fontSizeRow.value = Double(currentSettings.editorFontSize)
        tabWidthRow.value = Double(currentSettings.editorTabWidth)
        indentStyleRow.selected = EditorIndentStyle.allCases.firstIndex(of: currentSettings.editorIndentStyle) ?? 0
        autosaveDelayRow.value = Double(currentSettings.autosaveDelaySeconds)
        appearanceRow.selected = AppearanceMode.allCases.firstIndex(of: currentSettings.appearanceMode) ?? 0
        spellCheckEnabledRow.active = currentSettings.spellCheckEnabled
        spellCheckLanguageRow.sensitive = currentSettings.spellCheckEnabled
        let retentions = trashRetentionOptions.map(\.retention)
        trashRetentionRow.selected = retentions.firstIndex(of: currentSettings.trashRetention)
            ?? retentions.firstIndex(of: .days(30))
            ?? 0
        languageRow.selected = Self.languageValues.firstIndex(of: currentSettings.appLanguage) ?? 0
        outlineDensityRow.selected = OutlineDensity.allCases.firstIndex(of: currentSettings.outlineDensity) ?? 0
        outlineTreeLinesRow.active = currentSettings.outlineTreeLines
        outlineDragHandlesRow.active = currentSettings.outlineDragHandles
        outlineBreadcrumbRow.active = currentSettings.outlineBreadcrumbVisible
        renderEmojiRow.active = currentSettings.renderEmojiShortcodes
        if !spellCheckLanguages.isEmpty {
            // Index 0 represents the "follow system locale" option (no
            // explicit language). Subsequent indices map onto entries in
            // ``spellCheckLanguages`` (see buildUI for the model setup).
            if let language = currentSettings.spellCheckLanguage,
               let index = spellCheckLanguages.firstIndex(where: { $0.code == language }) {
                spellCheckLanguageRow.selected = index + 1
            } else {
                spellCheckLanguageRow.selected = 0
            }
        }
        isUpdatingControls = false
    }

    private func handleInlinePreferenceChange() {
        guard !isUpdatingControls else { return }

        let indentStyle = EditorIndentStyle.allCases[
            min(max(indentStyleRow.selected, 0), EditorIndentStyle.allCases.count - 1),
        ]
        let appearanceMode = AppearanceMode.allCases[
            min(max(appearanceRow.selected, 0), AppearanceMode.allCases.count - 1),
        ]
        let resolvedSpellCheckLanguage: String?
        if !spellCheckLanguages.isEmpty {
            let languageIndex = spellCheckLanguageRow.selected
            if languageIndex <= 0 {
                resolvedSpellCheckLanguage = nil
            } else {
                let offset = languageIndex - 1
                let clamped = min(max(offset, 0), spellCheckLanguages.count - 1)
                resolvedSpellCheckLanguage = spellCheckLanguages[clamped].code
            }
        } else {
            resolvedSpellCheckLanguage = currentSettings.spellCheckLanguage
        }
        let trashRetentionIndex = min(
            max(trashRetentionRow.selected, 0),
            trashRetentionOptions.count - 1,
        )
        let trashRetention = trashRetentionOptions[trashRetentionIndex].retention
        let appLanguage = Self.languageValues[
            min(max(languageRow.selected, 0), Self.languageValues.count - 1),
        ]
        let outlineDensity = OutlineDensity.allCases[
            min(max(outlineDensityRow.selected, 0), OutlineDensity.allCases.count - 1),
        ]
        let updatedSettings = AppSettings(
            customNotesDirectoryPath: currentSettings.customNotesDirectoryPath,
            wrapsEditorLines: wrapLinesRow.active,
            editorFontSize: Int(fontSizeRow.value.rounded()),
            editorTabWidth: Int(tabWidthRow.value.rounded()),
            editorIndentStyle: indentStyle,
            autosaveDelaySeconds: Int(autosaveDelayRow.value.rounded()),
            appearanceMode: appearanceMode,
            spellCheckEnabled: spellCheckEnabledRow.active,
            spellCheckLanguage: resolvedSpellCheckLanguage,
            trashRetention: trashRetention,
            appLanguage: appLanguage,
            outlineDensity: outlineDensity,
            outlineTreeLines: outlineTreeLinesRow.active,
            outlineDragHandles: outlineDragHandlesRow.active,
            outlineBreadcrumbVisible: outlineBreadcrumbRow.active,
            renderEmojiShortcodes: renderEmojiRow.active,
        )

        do {
            let appliedSettings = try applySettingsChange(updatedSettings)
            updateSettings(appliedSettings)
            updateNotesDirectory(
                appliedSettings.resolvedNotesDirectory(defaultDirectory: defaultNotesDirectory),
            )
        } catch {
            updateSettings(currentSettings)
            presentError(
                heading: "Could not update settings".localized,
                body: error.localizedDescription,
            )
        }
    }

    private func presentError(heading: String, body: String) {
        let dialog = AlertDialog(heading: heading, body: body)
        dialog.addResponse("ok", label: "OK".localized)
        dialog.defaultResponse = "ok"
        dialog.closeResponse = "ok"
        dialog.present(window)
    }
}

#if DEBUG
    @MainActor
    extension SettingsWindow {
        /// Every translated label the settings window shows, so a language
        /// switch can be asserted across the whole page rather than one row.
        var debugLocalizedChrome: [String: String] {
            [
                "windowTitle": window.title ?? "",
                "headerTitle": windowTitle.title,
                "headerSubtitle": windowTitle.subtitle,
                "storageGroup": storageGroup.title,
                "storageDescription": storageGroup.description ?? "",
                "notesFolderRow": notesFolderRow.title,
                "browseButton": browseButton.label ?? "",
                "trashRetentionRow": trashRetentionRow.title,
                "editorGroup": editorGroup.title,
                "wrapLinesRow": wrapLinesRow.title,
                "fontSizeRow": fontSizeRow.title,
                "fontSizeSubtitle": fontSizeRow.subtitle ?? "",
                "appearanceGroup": appearanceGroup.title,
                "appearanceRow": appearanceRow.title,
                "languageGroup": languageGroup.title,
                "languageRow": languageRow.title,
                "languageSubtitle": languageRow.subtitle ?? "",
                "spellCheckGroup": spellCheckGroup.title,
                "outlineGroup": outlineGroup.title,
                "outlineDensityRow": outlineDensityRow.title,
            ]
        }

        var debugSelectedLanguage: AppLanguage {
            Self.languageValues[min(max(languageRow.selected, 0), Self.languageValues.count - 1)]
        }

        func debugSetLanguage(_ language: AppLanguage) {
            languageRow.selected = Self.languageValues.firstIndex(of: language) ?? 0
            handleInlinePreferenceChange()
        }

        var debugDefaultHeight: Int {
            window.defaultHeight
        }

        func debugSetWrapLines(_ value: Bool) {
            wrapLinesRow.active = value
            handleInlinePreferenceChange()
        }

        func debugSetFontSize(_ value: Int) {
            fontSizeRow.value = Double(value)
            handleInlinePreferenceChange()
        }

        func debugSetTabWidth(_ value: Int) {
            tabWidthRow.value = Double(value)
            handleInlinePreferenceChange()
        }

        func debugSetIndentStyle(_ value: EditorIndentStyle) {
            indentStyleRow.selected = EditorIndentStyle.allCases.firstIndex(of: value) ?? 0
            handleInlinePreferenceChange()
        }

        func debugSetAutosaveDelaySeconds(_ value: Int) {
            autosaveDelayRow.value = Double(value)
            handleInlinePreferenceChange()
        }

        func debugSetAppearanceMode(_ value: AppearanceMode) {
            appearanceRow.selected = AppearanceMode.allCases.firstIndex(of: value) ?? 0
            handleInlinePreferenceChange()
        }
    }
#endif
