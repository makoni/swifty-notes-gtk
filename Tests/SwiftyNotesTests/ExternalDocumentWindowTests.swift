import Foundation
import Testing
@testable import SwiftyNotes
import Adwaita
import CAdwaita

struct ExternalDocumentWindowTests {
    @Test @MainActor
    func externalDocumentWindowLoadsMarkdownFileAndAutosavesEdits() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let fileURL = temp.appendingPathComponent("Opened.md", isDirectory: false)
        try "# Opened\n\nBody".write(to: fileURL, atomically: true, encoding: .utf8)

        let autosaveScheduler = TestMainActorScheduler()
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.externaldocument")
        try app.register()

        let window = try ExternalDocumentWindow(
            application: app,
            fileURL: fileURL,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(taskScheduler: autosaveScheduler.schedule(after:operation:)),
            autosaveDelay: .milliseconds(40)
        )

        window.present()

        #expect(window.debugViewMode == .split)
        #expect(window.debugEditorText == "# Opened\n\nBody")
        #expect(window.debugPreviewText.contains("Opened"))
        #expect(window.debugOverflowMenuSectionTitles == ["Document"])
        #expect(window.debugOverflowMenuItemsBySection == [
            "Document": [
                "Save As…",
                "Import into Library…",
                "Reveal in Folder"
            ]
        ])

        window.debugSetEditorText("# Updated\n\nSaved from external window")
        #expect(window.debugEditorModified)

        autosaveScheduler.runPendingActions()

        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "# Updated\n\nSaved from external window")
        #expect(!window.debugEditorModified)
        #expect(window.debugPreviewText.contains("Saved from external window"))
    }

    @Test @MainActor
    func externalDocumentWindowReloadsChangedFileAfterPoll() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let fileURL = temp.appendingPathComponent("Reloaded.md", isDirectory: false)
        try "# Before\n\nBody".write(to: fileURL, atomically: true, encoding: .utf8)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.externaldocumentreload")
        try app.register()

        let window = try ExternalDocumentWindow(
            application: app,
            fileURL: fileURL,
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator()
        )

        window.present()

        try "# After\n\nChanged on disk".write(to: fileURL, atomically: true, encoding: .utf8)
        window.debugPollForExternalChanges()

        #expect(window.debugEditorText == "# After\n\nChanged on disk")
        #expect(window.debugPreviewText.contains("After"))
        #expect(window.debugPreviewText.contains("Changed on disk"))
    }
}
