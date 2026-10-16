#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

/// One shared setup for the preview-typography fan-out tests: an
/// `AppController` wired to a temporary settings store and one external
/// document file, with a main window and / or an open external-document
/// window. The windows never present (headless test run), which is exactly
/// the launcher seam `SwiftyNotesLauncherTests` exercises.
private struct PreviewTypographyFanOutHarness {
    let controller: AppController
    let settingsStore: AppSettingsStore
    let fileURL: URL
    let application: Application
}

@MainActor
private func makePreviewTypographyFanOutHarness(
    in temp: URL,
    withMainWindow: Bool,
    seededZoomPercent: Int = 100,
    seededLineSpacingPercent: Int = 100,
) throws -> PreviewTypographyFanOutHarness {
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

    let fileURL = temp.appendingPathComponent("external.md", isDirectory: false)
    try "# External document\n\nBody text.\n".write(to: fileURL, atomically: true, encoding: .utf8)

    // The session bus persists across tests in the shared test process, so
    // every harness registers under its own application id.
    let app = Application(id: "me.spaceinbox.swiftynotes.tests.previewtypographyfanout-\(UUID().uuidString)")
    try app.register()

    let settingsStore = AppSettingsStore(
        settingsFileURL: temp
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false),
    )
    // Persist the starting typography first so the main window and the
    // external window both come up from the same saved values.
    let notesDirectory = temp.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
    try settingsStore.save(
        AppSettings(
            customNotesDirectoryPath: notesDirectory.path,
            previewZoomPercent: seededZoomPercent,
            previewLineSpacingPercent: seededLineSpacingPercent,
        ),
    )

    let controller = AppController(
        stateStore: WorkspaceStateStore(
            stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
        ),
        appSettingsStore: settingsStore,
        allowsWindowPresentation: false,
    )
    if withMainWindow {
        controller.activate(app: app)
    }
    controller.openDocuments(at: [fileURL], application: app)

    return PreviewTypographyFanOutHarness(
        controller: controller,
        settingsStore: settingsStore,
        fileURL: fileURL,
        application: app,
    )
}

extension MainWindowActionsTests {
    @Test("An unhandled Ctrl+scroll over the preview still scrolls") @MainActor
    func unhandledCtrlScrollOverThePreviewStillScrolls() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.previewzoomunhandled")
        try app.register()

        // No window owns this preview, so nobody handles the gesture —
        // the event must be left to scroll instead of swallowed.
        let preview = MarkdownPreview()
        #expect(preview.handlePreviewZoomScroll(deltaY: -1, modifiers: 1 << 2) == false)
        #expect(preview.handlePreviewZoomScroll(deltaY: -1, modifiers: 0) == false)
    }

    @Test("Changing preview typography in settings reaches open external-document windows") @MainActor
    func changingPreviewTypographyInSettingsReachesOpenExternalDocumentWindows() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let harness = try makePreviewTypographyFanOutHarness(in: temp, withMainWindow: true)
        let main = try #require(harness.controller.debugMainWindow)
        let external = try #require(harness.controller.debugExternalDocumentWindow(for: harness.fileURL))

        #expect(external.preview.rootScroll.hasCSSClass("preview-zoom-100"))

        var settings = main.appSettings
        settings.previewZoomPercent = 150
        settings.previewLineSpacingPercent = 130
        try main.updateAppSettings(settings)

        #expect(external.preview.rootScroll.hasCSSClass("preview-zoom-150"))
        #expect(external.preview.rootScroll.hasCSSClass("preview-spacing-130"))
        #expect(try harness.settingsStore.load().previewZoomPercent == 150)
        #expect(try harness.settingsStore.load().previewLineSpacingPercent == 130)
    }

    @Test("Ctrl+scroll in an external-document window zooms every preview") @MainActor
    func ctrlScrollInAnExternalDocumentWindowZoomsEveryPreview() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let harness = try makePreviewTypographyFanOutHarness(in: temp, withMainWindow: true)
        let main = try #require(harness.controller.debugMainWindow)
        let external = try #require(harness.controller.debugExternalDocumentWindow(for: harness.fileURL))

        // A second document window, so the fan-out has to reach every open
        // preview rather than only the one the gesture landed in.
        let secondFileURL = temp.appendingPathComponent("second.md", isDirectory: false)
        try "# Second document\n\nBody text.\n".write(to: secondFileURL, atomically: true, encoding: .utf8)
        harness.controller.openDocuments(at: [secondFileURL], application: harness.application)
        let secondExternal = try #require(
            harness.controller.debugExternalDocumentWindow(for: secondFileURL),
        )

        #expect(external.preview.handlePreviewZoomScroll(deltaY: -1, modifiers: 1 << 2) == true)
        #expect(try harness.settingsStore.load().previewZoomPercent == 110)
        #expect(main.preview.rootScroll.hasCSSClass("preview-zoom-110"))
        #expect(external.preview.rootScroll.hasCSSClass("preview-zoom-110"))
        #expect(secondExternal.preview.rootScroll.hasCSSClass("preview-zoom-110"))
    }

    @Test("Opening an external document applies the persisted preview typography") @MainActor
    func openingAnExternalDocumentAppliesThePersistedPreviewTypography() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // The persisted step has to reach the window on open, not only
        // through the live fan-out.
        let harness = try makePreviewTypographyFanOutHarness(
            in: temp,
            withMainWindow: false,
            seededZoomPercent: 150,
            seededLineSpacingPercent: 130,
        )
        let external = try #require(harness.controller.debugExternalDocumentWindow(for: harness.fileURL))

        #expect(external.preview.rootScroll.hasCSSClass("preview-zoom-150"))
        #expect(external.preview.rootScroll.hasCSSClass("preview-spacing-130"))
    }

    @Test("Ctrl+scroll in an external-document window persists zoom without a main window") @MainActor
    func ctrlScrollInAnExternalDocumentWindowPersistsZoomWithoutAMainWindow() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let harness = try makePreviewTypographyFanOutHarness(in: temp, withMainWindow: false)
        let external = try #require(harness.controller.debugExternalDocumentWindow(for: harness.fileURL))

        #expect(!harness.controller.debugHasMainWindow)
        #expect(external.preview.handlePreviewZoomScroll(deltaY: -1, modifiers: 1 << 2) == true)
        #expect(try harness.settingsStore.load().previewZoomPercent == 110)
        #expect(external.preview.rootScroll.hasCSSClass("preview-zoom-110"))
    }
}
#endif
