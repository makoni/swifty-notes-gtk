import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

struct MainWindowActionsTests {
    @Test @MainActor
    func `main window selection change dismisses context menu before sidebar refresh`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.contextmenu-dismiss")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        window.debugOpenContextMenuForDisplayedNote(at: 0)
        #expect(window.debugHasContextMenu)
        #expect(!window.debugNoteContextMenuLabels.isEmpty)

        window.selectNote(at: 1)

        #expect(!window.debugHasContextMenu)
        #expect(window.debugNoteContextMenuLabels.isEmpty)
        #expect(window.debugSelectedNoteContent == SwiftyNotesOverviewSeed.content)
    }

    @Test @MainActor
    func `main window create note dismisses existing context menu before sidebar refresh`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.contextmenu-newnote")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        window.debugOpenContextMenuForDisplayedNote(at: 0)
        #expect(window.debugHasContextMenu)

        window.debugCreateNote()

        #expect(!window.debugHasContextMenu)
        #expect(window.debugNotesCount == 4)
    }

    @Test @MainActor
    func `main window context menu actions execute for selected row after sidebar refresh`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.contextmenu")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.present()
        window.debugCreateNote()
        #expect(window.debugNotesCount == 4)
        #expect(window.debugOverflowMenuSectionTitles == ["Library", "Help"])
        #expect(window.debugOverflowMenuItemsBySection == [
            "Library": [
                "Settings",
                "Open Markdown File…",
                "Import into Library…",
                "Reload from disk",
                "Open notes folder",
            ],
            "Help": [
                "About Swifty Notes",
            ],
        ])

        window.debugOpenContextMenuForDisplayedNote(at: 1)
        #expect(window.debugHasContextMenu)
        #expect(window.debugNoteContextMenuLabels == [
            "Rename note…",
            "Duplicate note",
            "Move to…",
            "Export note…",
            "Copy note ID",
            "Delete…",
        ])

        let selectedStableID = window.debugSelectedNoteStableID()
        #expect(selectedStableID != nil)
        #expect(window.debugInvokeContextMenuAction(label: "Copy note ID"))
        #expect(!window.debugHasContextMenu)
        #expect(window.debugLastCopiedNoteID == selectedStableID)

        window.debugOpenContextMenuForDisplayedNote(at: 1)
        #expect(window.debugHasContextMenu)
        #expect(window.debugInvokeContextMenuAction(label: "Duplicate note"))
        #expect(!window.debugHasContextMenu)
        #expect(window.debugNotesCount == 5)
        #expect(Set(window.debugDisplayedNoteStableIDs).count == window.debugDisplayedNoteStableIDs.count)
    }

    @Test @MainActor
    func `main window settings action presents settings window`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.settingswindow")
        try app.register()

        let originalScheme = StyleManager.default.colorScheme
        defer { StyleManager.default.colorScheme = originalScheme }

        let repository = NotesRepository(notesDirectory: temp)
        let settingsStore = AppSettingsStore(
            settingsFileURL: temp
                .appendingPathComponent("config", isDirectory: true)
                .appendingPathComponent("settings.json", isDirectory: false),
        )
        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            appSettingsStore: settingsStore,
            appSettings: AppSettings(
                wrapsEditorLines: false,
                editorFontSize: 18,
                editorTabWidth: 2,
                editorIndentStyle: .tabs,
                autosaveDelaySeconds: 5,
                appearanceMode: .dark,
            ),
        )

        window.present()
        window.debugActivateSettingsAction()

        #expect(window.debugHasSettingsWindow)
        #expect(window.debugSettingsWindowDefaultHeight == 546)
        #expect(window.debugSettingsWindowSnapshot == .init(
            notesDirectoryPath: temp.standardizedFileURL.path(),
            wrapsEditorLines: false,
            editorFontSize: 18,
            editorTabWidth: 2,
            editorIndentStyle: .tabs,
            autosaveDelaySeconds: 5,
            appearanceMode: .dark,
            spellCheckEnabled: true,
            spellCheckLanguage: nil,
        ))
    }

    @Test @MainActor
    func `main window changing notes directory moves notes and persists setting`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let sourceDirectory = temp.appendingPathComponent("source-notes", isDirectory: true)
        let destinationDirectory = temp.appendingPathComponent("destination-notes", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let repository = NotesRepository(notesDirectory: sourceDirectory)
        _ = try repository.createNote(initialContent: "# Moved note\n\nBody")

        let settingsStore = AppSettingsStore(
            settingsFileURL: temp
                .appendingPathComponent("config", isDirectory: true)
                .appendingPathComponent("settings.json", isDirectory: false),
        )
        try settingsStore.save(AppSettings(customNotesDirectoryPath: sourceDirectory.path()))

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.settingsmove")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            appSettingsStore: settingsStore,
            appSettings: AppSettings(customNotesDirectoryPath: sourceDirectory.path()),
        )

        window.present()
        try window.debugChangeNotesDirectory(to: destinationDirectory)

        #expect(!FileManager.default.fileExists(atPath: sourceDirectory.path()))
        let movedNotes = try NotesRepository(notesDirectory: destinationDirectory).loadNotes()
        #expect(movedNotes.count == 1)
        #expect(movedNotes.first?.title == "Moved note")
        #expect(window.debugSelectedNoteContent?.contains("Moved note") == true)
        #expect(try settingsStore.load().customNotesDirectoryURL?.standardizedFileURL == destinationDirectory.standardizedFileURL)
    }

    @Test @MainActor
    func `main window settings window controls apply and persist preferences`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.settingscontrols")
        try app.register()

        let originalScheme = StyleManager.default.colorScheme
        defer { StyleManager.default.colorScheme = originalScheme }

        let settingsFileURL = temp
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        let settingsStore = AppSettingsStore(settingsFileURL: settingsFileURL)
        let initialSettings = AppSettings(customNotesDirectoryPath: temp.path())
        try settingsStore.save(initialSettings)
        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            appSettingsStore: settingsStore,
            appSettings: initialSettings,
        )

        window.present()
        window.debugActivateSettingsAction()
        #expect(window.debugHasSettingsWindow)

        window.debugSettingsSetWrapLines(false)
        window.debugSettingsSetFontSize(19)
        window.debugSettingsSetTabWidth(6)
        window.debugSettingsSetIndentStyle(.tabs)
        window.debugSettingsSetAutosaveDelaySeconds(9)
        window.debugSettingsSetAppearanceMode(.dark)

        #expect(window.debugEditorWrapsLines == false)
        #expect(window.debugEditorFontSize == 19)
        #expect(window.debugEditorTabWidth == 6)
        #expect(window.debugEditorInsertsSpacesInsteadOfTabs == false)
        #expect(window.debugAutosaveDelaySeconds == 9)
        #expect(window.debugAppearanceMode == .dark)
        #expect(StyleManager.default.colorScheme == .forceDark)
        #expect(window.debugSettingsWindowSnapshot == .init(
            notesDirectoryPath: temp.standardizedFileURL.path(),
            wrapsEditorLines: false,
            editorFontSize: 19,
            editorTabWidth: 6,
            editorIndentStyle: .tabs,
            autosaveDelaySeconds: 9,
            appearanceMode: .dark,
            spellCheckEnabled: true,
            spellCheckLanguage: nil,
        ))

        let stored = try settingsStore.load()
        #expect(stored.wrapsEditorLines == false)
        #expect(stored.editorFontSize == 19)
        #expect(stored.editorTabWidth == 6)
        #expect(stored.editorIndentStyle == .tabs)
        #expect(stored.autosaveDelaySeconds == 9)
        #expect(stored.appearanceMode == .dark)

        let relaunched = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace-relaunch.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            appSettingsStore: settingsStore,
            appSettings: stored,
        )
        #expect(relaunched.debugEditorWrapsLines == false)
        #expect(relaunched.debugEditorFontSize == 19)
        #expect(relaunched.debugEditorTabWidth == 6)
        #expect(relaunched.debugEditorInsertsSpacesInsteadOfTabs == false)
        #expect(relaunched.debugAutosaveDelaySeconds == 9)
        #expect(relaunched.debugAppearanceMode == .dark)
    }

    @Test @MainActor
    func `main window updating preferences persists and applies them at runtime`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.settingsapply")
        try app.register()

        let originalScheme = StyleManager.default.colorScheme
        defer { StyleManager.default.colorScheme = originalScheme }

        let settingsFileURL = temp
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        let settingsStore = AppSettingsStore(settingsFileURL: settingsFileURL)
        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            appSettingsStore: settingsStore,
            appSettings: .default,
        )

        window.present()
        try window.debugUpdateAppSettings(AppSettings(
            customNotesDirectoryPath: temp.path(),
            wrapsEditorLines: false,
            editorFontSize: 17,
            editorTabWidth: 8,
            editorIndentStyle: .tabs,
            autosaveDelaySeconds: 7,
            appearanceMode: .light,
        ))

        #expect(window.debugEditorWrapsLines == false)
        #expect(window.debugEditorFontSize == 17)
        #expect(window.debugEditorTabWidth == 8)
        #expect(window.debugEditorInsertsSpacesInsteadOfTabs == false)
        #expect(window.debugAutosaveDelaySeconds == 7)
        #expect(window.debugAppearanceMode == .light)
        #expect(window.debugSettingsWindowSnapshot == nil)
        #expect(StyleManager.default.colorScheme == .forceLight)

        let stored = try settingsStore.load()
        #expect(stored.wrapsEditorLines == false)
        #expect(stored.editorFontSize == 17)
        #expect(stored.editorTabWidth == 8)
        #expect(stored.editorIndentStyle == .tabs)
        #expect(stored.autosaveDelaySeconds == 7)
        #expect(stored.appearanceMode == .light)
    }

    @Test @MainActor
    func `main window open notes folder uses injected directory opener`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.opennotesfolder")
        try app.register()

        let openedURL = URLRecorder()
        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            directoryOpener: { url in
                openedURL.set(url)
            },
        )

        window.debugLoadInitialNotes()
        window.debugOpenNotesFolder()

        #expect(openedURL.snapshot()?.standardizedFileURL == temp.standardizedFileURL)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: temp.path(), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test @MainActor
    func `main window open notes folder menu action uses injected directory opener`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.opennotesfolderaction")
        try app.register()

        let openedURL = URLRecorder()
        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
            directoryOpener: { url in
                openedURL.set(url)
            },
        )

        window.present()
        window.debugActivateOpenNotesFolderAction()

        #expect(openedURL.snapshot()?.standardizedFileURL == temp.standardizedFileURL)
    }

    @Test
    func `open directory in system file manager uses default URI handler first`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let expectedURI = temp.standardizedFileURL.absoluteString

        var launchedURIs: [String] = []
        var fallbackURIs: [String] = []

        try MainWindow.openDirectoryInSystemFileManager(
            temp,
            launchDefaultForURI: { uri in
                launchedURIs.append(uri)
            },
            fallbackOpenURI: { uri in
                fallbackURIs.append(uri)
            },
        )

        #expect(launchedURIs == [expectedURI])
        #expect(fallbackURIs.isEmpty)
    }

    @Test
    func `open directory in system file manager falls back to XDG open when default handler fails`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let expectedURI = temp.standardizedFileURL.absoluteString

        var launchedURIs: [String] = []
        var fallbackURIs: [String] = []

        try MainWindow.openDirectoryInSystemFileManager(
            temp,
            launchDefaultForURI: { uri in
                launchedURIs.append(uri)
                throw CocoaError(.fileNoSuchFile)
            },
            fallbackOpenURI: { uri in
                fallbackURIs.append(uri)
            },
        )

        #expect(launchedURIs == [expectedURI])
        #expect(fallbackURIs == [expectedURI])
    }

    @Test @MainActor
    func `main window about menu action presents about dialog`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.aboutdialog")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.present()
        window.debugActivateAboutAction()

        #expect(window.debugHasAboutDialog)
        #expect(window.debugAboutDialogSnapshot == .init(
            applicationName: "Swifty Notes",
            version: "1.1.3",
            developerName: "Sergey Armodin",
            copyright: "© 2026 Sergey Armodin",
            website: "https://github.com/makoni/swifty-notes-gtk",
            issueURL: "https://github.com/makoni/swifty-notes-gtk/issues",
            comments: "A native GTK markdown notes app written in Swift using swift-adwaita.",
        ))

        window.debugCloseAboutDialog()
        #expect(!window.debugHasAboutDialog)
    }

    @Test @MainActor
    func `main window about dialog uses release version environment when provided`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let previousValue = ProcessInfo.processInfo.environment["SWIFTY_NOTES_VERSION"]
        setenv("SWIFTY_NOTES_VERSION", "1.2.3", 1)
        defer {
            if let previousValue {
                setenv("SWIFTY_NOTES_VERSION", previousValue, 1)
            } else {
                unsetenv("SWIFTY_NOTES_VERSION")
            }
        }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.aboutdialogreleaseversion")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.present()
        window.debugActivateAboutAction()

        #expect(window.debugAboutDialogSnapshot?.version == "1.2.3")

        window.debugCloseAboutDialog()
    }

    @Test @MainActor
    func `main window switching between notes refreshes preview`() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let first = Note(
            id: UUID(),
            filename: "first.md",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            content: "# First\n\nOne",
        )
        let second = Note(
            id: UUID(),
            filename: "second.md",
            createdAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 200),
            content: "# Second\n\nTwo",
        )
        _ = try repository.save(note: first)
        _ = try repository.save(note: second)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.selectionswitch")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        try await Task.sleep(for: .milliseconds(30))
        #expect(window.debugPreviewText.contains("Second"))
        #expect(window.debugPreviewText.contains("Two"))

        window.present()
        try await Task.sleep(for: .milliseconds(30))

        window.debugSelectDisplayedNote(at: 1)
        try await Task.sleep(for: .milliseconds(10))
        #expect(window.debugPreviewText.contains("First"))
        #expect(window.debugPreviewText.contains("One"))

        window.debugSelectDisplayedNote(at: 0)
        try await Task.sleep(for: .milliseconds(10))
        #expect(window.debugPreviewText.contains("Second"))
        #expect(window.debugPreviewText.contains("Two"))
    }

    @Test @MainActor
    func `main window sidebar sort control reflects and changes sort mode`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let repository = NotesRepository(notesDirectory: temp)
        let alpha = Note(
            id: UUID(),
            filename: "alpha.md",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            content: "# Alpha\n",
        )
        let zeta = Note(
            id: UUID(),
            filename: "zeta.md",
            createdAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 200),
            content: "# Zeta\n",
        )
        _ = try repository.save(note: alpha)
        _ = try repository.save(note: zeta)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.sortcontrol")
        try app.register()

        let window = MainWindow(
            application: app,
            state: AppState(),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: repository,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )

        window.debugLoadInitialNotes()
        #expect(window.debugSortMode == .newestFirst)
        #expect(window.debugSidebarSortSelection == 0)
        #expect(window.debugDisplayedNoteTitles == ["Zeta", "Alpha"])

        window.debugEmitSortButtonClicked()
        #expect(window.debugSortMode == .oldestFirst)
        #expect(window.debugSidebarSortSelection == 1)
        #expect(window.debugDisplayedNoteTitles == ["Alpha", "Zeta"])

        window.debugSelectSidebarSort(at: 2)

        #expect(window.debugSortMode == .title)
        #expect(window.debugSidebarSortSelection == 2)
        #expect(window.debugDisplayedNoteTitles == ["Alpha", "Zeta"])
    }
}
