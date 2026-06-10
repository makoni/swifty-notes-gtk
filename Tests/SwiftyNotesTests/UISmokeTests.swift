import Foundation
@testable import SwiftyNotes
import Testing

struct UISmokeTests {
    @Test("App launches under headless wayland with accessible window and seeded controls")
    func appLaunchesUnderHeadlessWaylandWithAccessibleWindowAndSeededControls() throws {
        let result = try runWaylandUIScript("""
        frame = wait_for_frame()
        require_named(frame, "Hide Notes Sidebar")
        require_named(frame, "New Note")
        require_named(frame, "Save Note")
        require_named(frame, "Delete Note")
        require_named(frame, "Editor")
        require_named(frame, "Split")
        require_named(frame, "Preview")
        require_named(frame, "Markdown Showcase")
        require_named(frame, "About Swifty Notes")
        require_named(frame, "Using Swifty Notes CLI")
        require_named(frame, "Notes (3)")
        assert any(
            "A screenshot-ready note that shows off the native preview, spacing, and typography." in name
            for name in visible_names(frame)
        ), visible_names(frame)

        wait_until(lambda: os.path.isdir(NOTES_DIR), "notes dir created")
        # Default seed places explanatory guides under a "Guides"
        # sub-folder, so walk recursively to pick up note.md files
        # nested one level deep too.
        def collect_seeded_notes():
            paths = []
            for root, dirs, files in os.walk(NOTES_DIR):
                if ".trash" in dirs:
                    dirs.remove(".trash")
                if "note.md" in files:
                    paths.append(os.path.join(root, "note.md"))
            return sorted(paths) or None
        note_files = wait_until(collect_seeded_notes, "seeded note files written")
        assert len(note_files) == 3, note_files
        contents = [open(path, "r", encoding="utf-8").read() for path in note_files]
        assert any("Markdown Showcase" in content for content in contents)
        assert any("About Swifty Notes" in content for content in contents)
        assert any("Using Swifty Notes CLI" in content for content in contents)
        # The two guide notes live in the Guides folder, the showcase
        # stays at root — assert the layout so a regression that flat-
        # tens the seed surfaces immediately.
        assert any("/Guides/" in path for path in note_files), note_files
        assert sum(1 for path in note_files if "/Guides/" in path) == 2, note_files
        """)
        expectUIScriptSucceeded(result)
    }

    @Test("App restores workspace state under headless wayland")
    func appRestoresWorkspaceStateUnderHeadlessWayland() throws {
        let result = try runWaylandUIScript(
            """
            frame = wait_for_frame()
            require_named(frame, "Hide Notes Sidebar")
            require_named(frame, "Editor")
            require_named(frame, "Split")
            require_named(frame, "Preview")
            require_named(frame, "Sort Notes by Title")
            require_named(frame, "Alpha")
            assert find_named(frame, "Beta") is None, visible_names(frame)

            assert os.path.isdir(NOTES_DIR), NOTES_DIR
            note_dirs = sorted(
                name for name in os.listdir(NOTES_DIR)
                if os.path.isdir(os.path.join(NOTES_DIR, name))
                and os.path.isfile(os.path.join(NOTES_DIR, name, "note.md"))
            )
            assert len(note_dirs) == 2, note_dirs
            """,
            prepare: { xdgDataHome, xdgStateHome in
                let notesDirectory = xdgDataHome
                    .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
                    .appendingPathComponent("notes", isDirectory: true)
                let repository = NotesRepository(notesDirectory: notesDirectory)
                let alpha = try repository.createNote(initialContent: "# Alpha\n\nFirst")
                _ = try repository.createNote(initialContent: "# Beta\n\nSecond")

                let stateFileURL = xdgStateHome
                    .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
                    .appendingPathComponent("workspace.json", isDirectory: false)
                let stateStore = WorkspaceStateStore(stateFileURL: stateFileURL)
                try stateStore.save(WorkspaceState(
                    selectedNoteID: alpha.id,
                    isSidebarVisible: true,
                    isPreviewVisible: false,
                    searchQuery: "Alpha",
                    sortMode: .title,
                    windowWidth: 1200,
                    windowHeight: 800,
                    previewWidth: 560,
                ))
            },
        )
        expectUIScriptSucceeded(result)
    }

    @Test("App editing does not emit snapshot warnings under headless wayland")
    func appEditingDoesNotEmitSnapshotWarningsUnderHeadlessWayland() throws {
        let result = try runWaylandUIScript(
            """
            frame = wait_for_frame()
            require_named(frame, "Markdown Editor")
            app_stderr_log = os.environ["APP_STDERR_LOG"]
            wait_until(
                lambda: "Smoke edit from launch hook" in open(app_stderr_log, "r", encoding="utf-8").read(),
                "launch edit settles",
                timeout=5
            )
            time.sleep(2)
            stderr = open(app_stderr_log, "r", encoding="utf-8").read()
            assert "Trying to snapshot" not in stderr, stderr
            """,
            environment: [
                "SWIFTY_NOTES_DEBUG_APPEND_TEXT_ON_LAUNCH": "Smoke edit from launch hook",
            ],
        )
        expectUIScriptSucceeded(result)
    }

    @Test("App autosave clears unsaved status under headless wayland")
    func appAutosaveClearsUnsavedStatusUnderHeadlessWayland() throws {
        let result = try runWaylandUIScript(
            """
            frame = wait_for_frame()
            app_stderr_log = os.environ["APP_STDERR_LOG"]
            wait_until(lambda: os.path.isdir(NOTES_DIR), "notes dir created")
            note_dirs = wait_until(
                lambda: sorted(
                    name for name in os.listdir(NOTES_DIR)
                    if os.path.isdir(os.path.join(NOTES_DIR, name))
                    and os.path.isfile(os.path.join(NOTES_DIR, name, "note.md"))
                ) or None,
                "note directory created"
            )
            wait_until(
                lambda: any(
                    "Smoke autosave edit" in open(
                        os.path.join(NOTES_DIR, note_dir, "note.md"),
                        "r",
                        encoding="utf-8"
                    ).read()
                    for note_dir in note_dirs
                ),
                "autosave writes note content",
                timeout=15
            )
            subtitle_log = wait_until(
                lambda: next(
                    (
                        line.strip()
                        for line in open(app_stderr_log, "r", encoding="utf-8").read().splitlines()
                        if line.startswith("SwiftyNotes debug header subtitle:")
                    ),
                    None
                ),
                "header subtitle logged",
                timeout=15
            )
            assert "Saved" in subtitle_log, subtitle_log
            assert "Unsaved changes" not in subtitle_log, subtitle_log
            """,
            environment: [
                "SWIFTY_NOTES_DEBUG_APPEND_TEXT_ON_LAUNCH": "Smoke autosave edit",
                "SWIFTY_NOTES_DEBUG_EDIT_DELAY_MS": "200",
                "SWIFTY_NOTES_DEBUG_LOG_HEADER_SUBTITLE_DELAY_MS": "3200",
            ],
        )
        expectUIScriptSucceeded(result)
    }

    @Test("App creating note does not emit snapshot warnings under headless wayland")
    func appCreatingNoteDoesNotEmitSnapshotWarningsUnderHeadlessWayland() throws {
        let result = try runWaylandUIScript(
            """
            frame = wait_for_frame()
            require_named(frame, "New Note")
            wait_until(
                lambda: find_named(frame, "Notes (4)") is not None,
                "created note appears",
                timeout=5
            )
            app_stderr_log = os.environ["APP_STDERR_LOG"]
            time.sleep(1)
            stderr = open(app_stderr_log, "r", encoding="utf-8").read()
            assert "Trying to snapshot" not in stderr, stderr
            """,
            environment: [
                "SWIFTY_NOTES_DEBUG_CREATE_NOTE_ON_LAUNCH": "1",
            ],
        )
        expectUIScriptSucceeded(result)
    }

    @Test("App switching notes does not emit snapshot warnings under headless wayland")
    func appSwitchingNotesDoesNotEmitSnapshotWarningsUnderHeadlessWayland() throws {
        let result = try runWaylandUIScript(
            """
            app_stderr_log = os.environ["APP_STDERR_LOG"]
            wait_until(
                lambda: "SwiftyNotes debug launch select note: 1" in open(app_stderr_log, "r", encoding="utf-8").read(),
                "launch selection settles",
                timeout=5
            )
            time.sleep(1)
            stderr = open(app_stderr_log, "r", encoding="utf-8").read()
            assert "Trying to snapshot" not in stderr, stderr
            """,
            prepare: { xdgDataHome, _ in
                let notesDirectory = xdgDataHome
                    .appendingPathComponent(AppIdentity.identifier, isDirectory: true)
                    .appendingPathComponent("notes", isDirectory: true)
                let repository = NotesRepository(notesDirectory: notesDirectory)
                _ = try repository.createNote(initialContent: "# Alpha\n\nFirst")
                _ = try repository.createNote(initialContent: "# Beta\n\nSecond")
            },
            environment: [
                "SWIFTY_NOTES_DEBUG_SELECT_NOTE_INDEX_ON_LAUNCH": "1",
            ],
            requiresAccessibility: false,
        )
        expectUIScriptSucceeded(result)
    }

    @Test("App can run launch scroll sweep and quit under headless wayland")
    func appCanRunLaunchScrollSweepAndQuitUnderHeadlessWayland() throws {
        let result = try runWaylandUIScript(
            """
            app_stderr_log = os.environ["APP_STDERR_LOG"]

            start_log = wait_until(
                lambda: next(
                    (
                        line.strip()
                        for line in open(app_stderr_log, "r", encoding="utf-8").read().splitlines()
                        if line.startswith("SwiftyNotes debug scroll sweep starting:")
                    ),
                    None
                ),
                "scroll sweep starts",
                timeout=15
            )
            complete_log = wait_until(
                lambda: next(
                    (
                        line.strip()
                        for line in open(app_stderr_log, "r", encoding="utf-8").read().splitlines()
                        if line.startswith("SwiftyNotes debug scroll sweep completed:")
                    ),
                    None
                ),
                "scroll sweep completes",
                timeout=20
            )
            assert "maxScroll=" in start_log, start_log
            assert "steps=" in complete_log, complete_log

            def app_has_exited():
                try:
                    os.kill(TARGET_PID, 0)
                    return None
                except OSError:
                    return True

            wait_until(app_has_exited, "app exits after scroll sweep", timeout=10)
            stderr = open(app_stderr_log, "r", encoding="utf-8").read()
            assert "Trying to snapshot" not in stderr, stderr
            """,
            environment: [
                "SWIFTY_NOTES_DEBUG_SCROLL_SWEEP_ON_LAUNCH": "1",
                "SWIFTY_NOTES_DEBUG_SCROLL_DELAY_MS": "300",
                "SWIFTY_NOTES_DEBUG_SCROLL_DURATION_MS": "1500",
                "SWIFTY_NOTES_DEBUG_SCROLL_STEP_MS": "20",
                "SWIFTY_NOTES_DEBUG_QUIT_AFTER_SCROLL": "1",
            ],
            requiresAccessibility: false,
        )
        expectUIScriptSucceeded(result)
    }

    @Test("Settings window opens under headless wayland and shows controls")
    func settingsWindowOpensUnderHeadlessWaylandAndShowsControls() throws {
        let result = try runWaylandUIScript(
            """
            def wait_for_named_frame(name):
                def locate():
                    desktop = pyatspi.Registry.getDesktop(0)
                    for index in range(desktop.childCount):
                        app = desktop.getChildAtIndex(index)
                        if (app.name or "").lower() != "swiftynotes":
                            continue
                        if process_id(app) != TARGET_PID:
                            continue
                        for child_index in range(app.childCount):
                            candidate = app.getChildAtIndex(child_index)
                            if candidate.getRoleName() == "frame" and (candidate.name or "") == name:
                                return candidate
                    return None
                return wait_until(locate, f"{name} frame appears", timeout=40)

            wait_for_frame()
            settings_frame = wait_for_named_frame("Settings")
            require_named(settings_frame, "Notes folder")
            require_named(settings_frame, "Wrap long lines")
            require_named(settings_frame, "Editor")
            require_named(settings_frame, "Indent style")
            require_named(settings_frame, "Saving")
            require_named(settings_frame, "Appearance")
            """,
            environment: [
                "SWIFTY_NOTES_DEBUG_OPEN_SETTINGS_ON_LAUNCH": "1",
            ],
        )
        expectUIScriptSucceeded(result)
    }
}

private struct UIScriptResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private func runUIScript(
    _ script: String,
    environment: [String: String],
) throws -> UIScriptResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/timeout", isDirectory: false)
    process.arguments = ["45s", "bash", "-lc", script]
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let stdoutURL = tempDirectory.appendingPathComponent("stdout.log", isDirectory: false)
    let stderrURL = tempDirectory.appendingPathComponent("stderr.log", isDirectory: false)
    _ = FileManager.default.createFile(atPath: stdoutURL.path(), contents: nil)
    _ = FileManager.default.createFile(atPath: stderrURL.path(), contents: nil)
    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
    let stderrHandle = try FileHandle(forWritingTo: stderrURL)
    defer {
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }

    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle

    try process.run()
    process.waitUntilExit()

    try? stdoutHandle.synchronize()
    try? stderrHandle.synchronize()
    let stdoutData = (try? Data(contentsOf: stdoutURL)) ?? Data()
    let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()

    return UIScriptResult(
        exitCode: process.terminationStatus,
        stdout: String(decoding: stdoutData, as: UTF8.self),
        stderr: String(decoding: stderrData, as: UTF8.self),
    )
}

private func runWaylandUIScript(
    _ pythonScript: String,
    prepare: ((URL, URL) throws -> Void)? = nil,
    environment: [String: String] = [:],
    requiresAccessibility: Bool = true,
) throws -> UIScriptResult {
    guard ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"] != nil else {
        return UIScriptResult(exitCode: 0, stdout: "", stderr: "")
    }
    guard isExecutableAvailable("weston") else {
        return UIScriptResult(exitCode: 0, stdout: "", stderr: "")
    }

    let temp = temporaryDirectory()
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let runtimeDirectory = temp.appendingPathComponent("runtime", isDirectory: true)
    let xdgDataHome = temp.appendingPathComponent("xdg-data", isDirectory: true)
    let xdgStateHome = temp.appendingPathComponent("xdg-state", isDirectory: true)
    let xdgConfigHome = temp.appendingPathComponent("xdg-config", isDirectory: true)
    let appID = "\(AppIdentity.identifier).uitests.t\(temp.lastPathComponent.replacingOccurrences(of: "-", with: "").lowercased())"
    try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: xdgDataHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: xdgStateHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: xdgConfigHome, withIntermediateDirectories: true)
    try prepare?(xdgDataHome, xdgStateHome)

    let accessibilityEnvironment: String
    let pythonImport: String
    if requiresAccessibility {
        accessibilityEnvironment = """
        export NO_AT_BRIDGE=0
        export GTK_A11Y=atspi
        """
        pythonImport = "import pyatspi"
    } else {
        accessibilityEnvironment = """
        export NO_AT_BRIDGE=1
        unset GTK_A11Y || true
        """
        pythonImport = ""
    }

    let script = """
    set -euo pipefail
    \(accessibilityEnvironment)
    export GDK_BACKEND=wayland
    export XDG_RUNTIME_DIR="$TEST_RUNTIME_DIR"
    export WAYLAND_DISPLAY="swifty-notes-test-wayland"
    export XDG_DATA_HOME="$XDG_DATA_HOME"
    export XDG_STATE_HOME="$XDG_STATE_HOME"
    export XDG_CONFIG_HOME="$XDG_CONFIG_HOME"
    export NOTES_DIR="$XDG_DATA_HOME/\(AppIdentity.identifier)/notes"
    export SETTINGS_FILE="$XDG_CONFIG_HOME/\(AppIdentity.identifier)/settings.json"
    export APP_STDERR_LOG="$XDG_RUNTIME_DIR/app.err"
    export APP_STDOUT_LOG="$XDG_RUNTIME_DIR/app.out"
    export WESTON_STDERR_LOG="$XDG_RUNTIME_DIR/weston.err"
    export WESTON_STDOUT_LOG="$XDG_RUNTIME_DIR/weston.out"
    chmod 700 "$XDG_RUNTIME_DIR"

    weston --backend=headless --renderer=pixman --shell=desktop --socket="$WAYLAND_DISPLAY" --width=1440 --height=1024 --idle-time=0 >"$WESTON_STDOUT_LOG" 2>"$WESTON_STDERR_LOG" &
    WESTON_PID=$!
    for _ in $(seq 1 80); do
      [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && break
      sleep 0.25
    done
    if [ ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
      echo "Weston socket was not created" >&2
      cat "$WESTON_STDERR_LOG" >&2 || true
      exit 1
    fi
    "$APP" >"$APP_STDOUT_LOG" 2>"$APP_STDERR_LOG" &
    APP_PID=$!
    cleanup() {
      kill "$APP_PID" 2>/dev/null || true
      kill "$WESTON_PID" 2>/dev/null || true
      sleep 1
      kill -9 "$APP_PID" 2>/dev/null || true
      kill -9 "$WESTON_PID" 2>/dev/null || true
      wait "$APP_PID" 2>/dev/null || true
      wait "$WESTON_PID" 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM
    export APP_PID
    python3 - <<'PY'
    import os
    import time
    \(pythonImport)

    TARGET_PID = int(os.environ["APP_PID"])
    NOTES_DIR = os.environ["NOTES_DIR"]
    SETTINGS_FILE = os.environ["SETTINGS_FILE"]

    def process_id(node):
        for attribute in ("get_process_id", "getProcessId"):
            accessor = getattr(node, attribute, None)
            if callable(accessor):
                try:
                    return int(accessor())
                except Exception:
                    pass
        return None

    def walk(node):
        if node is None:
            return
        try:
            for index in range(node.childCount):
                child = node.getChildAtIndex(index)
                if child is None:
                    continue
                yield child
                yield from walk(child)
        except Exception:
            return

    def visible_names(root):
        names = []
        if root is not None and root.name:
            names.append(root.name)
        for child in walk(root):
            if child.name:
                names.append(child.name)
        return sorted(set(names))

    def wait_until(predicate, description, timeout=15):
        deadline = time.time() + timeout
        last_error = None
        while time.time() < deadline:
            try:
                value = predicate()
                if value:
                    return value
            except Exception as exc:
                last_error = exc
            time.sleep(0.25)
        if last_error is not None:
            raise AssertionError(f"{description}: {last_error}")
        raise AssertionError(description)

    def wait_for_frame():
        def locate():
            desktop = pyatspi.Registry.getDesktop(0)
            for index in range(desktop.childCount):
                app = desktop.getChildAtIndex(index)
                if (app.name or "").lower() != "swiftynotes":
                    continue
                if process_id(app) != TARGET_PID:
                    continue
                for child_index in range(app.childCount):
                    candidate = app.getChildAtIndex(child_index)
                    if candidate.getRoleName() == "frame" and (candidate.name or "") == "Swifty Notes":
                        return candidate
            return None
        return wait_until(locate, "Swifty Notes frame appears", timeout=40)

    def find_named(root, name):
        if root is None:
            return None
        if (root.name or "") == name:
            return root
        for child in walk(root):
            if (child.name or "") == name:
                return child
        return None

    def require_named(root, name):
        node = find_named(root, name)
        if node is None:
            raise AssertionError(f"Could not find '{name}'. Visible names: {visible_names(root)}")
        return node

    \(pythonScript)
    PY

    cleanup
    trap - EXIT INT TERM
    """

    return try runUIScript(
        script,
        environment: [
            "APP": swiftyNotesExecutableURL().path(),
            "SWIFTY_NOTES_APP_ID": appID,
            "TEST_RUNTIME_DIR": runtimeDirectory.path(),
            "XDG_DATA_HOME": xdgDataHome.path(),
            "XDG_STATE_HOME": xdgStateHome.path(),
            "XDG_CONFIG_HOME": xdgConfigHome.path(),
        ].merging(environment) { _, new in new },
    )
}

private func expectUIScriptSucceeded(_ result: UIScriptResult) {
    if result.exitCode != 0 {
        Issue.record("stdout:\n\(result.stdout)\nstderr:\n\(result.stderr)")
    }
    #expect(result.exitCode == 0)
}

private func isExecutableAvailable(_ name: String) -> Bool {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for directory in path.split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: candidate.path()) {
            return true
        }
    }
    return false
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func swiftyNotesExecutableURL() -> URL {
    URL(fileURLWithPath: CommandLine.arguments[0], isDirectory: false)
        .deletingLastPathComponent()
        .appendingPathComponent("swiftynotes", isDirectory: false)
}
