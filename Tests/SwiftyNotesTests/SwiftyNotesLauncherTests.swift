import Adwaita
import Foundation
import Testing
@testable import SwiftyNotes

struct SwiftyNotesLauncherTests {
    @Test @MainActor
    func appControllerOpenDocumentsCreatesExternalWindowsWithoutMainWindow() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let firstURL = temp.appendingPathComponent("first.md", isDirectory: false)
        let secondURL = temp.appendingPathComponent("second.md", isDirectory: false)
        try "# First\n".write(to: firstURL, atomically: true, encoding: .utf8)
        try "# Second\n".write(to: secondURL, atomically: true, encoding: .utf8)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.desktop-open")
        try app.register()

        let controller = AppController(
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            appSettingsStore: AppSettingsStore(
                settingsFileURL: temp
                    .appendingPathComponent("config", isDirectory: true)
                    .appendingPathComponent("settings.json", isDirectory: false)
            )
        )

        controller.openDocuments(at: [firstURL, secondURL], application: app)

        #expect(!controller.debugHasMainWindow)
        #expect(controller.debugExternalDocumentFileURLs == [
            firstURL.standardizedFileURL,
            secondURL.standardizedFileURL
        ])
    }

    @Test @MainActor
    func appControllerOpenDocumentsReusesExistingExternalWindowForSameFile() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let fileURL = temp.appendingPathComponent("reused.md", isDirectory: false)
        try "# Reused\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.desktop-open-reuse")
        try app.register()

        let controller = AppController(
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false)
            ),
            appSettingsStore: AppSettingsStore(
                settingsFileURL: temp
                    .appendingPathComponent("config", isDirectory: true)
                    .appendingPathComponent("settings.json", isDirectory: false)
            )
        )

        controller.openDocuments(at: [fileURL], application: app)
        let firstWindowID = controller.debugExternalWindowIdentifier(for: fileURL)

        controller.openDocuments(at: [fileURL], application: app)
        let secondWindowID = controller.debugExternalWindowIdentifier(for: fileURL)

        #expect(controller.debugExternalDocumentFileURLs == [fileURL.standardizedFileURL])
        #expect(firstWindowID != nil)
        #expect(firstWindowID == secondWindowID)
    }
}
