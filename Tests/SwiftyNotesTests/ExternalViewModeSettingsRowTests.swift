#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

extension MainWindowActionsTests {
    @Test("The settings window offers the external-file view modes and saves the choice") @MainActor
    func settingsWindowOffersExternalFileViewModesAndSavesTheChoice() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.externalviewmodesettings")
        try app.register()

        let settingsFileURL = temp
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        let settingsStore = AppSettingsStore(settingsFileURL: settingsFileURL)
        let initialSettings = AppSettings(
            customNotesDirectoryPath: temp.path(),
            externalDocumentViewMode: .preview,
        )
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

        try LocalizationTestSupport.withRestoredLanguage {
            // English ships no catalogue: it is the msgid language, so the
            // titles read back as their source form on any host locale.
            LocalizationTestSupport.applySessionLanguage("en")

            window.present()
            window.debugActivateSettingsAction()
            #expect(window.debugHasSettingsWindow)
            try #require(
                window.debugSettingsLocalizedChrome?["externalViewModeRow"] == "Opened files start in",
            )
            #expect(
                window.debugSettingsEditorGroupRowTitles?.contains("Opened files start in") == true,
            )
            #expect(
                window.debugSettingsExternalViewModeOptions == ["Editor", "Split", "Preview"],
            )
            #expect(window.debugSettingsSelectedExternalViewMode == .preview)

            window.debugSettingsSetExternalViewMode(.editor)

            #expect(window.appSettings.externalDocumentViewMode == .editor)
            let stored = try settingsStore.load()
            #expect(stored.externalDocumentViewMode == .editor)
        }
    }
}
#endif
