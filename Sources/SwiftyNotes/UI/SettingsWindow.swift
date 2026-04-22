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
    }

    let window: ApplicationWindow

    private let notesFolderRow = ActionRow(title: "Notes folder")
    private let resetToDefaultRow = ActionRow(title: "Use default location")
    private let openCurrentFolderRow = ActionRow(title: "Open current folder")
    private let wrapLinesRow = SwitchRow(title: "Wrap long lines")
    private let fontSizeRow = SpinRow(title: "Editor font size", min: 10, max: 32, step: 1)
    private let tabWidthRow = SpinRow(title: "Tab width", min: 1, max: 8, step: 1)
    private let indentStyleRow = ComboRow(title: "Indent style")
    private let autosaveDelayRow = SpinRow(title: "Autosave delay", min: 1, max: 60, step: 1)
    private let appearanceRow = ComboRow(title: "Appearance")
    private let browseButton = Button(label: "Browse…")
    private let resetButton = Button(label: "Reset")
    private let openButton = Button(label: "Open")
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
        openDirectory: @escaping (URL) throws -> Void
    ) {
        self.window = ApplicationWindow(application: application)
        self.currentSettings = currentSettings
        self.currentNotesDirectory = currentNotesDirectory.standardizedFileURL
        self.defaultNotesDirectory = defaultNotesDirectory.standardizedFileURL
        self.applyNotesDirectoryChange = applyNotesDirectoryChange
        self.applySettingsChange = applySettingsChange
        self.openDirectory = openDirectory

        window.title = "Settings"
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
            appearanceMode: currentSettings.appearanceMode
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
        let title = WindowTitle(title: "Settings", subtitle: "Preferences")
        let headerBar = HeaderBar()
        headerBar.titleWidget = title

        let storageGroup = PreferencesGroup(
            title: "Storage",
            description: "Choose where Swifty Notes stores markdown files and companion assets."
        )

        notesFolderRow.subtitleSelectable = true
        notesFolderRow.subtitleLines = 3
        browseButton.valign = .center
        browseButton.onClicked { [weak self] in
            self?.chooseNotesFolder()
        }
        notesFolderRow.addSuffix(browseButton)
        notesFolderRow.activatableWidget = browseButton
        storageGroup.add(notesFolderRow)

        resetToDefaultRow.subtitle = defaultNotesDirectory.path(percentEncoded: false)
        resetToDefaultRow.subtitleSelectable = true
        resetToDefaultRow.subtitleLines = 3
        resetButton.valign = .center
        resetButton.onClicked { [weak self] in
            self?.applyNotesFolderChange(self?.defaultNotesDirectory)
        }
        resetToDefaultRow.addSuffix(resetButton)
        resetToDefaultRow.activatableWidget = resetButton
        storageGroup.add(resetToDefaultRow)

        openCurrentFolderRow.subtitle = "Reveal the active notes folder in your file manager."
        openButton.valign = .center
        openButton.onClicked { [weak self] in
            self?.openCurrentNotesFolder()
        }
        openCurrentFolderRow.addSuffix(openButton)
        openCurrentFolderRow.activatableWidget = openButton
        storageGroup.add(openCurrentFolderRow)

        let editorGroup = PreferencesGroup(
            title: "Editor",
            description: "Control wrapping, indentation, and editor text size."
        )

        wrapLinesRow.subtitle = "Wrap markdown paragraphs instead of scrolling horizontally."
        wrapLinesRow.onNotify(.active) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        editorGroup.add(wrapLinesRow)

        fontSizeRow.subtitle = "Points"
        fontSizeRow.digits = 0
        fontSizeRow.numeric = true
        fontSizeRow.onNotify(.value) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        editorGroup.add(fontSizeRow)

        tabWidthRow.subtitle = "Columns"
        tabWidthRow.digits = 0
        tabWidthRow.numeric = true
        tabWidthRow.onNotify(.value) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        editorGroup.add(tabWidthRow)

        indentStyleRow.subtitle = "Choose whether Tab inserts spaces or hard tabs."
        indentStyleRow.setModel(StringList(EditorIndentStyle.allCases.map(\.displayName)))
        indentStyleRow.onNotify(.selected) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        editorGroup.add(indentStyleRow)

        let savingGroup = PreferencesGroup(
            title: "Saving",
            description: "Autosave runs after the last edit using the configured delay."
        )
        autosaveDelayRow.subtitle = "Seconds"
        autosaveDelayRow.digits = 0
        autosaveDelayRow.numeric = true
        autosaveDelayRow.onNotify(.value) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        savingGroup.add(autosaveDelayRow)

        let appearanceGroup = PreferencesGroup(
            title: "Appearance",
            description: "Override the application theme or follow the system."
        )
        appearanceRow.setModel(StringList(AppearanceMode.allCases.map(\.displayName)))
        appearanceRow.onNotify(.selected) { [weak self] in
            self?.handleInlinePreferenceChange()
        }
        appearanceGroup.add(appearanceRow)

        let content = Box(orientation: .vertical, spacing: 24)
        content.setMargins(24)
        content.append(storageGroup)
        content.append(editorGroup)
        content.append(savingGroup)
        content.append(appearanceGroup)

        let scrolled = ScrolledWindow(child: content)
        scrolled.setPolicy(horizontal: .never, vertical: .automatic)

        let toolbar = ToolbarView()
        toolbar.addTopBar(headerBar)
        toolbar.content = scrolled
        window.setContent(toolbar)
    }

    private func chooseNotesFolder() {
        let dialog = FileDialog()
        dialog.title = "Choose Notes Folder"
        dialog.modal = true
        activeFileDialog = dialog
        dialog.selectFolder(parent: window) { [weak self, weak dialog] result in
            guard let self, let dialog else { return }
            if self.activeFileDialog === dialog {
                self.activeFileDialog = nil
            }
            let path: String?
            switch result {
            case let .success(value):
                path = value
            case let .failure(error):
                self.presentError(
                    heading: "Could not choose a notes folder",
                    body: error.message
                )
                return
            }
            guard let path else { return }
            self.applyNotesFolderChange(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    private func applyNotesFolderChange(_ folderURL: URL?) {
        guard let folderURL else { return }
        do {
            let activeFolder = try applyNotesDirectoryChange(folderURL.standardizedFileURL)
            updateNotesDirectory(activeFolder)
            currentSettings = currentSettings.updatingNotesDirectory(
                activeFolder,
                defaultDirectory: defaultNotesDirectory
            )
        } catch {
            presentError(
                heading: "Could not change the notes folder",
                body: error.localizedDescription
            )
        }
    }

    private func openCurrentNotesFolder() {
        do {
            try openDirectory(currentNotesDirectory)
        } catch {
            presentError(
                heading: "Could not open notes folder",
                body: error.localizedDescription
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
        isUpdatingControls = false
    }

    private func handleInlinePreferenceChange() {
        guard !isUpdatingControls else { return }

        let indentStyle = EditorIndentStyle.allCases[
            min(max(indentStyleRow.selected, 0), EditorIndentStyle.allCases.count - 1)
        ]
        let appearanceMode = AppearanceMode.allCases[
            min(max(appearanceRow.selected, 0), AppearanceMode.allCases.count - 1)
        ]
        let updatedSettings = AppSettings(
            customNotesDirectoryPath: currentSettings.customNotesDirectoryPath,
            wrapsEditorLines: wrapLinesRow.active,
            editorFontSize: Int(fontSizeRow.value.rounded()),
            editorTabWidth: Int(tabWidthRow.value.rounded()),
            editorIndentStyle: indentStyle,
            autosaveDelaySeconds: Int(autosaveDelayRow.value.rounded()),
            appearanceMode: appearanceMode
        )

        do {
            let appliedSettings = try applySettingsChange(updatedSettings)
            updateSettings(appliedSettings)
            updateNotesDirectory(
                appliedSettings.resolvedNotesDirectory(defaultDirectory: defaultNotesDirectory)
            )
        } catch {
            updateSettings(currentSettings)
            presentError(
                heading: "Could not update settings",
                body: error.localizedDescription
            )
        }
    }

    private func presentError(heading: String, body: String) {
        let dialog = AlertDialog(heading: heading, body: body)
        dialog.addResponse("ok", label: "OK")
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
