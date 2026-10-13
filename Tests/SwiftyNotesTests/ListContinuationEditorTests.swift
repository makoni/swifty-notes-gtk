#if !os(macOS)
    import Adwaita
    import Foundation
    @testable import SwiftyNotes
    import Testing

    // Return / Shift+Return continuation wired to the editor's Return key
    // (GitHub issue #34, part 2). The pure transform half lives in
    // `MarkdownListContinuationTests`; this drives the window-level
    // `handleReturn` through the same debug helpers the formatting-shortcut
    // tests use. The tests are added to `MainWindowActionsTests` so they run
    // under the CI suite filter.
    //
    // Scope note: these tests exercise `handleReturn` (the transform + edit
    // application). The capture-phase key controller in `MarkdownEditor.init` —
    // its Return keyval check, IME filter call, and modifier masking — can only
    // be driven by a real key event, so it is covered at the black-box level
    // (Wayland) rather than here.
    extension MainWindowActionsTests {
        @Test("Return continues a list in the main window's editor") @MainActor
        func returnContinuesAListInTheMainWindowEditor() throws {
            let (window, temp) = try makeListContinuationMainWindow(id: "listcontinuation.main")
            defer { try? FileManager.default.removeItem(at: temp) }

            window.debugSetEditorText("- one")
            window.debugSelectEditorRange(5 ..< 5)

            #expect(window.debugPressReturn() == true)
            #expect(window.debugEditorText == "- one\n- ")
            #expect(window.debugEditorCaret == 8)
        }

        @Test("Return on a plain line falls through to GTK") @MainActor
        func returnOnAPlainLineFallsThroughToGTK() throws {
            let (window, temp) = try makeListContinuationMainWindow(id: "listcontinuation.plain")
            defer { try? FileManager.default.removeItem(at: temp) }

            window.debugSetEditorText("plain")
            window.debugSelectEditorRange(5 ..< 5)

            #expect(window.debugPressReturn() == false)
            #expect(window.debugEditorText == "plain")
            #expect(window.debugEditorCaret == 5)
        }

        @Test("Return in an empty document falls through to GTK") @MainActor
        func returnInAnEmptyDocumentFallsThroughToGTK() throws {
            let (window, temp) = try makeListContinuationMainWindow(id: "listcontinuation.empty")
            defer { try? FileManager.default.removeItem(at: temp) }

            window.debugSetEditorText("")
            window.debugSelectEditorRange(0 ..< 0)

            #expect(window.debugPressReturn() == false)
            #expect(window.debugEditorText == "")
            #expect(window.debugEditorCaret == 0)
        }

        @Test("Shift+Return keeps typing inside the item") @MainActor
        func shiftReturnKeepsTypingInsideTheItem() throws {
            let (window, temp) = try makeListContinuationMainWindow(id: "listcontinuation.soft")
            defer { try? FileManager.default.removeItem(at: temp) }

            window.debugSetEditorText("1. one")
            window.debugSelectEditorRange(6 ..< 6)

            #expect(window.debugPressReturn(softBreak: true) == true)
            #expect(window.debugEditorText == "1. one\n   ")
            #expect(window.debugEditorCaret == 10)
        }

        @Test("Continuing a list is a single undo step") @MainActor
        func continuingAListIsASingleUndoStep() throws {
            let (window, temp) = try makeListContinuationMainWindow(id: "listcontinuation.undo")
            defer { try? FileManager.default.removeItem(at: temp) }

            window.debugSetEditorText("- one")
            window.debugSelectEditorRange(5 ..< 5)

            #expect(window.debugPressReturn() == true)
            #expect(window.debugEditorText == "- one\n- ")

            // `handleReturn` wraps the delete+insert in one user action, so a
            // single undo must revert the whole continuation, not half of it.
            window.editor.buffer.undo()

            #expect(window.debugEditorText == "- one")
        }

        @Test("Return continues a list in a standalone document window") @MainActor
        func returnContinuesAListInAStandaloneDocumentWindow() throws {
            let (window, temp) = try makeListContinuationExternalWindow(id: "listcontinuation.external")
            defer { try? FileManager.default.removeItem(at: temp) }

            window.debugSetEditorText("- one")
            window.debugSelectEditorRange(5 ..< 5)

            #expect(window.debugPressReturn() == true)
            #expect(window.debugEditorText == "- one\n- ")
            #expect(window.debugEditorCaret == 8)
        }

        // MARK: - Helpers

        @MainActor
        private func makeListContinuationMainWindow(id: String) throws -> (MainWindow, URL) {
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
        private func makeListContinuationExternalWindow(id: String) throws -> (ExternalDocumentWindow, URL) {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let fileURL = temp.appendingPathComponent("Opened.md", isDirectory: false)
            try "- one".write(to: fileURL, atomically: true, encoding: .utf8)

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
    }
#endif
