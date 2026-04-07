import Foundation
import Testing
@testable import SwiftyNotes

struct UISmokeTests {
    @Test
    func appLaunchesUnderHeadlessWaylandWithAccessibleWindowAndSeededControls() throws {
        let result = try runWaylandUIScript("""
        frame = wait_for_frame()
        require_named(frame, "Hide Notes Sidebar")
        require_named(frame, "New Note")
        require_named(frame, "Save Note")
        require_named(frame, "Delete Note")
        require_named(frame, "Hide Preview")
        require_named(frame, "Markdown Showcase")
        require_named(frame, "Notes (1)")
        require_named(frame, "Welcome to the demo note for Swifty Notes. This document shows the main Markdown features supported by the editor and preview.")

        wait_until(lambda: os.path.isdir(NOTES_DIR), "notes dir created")
        md_files = wait_until(
            lambda: sorted(name for name in os.listdir(NOTES_DIR) if name.endswith(".md")) or None,
            "seeded markdown note written"
        )
        assert len(md_files) == 1, md_files
        showcase = open(os.path.join(NOTES_DIR, md_files[0]), "r", encoding="utf-8").read()
        assert "Markdown Showcase" in showcase
        """)
        expectUIScriptSucceeded(result)
    }

    @Test
    func appRestoresWorkspaceStateUnderHeadlessWayland() throws {
        let result = try runWaylandUIScript(
            """
            frame = wait_for_frame()
            require_named(frame, "Hide Notes Sidebar")
            require_named(frame, "Show Preview")
            require_named(frame, "Sort Notes by Title")
            require_named(frame, "Alpha")
            assert find_named(frame, "Beta") is None, visible_names(frame)

            assert os.path.isdir(NOTES_DIR), NOTES_DIR
            md_files = sorted(name for name in os.listdir(NOTES_DIR) if name.endswith(".md"))
            assert len(md_files) == 2, md_files
            """,
            prepare: { xdgDataHome, xdgStateHome in
                let notesDirectory = xdgDataHome
                    .appendingPathComponent("me.spaceinbox.SwiftyNotes", isDirectory: true)
                    .appendingPathComponent("notes", isDirectory: true)
                let repository = NotesRepository(notesDirectory: notesDirectory)
                let alpha = try repository.createNote(initialContent: "# Alpha\n\nFirst")
                _ = try repository.createNote(initialContent: "# Beta\n\nSecond")

                let stateFileURL = xdgStateHome
                    .appendingPathComponent("me.spaceinbox.SwiftyNotes", isDirectory: true)
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
                    previewWidth: 560
                ))
            }
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
    environment: [String: String]
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
        stderr: String(decoding: stderrData, as: UTF8.self)
    )
}

private func runWaylandUIScript(
    _ pythonScript: String,
    prepare: ((URL, URL) throws -> Void)? = nil
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
    let appID = "me.spaceinbox.SwiftyNotes.UITests.\(temp.lastPathComponent.lowercased())"
    try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: xdgDataHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: xdgStateHome, withIntermediateDirectories: true)
    try prepare?(xdgDataHome, xdgStateHome)

    let script = """
    set -euo pipefail
    export NO_AT_BRIDGE=0
    export GTK_A11Y=atspi
    export GDK_BACKEND=wayland
    export XDG_RUNTIME_DIR="$TEST_RUNTIME_DIR"
    export WAYLAND_DISPLAY="swifty-notes-test-wayland"
    export XDG_DATA_HOME="$XDG_DATA_HOME"
    export XDG_STATE_HOME="$XDG_STATE_HOME"
    export NOTES_DIR="$XDG_DATA_HOME/me.spaceinbox.SwiftyNotes/notes"
    chmod 700 "$XDG_RUNTIME_DIR"

    weston --backend=headless --renderer=pixman --shell=desktop --socket="$WAYLAND_DISPLAY" --width=1440 --height=1024 --idle-time=0 >/tmp/swifty-ui-smoke-weston.out 2>/tmp/swifty-ui-smoke-weston.err &
    WESTON_PID=$!
    for _ in $(seq 1 80); do
      [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && break
      sleep 0.25
    done
    if [ ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
      echo "Weston socket was not created" >&2
      cat /tmp/swifty-ui-smoke-weston.err >&2 || true
      exit 1
    fi
    "$APP" >/tmp/swifty-ui-smoke.out 2>/tmp/swifty-ui-smoke.err &
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
    import pyatspi
    import time
    
    TARGET_PID = int(os.environ["APP_PID"])
    NOTES_DIR = os.environ["NOTES_DIR"]

    def walk(node):
        try:
            for index in range(node.childCount):
                child = node.getChildAtIndex(index)
                yield child
                yield from walk(child)
        except Exception:
            return

    def visible_names(root):
        names = []
        if root.name:
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
        def process_id(node):
            for attribute in ("get_process_id", "getProcessId"):
                accessor = getattr(node, attribute, None)
                if callable(accessor):
                    try:
                        return int(accessor())
                    except Exception:
                        pass
            return None

        def locate():
            desktop = pyatspi.Registry.getDesktop(0)
            for index in range(desktop.childCount):
                app = desktop.getChildAtIndex(index)
                if (app.name or "") != "SwiftyNotes":
                    continue
                if process_id(app) != TARGET_PID:
                    continue
                for child_index in range(app.childCount):
                    candidate = app.getChildAtIndex(child_index)
                    if candidate.getRoleName() == "frame" and (candidate.name or "") == "Swifty Notes":
                        return candidate
            return None
        return wait_until(locate, "Swifty Notes frame appears")

    def find_named(root, name):
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
            "XDG_STATE_HOME": xdgStateHome.path()
        ]
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
        .appendingPathComponent("SwiftyNotes", isDirectory: false)
}
