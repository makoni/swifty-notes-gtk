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
    // Scope note: three layers cover the editor's Return key.
    //  1. `handleReturn` (the transform + edit application) is driven through
    //     the window debug helpers, as before.
    //  2. The capture-phase controller's *decision* — the Return keyval check,
    //     the input-method filter call, and the modifier masking — lives in
    //     `MarkdownEditor.handleReturnKey`, which is unit-tested here directly
    //     against a bare `SourceBuffer` and a synthetic `inputMethodConsumes`
    //     closure (no key event needed).
    //  3. The end-to-end path — a real key press reaching the editor while the
    //     input method claims Return — is covered by the xdotool test at the
    //     bottom of this file. It runs only where an X11 display and `xdotool`
    //     are both available (the CI xvfb job) and skips cleanly elsewhere
    //     (e.g. a local Wayland session).
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

        // MARK: - handleReturnKey (the controller's decision, no key event)

        // `handleReturnKey` is the pure decision the capture-phase controller
        // makes for every key press. Drive it with a bare `SourceBuffer` and a
        // synthetic `inputMethodConsumes` so each branch is asserted without a
        // real event. Modifier values are the `GdkModifierType` bits from
        // <gdk/gdkenums.h>.

        @Test("An input method that claims Return stops the list from continuing") @MainActor
        func anInputMethodThatClaimsReturnStopsTheListFromContinuing() {
            let buffer = SourceBuffer()
            buffer.text = "- one"
            buffer.placeCursor(at: 5)

            let handled = MarkdownEditor.handleReturnKey(
                keyval: UInt32(GDK_KEY_Return),
                modifiers: 0,
                buffer: buffer,
            ) { true }

            #expect(handled == true)
            #expect(buffer.text == "- one")
        }

        @Test("Return asks the input method before anything else") @MainActor
        func returnAsksTheInputMethodBeforeAnythingElse() {
            let buffer = SourceBuffer()
            buffer.text = "- one"
            buffer.placeCursor(at: 5)

            var inputMethodCalls = 0
            let handled = MarkdownEditor.handleReturnKey(
                keyval: UInt32(GDK_KEY_Return),
                modifiers: 0,
                buffer: buffer,
            ) {
                inputMethodCalls += 1
                return false
            }
            // Return is a Return key: the input method is asked exactly once,
            // and since it did not consume the key the list still continues.
            #expect(inputMethodCalls == 1)
            #expect(handled == true)
            #expect(buffer.text == "- one\n- ")

            // A non-Return key never reaches the input method.
            let otherHandled = MarkdownEditor.handleReturnKey(
                keyval: UInt32(GDK_KEY_a),
                modifiers: 0,
                buffer: buffer,
            ) {
                inputMethodCalls += 1
                return true
            }
            #expect(inputMethodCalls == 1)
            #expect(otherHandled == false)
        }

        @Test("Return with Control, Alt or Super falls through to GTK") @MainActor
        func returnWithControlAltOrSuperFallsThroughToGTK() {
            let buffer = SourceBuffer()
            buffer.text = "- one"
            buffer.placeCursor(at: 5)

            let modifiersToCheck: [(String, UInt32)] = [
                ("control", 1 << 2),
                ("alt", 1 << 3),
                ("super", 1 << 26),
                ("meta", 1 << 28),
            ]
            for (name, modifiers) in modifiersToCheck {
                let handled = MarkdownEditor.handleReturnKey(
                    keyval: UInt32(GDK_KEY_Return),
                    modifiers: modifiers,
                    buffer: buffer,
                ) { false }
                #expect(handled == false, "expected \(name)+Return to fall through to GTK")
                #expect(buffer.text == "- one", "\(name)+Return must not change the text")
            }
        }

        @Test("Caps Lock does not stop Return from continuing a list") @MainActor
        func capsLockDoesNotStopReturnFromContinuingAList() {
            let buffer = SourceBuffer()
            buffer.text = "- one"
            buffer.placeCursor(at: 5)

            // Lock is 1 << 1.
            let handled = MarkdownEditor.handleReturnKey(
                keyval: UInt32(GDK_KEY_Return),
                modifiers: 1 << 1,
                buffer: buffer,
            ) { false }

            #expect(handled == true)
            #expect(buffer.text == "- one\n- ")
        }

        @Test("Shift+Return with Caps Lock keeps typing inside the item") @MainActor
        func shiftReturnWithCapsLockKeepsTypingInsideTheItem() {
            let buffer = SourceBuffer()
            buffer.text = "- one"
            buffer.placeCursor(at: 5)

            // Shift is 1 << 0, Lock is 1 << 1.
            let handled = MarkdownEditor.handleReturnKey(
                keyval: UInt32(GDK_KEY_Return),
                modifiers: (1 << 0) | (1 << 1),
                buffer: buffer,
            ) { false }

            #expect(handled == true)
            #expect(buffer.text == "- one\n  ")
        }

        @Test("Keypad Enter continues a list like Return") @MainActor
        func keypadEnterContinuesAListLikeReturn() {
            let buffer = SourceBuffer()
            buffer.text = "- one"
            buffer.placeCursor(at: 5)

            let handled = MarkdownEditor.handleReturnKey(
                keyval: UInt32(GDK_KEY_KP_Enter),
                modifiers: 0,
                buffer: buffer,
            ) { false }

            #expect(handled == true)
            #expect(buffer.text == "- one\n- ")
        }

        // MARK: - Real key press through a real input method (X11 + xdotool)

        // Layer 3: drive a real key event through GTK's built-in simple input
        // method. While a composition is open the Return key belongs to the
        // input method — the same situation a Japanese/Chinese IME creates —
        // so this proves the editor lets the input method have it end to end.
        //
        // Runs only where `xdotool` is on PATH *and* the session is X11 (the
        // CI xvfb job); skips cleanly on a local Wayland session (which also
        // has no xdotool). On a local *X11* session with xdotool installed it
        // will run, and `xdotool windowfocus` grabs input focus from whatever
        // you were doing and does not restore it — so do not run the suite on
        // a live X desktop without expecting that focus grab.
        @Test("Return that commits an input-method composition does not continue the list") @MainActor
        func returnThatCommitsAnInputMethodCompositionDoesNotContinueTheList() throws {
            guard let xdotool = xdotoolExecutablePath(), isX11Display else {
                // The CI core job installs xdotool and runs under xvfb-run, so
                // a skip there means the job lost one of them: fail instead of
                // passing without testing anything.
                if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" {
                    Issue.record("the input-method test needs xdotool and an X11 display on CI")
                }
                return
            }

            // Registering the Application initializes GTK, which the
            // `GtkSettings` lookup below needs.
            let (app, repository, temp) = try makeListContinuationApp(id: "listcontinuation.ime")
            defer { try? FileManager.default.removeItem(at: temp) }

            // Force GTK's built-in simple IME (which supports Ctrl+Shift+U hex
            // entry) before the window's text view is created, and restore the
            // previous value when we're done.
            guard let settingsPointer = gtk_settings_get_default() else {
                Issue.record("GTK has no default settings after the application registered")
                return
            }
            let settings = GObjectRef(borrowing: UnsafeMutableRawPointer(settingsPointer))
            var previousIMModule = settings.getProperty("gtk-im-module")
            var simpleIMModule = GValueRef("gtk-im-context-simple")
            settings.setProperty("gtk-im-module", value: &simpleIMModule)
            defer { settings.setProperty("gtk-im-module", value: &previousIMModule) }

            let window = makeMainWindow(app: app, repository: repository, temp: temp)

            // A unique title so `xdotool search --name` finds exactly this
            // window even if other test windows are still mapped.
            let title = "swifty-notes-ime-\(UUID().uuidString)"
            window.window.title = title

            window.debugSetEditorText("- one")
            window.debugSelectEditorRange(5 ..< 5)

            // Give the window time to be realized and mapped before focusing it
            // from X11.
            pumpMainContext(.milliseconds(500))
            window.debugFocusEditor()
            pumpMainContext(.milliseconds(100))

            // Focus the window, then type Ctrl+Shift+U, e, 9, Return — the
            // simple IME's hex entry for U+00E9 (é). xdotool blocks, so pump
            // the main context while it runs; GTK must keep processing the
            // events xdotool delivers. (Not `--window`: that sends synthetic
            // events GTK ignores.)
            try runXdotool(xdotool, ["search", "--sync", "--name", title, "windowfocus", "--sync"])
            try runXdotool(xdotool, ["key", "--delay", "50", "ctrl+shift+u", "e", "9", "Return"])
            pumpMainContext(.milliseconds(300))

            // The composition committed é and the list did NOT continue.
            #expect(window.debugEditorText == "- oneé")
            #expect(window.debugEditorCaret == 6)

            // A plain Return now (no composition open) must continue the list,
            // proving the keys really reached the editor.
            try runXdotool(xdotool, ["key", "Return"])
            pumpMainContext(.milliseconds(300))
            #expect(window.debugEditorText == "- oneé\n- ")
            #expect(window.debugEditorCaret == 9)
        }

        // MARK: - Helpers

        @MainActor
        private func makeListContinuationApp(id: String) throws -> (Application, NotesRepository, URL) {
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
            return (app, repository, temp)
        }

        @MainActor
        private func makeMainWindow(app: Application, repository: NotesRepository, temp: URL) -> MainWindow {
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
            return window
        }

        @MainActor
        private func makeListContinuationMainWindow(id: String) throws -> (MainWindow, URL) {
            let (app, repository, temp) = try makeListContinuationApp(id: id)
            let window = makeMainWindow(app: app, repository: repository, temp: temp)
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

        // The xdotool binary on PATH, or nil when the test must skip.
        @MainActor
        private func xdotoolExecutablePath() -> String? {
            let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
            for directory in searchPath.split(separator: ":") {
                let candidate = String(directory) + "/xdotool"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
            return nil
        }

        // True when this process is on an X11 display rather than Wayland.
        // GTK picks its backend the same way (Wayland when `WAYLAND_DISPLAY`
        // is set, else X11 when `DISPLAY` is), so this mirrors the display the
        // window actually gets.
        @MainActor
        private var isX11Display: Bool {
            let environment = ProcessInfo.processInfo.environment
            return environment["DISPLAY"] != nil && environment["WAYLAND_DISPLAY"] == nil
        }

        private struct XdotoolExit: Error, LocalizedError {
            let status: Int32
            var errorDescription: String? { "xdotool exited with status \(status)" }
        }

        // Runs an xdotool command as a child process while pumping the main
        // context, because xdotool blocks and GTK must keep processing the
        // events it delivers.
        @MainActor
        private func runXdotool(_ executable: String, _ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            try process.run()
            while process.isRunning {
                MainContext.pump(for: .milliseconds(25))
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw XdotoolExit(status: process.terminationStatus)
            }
        }

        @MainActor
        private func pumpMainContext(_ duration: Duration) {
            MainContext.pump(for: duration)
        }
    }
#endif
