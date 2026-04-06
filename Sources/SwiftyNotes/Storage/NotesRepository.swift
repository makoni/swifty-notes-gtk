import Foundation

public struct NotesDirectorySnapshot: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let filename: String
        public let modifiedAt: TimeInterval
        public let fileSize: UInt64
        public let contentFingerprint: UInt64

        public init(
            filename: String,
            modifiedAt: TimeInterval,
            fileSize: UInt64,
            contentFingerprint: UInt64 = 0
        ) {
            self.filename = filename
            self.modifiedAt = modifiedAt
            self.fileSize = fileSize
            self.contentFingerprint = contentFingerprint
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }
}

public final class NotesRepository: @unchecked Sendable {
    private let notesDirectory: URL
    private let fileManager: FileManager
    private let formatter: ISO8601DateFormatter
    private let queue: DispatchQueue

    public init(
        notesDirectory: URL = NotesRepository.defaultNotesDirectory(),
        fileManager: FileManager = .default
    ) {
        self.notesDirectory = notesDirectory
        self.fileManager = fileManager
        self.formatter = ISO8601DateFormatter()
        self.queue = DispatchQueue(label: "io.github.makoni.SwiftyNotes.notes-repository")
        formatter.formatOptions = [.withInternetDateTime]
    }

    public var notesDirectoryURL: URL {
        notesDirectory
    }

    public static func defaultNotesDirectory() -> URL {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let base: URL
        if let xdgDataHome = env["XDG_DATA_HOME"], !xdgDataHome.isEmpty {
            base = URL(fileURLWithPath: xdgDataHome, isDirectory: true)
        } else {
            base = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("share", isDirectory: true)
        }
        return base
            .appendingPathComponent("io.github.makoni.SwiftyNotes", isDirectory: true)
            .appendingPathComponent("notes", isDirectory: true)
    }

    public func ensureNotesDirectory() throws {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
        }
    }

    public func loadNotes() throws -> [Note] {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            let urls = try fileManager.contentsOfDirectory(
                at: notesDirectory,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            let noteFiles = urls.filter { $0.pathExtension == "md" }
            let notes = try noteFiles.map(loadNoteUnlocked(from:))
            return notes.sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.filename > $1.filename
                }
                return $0.createdAt > $1.createdAt
            }
        }
    }

    public func createNote(initialContent: String = "") throws -> Note {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            let note = makeNewNote(content: initialContent)
            try persistUnlocked(note)
            return note
        }
    }

    public func duplicate(note: Note) throws -> Note {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            let duplicated = makeNewNote(content: note.content)
            try persistUnlocked(duplicated)
            return duplicated
        }
    }

    public func importNote(from sourceURL: URL) throws -> Note {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            let content = try String(contentsOf: sourceURL, encoding: .utf8)
            let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path())
            let createdAt = (attributes[.creationDate] as? Date) ?? Date()
            let note = makeNewNote(content: content, createdAt: createdAt)
            try persistUnlocked(note)
            return note
        }
    }

    public func export(note: Note, to destinationURL: URL) throws {
        try queue.sync {
            let directory = destinationURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try note.content.data(using: .utf8)?.write(to: destinationURL, options: .atomic)
        }
    }

    public func save(note: Note) throws -> Note {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            let updated = Note(
                id: note.id,
                filename: note.filename,
                createdAt: note.createdAt,
                updatedAt: Date(),
                content: note.content
            )
            try persistUnlocked(updated)
            return updated
        }
    }

    public func delete(note: Note) throws {
        try queue.sync {
            let url = notesDirectory.appendingPathComponent(note.filename, isDirectory: false)
            if fileManager.fileExists(atPath: url.path()) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    public func directorySnapshot() throws -> NotesDirectorySnapshot {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            let urls = try fileManager.contentsOfDirectory(
                at: notesDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            let entries = try urls
                .filter { $0.pathExtension == "md" }
                .map(makeSnapshotEntryUnlocked(from:))
                .sorted { $0.filename < $1.filename }
            return NotesDirectorySnapshot(entries: entries)
        }
    }

    public func noteURL(for note: Note) -> URL {
        notesDirectory.appendingPathComponent(note.filename, isDirectory: false)
    }

    private func ensureNotesDirectoryUnlocked() throws {
        try fileManager.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
    }

    private func loadNoteUnlocked(from url: URL) throws -> Note {
        let attributes = try fileManager.attributesOfItem(atPath: url.path())
        let content = try String(contentsOf: url, encoding: .utf8)
        let filename = url.lastPathComponent
        let id = Self.id(fromFilename: filename)
        let createdAt = (attributes[.creationDate] as? Date) ?? Self.createdAt(fromFilename: filename) ?? Date()
        let updatedAt = (attributes[.modificationDate] as? Date) ?? createdAt
        return Note(
            id: id,
            filename: filename,
            createdAt: createdAt,
            updatedAt: updatedAt,
            content: content
        )
    }

    private func persistUnlocked(_ note: Note) throws {
        let url = notesDirectory.appendingPathComponent(note.filename, isDirectory: false)
        guard let data = note.content.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: url, options: .atomic)
    }

    private func makeSnapshotEntryUnlocked(from url: URL) throws -> NotesDirectorySnapshot.Entry {
        let attributes = try fileManager.attributesOfItem(atPath: url.path())
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let data = try Data(contentsOf: url)
        return .init(
            filename: url.lastPathComponent,
            modifiedAt: modifiedAt,
            fileSize: fileSize,
            contentFingerprint: Self.contentFingerprint(for: data)
        )
    }

    private func makeNewNote(content: String, createdAt: Date = Date()) -> Note {
        let id = UUID()
        let timestamp = formatter.string(from: createdAt).replacingOccurrences(of: ":", with: "-")
        let filename = "\(timestamp)--\(id.uuidString.lowercased()).md"
        return Note(id: id, filename: filename, createdAt: createdAt, updatedAt: createdAt, content: content)
    }

    private static func id(fromFilename filename: String) -> UUID {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        guard stem.contains("--") else {
            return UUID()
        }
        let parts = stem.components(separatedBy: "--")
        if let last = parts.last, let uuid = UUID(uuidString: last) {
            return uuid
        }
        return UUID()
    }

    private static func createdAt(fromFilename filename: String) -> Date? {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        guard let timestamp = stem.components(separatedBy: "--").first else { return nil }
        let restored = timestamp.replacingOccurrences(of: "-", with: ":")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: restored)
    }

    private static func contentFingerprint(for data: Data) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
