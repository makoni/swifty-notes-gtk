#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

struct SwiftyNotesLauncherTests {
    @Test("App controller open documents creates external windows without main window") @MainActor
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
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            appSettingsStore: AppSettingsStore(
                settingsFileURL: temp
                    .appendingPathComponent("config", isDirectory: true)
                    .appendingPathComponent("settings.json", isDirectory: false),
            ),
            allowsWindowPresentation: false,
        )

        controller.openDocuments(at: [firstURL, secondURL], application: app)

        #expect(!controller.debugHasMainWindow)
        #expect(controller.debugExternalDocumentFileURLs == [
            firstURL.standardizedFileURL,
            secondURL.standardizedFileURL,
        ])
    }

    @Test("Application id falls back to AppIdentity outside override")
    func applicationIdFallsBackToAppIdentityOutsideOverride() {
        let resolved = SwiftyNotesLauncher.resolveApplicationID(
            override: nil,
            env: ["PATH": "/usr/bin"],
        )
        #expect(resolved == AppIdentity.identifier)
    }

    @Test("Application id honors SWIFTY_NOTES_APP_ID override regardless of snap environment")
    func applicationIdHonorsSWIFTYNOTESAPPIDOverrideRegardlessOfSnapEnvironment() {
        let resolved = SwiftyNotesLauncher.resolveApplicationID(
            override: "me.example.custom",
            env: [
                "SNAP_INSTANCE_NAME": "swifty-notes",
                "SNAP_NAME": "swifty-notes",
            ],
        )
        #expect(resolved == "me.example.custom")
    }

    @Test("Application id stays canonical even under snap environment")
    func applicationIdStaysCanonicalEvenUnderSnapEnvironment() {
        let resolved = SwiftyNotesLauncher.resolveApplicationID(
            override: nil,
            env: [
                "SNAP_INSTANCE_NAME": "swifty-notes",
                "SNAP_NAME": "swifty-notes",
            ],
        )
        #expect(resolved == AppIdentity.identifier)
    }

    @Test("Application id ignores empty whitespace override")
    func applicationIdIgnoresEmptyWhitespaceOverride() {
        let resolved = SwiftyNotesLauncher.resolveApplicationID(
            override: "   ",
            env: [:],
        )
        #expect(resolved == AppIdentity.identifier)
    }

    @Test("Application flags default to handlesOpen outside a snap environment")
    func applicationFlagsDefaultToHandlesOpenOutsideASnapEnvironment() {
        let flags = SwiftyNotesLauncher.resolveApplicationFlags(env: ["PATH": "/usr/bin"])
        #expect(flags == .handlesOpen)
    }

    @Test("Application flags add nonUnique under strict-confined snap to skip session-bus binding")
    func applicationFlagsAddNonUniqueUnderStrictConfinedSnapToSkipSessionBus() {
        let flags = SwiftyNotesLauncher.resolveApplicationFlags(env: [
            "SNAP": "/snap/swifty-notes/current",
            "SNAP_NAME": "swifty-notes",
            "SNAP_INSTANCE_NAME": "swifty-notes",
        ])
        #expect(flags.contains(.handlesOpen))
        #expect(flags.contains(.nonUnique))
    }

    @Test("Application flags add nonUnique even when only SNAP env is set")
    func applicationFlagsAddNonUniqueEvenWhenOnlySNAPEnvIsSet() {
        let flags = SwiftyNotesLauncher.resolveApplicationFlags(env: [
            "SNAP": "/snap/swifty-notes/current",
        ])
        #expect(flags.contains(.nonUnique))
    }

    @Test("App controller open documents reuses existing external window for same file") @MainActor
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
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            appSettingsStore: AppSettingsStore(
                settingsFileURL: temp
                    .appendingPathComponent("config", isDirectory: true)
                    .appendingPathComponent("settings.json", isDirectory: false),
            ),
            allowsWindowPresentation: false,
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
#endif
