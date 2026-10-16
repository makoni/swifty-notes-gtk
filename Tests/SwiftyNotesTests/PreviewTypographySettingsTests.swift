#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

extension MainWindowActionsTests {
    @Test("Ctrl+scroll over the preview zooms it and saves the step") @MainActor
    func ctrlScrollOverThePreviewZoomsItAndSavesTheStep() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.previewzoomscroll")
        try app.register()

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

        #expect(window.appSettings.previewZoomPercent == 100)
        #expect(window.preview.previewZoomPercent == 100)

        // A plain scroll must not zoom.
        #expect(window.debugPreviewZoomScroll(deltaY: -1, modifiers: 0) == false)
        #expect(window.appSettings.previewZoomPercent == 100)
        #expect(try settingsStore.load().previewZoomPercent == 100)

        // A Ctrl+scroll step zooms the preview, the in-memory settings and
        // the persisted settings all move one step.
        #expect(window.debugPreviewZoomScroll(deltaY: -1, modifiers: 1 << 2) == true)
        #expect(window.appSettings.previewZoomPercent == 110)
        #expect(window.preview.previewZoomPercent == 110)
        #expect(try settingsStore.load().previewZoomPercent == 110)
    }

    @Test("The settings window offers the preview typography rows and saves the choices") @MainActor
    func settingsWindowOffersPreviewTypographyAndSavesTheChoices() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.previewtypographysettings")
        try app.register()

        let settingsFileURL = temp
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        let settingsStore = AppSettingsStore(settingsFileURL: settingsFileURL)
        let initialSettings = AppSettings(
            customNotesDirectoryPath: temp.path(),
            previewZoomPercent: 150,
            previewLineSpacingPercent: 130,
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
            #expect(
                window.debugSettingsPreviewGroupRowTitles?.count == 3
                    && window.debugSettingsPreviewGroupRowTitles?.contains("Render emoji shortcodes") == true
                    && window.debugSettingsPreviewGroupRowTitles?.contains("Preview zoom") == true
                    && window.debugSettingsPreviewGroupRowTitles?.contains("Line spacing") == true,
                "expected the emoji, zoom and line-spacing rows in the preview group: \(window.debugSettingsPreviewGroupRowTitles ?? [])",
            )
            try #require(
                window.debugSettingsLocalizedChrome?["previewZoomRow"] == "Preview zoom",
            )
            #expect(
                window.debugSettingsLocalizedChrome?["previewZoomSubtitle"]
                    == "Percent of the normal size. Ctrl+scroll over the preview changes it too.",
            )
            try #require(
                window.debugSettingsLocalizedChrome?["lineSpacingRow"] == "Line spacing",
            )
            #expect(
                window.debugSettingsLocalizedChrome?["lineSpacingSubtitle"]
                    == "Percent of the normal spacing between lines in the preview.",
            )
            // The rows start from the persisted values.
            #expect(window.debugSettingsPreviewZoomValue == 150)
            #expect(window.debugSettingsLineSpacingValue == 130)

            window.debugSettingsSetPreviewZoom(170)
            #expect(window.appSettings.previewZoomPercent == 170)
            #expect(try settingsStore.load().previewZoomPercent == 170)

            window.debugSettingsSetLineSpacing(120)
            #expect(window.appSettings.previewLineSpacingPercent == 120)
            #expect(try settingsStore.load().previewLineSpacingPercent == 120)

            // The rows themselves clamp off-range values before anything is
            // saved, so an out-of-range write lands on a real step.
            window.debugSettingsSetPreviewZoom(250)
            #expect(window.debugSettingsPreviewZoomValue == 200)
            #expect(try settingsStore.load().previewZoomPercent == 200)

            window.debugSettingsSetPreviewZoom(30)
            #expect(window.debugSettingsPreviewZoomValue == 50)
            #expect(try settingsStore.load().previewZoomPercent == 50)

            window.debugSettingsSetLineSpacing(300)
            #expect(window.debugSettingsLineSpacingValue == 200)
            #expect(try settingsStore.load().previewLineSpacingPercent == 200)

            window.debugSettingsSetLineSpacing(30)
            #expect(window.debugSettingsLineSpacingValue == 80)
            #expect(try settingsStore.load().previewLineSpacingPercent == 80)
        }
    }
}
#endif
