#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

// Default view mode for documents opened from outside the library (#35):
// the window half of the preference. The persistence half (defaults,
// round-trip, legacy payloads) lives in `SettingsStoreTests`.

extension MainWindowActionsTests {
    @Test("A file opened from outside starts in split by default") @MainActor
    func fileOpenedFromOutsideStartsInSplitByDefault() throws {
        let (window, temp) = try makeExternalViewModeWindow(id: "externalviewmode.default")
        defer { try? FileManager.default.removeItem(at: temp) }

        #expect(window.debugViewMode == .split)
    }

    @Test("A file opened from outside starts in the preferred view mode", arguments: [EditorViewMode.editor, .preview]) @MainActor
    func fileOpenedFromOutsideStartsInThePreferredViewMode(mode: EditorViewMode) throws {
        let (window, temp) = try makeExternalViewModeWindow(
            id: "externalviewmode.\(mode)",
            appSettings: AppSettings(externalDocumentViewMode: mode),
        )
        defer { try? FileManager.default.removeItem(at: temp) }

        #expect(window.debugViewMode == mode)
    }

    @Test("Changing the preference leaves an open standalone window alone") @MainActor
    func changingThePreferenceLeavesAnOpenStandaloneWindowAlone() throws {
        let (window, temp) = try makeExternalViewModeWindow(id: "externalviewmode.runtime")
        defer { try? FileManager.default.removeItem(at: temp) }

        let settingsWithPreview = AppSettings(externalDocumentViewMode: .preview)
        window.applyRuntimeSettings(settingsWithPreview, shouldRefreshPreview: false)

        #expect(window.debugViewMode == .split)
    }

    // MARK: - Helpers

    @MainActor
    private func makeExternalViewModeWindow(
        id: String,
        appSettings: AppSettings = .default,
    ) throws -> (ExternalDocumentWindow, URL) {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let fileURL = temp.appendingPathComponent("Opened.md", isDirectory: false)
        try "Hello world".write(to: fileURL, atomically: true, encoding: .utf8)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.\(id)")
        try app.register()

        let window = try ExternalDocumentWindow(
            application: app,
            fileURL: fileURL,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(taskScheduler: TestMainActorScheduler().schedule(after:operation:)),
            appSettings: appSettings,
            autosaveDelay: .milliseconds(40),
        )
        window.present()
        return (window, temp)
    }
}
#endif
