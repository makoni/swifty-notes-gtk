#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

struct MainWindowOutlineTests {
    @MainActor
    private static func makeWindow(
        appID: String,
        isOutlineVisible: Bool = true,
    ) throws -> MainWindow {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = Application(id: appID)
        try app.register()
        return MainWindow(
            application: app,
            state: AppState(persistedState: WorkspaceState(isOutlineVisible: isOutlineVisible)),
            stateStore: WorkspaceStateStore(
                stateFileURL: temp.appendingPathComponent("workspace.json", isDirectory: false),
            ),
            repository: NotesRepository(notesDirectory: temp),
            renderer: MarkdownRenderer(),
            autosave: AutosaveCoordinator(),
        )
    }

    @Test @MainActor
    func `default state has the outline panel visible`() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.outline.default")
        #expect(window.debugIsOutlineVisible == true)
    }

    @Test @MainActor
    func `persisted state with the panel hidden honours that on launch`() throws {
        let window = try Self.makeWindow(
            appID: "me.spaceinbox.swiftynotes.tests.outline.hiddenstart",
            isOutlineVisible: false,
        )
        #expect(window.debugIsOutlineVisible == false)
    }

    @Test @MainActor
    func `toggle action flips visibility and mirrors it back into AppState`() throws {
        let window = try Self.makeWindow(appID: "me.spaceinbox.swiftynotes.tests.outline.toggle")
        #expect(window.debugIsOutlineVisible == true)

        window.debugToggleOutline()
        #expect(window.debugIsOutlineVisible == false)
        #expect(window.debugAppStateIsOutlineVisible == false)

        window.debugToggleOutline()
        #expect(window.debugIsOutlineVisible == true)
        #expect(window.debugAppStateIsOutlineVisible == true)
    }
}
#endif
