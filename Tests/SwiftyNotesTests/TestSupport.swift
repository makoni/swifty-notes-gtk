import Foundation
import Testing
@testable import SwiftyNotes
import Adwaita
import CAdwaita

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
