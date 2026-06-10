#if os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import XCTest

final class MainWindowActionsXCTests: XCTestCase {
    @MainActor func test_main_window_selection_change_dismisses_context_menu_before_sidebar_refresh() throws {
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
        // Seeded sidebar order with "Guides" expanded:
        // [About, Using CLI, Markdown Showcase]. Picking index 0
        // (About) keeps the test exercising the same selection path.
        window.debugOpenContextMenuForDisplayedNote(at: 2)
        XCTAssertTrue(window.debugHasContextMenu)
        XCTAssertFalse(window.debugNoteContextMenuLabels.isEmpty)

        window.selectNote(at: 0)

        XCTAssertFalse(window.debugHasContextMenu)
        XCTAssertTrue(window.debugNoteContextMenuLabels.isEmpty)
        XCTAssertTrue(window.debugSelectedNoteContent == SwiftyNotesOverviewSeed.content)
    }

    @MainActor func test_main_window_create_note_dismisses_existing_context_menu_before_sidebar_refresh() throws {
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
        XCTAssertTrue(window.debugHasContextMenu)

        window.debugCreateNote()

        XCTAssertFalse(window.debugHasContextMenu)
        XCTAssertTrue(window.debugNotesCount == 4)
    }

    @MainActor func test_main_window_context_menu_actions_execute_for_selected_row_after_sidebar_refresh() throws {
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
        XCTAssertTrue(window.debugNotesCount == 4)
        XCTAssertTrue(window.debugOverflowMenuSectionTitles == ["Library", "Help"])
        XCTAssertTrue(window.debugOverflowMenuItemsBySection == [
            "Library": [
                "Settings",
                "Open Markdown File…",
                "Import into Library…",
                "Reload from disk",
                "Open notes folder",
            ],
            "Help": [
                "Check for Updates…",
                "About Swifty Notes",
            ],
        ])

        window.debugOpenContextMenuForDisplayedNote(at: 1)
        XCTAssertTrue(window.debugHasContextMenu)
        XCTAssertTrue(window.debugNoteContextMenuLabels == [
            "Rename note…",
            "Duplicate note",
            "Move to…",
            "Export note…",
            "Copy note ID",
            "Delete…",
        ])

        let selectedStableID = window.debugSelectedNoteStableID()
        XCTAssertNotNil(selectedStableID)
        XCTAssertTrue(window.debugInvokeContextMenuAction(label: "Copy note ID"))
        XCTAssertFalse(window.debugHasContextMenu)
        XCTAssertTrue(window.debugLastCopiedNoteID == selectedStableID)

        window.debugOpenContextMenuForDisplayedNote(at: 1)
        XCTAssertTrue(window.debugHasContextMenu)
        XCTAssertTrue(window.debugInvokeContextMenuAction(label: "Duplicate note"))
        XCTAssertFalse(window.debugHasContextMenu)
        XCTAssertTrue(window.debugNotesCount == 5)
        XCTAssertTrue(Set(window.debugDisplayedNoteStableIDs).count == window.debugDisplayedNoteStableIDs.count)
    }

    @MainActor func test_main_window_settings_action_presents_settings_window() throws {
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

        XCTAssertTrue(window.debugHasSettingsWindow)
        XCTAssertTrue(window.debugSettingsWindowDefaultHeight == 546)
        XCTAssertTrue(window.debugSettingsWindowSnapshot == .init(
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

    @MainActor func test_main_window_changing_notes_directory_moves_notes_and_persists_setting() throws {
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

        XCTAssertTrue(!FileManager.default.fileExists(atPath: sourceDirectory.path()))
        let movedNotes = try NotesRepository(notesDirectory: destinationDirectory).loadNotes()
        XCTAssertTrue(movedNotes.count == 1)
        XCTAssertTrue(movedNotes.first?.title == "Moved note")
        XCTAssertTrue(window.debugSelectedNoteContent?.contains("Moved note") == true)
        XCTAssertTrue(try settingsStore.load().customNotesDirectoryURL?.standardizedFileURL == destinationDirectory.standardizedFileURL)
    }

    @MainActor func test_main_window_settings_window_controls_apply_and_persist_preferences() throws {
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
        XCTAssertTrue(window.debugHasSettingsWindow)

        window.debugSettingsSetWrapLines(false)
        window.debugSettingsSetFontSize(19)
        window.debugSettingsSetTabWidth(6)
        window.debugSettingsSetIndentStyle(.tabs)
        window.debugSettingsSetAutosaveDelaySeconds(9)
        window.debugSettingsSetAppearanceMode(.dark)

        XCTAssertTrue(window.debugEditorWrapsLines == false)
        XCTAssertTrue(window.debugEditorFontSize == 19)
        XCTAssertTrue(window.debugEditorTabWidth == 6)
        XCTAssertTrue(window.debugEditorInsertsSpacesInsteadOfTabs == false)
        XCTAssertTrue(window.debugAutosaveDelaySeconds == 9)
        XCTAssertTrue(window.debugAppearanceMode == .dark)
        XCTAssertTrue(StyleManager.default.colorScheme == .forceDark)
        XCTAssertTrue(window.debugSettingsWindowSnapshot == .init(
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
        XCTAssertTrue(stored.wrapsEditorLines == false)
        XCTAssertTrue(stored.editorFontSize == 19)
        XCTAssertTrue(stored.editorTabWidth == 6)
        XCTAssertTrue(stored.editorIndentStyle == .tabs)
        XCTAssertTrue(stored.autosaveDelaySeconds == 9)
        XCTAssertTrue(stored.appearanceMode == .dark)

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
        XCTAssertTrue(relaunched.debugEditorWrapsLines == false)
        XCTAssertTrue(relaunched.debugEditorFontSize == 19)
        XCTAssertTrue(relaunched.debugEditorTabWidth == 6)
        XCTAssertTrue(relaunched.debugEditorInsertsSpacesInsteadOfTabs == false)
        XCTAssertTrue(relaunched.debugAutosaveDelaySeconds == 9)
        XCTAssertTrue(relaunched.debugAppearanceMode == .dark)
    }

    @MainActor func test_main_window_updating_preferences_persists_and_applies_them_at_runtime() throws {
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

        XCTAssertTrue(window.debugEditorWrapsLines == false)
        XCTAssertTrue(window.debugEditorFontSize == 17)
        XCTAssertTrue(window.debugEditorTabWidth == 8)
        XCTAssertTrue(window.debugEditorInsertsSpacesInsteadOfTabs == false)
        XCTAssertTrue(window.debugAutosaveDelaySeconds == 7)
        XCTAssertTrue(window.debugAppearanceMode == .light)
        XCTAssertNil(window.debugSettingsWindowSnapshot)
        XCTAssertTrue(StyleManager.default.colorScheme == .forceLight)

        let stored = try settingsStore.load()
        XCTAssertTrue(stored.wrapsEditorLines == false)
        XCTAssertTrue(stored.editorFontSize == 17)
        XCTAssertTrue(stored.editorTabWidth == 8)
        XCTAssertTrue(stored.editorIndentStyle == .tabs)
        XCTAssertTrue(stored.autosaveDelaySeconds == 7)
        XCTAssertTrue(stored.appearanceMode == .light)
    }

    @MainActor func test_main_window_open_notes_folder_uses_injected_directory_opener() throws {
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

        XCTAssertTrue(openedURL.snapshot()?.standardizedFileURL == temp.standardizedFileURL)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path(), isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    @MainActor func test_main_window_open_notes_folder_menu_action_uses_injected_directory_opener() throws {
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

        XCTAssertTrue(openedURL.snapshot()?.standardizedFileURL == temp.standardizedFileURL)
    }

    func test_open_directory_in_system_file_manager_uses_default_URI_handler_first() throws {
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

        XCTAssertTrue(launchedURIs == [expectedURI])
        XCTAssertTrue(fallbackURIs.isEmpty)
    }

    func test_open_directory_in_system_file_manager_falls_back_to_XDG_open_when_default_handler_fails() throws {
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

        XCTAssertTrue(launchedURIs == [expectedURI])
        XCTAssertTrue(fallbackURIs == [expectedURI])
    }

    @MainActor func test_main_window_about_menu_action_presents_about_dialog() throws {
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

        XCTAssertTrue(window.debugHasAboutDialog)
        XCTAssertTrue(window.debugAboutDialogSnapshot == .init(
            applicationName: "Swifty Notes",
            version: "1.3.0",
            developerName: "Sergey Armodin",
            copyright: "© 2026 Sergey Armodin",
            website: "https://github.com/makoni/swifty-notes-gtk",
            issueURL: "https://github.com/makoni/swifty-notes-gtk/issues",
            comments: "A native GTK markdown notes app written in Swift using swift-adwaita.",
        ))

        window.debugCloseAboutDialog()
        XCTAssertFalse(window.debugHasAboutDialog)
    }

    @MainActor func test_main_window_about_dialog_uses_release_version_environment_when_provided() throws {
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

        XCTAssertTrue(window.debugAboutDialogSnapshot?.version == "1.2.3")

        window.debugCloseAboutDialog()
    }

    @MainActor func test_main_window_switching_between_notes_refreshes_preview() async throws {
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
        XCTAssertTrue(window.debugPreviewText.contains("Second"))
        XCTAssertTrue(window.debugPreviewText.contains("Two"))

        window.present()
        try await Task.sleep(for: .milliseconds(30))

        window.debugSelectDisplayedNote(at: 1)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(window.debugPreviewText.contains("First"))
        XCTAssertTrue(window.debugPreviewText.contains("One"))

        window.debugSelectDisplayedNote(at: 0)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(window.debugPreviewText.contains("Second"))
        XCTAssertTrue(window.debugPreviewText.contains("Two"))
    }

    @MainActor func test_main_window_sidebar_sort_control_reflects_and_changes_sort_mode() throws {
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
        XCTAssertTrue(window.debugSortMode == .newestFirst)
        XCTAssertTrue(window.debugSidebarSortSelection == 0)
        XCTAssertTrue(window.debugDisplayedNoteTitles == ["Zeta", "Alpha"])

        window.debugEmitSortButtonClicked()
        XCTAssertTrue(window.debugSortMode == .oldestFirst)
        XCTAssertTrue(window.debugSidebarSortSelection == 1)
        XCTAssertTrue(window.debugDisplayedNoteTitles == ["Alpha", "Zeta"])

        window.debugSelectSidebarSort(at: 2)

        XCTAssertTrue(window.debugSortMode == .title)
        XCTAssertTrue(window.debugSidebarSortSelection == 2)
        XCTAssertTrue(window.debugDisplayedNoteTitles == ["Alpha", "Zeta"])
    }
}
#endif
