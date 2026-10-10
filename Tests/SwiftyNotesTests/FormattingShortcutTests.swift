#if !os(macOS)
    import Adwaita
    import CAdwaita
#endif
import Foundation
@testable import SwiftyNotes
import Testing

// Keyboard accelerators for the formatting actions (#33). The pure half
// lives in `MarkdownFormattingTests` and the window half in
// `MainWindowActionsTests` so both run under the CI suite filter.

extension MarkdownFormattingTests {
    @Test("Formatting shortcuts bind the agreed accelerators")
    func formattingShortcutsBindTheAgreedAccelerators() {
        let expected: [MarkdownFormattingAction: String] = [
            .bold: "<Primary>b",
            .italic: "<Primary>i",
            .link: "<Primary>k",
            .code: "<Primary>e",
            .quote: "<Primary><Shift>q",
            .bulletList: "<Primary><Shift>l",
            .numberedList: "<Primary><Shift>o",
        ]
        for action in MarkdownFormattingAction.allCases {
            #expect(action.accelerator == expected[action], "accelerator for \(action)")
        }
    }

    @Test("Formatting shortcut action names are stable and unique")
    func formattingShortcutActionNamesAreStableAndUnique() {
        let expected: [MarkdownFormattingAction: String] = [
            .heading: "format-heading",
            .bold: "format-bold",
            .italic: "format-italic",
            .code: "format-code",
            .link: "format-link",
            .quote: "format-quote",
            .bulletList: "format-bullet-list",
            .numberedList: "format-numbered-list",
            .taskList: "format-task-list",
            .table: "format-table",
        ]
        for action in MarkdownFormattingAction.allCases {
            #expect(action.shortcutActionName == expected[action], "action name for \(action)")
        }
        let names = MarkdownFormattingAction.allCases.map(\.shortcutActionName)
        #expect(Set(names).count == names.count)
    }

    @Test("Formatting accelerators leave the existing app and window accelerators alone")
    func formattingAcceleratorsLeaveTheExistingAppAcceleratorsAlone() {
        let existing: Set = [
            // App-level (SwiftyNotesLauncher).
            "F9", "<Primary>g", "<Primary>f", "<Primary>h", "<Primary>q",
            // Window-level (MainWindow / ExternalDocumentWindow).
            "<Primary>n", "<Primary>s", "<Primary>o",
            "<Primary><Shift>f", "<Primary><Shift>s", "<Primary><Shift>d",
        ]
        let accelerators = MarkdownFormattingAction.allCases.compactMap(\.accelerator)
        #expect(Set(accelerators).count == accelerators.count)
        #expect(Set(accelerators).isDisjoint(with: existing))
    }

    /// GTK matches `<Shift>` accelerators against the shifted keyval, so
    /// `<Primary><Shift>8` never fires: the key press arrives as `asterisk`
    /// on a US layout and as something else elsewhere. A letter's shifted
    /// keyval is its upper case on every layout, which GTK accounts for.
    @Test("Formatting accelerators press a letter key")
    func formattingAcceleratorsPressALetterKey() {
        for accelerator in MarkdownFormattingAction.allCases.compactMap(\.accelerator) {
            let key = accelerator.split(separator: ">").last.map(String.init) ?? accelerator
            #expect(key.count == 1 && key.allSatisfy { $0.isASCII && $0.isLowercase }, "\(accelerator) ends in a letter")
        }
    }
}

#if !os(macOS)
    extension MainWindowActionsTests {
        @Test("Formatting shortcut actions are registered on the application with their accelerators") @MainActor
        func formattingShortcutActionsAreRegisteredWithTheirAccelerators() throws {
            let app = Application(id: "me.spaceinbox.swiftynotes.tests.formattingshortcuts")
            try app.register()

            SwiftyNotesLauncher.installFormattingActions(on: app, controller: AppController())

            for action in MarkdownFormattingAction.allCases {
                let name = action.shortcutActionName
                #expect(
                    g_action_map_lookup_action(OpaquePointer(app.gtkApplicationPointer), name) != nil,
                    "app.\(name) is registered",
                )

                let registered = registeredAccelerators(app, "app.\(name)").compactMap(parsedAccelerator)
                let wanted = [action.accelerator].compactMap { $0 }.compactMap(parsedAccelerator)
                #expect(registered.count == wanted.count, "accelerator count for app.\(name)")
                #expect(zip(registered, wanted).allSatisfy { $0 == $1 }, "accelerator for app.\(name)")
            }
        }

        @Test("Every formatting accelerator is a string GTK can parse") @MainActor
        func everyFormattingAcceleratorIsAStringGTKCanParse() {
            for accelerator in MarkdownFormattingAction.allCases.compactMap(\.accelerator) {
                #expect(parsedAccelerator(accelerator) != nil, "\(accelerator) parses")
            }
        }

        @Test("Formatting shortcut formats the selection in the main window") @MainActor
        func formattingShortcutFormatsTheSelectionInTheMainWindow() throws {
            let (window, temp) = try makeFormattingShortcutMainWindow(id: "formattingshortcut.main")
            defer { try? FileManager.default.removeItem(at: temp) }

            window.debugSetEditorText("Hello world")
            window.debugSelectEditorRange(6 ..< 11)
            window.performFormattingShortcut(.bold)

            #expect(window.debugEditorText == "Hello **world**")
        }

        @Test("Formatting shortcut does nothing while the main window shows only the preview") @MainActor
        func formattingShortcutDoesNothingInMainWindowPreviewMode() throws {
            let (window, temp) = try makeFormattingShortcutMainWindow(id: "formattingshortcut.mainpreview")
            defer { try? FileManager.default.removeItem(at: temp) }

            window.debugSetEditorText("Hello world")
            window.debugSelectEditorRange(6 ..< 11)
            window.debugSelectViewMode(.preview)
            #expect(window.debugViewMode == .preview)

            window.performFormattingShortcut(.bold)

            #expect(window.debugEditorText == "Hello world")
        }

        @Test("Formatting shortcut formats the selection in a standalone document window") @MainActor
        func formattingShortcutFormatsTheSelectionInAStandaloneDocumentWindow() throws {
            let (window, temp) = try makeFormattingShortcutExternalWindow(id: "formattingshortcut.external")
            defer { try? FileManager.default.removeItem(at: temp) }

            window.debugSetEditorText("Hello world")
            window.debugSelectEditorRange(6 ..< 11)
            window.performFormattingShortcut(.bold)

            #expect(window.debugEditorText == "Hello **world**")
        }

        @Test("Formatting shortcut does nothing while a standalone document window shows only the preview") @MainActor
        func formattingShortcutDoesNothingInStandaloneWindowPreviewMode() throws {
            let (window, temp) = try makeFormattingShortcutExternalWindow(id: "formattingshortcut.externalpreview")
            defer { try? FileManager.default.removeItem(at: temp) }

            window.debugSetEditorText("Hello world")
            window.debugSelectEditorRange(6 ..< 11)
            window.debugSetViewMode(.preview)
            #expect(window.debugViewMode == .preview)

            window.performFormattingShortcut(.bold)

            #expect(window.debugEditorText == "Hello world")
        }

        // MARK: - Helpers

        @MainActor
        private func makeFormattingShortcutMainWindow(id: String) throws -> (MainWindow, URL) {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let repository = NotesRepository(notesDirectory: temp)
            let note = Note(
                id: UUID(),
                filename: "note.md",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100),
                content: "Hello world",
            )
            _ = try repository.save(note: note)

            let app = Application(id: "me.spaceinbox.swiftynotes.tests.\(id)")
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
            window.present()
            return (window, temp)
        }

        @MainActor
        private func makeFormattingShortcutExternalWindow(id: String) throws -> (ExternalDocumentWindow, URL) {
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
                autosaveDelay: .milliseconds(40),
            )
            window.present()
            return (window, temp)
        }

        @MainActor
        private func registeredAccelerators(_ app: Application, _ detailedActionName: String) -> [String] {
            guard let list = gtk_application_get_accels_for_action(app.gtkApplicationPointer, detailedActionName) else {
                return []
            }
            defer { g_strfreev(list) }
            var result: [String] = []
            var index = 0
            while let entry = list[index] {
                result.append(String(cString: entry))
                index += 1
            }
            return result
        }
    }

    /// GTK normalises accelerators when it stores them (`<Primary>` comes
    /// back as `<Control>`), so compare parsed key + modifiers, not strings.
    private struct ParsedAccelerator: Equatable {
        let key: UInt32
        let modifiers: UInt32
    }

    private func parsedAccelerator(_ accelerator: String) -> ParsedAccelerator? {
        var key: guint = 0
        var modifiers = GdkModifierType(rawValue: 0)
        guard gtk_accelerator_parse(accelerator, &key, &modifiers) != 0, key != 0 else { return nil }
        return ParsedAccelerator(key: key, modifiers: modifiers.rawValue)
    }
#endif
