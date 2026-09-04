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
