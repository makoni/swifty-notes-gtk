import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

actor SaveRecorder {
    private var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }

    func snapshot() -> [Int] {
        values
    }
}

@MainActor
final class URLRecorder {
    private var value: URL?

    func set(_ url: URL) {
        value = url
    }

    func snapshot() -> URL? {
        value
    }
}

struct CLITestSummary: Decodable {
    let id: String
    let title: String
    let filename: String
    let createdAt: Date
    let updatedAt: Date
}

struct CLITestDocument: Decodable {
    let id: String
    let title: String
    let filename: String
    let createdAt: Date
    let updatedAt: Date
    let content: String
}

extension JSONDecoder {
    static var swiftyNotesCLI: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

@MainActor
final class TestMainActorScheduler {
    private final class Entry {
        let action: @MainActor () -> Void
        var isCancelled = false

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }
    }

    private var pendingEntries: [Entry] = []

    func schedule(_ action: @escaping @MainActor () -> Void) {
        pendingEntries.append(Entry(action: action))
    }

    func schedule(after _: Duration, operation: @escaping @MainActor () -> Void) -> (() -> Void) {
        let entry = Entry(action: operation)
        pendingEntries.append(entry)
        return {
            entry.isCancelled = true
        }
    }

    func runPendingActions() {
        while !pendingEntries.isEmpty {
            let entries = pendingEntries
            pendingEntries.removeAll()
            for entry in entries where !entry.isCancelled {
                entry.action()
            }
        }
    }
}

/// Running a command-line tool and collecting what it said.
///
/// Six suites in this target start a `Process`; three of them need the output
/// of one. The plumbing lives here because getting it wrong deadlocks rather
/// than fails: reading one pipe to EOF before the other blocks forever as
/// soon as the child fills the pipe it is not being read from, and the tools
/// here are ones that write a diagnostic per offending input.
enum ToolRunner {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// The first `name` on PATH, or `nil`.
    ///
    /// PATH rather than a fixed list of directories: `swift` lives wherever
    /// the toolchain was installed, which on a developer machine is neither
    /// /usr/bin nor /usr/local/bin.
    static func onPath(_ name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// A tool in one of the usual system directories, or `nil`.
    static func systemTool(_ name: String) -> URL? {
        for directory in ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin"] {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func run(_ executable: URL, _ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        let outQueue = DispatchQueue(label: "swiftynotes.tool.out")
        let errQueue = DispatchQueue(label: "swiftynotes.tool.err")
        let finished = DispatchSemaphore(value: 0)
        var outData = Data()
        var errData = Data()

        let readOut = DispatchWorkItem {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        let readErr = DispatchWorkItem {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        outQueue.async(execute: readOut)
        errQueue.async(execute: readErr)
        finished.wait()
        finished.wait()
        process.waitUntilExit()

        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
        )
    }
}

/// Process-global localization state, put back afterwards.
///
/// `LANGUAGE`, `LC_MESSAGES`, gettext's catalogue cache and the text-domain
/// binding are all per-process, so a suite that moves any of them owes every
/// later suite a restore. Shared rather than copied per suite: the two copies
/// this replaced had already drifted apart in the order they restored things.
@MainActor
enum LocalizationTestSupport {
    /// Runs `body` with the session's language, messages locale and domain
    /// binding restored on every exit path.
    static func withRestoredLanguage(_ body: () throws -> Void) throws {
        let previous = ProcessInfo.processInfo.environment["LANGUAGE"]
        // `setLanguage` installs a real locale to escape the C locale, which
        // mutates the process's LC_MESSAGES. Restoring LANGUAGE alone would
        // leave that behind for every later test.
        let previousMessagesLocale = currentMessagesLocale()
        defer {
            restore(language: previous, messagesLocale: previousMessagesLocale)
        }
        // Rebinds the domain to the shipped catalogue, which is also what a
        // suite that bound it elsewhere needs on the way in.
        initializeLocalization()
        applySessionLanguage(previous)
        try body()
    }

    /// Puts the three pieces of global state back.
    ///
    /// Deliberately `setLanguage(nil)` rather than `applyLanguage(.system)`:
    /// the latter also assigns GTK's default text direction, which makes GTK
    /// walk its list of live toplevels — and in a shared test process that
    /// list holds windows earlier suites left behind, so the walk reads freed
    /// memory and takes the whole run down. Only the translations need
    /// putting back here; the direction is the app's business, and the tests
    /// that care about it assert the decision rather than assigning it.
    static func restore(language: String?, messagesLocale: String?) {
        applySessionLanguage(language)
        _ = setLanguage(nil)
        // The binding, not just the language: a suite that pointed the domain
        // at a temporary directory has usually deleted it by now, and
        // `configureLocalization` only rebinds when it finds a catalogue.
        #expect(
            initializeLocalization(),
            """
            no catalogue found while restoring localization — the text domain may still \
            point at a directory this suite removed, and every later suite would then \
            read msgids instead of translations
            """,
        )
        if let messagesLocale {
            #expect(
                setMessagesLocale(messagesLocale),
                "failed to restore LC_MESSAGES — later suites would sample a locale they did not set",
            )
        }
    }

    /// Installs `language` as the session's own LANGUAGE, which is the
    /// baseline ``AppLanguage.system`` returns to.
    static func applySessionLanguage(_ language: String?) {
        if let language {
            setenv("LANGUAGE", language, 1)
        } else {
            unsetenv("LANGUAGE")
        }
        recaptureSessionLanguage()
    }

    /// A settings window and the objects that have to outlive the assertion.
    ///
    /// The application and the parent window are handed back rather than kept
    /// inside the builder: released, they take the settings window's content
    /// with them, and a measurement then reads `nil` off a finalized object.
    struct SettingsWindowRig {
        let application: Application
        let parentWindow: ApplicationWindow
        let window: SettingsWindow
    }

    /// A settings window over a throwaway notes directory.
    ///
    /// The caller owns `directory`. Shared because two suites were building
    /// the same eight arguments with the same temporary-directory dance.
    static func makeSettingsWindow(
        suffix: String,
        directory: URL,
        applySettingsChange: @escaping (AppSettings) -> AppSettings = { $0 },
    ) throws -> SettingsWindowRig {
        let application = Application(id: "me.spaceinbox.swiftynotes.tests.\(suffix)")
        try application.register()
        let parent = ApplicationWindow(application: application)
        let window = SettingsWindow(
            application: application,
            parentWindow: parent,
            currentSettings: AppSettings(customNotesDirectoryPath: directory.path()),
            currentNotesDirectory: directory,
            defaultNotesDirectory: directory,
            applyNotesDirectoryChange: { $0 },
            applySettingsChange: applySettingsChange,
            openDirectory: { _ in },
        )
        return SettingsWindowRig(application: application, parentWindow: parent, window: window)
    }
}
