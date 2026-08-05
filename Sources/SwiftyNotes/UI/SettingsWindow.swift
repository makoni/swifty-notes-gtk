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

    private let notesFolderRow = ActionRow(title: "Notes folder".localized)
    private let resetToDefaultRow = ActionRow(title: "Use default location".localized)
    private let openCurrentFolderRow = ActionRow(title: "Open current folder".localized)
    private let trashRetentionRow = ComboRow(title: "Empty Trash automatically".localized)
    private let wrapLinesRow = SwitchRow(title: "Wrap long lines".localized)
    private let fontSizeRow = SpinRow(title: "Editor font size".localized, min: 10, max: 32, step: 1)
    private let tabWidthRow = SpinRow(title: "Tab width".localized, min: 1, max: 8, step: 1)
    private let indentStyleRow = ComboRow(title: "Indent style".localized)
    private let autosaveDelayRow = SpinRow(title: "Autosave delay".localized, min: 1, max: 60, step: 1)
    private let appearanceRow = ComboRow(title: "Appearance".localized)
    private let spellCheckEnabledRow = SwitchRow(title: "Enable spell-check".localized)
    private let spellCheckLanguageRow = ComboRow(title: "Spell-check language".localized)
    private let spellCheckLanguages: [SpellChecking.LanguageOption]
    private let outlineDensityRow = ComboRow(title: "Outline density".localized)
    private let outlineTreeLinesRow = SwitchRow(title: "Tree lines under H2 sections".localized)
    private let outlineDragHandlesRow = SwitchRow(title: "Drag handles on hover".localized)
    private let outlineBreadcrumbRow = SwitchRow(title: "Breadcrumb strip above editor".localized)
    private let renderEmojiRow = SwitchRow(title: "Render emoji shortcodes".localized)
    private let trashRetentionOptions: [(retention: TrashRetention, displayName: String)] = [
        (.never, "Never".localized),
        (.days(7), "After 7 days".localized),
        (.days(30), "After 30 days".localized),
        (.days(90), "After 90 days".localized),
        (.days(365), "After a year".localized),
    ]
    private let browseButton = Button(label: "Browse…".localized)
    private let resetButton = Button(label: "Reset".localized)
    private let openButton = Button(label: "Open".localized)
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

        window.title = "Settings".localized
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
        let title = WindowTitle(title: "Settings".localized, subtitle: "Preferences".localized)
        let headerBar = HeaderBar()
        headerBar.titleWidget = title

        let storageGroup = PreferencesGroup(
            title: "Storage".localized,
            description: "Choose where Swifty Notes stores markdown files and companion assets.".localized,
        )

        notesFolderRow.subtitleSelectable = true
        notesFolderRow.subtitleLines = 3
        browseButton.valign = .center
        MacOSClickWorkaround.onClick(browseButton) { [weak self] in
            self?.chooseNotesFolder()
        }
        notesFolderRow.addSuffix(browseButton)
        notesFolderRow.activatableWidget = browseButton
        storageGroup.add(notesFolderRow)

        resetToDefaultRow.subtitle = defaultNotesDirectory.path(percentEncoded: false)
        resetToDefaultRow.subtitleSelectable = true
        resetToDefaultRow.subtitleLines = 3
        resetButton.valign = .center
        MacOSClickWorkaround.onClick(resetButton) { [weak self] in
            self?.applyNotesFolderChange(self?.defaultNotesDirectory)
        }
        resetToDefaultRow.addSuffix(resetButton)
        resetToDefaultRow.activatableWidget = resetButton
        storageGroup.add(resetToDefaultRow)

        openCurrentFolderRow.subtitle = "Reveal the active notes folder in your file manager.".localized
        openButton.valign = .center
        MacOSClickWorkaround.onClick(openButton) { [weak self] in
            self?.openCurrentNotesFolder()
        }
        openCurrentFolderRow.addSuffix(openButton)
        openCurrentFolderRow.activatableWidget = openButton
        storageGroup.add(openCurrentFolderRow)

        trashRetentionRow.subtitle = "Permanently delete trashed notes after this much time has passed.".localized
        trashRetentionRow.setModel(StringList(trashRetentionOptions.map(\.displayName)))
        trashRetentionRow.onNotify(.selected) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        storageGroup.add(trashRetentionRow)

        let editorGroup = PreferencesGroup(
            title: "Editor".localized,
            description: "Control wrapping, indentation, and editor text size.".localized,
        )

        wrapLinesRow.subtitle = "Wrap markdown paragraphs instead of scrolling horizontally.".localized
        wrapLinesRow.onNotify(.active) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        editorGroup.add(wrapLinesRow)

        fontSizeRow.subtitle = "Points".localized
        fontSizeRow.digits = 0
        fontSizeRow.numeric = true
        fontSizeRow.onNotify(.value) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        editorGroup.add(fontSizeRow)

        tabWidthRow.subtitle = "Columns".localized
        tabWidthRow.digits = 0
        tabWidthRow.numeric = true
        tabWidthRow.onNotify(.value) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        editorGroup.add(tabWidthRow)

        indentStyleRow.subtitle = "Choose whether Tab inserts spaces or hard tabs.".localized
        indentStyleRow.setModel(StringList(EditorIndentStyle.allCases.map(\.displayName)))
        indentStyleRow.onNotify(.selected) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        editorGroup.add(indentStyleRow)

        let previewGroup = PreferencesGroup(
            title: "Preview".localized,
            description: "Control how rendered Markdown appears in the preview.".localized,
        )
        renderEmojiRow.subtitle = "Show :shortcode: aliases (e.g. :rocket:) as emoji. Source text and code are unchanged.".localized
        renderEmojiRow.onNotify(.active) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        previewGroup.add(renderEmojiRow)

        let savingGroup = PreferencesGroup(
            title: "Saving".localized,
            description: "Autosave runs after the last edit using the configured delay.".localized,
        )
        autosaveDelayRow.subtitle = "Seconds".localized
        autosaveDelayRow.digits = 0
        autosaveDelayRow.numeric = true
        autosaveDelayRow.onNotify(.value) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        savingGroup.add(autosaveDelayRow)

        let appearanceGroup = PreferencesGroup(
            title: "Appearance".localized,
            description: "Override the application theme or follow the system.".localized,
        )
        appearanceRow.setModel(StringList(AppearanceMode.allCases.map(\.displayName)))
        appearanceRow.onNotify(.selected) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        appearanceGroup.add(appearanceRow)

        let spellCheckGroup = PreferencesGroup(
            title: "Spell check".localized,
            description: "Underline misspellings while you type and offer corrections in the right-click menu.".localized,
        )
        spellCheckEnabledRow.subtitle = "Highlight misspellings inline using libspelling and the system dictionaries.".localized
        spellCheckEnabledRow.onNotify(.active) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        spellCheckGroup.add(spellCheckEnabledRow)

        if !spellCheckLanguages.isEmpty {
            spellCheckLanguageRow.subtitle = "Choose a dictionary, or follow the system locale.".localized
            let displayNames = ["Follow system locale".localized] + spellCheckLanguages.map(\.displayName)
            spellCheckLanguageRow.setModel(StringList(displayNames))
            spellCheckLanguageRow.onNotify(.selected) { [weak self] in
                self?.handleInlinePreferenceChange()
            }
            spellCheckGroup.add(spellCheckLanguageRow)
        }

        let outlineGroup = PreferencesGroup(
            title: "Outline".localized,
            description: "Tweak the right-hand outline panel and the breadcrumb strip above the editor.".localized,
        )
        outlineDensityRow.subtitle = "Comfortable matches the default; Compact tightens row padding.".localized
        outlineDensityRow.setModel(StringList(OutlineDensity.allCases.map(\.displayName)))
        outlineDensityRow.onNotify(.selected) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        outlineGroup.add(outlineDensityRow)
        outlineTreeLinesRow.subtitle = "Vertical guides linking H3+ subsections to their H2 parent.".localized
        outlineTreeLinesRow.onNotify(.active) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        outlineGroup.add(outlineTreeLinesRow)
        outlineDragHandlesRow.subtitle = "Show the drag affordance on hover. Drag-to-reorder ships separately.".localized
        outlineDragHandlesRow.onNotify(.active) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        outlineGroup.add(outlineDragHandlesRow)
        outlineBreadcrumbRow.subtitle = "“You are here” strip above the editor toolbar.".localized
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
        content.append(spellCheckGroup)
        content.append(outlineGroup)

        let scrolled = ScrolledWindow(child: content)
        scrolled.setPolicy(horizontal: .never, vertical: .automatic)

        let toolbar = ToolbarView()
        toolbar.addTopBar(headerBar)
        toolbar.content = scrolled
        window.setContent(toolbar)
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
        trashRetentionRow.selected = trashRetentionOptions.firstIndex {
            $0.retention == currentSettings.trashRetention
        } ?? trashRetentionOptions.firstIndex { $0.retention == .days(30) } ?? 0
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
