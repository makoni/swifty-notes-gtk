import Foundation
#if canImport(Glibc)
import Glibc
#endif

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
            contentFingerprint: UInt64 = 0,
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

private struct StoredNoteMetadata: Codable {
    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    /// Non-nil only when the note is in the trash. Tracks when the
    /// soft-delete happened so the auto-prune sweep can permanently
    /// remove old entries.
    let deletedAt: Date?
    /// Folder the note lived in before it was soft-deleted, so
    /// restore can put it back where it came from. Empty string if it
    /// was at the root.
    let originalFolderPath: String?
}

private struct StagedOrphanedAssets: Codable {
    let schemaVersion: Int
    let relativePaths: [String]
}

public enum NoteExportAssetCollision: Sendable {
    case fail
    case merge
}

public struct NoteExportOutcome: Equatable, Sendable {
    public let markdownURL: URL
    public let assetsDestinationURL: URL?
    public let assetsCopied: Int

    public init(markdownURL: URL, assetsDestinationURL: URL?, assetsCopied: Int) {
        self.markdownURL = markdownURL
        self.assetsDestinationURL = assetsDestinationURL
        self.assetsCopied = assetsCopied
    }
}

public enum NoteExportError: Error, LocalizedError {
    case assetsDestinationExists(URL)

    public var errorDescription: String? {
        switch self {
        case let .assetsDestinationExists(url):
            "An \"assets\" folder already exists at \(url.path(percentEncoded: false))."
        }
    }
}

enum NotesRepositoryAssetImportError: Error, LocalizedError, Equatable {
    case unsupportedImageType(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedImageType(filename):
            "Unsupported image type for \(filename)."
        }
    }
}

public enum NotesRepositoryFolderError: Error, LocalizedError, Equatable {
    case invalidName(String)
    case nameTooLong(String, limit: Int)
    case pathTooLong(String, limit: Int)
    case alreadyExists(String)
    case notFound(String)
    case wouldNestInsideSelf(source: String, destination: String)
    case cannotNestInsideNote(notePath: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidName(name):
            "\"\(name)\" is not a valid folder name."
        case let .nameTooLong(name, limit):
            "Folder name \"\(name)\" exceeds the file system limit of \(limit) bytes."
        case let .pathTooLong(path, limit):
            "Path \"\(path)\" exceeds the file system limit of \(limit) bytes."
        case let .alreadyExists(path):
            "A folder or note already exists at \"\(path)\"."
        case let .notFound(path):
            "Folder \"\(path)\" was not found."
        case let .wouldNestInsideSelf(source, destination):
            "Cannot move \"\(source)\" into its own descendant \"\(destination)\"."
        case let .cannotNestInsideNote(notePath):
            "Cannot place a folder or note inside the note directory at \"\(notePath)\"."
        }
    }
}

public final class NotesRepository: @unchecked Sendable {
    private static let noteFilename = "note.md"
    private static let metadataFilename = "meta.json"
    private static let assetsDirectoryName = "assets"
    private static let stagedOrphanedAssetsFilename = ".orphaned-assets.json"
    /// Hidden directory that holds soft-deleted notes. Each entry
    /// keeps its uuid as folder name and carries `deletedAt` /
    /// `originalFolderPath` in `meta.json`.
    private static let trashDirectoryName = ".trash"
    private static let storageSchemaVersion = 1
    private static let orphanedAssetsSchemaVersion = 1
    private static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff",
    ]

    private let notesDirectory: URL
    private let fileManager: FileManager
    private let formatter: ISO8601DateFormatter
    private let queue: DispatchQueue
    private let metadataEncoder = JSONEncoder()
    private let metadataDecoder = JSONDecoder()
    private var hasPrunedStagedOrphanedAssets = false

    public init(
        notesDirectory: URL = NotesRepository.defaultNotesDirectory(),
        fileManager: FileManager = .default,
    ) {
        self.notesDirectory = notesDirectory
        self.fileManager = fileManager
        formatter = ISO8601DateFormatter()
        queue = DispatchQueue(label: AppIdentity.notesRepositoryQueueLabel)
        formatter.formatOptions = [.withInternetDateTime]
        metadataEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        metadataEncoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.metadataDateString(from: date))
        }
        metadataDecoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = Self.metadataDate(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid note metadata date")
        }
    }

    public var notesDirectoryURL: URL {
        notesDirectory
    }

    public static func defaultNotesDirectory() -> URL {
        if let configuredDirectory = try? AppSettingsStore().load().customNotesDirectoryURL {
            return configuredDirectory
        }
        return fallbackNotesDirectory()
    }

    public static func fallbackNotesDirectory() -> URL {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let base: URL = if let xdgDataHome = env["XDG_DATA_HOME"], !xdgDataHome.isEmpty {
            URL(fileURLWithPath: xdgDataHome, isDirectory: true)
        } else {
            fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("share", isDirectory: true)
        }
        return AppIdentity.applicationDirectory(in: base)
            .appendingPathComponent("notes", isDirectory: true)
    }

    public static func supportsImageAssetImport(from sourceURL: URL) -> Bool {
        normalizedImageExtension(for: sourceURL) != nil
    }

    public func ensureNotesDirectory() throws {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
        }
    }

    public func loadNotes() throws -> [Note] {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            let notes = try storedNoteEntriesUnlocked().map { entry in
                try loadNoteUnlocked(from: entry.directoryURL, folderPath: entry.folderPath)
            }
            let deduplicated = try resolveDuplicateIDsUnlocked(notes)
            for note in deduplicated {
                try repairShowcaseImageUnlockedIfNeeded(for: note)
            }
            return deduplicated.sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.stableID > $1.stableID
                }
                return $0.createdAt > $1.createdAt
            }
        }
    }

    /// Two on-disk note directories can end up sharing the same `id` if a
    /// user clones a UUID directory (or merges vaults). Without resolution
    /// every lookup by id picks the first match deterministically and the
    /// later copies become unreachable through the GUI/CLI. We mint a
    /// fresh UUID for the later occurrences and rewrite their `meta.json`
    /// so subsequent reloads are stable.
    private func resolveDuplicateIDsUnlocked(_ notes: [Note]) throws -> [Note] {
        let stableOrdered = notes.sorted { lhs, rhs in
            if lhs.folderPath == rhs.folderPath {
                return lhs.filename < rhs.filename
            }
            return lhs.folderPath < rhs.folderPath
        }
        var seen: Set<UUID> = []
        var resolved: [Note] = []
        resolved.reserveCapacity(stableOrdered.count)
        for note in stableOrdered {
            if seen.contains(note.id) {
                let renumbered = Note(
                    id: UUID(),
                    filename: note.filename,
                    folderPath: note.folderPath,
                    createdAt: note.createdAt,
                    updatedAt: note.updatedAt,
                    content: note.content,
                )
                try persistMetadataUnlocked(renumbered)
                seen.insert(renumbered.id)
                resolved.append(renumbered)
            } else {
                seen.insert(note.id)
                resolved.append(note)
            }
        }
        return resolved
    }

    /// Writes only the `meta.json` for the note. Used by the duplicate-id
    /// resolver — we only need to persist the new id, not the markdown.
    private func persistMetadataUnlocked(_ note: Note) throws {
        let metadataURL = noteDirectoryURL(for: note)
            .appendingPathComponent(Self.metadataFilename, isDirectory: false)
        let metadata = StoredNoteMetadata(
            schemaVersion: Self.storageSchemaVersion,
            id: note.id,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            deletedAt: note.deletedAt,
            originalFolderPath: note.originalFolderPath,
        )
        let data = try metadataEncoder.encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }

    /// All folder paths under the notes directory. Empty array means no
    /// folders have been created yet — every note is at the root.
    public func listFolders() throws -> [String] {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            return try storedFolderPathsUnlocked().sorted()
        }
    }

    public func createNote(initialContent: String = "", in folderPath: String = "") throws -> Note {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            let normalizedFolder = try normalizedExistingFolderPathUnlocked(folderPath)
            let note = makeNewNote(content: initialContent, folderPath: normalizedFolder)
            try persistUnlocked(note)
            return note
        }
    }

    public func createFolder(at path: String) throws {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            let trimmed = Self.trimmedFolderPath(path)
            guard !trimmed.isEmpty else {
                throw NotesRepositoryFolderError.invalidName(path)
            }
            try validateFolderPathComponents(trimmed)
            let url = folderURL(for: trimmed)
            try validateAbsolutePathLength(url)
            if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                throw NotesRepositoryFolderError.alreadyExists(trimmed)
            }
            try ensureNoNoteAncestorUnlocked(trimmed)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    public func renameFolder(at path: String, to newName: String) throws {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            let source = Self.trimmedFolderPath(path)
            guard !source.isEmpty else {
                throw NotesRepositoryFolderError.invalidName(path)
            }
            let trimmedNewName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            try validateFolderName(trimmedNewName)
            let parent = Self.parentFolderPath(of: source)
            let destination = parent.isEmpty ? trimmedNewName : "\(parent)/\(trimmedNewName)"
            let sourceURL = folderURL(for: source)
            let destinationURL = folderURL(for: destination)
            try ensureFolderExistsUnlocked(at: source)
            try validateAbsolutePathLength(destinationURL)
            if destination != source,
               fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
                throw NotesRepositoryFolderError.alreadyExists(destination)
            }
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    /// Soft-deletes every note inside the folder (so each one can
    /// still be restored from Trash with its original folder path),
    /// then removes the folder structure itself. Symmetric with
    /// per-note ``delete(note:)`` — the user is never one wrong click
    /// away from permanently losing nested notes.
    public func deleteFolderRecursively(at path: String) throws {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            let trimmed = Self.trimmedFolderPath(path)
            guard !trimmed.isEmpty else {
                throw NotesRepositoryFolderError.invalidName(path)
            }
            try ensureFolderExistsUnlocked(at: trimmed)
            let folderURL = folderURL(for: trimmed)
            var notesToTrash: [(URL, String)] = []
            try walkNoteDirectoriesUnlocked(at: folderURL, folderPath: trimmed) { url, parentFolder in
                notesToTrash.append((url, parentFolder))
            }
            for (noteDirURL, parentFolder) in notesToTrash {
                let note = try loadNoteUnlocked(from: noteDirURL, folderPath: parentFolder)
                try moveToTrashUnlocked(note: note)
            }
            // Wipe whatever is left of the folder tree (sub-folders
            // emptied by the moves above, plus any non-note files
            // the user may have dropped in there).
            if fileManager.fileExists(atPath: folderURL.path(percentEncoded: false)) {
                try fileManager.removeItem(at: folderURL)
            }
        }
    }

    public func moveFolder(at path: String, to newParentPath: String) throws {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            let source = Self.trimmedFolderPath(path)
            guard !source.isEmpty else {
                throw NotesRepositoryFolderError.invalidName(path)
            }
            let parent = Self.trimmedFolderPath(newParentPath)
            try ensureFolderExistsUnlocked(at: source)
            if !parent.isEmpty {
                try ensureFolderExistsUnlocked(at: parent)
            }
            if parent == source || Self.isPath(parent, descendantOf: source) {
                throw NotesRepositoryFolderError.wouldNestInsideSelf(source: source, destination: parent)
            }
            let lastComponent = (source as NSString).lastPathComponent
            let destination = parent.isEmpty ? lastComponent : "\(parent)/\(lastComponent)"
            if destination == source { return }
            let destinationURL = folderURL(for: destination)
            try validateAbsolutePathLength(destinationURL)
            if fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
                throw NotesRepositoryFolderError.alreadyExists(destination)
            }
            try fileManager.moveItem(at: folderURL(for: source), to: destinationURL)
        }
    }

    @discardableResult
    public func move(note: Note, to folderPath: String) throws -> Note {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            let normalizedFolder = try normalizedExistingFolderPathUnlocked(folderPath)
            if normalizedFolder == note.folderPath { return note }
            let sourceURL = noteDirectoryURL(for: note)
            guard fileManager.fileExists(atPath: sourceURL.path(percentEncoded: false)) else {
                throw NotesRepositoryFolderError.notFound(note.folderPath)
            }
            let directoryName = noteDirectoryName(for: note)
            let destinationParent = normalizedFolder.isEmpty ? notesDirectory : folderURL(for: normalizedFolder)
            let destinationURL = destinationParent.appendingPathComponent(directoryName, isDirectory: true)
            try validateAbsolutePathLength(destinationURL)
            if fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
                throw NotesRepositoryFolderError.alreadyExists(
                    Self.joinedFolderPath(parent: normalizedFolder, child: directoryName)
                )
            }
            try fileManager.createDirectory(at: destinationParent, withIntermediateDirectories: true)
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            return Note(
                id: note.id,
                filename: note.filename,
                folderPath: normalizedFolder,
                createdAt: note.createdAt,
                updatedAt: note.updatedAt,
                content: note.content,
            )
        }
    }

    public func duplicate(note: Note) throws -> Note {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            let duplicated = makeNewNote(content: note.content)
            try persistUnlocked(duplicated)
            try copyAssetsUnlocked(from: note, to: duplicated)
            return duplicated
        }
    }

    public func importNote(from sourceURL: URL) throws -> Note {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            let content = try String(contentsOf: sourceURL, encoding: .utf8)
            let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path(percentEncoded: false))
            let createdAt = (attributes[.creationDate] as? Date) ?? Date()
            let note = makeNewNote(content: content, createdAt: createdAt)
            try persistUnlocked(note)
            return note
        }
    }

    @discardableResult
    public func export(
        note: Note,
        to destinationURL: URL,
        assetsCollision: NoteExportAssetCollision = .fail,
    ) throws -> NoteExportOutcome {
        try queue.sync { () throws -> NoteExportOutcome in
            let directory = destinationURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try note.content.data(using: .utf8)?.write(to: destinationURL, options: .atomic)

            let sourceAssetsURL = noteAssetsDirectoryURL(for: note)
            let sourceFiles = directoryContainsFilesUnlocked(at: sourceAssetsURL)
                ? (try? recursiveRegularFilesUnlocked(in: sourceAssetsURL)) ?? []
                : []
            guard !sourceFiles.isEmpty else {
                return NoteExportOutcome(
                    markdownURL: destinationURL,
                    assetsDestinationURL: nil,
                    assetsCopied: 0,
                )
            }

            let destinationAssetsURL = directory.appendingPathComponent(
                Self.assetsDirectoryName,
                isDirectory: true,
            )
            let destinationExists = fileManager.fileExists(
                atPath: destinationAssetsURL.path(percentEncoded: false),
            )
            if destinationExists, case .fail = assetsCollision {
                throw NoteExportError.assetsDestinationExists(destinationAssetsURL)
            }

            let copied = try copyAssetsForExportUnlocked(
                files: sourceFiles,
                from: sourceAssetsURL,
                to: destinationAssetsURL,
            )
            return NoteExportOutcome(
                markdownURL: destinationURL,
                assetsDestinationURL: destinationAssetsURL,
                assetsCopied: copied,
            )
        }
    }

    public func hasExportableAssets(note: Note) -> Bool {
        queue.sync {
            directoryContainsFilesUnlocked(at: noteAssetsDirectoryURL(for: note))
        }
    }

    public func importImageAsset(from sourceURL: URL, for note: Note) throws -> String {
        try queue.sync {
            guard let imageExtension = Self.normalizedImageExtension(for: sourceURL) else {
                throw NotesRepositoryAssetImportError.unsupportedImageType(sourceURL.lastPathComponent)
            }
            let data = try Data(contentsOf: sourceURL)
            return try importImageAssetUnlocked(
                data: data,
                rawBaseName: sourceURL.deletingPathExtension().lastPathComponent,
                imageExtension: imageExtension,
                for: note,
            )
        }
    }

    /// Saves the given image bytes into the note's `assets/` directory
    /// under a unique filename derived from `baseName` (e.g. `pasted.png`,
    /// `pasted-2.png`, …) and returns the relative reference suitable for
    /// a Markdown `![](…)` link. Used by the clipboard-paste path that
    /// receives raw decoded bytes instead of a source URL.
    public func importImageAsset(
        data: Data,
        baseName: String,
        fileExtension: String,
        for note: Note,
    ) throws -> String {
        try queue.sync {
            let trimmed = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard Self.supportedImageExtensions.contains(trimmed) else {
                throw NotesRepositoryAssetImportError.unsupportedImageType("\(baseName).\(fileExtension)")
            }
            return try importImageAssetUnlocked(
                data: data,
                rawBaseName: baseName,
                imageExtension: trimmed,
                for: note,
            )
        }
    }

    /// Shared body of the URL-based and data-based image-asset imports.
    /// Caller has already validated the image extension and acquired
    /// the queue lock.
    private func importImageAssetUnlocked(
        data: Data,
        rawBaseName: String,
        imageExtension: String,
        for note: Note,
    ) throws -> String {
        try ensureNotesDirectoryUnlocked()
        let assetsDirectoryURL = noteAssetsDirectoryURL(for: note)
        try fileManager.createDirectory(at: assetsDirectoryURL, withIntermediateDirectories: true)

        let stem = Note.sanitizedFilenameStem(from: rawBaseName, defaultStem: "image")
        let filename = uniqueImportedAssetFilenameUnlocked(
            baseName: stem,
            imageExtension: imageExtension,
            in: assetsDirectoryURL,
        )
        let destinationURL = assetsDirectoryURL.appendingPathComponent(filename, isDirectory: false)
        try data.write(to: destinationURL, options: .atomic)
        return Self.relativeAssetPath(for: filename)
    }

    public func save(note: Note) throws -> Note {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            let updated = Note(
                id: note.id,
                filename: Self.noteRelativePath(forDirectoryNamed: noteDirectoryName(for: note)),
                folderPath: note.folderPath,
                createdAt: note.createdAt,
                updatedAt: Date(),
                content: note.content,
            )
            try persistUnlocked(updated)
            try stageOrphanedAssetsUnlocked(for: updated)
            return updated
        }
    }

    /// Pure decision helper for the auto-prune sweep. Returns the
    /// subset of `entries` whose `deletedAt` is at least `retention`
    /// in the past relative to `now`. Legacy entries with `nil`
    /// `deletedAt` are skipped so they aren't auto-deleted before
    /// they have a known age, and entries with `deletedAt` in the
    /// future are skipped to survive a backwards clock jump.
    public static func entriesEligibleForPrune(
        in entries: [TrashEntry],
        retention: TrashRetention,
        now: Date,
    ) -> [TrashEntry] {
        guard case let .days(days) = retention, days >= 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 3600)
        return entries.filter { entry in
            guard let deletedAt = entry.deletedAt else { return false }
            guard deletedAt <= now else { return false }
            return deletedAt < cutoff
        }
    }

    /// Soft-deletes the note: moves its directory under
    /// `notes/.trash/<uuid>/` and stamps `deletedAt` /
    /// `originalFolderPath` into the in-trash `meta.json` so
    /// ``restore(noteWithID:)`` can put it back where it came from
    /// and ``pruneTrashIfNeeded(retention:now:)`` knows its age.
    public func delete(note: Note) throws {
        try queue.sync { try moveToTrashUnlocked(note: note) }
    }

    /// Explicit alias for the soft-delete path. ``delete(note:)``
    /// already routes here; ``moveToTrash(note:)`` is what the UI
    /// reaches for when it wants the operation by name.
    public func moveToTrash(note: Note) throws {
        try queue.sync { try moveToTrashUnlocked(note: note) }
    }

    /// Returns every note currently in `.trash/<uuid>/`.
    /// `folderPath` on the result stays empty so callers can render
    /// these under a dedicated Trash entry; `originalFolderPath`
    /// carries the pre-deletion location, `deletedAt` carries when
    /// the soft-delete happened.
    public func trashedNotes() throws -> [Note] {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            return try trashedNotesUnlocked()
        }
    }

    /// Moves a soft-deleted note back to its original folder
    /// (recreating the folder if it disappeared in the meantime) and
    /// clears the trash metadata.
    public func restore(noteWithID id: UUID) throws {
        try queue.sync { try restoreUnlocked(noteID: id) }
    }

    /// Permanently removes a single trashed note from disk.
    public func permanentlyDelete(noteWithID id: UUID) throws {
        try queue.sync { try permanentlyDeleteUnlocked(noteID: id) }
    }

    /// Permanently removes every trashed note from disk.
    public func emptyTrash() throws {
        try queue.sync {
            let trashURL = self.trashDirectoryURL
            guard fileManager.fileExists(atPath: trashURL.path(percentEncoded: false)) else {
                return
            }
            try fileManager.removeItem(at: trashURL)
        }
    }

    /// Permanently deletes every trashed note whose `deletedAt` is
    /// older than `retention` relative to `now`. Legacy entries
    /// without a `deletedAt` get stamped (with `now`) on first
    /// encounter so the *next* sweep can age them out cleanly.
    public func pruneTrashIfNeeded(retention: TrashRetention, now: Date) throws {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            let entries = try trashEntriesForPruneUnlocked(now: now)
            let due = Self.entriesEligibleForPrune(in: entries, retention: retention, now: now)
            for entry in due {
                try permanentlyDeleteUnlocked(noteID: entry.id)
            }
        }
    }

    var trashDirectoryURL: URL {
        notesDirectory.appendingPathComponent(Self.trashDirectoryName, isDirectory: true)
    }

    private func moveToTrashUnlocked(note: Note) throws {
        try ensureNotesDirectoryUnlocked()
        let sourceDirectory = noteDirectoryURL(for: note)
        let trashDirectory = trashDirectoryURL
        try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let destinationDirectory = trashDirectory
            .appendingPathComponent(note.id.uuidString.lowercased(), isDirectory: true)

        let destinationPath = destinationDirectory.path(percentEncoded: false)
        if fileManager.fileExists(atPath: destinationPath) {
            // A previous trash entry with the same id is still on
            // disk (e.g. a crash mid-operation). Wipe it so the move
            // can proceed atomically.
            try fileManager.removeItem(at: destinationDirectory)
        }

        if fileManager.fileExists(atPath: sourceDirectory.path(percentEncoded: false)) {
            try fileManager.moveItem(at: sourceDirectory, to: destinationDirectory)
        } else {
            // Legacy path-based note (no per-note directory) — fall
            // back to deleting the markdown file in place. This
            // mirrors the pre-soft-delete behaviour for very old
            // notes the user hasn't migrated yet.
            let markdownURL = noteURL(for: note)
            if fileManager.fileExists(atPath: markdownURL.path(percentEncoded: false)) {
                try fileManager.removeItem(at: markdownURL)
            }
            return
        }

        let metadataURL = destinationDirectory.appendingPathComponent(Self.metadataFilename, isDirectory: false)
        let metadata = StoredNoteMetadata(
            schemaVersion: Self.storageSchemaVersion,
            id: note.id,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            deletedAt: Date(),
            originalFolderPath: note.folderPath,
        )
        let data = try metadataEncoder.encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }

    private func trashedNotesUnlocked() throws -> [Note] {
        let trashURL = trashDirectoryURL
        guard fileManager.fileExists(atPath: trashURL.path(percentEncoded: false)) else {
            return []
        }
        let children = try fileManager.contentsOfDirectory(
            at: trashURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
        )
        return try children
            .filter(\.hasDirectoryPath)
            .compactMap { url -> Note? in
                let noteFile = url.appendingPathComponent(Self.noteFilename, isDirectory: false)
                guard fileManager.fileExists(atPath: noteFile.path(percentEncoded: false)) else {
                    return nil
                }
                return try loadNoteUnlocked(from: url, folderPath: "")
            }
            .sorted { ($0.deletedAt ?? Date.distantPast) > ($1.deletedAt ?? Date.distantPast) }
    }

    private func restoreUnlocked(noteID: UUID) throws {
        let trashedDirectory = trashDirectoryURL
            .appendingPathComponent(noteID.uuidString.lowercased(), isDirectory: true)
        guard fileManager.fileExists(atPath: trashedDirectory.path(percentEncoded: false)) else {
            return
        }
        let note = try loadNoteUnlocked(from: trashedDirectory, folderPath: "")
        let target = note.originalFolderPath ?? ""
        let restoredFolderURL = target.isEmpty ? notesDirectory : folderURL(for: target)
        // Recreate the original folder path if it disappeared while
        // the note was in the trash. Skip the validation that
        // ``createFolder`` runs — the path was already valid when
        // the note was saved.
        try fileManager.createDirectory(at: restoredFolderURL, withIntermediateDirectories: true)
        let destination = restoredFolderURL.appendingPathComponent(
            noteID.uuidString.lowercased(),
            isDirectory: true,
        )
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: trashedDirectory, to: destination)

        // Clear the trash markers on the restored note's meta.json.
        let metadataURL = destination.appendingPathComponent(Self.metadataFilename, isDirectory: false)
        let cleared = StoredNoteMetadata(
            schemaVersion: Self.storageSchemaVersion,
            id: note.id,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            deletedAt: nil,
            originalFolderPath: nil,
        )
        let data = try metadataEncoder.encode(cleared)
        try data.write(to: metadataURL, options: .atomic)
    }

    private func permanentlyDeleteUnlocked(noteID: UUID) throws {
        let trashedDirectory = trashDirectoryURL
            .appendingPathComponent(noteID.uuidString.lowercased(), isDirectory: true)
        if fileManager.fileExists(atPath: trashedDirectory.path(percentEncoded: false)) {
            try fileManager.removeItem(at: trashedDirectory)
        }
    }

    private func trashEntriesForPruneUnlocked(now: Date) throws -> [TrashEntry] {
        let trashURL = trashDirectoryURL
        guard fileManager.fileExists(atPath: trashURL.path(percentEncoded: false)) else {
            return []
        }
        let children = try fileManager.contentsOfDirectory(
            at: trashURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
        )
        var entries: [TrashEntry] = []
        for child in children where child.hasDirectoryPath {
            let metadataURL = child.appendingPathComponent(Self.metadataFilename, isDirectory: false)
            guard let id = UUID(uuidString: child.lastPathComponent) else { continue }
            guard fileManager.fileExists(atPath: metadataURL.path(percentEncoded: false)) else {
                continue
            }
            let data = try Data(contentsOf: metadataURL)
            let metadata = try metadataDecoder.decode(StoredNoteMetadata.self, from: data)
            if metadata.deletedAt == nil {
                // Legacy entry with no timestamp — stamp with `now`
                // so the next sweep can age it out.
                let stamped = StoredNoteMetadata(
                    schemaVersion: metadata.schemaVersion,
                    id: metadata.id,
                    createdAt: metadata.createdAt,
                    updatedAt: metadata.updatedAt,
                    deletedAt: now,
                    originalFolderPath: metadata.originalFolderPath ?? "",
                )
                let stampedData = try metadataEncoder.encode(stamped)
                try stampedData.write(to: metadataURL, options: .atomic)
                entries.append(TrashEntry(id: id, deletedAt: nil))
            } else {
                entries.append(TrashEntry(id: id, deletedAt: metadata.deletedAt))
            }
        }
        return entries
    }

    /// Lightweight emptiness check for the trash directory — used by
    /// the seed gate so we don't decode `meta.json` files just to ask
    /// "did the user ever delete anything?".
    private func trashEntryIDsUnlocked() throws -> [UUID] {
        let trashURL = trashDirectoryURL
        guard fileManager.fileExists(atPath: trashURL.path(percentEncoded: false)) else {
            return []
        }
        let children = try fileManager.contentsOfDirectory(
            at: trashURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
        )
        return children
            .filter(\.hasDirectoryPath)
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
    }

    public func directorySnapshot() throws -> NotesDirectorySnapshot {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            let entries = try storedNoteEntriesUnlocked()
                .map { try makeSnapshotEntryUnlocked(from: $0.directoryURL, folderPath: $0.folderPath) }
                .sorted { $0.filename < $1.filename }
            return NotesDirectorySnapshot(entries: entries)
        }
    }

    /// Cheaper variant of ``directorySnapshot()`` for change monitoring.
    ///
    /// Preserves the same filename / modifiedAt / fileSize comparison shape,
    /// but skips content hashing so periodic external-change checks do not
    /// read every note file into memory while the app is idle or scrolling.
    public func directoryMonitorSnapshot() throws -> NotesDirectorySnapshot {
        try queue.sync {
            try prepareNotesDirectoryForMonitoringUnlocked()
            let noteEntries = try storedNoteEntriesUnlocked().map {
                try makeSnapshotEntryUnlocked(
                    from: $0.directoryURL,
                    folderPath: $0.folderPath,
                    includeContentFingerprint: false,
                )
            }
            let legacyEntries = try legacyFlatMarkdownFilesUnlocked()
                .map(makeLegacyFlatSnapshotEntryUnlocked)
            let entries = (noteEntries + legacyEntries)
                .sorted { $0.filename < $1.filename }
            return NotesDirectorySnapshot(entries: entries)
        }
    }

    public func noteURL(for note: Note) -> URL {
        noteDirectoryURL(for: note).appendingPathComponent(Self.noteFilename, isDirectory: false)
    }

    public func noteContentBaseDirectoryURL(for note: Note) -> URL {
        noteDirectoryURL(for: note)
    }

    public func noteDirectoryURL(for note: Note) -> URL {
        let parent: URL = note.folderPath.isEmpty
            ? notesDirectory
            : folderURL(for: note.folderPath)
        return parent.appendingPathComponent(noteDirectoryName(for: note), isDirectory: true)
    }

    public func folderURL(for folderPath: String) -> URL {
        notesDirectory.appendingPathComponent(folderPath, isDirectory: true)
    }

    public func noteAssetsDirectoryURL(for note: Note) -> URL {
        noteDirectoryURL(for: note).appendingPathComponent(Self.assetsDirectoryName, isDirectory: true)
    }

    @discardableResult
    public func seedMarkdownShowcaseIfNeeded(createdAt: Date = Date()) throws -> Note? {
        try queue.sync { () throws -> Note? in
            try ensureNotesDirectoryUnlocked()
            if try !storedNoteEntriesUnlocked().isEmpty {
                return nil
            }

            let note = makeNewNote(content: MarkdownShowcaseSeed.content, createdAt: createdAt)
            try persistUnlocked(note)
            try persistShowcaseImageUnlockedIfNeeded(for: note)
            return note
        }
    }

    /// Folder the seeded onboarding guides land in. Surfaces the
    /// folder feature on first launch so users immediately see that
    /// notes can be grouped.
    public static let defaultSeedGuidesFolder = "Guides"

    @discardableResult
    public func seedDefaultNotesIfNeeded(createdAt: Date = Date()) throws -> [Note] {
        try queue.sync { () throws -> [Note] in
            try ensureNotesDirectoryUnlocked()
            if try !storedNoteEntriesUnlocked().isEmpty {
                return []
            }
            // A non-empty Trash means the user has already
            // interacted with the app and chose to delete things.
            // Re-seeding would surprise them with marketing notes
            // alongside their bin. Empty Trash → the user is asking
            // for a fresh start, so let the seed fire again.
            if try !trashEntryIDsUnlocked().isEmpty {
                return []
            }

            let showcase = makeNewNote(content: MarkdownShowcaseSeed.content, createdAt: createdAt)
            try persistUnlocked(showcase)
            try persistShowcaseImageUnlockedIfNeeded(for: showcase)

            try fileManager.createDirectory(
                at: folderURL(for: Self.defaultSeedGuidesFolder),
                withIntermediateDirectories: true,
            )

            let overview = makeNewNote(
                content: SwiftyNotesOverviewSeed.content,
                createdAt: createdAt.addingTimeInterval(-1),
                folderPath: Self.defaultSeedGuidesFolder,
            )
            try persistUnlocked(overview)

            let cliGuide = makeNewNote(
                content: SwiftyNotesCLISeed.content,
                createdAt: createdAt.addingTimeInterval(-2),
                folderPath: Self.defaultSeedGuidesFolder,
            )
            try persistUnlocked(cliGuide)

            return [showcase, overview, cliGuide]
        }
    }

    private func ensureNotesDirectoryUnlocked() throws {
        try migrateLegacyStorageIfNeededUnlocked()
        try fileManager.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        try migrateLegacyFlatNoteLayoutIfNeededUnlocked()
        if !hasPrunedStagedOrphanedAssets {
            try pruneStagedOrphanedAssetsUnlocked()
            hasPrunedStagedOrphanedAssets = true
        }
    }

    /// Minimal setup path for cheap monitor polling.
    ///
    /// Polling only needs the directory tree to exist so it can compare
    /// metadata snapshots. Full legacy migration and staged-asset pruning
    /// stay on the heavier load/save paths; if the monitor notices a new
    /// legacy root markdown file it includes a synthetic entry so the UI
    /// reload path can run the full migration on demand.
    private func prepareNotesDirectoryForMonitoringUnlocked() throws {
        try migrateLegacyStorageIfNeededUnlocked()
        try fileManager.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
    }

    private func migrateLegacyStorageIfNeededUnlocked() throws {
        guard notesDirectory.lastPathComponent == "notes" else { return }
        let appDirectory = notesDirectory.deletingLastPathComponent()
        try AppIdentity.migrateApplicationDirectoryIfNeeded(currentDirectory: appDirectory, fileManager: fileManager)
    }

    private func migrateLegacyFlatNoteLayoutIfNeededUnlocked() throws {
        let legacyMarkdownFiles = try legacyFlatMarkdownFilesUnlocked()
        guard !legacyMarkdownFiles.isEmpty else { return }

        let legacyShowcaseAssetURL = notesDirectory.appendingPathComponent(
            MarkdownShowcaseSeed.legacySharedImageFilename,
            isDirectory: false,
        )

        for legacyMarkdownFile in legacyMarkdownFiles {
            var note = try loadLegacyNoteUnlocked(from: legacyMarkdownFile)
            note = migratedLegacyNote(note, legacyShowcaseAssetURL: legacyShowcaseAssetURL)
            try persistUnlocked(note)
            try copyLegacyShowcaseAssetUnlockedIfNeeded(from: legacyShowcaseAssetURL, to: note)
            if fileManager.fileExists(atPath: legacyMarkdownFile.path(percentEncoded: false)) {
                try fileManager.removeItem(at: legacyMarkdownFile)
            }
        }

        if fileManager.fileExists(atPath: legacyShowcaseAssetURL.path(percentEncoded: false)) {
            try fileManager.removeItem(at: legacyShowcaseAssetURL)
        }
    }

    private func legacyFlatMarkdownFilesUnlocked() throws -> [URL] {
        let rootContents = try fileManager.contentsOfDirectory(
            at: notesDirectory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles],
        )
        return rootContents
            .filter { !$0.hasDirectoryPath && $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private struct StoredNoteEntry {
        let directoryURL: URL
        let folderPath: String
    }

    private func storedNoteEntriesUnlocked() throws -> [StoredNoteEntry] {
        var entries: [StoredNoteEntry] = []
        try walkNoteDirectoriesUnlocked(at: notesDirectory, folderPath: "") { url, folderPath in
            entries.append(StoredNoteEntry(directoryURL: url, folderPath: folderPath))
        }
        return entries
    }

    private func storedFolderPathsUnlocked() throws -> [String] {
        var folders: [String] = []
        try walkFolderDirectoriesUnlocked(at: notesDirectory, folderPath: "") { folderPath in
            folders.append(folderPath)
        }
        return folders
    }

    private func walkNoteDirectoriesUnlocked(
        at directoryURL: URL,
        folderPath: String,
        visit: (URL, String) -> Void,
    ) throws {
        let children = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
        )
        for child in children where child.hasDirectoryPath {
            let noteFile = child.appendingPathComponent(Self.noteFilename, isDirectory: false)
            if fileManager.fileExists(atPath: noteFile.path(percentEncoded: false)) {
                visit(child, folderPath)
            } else {
                let subPath = Self.joinedFolderPath(parent: folderPath, child: child.lastPathComponent)
                try walkNoteDirectoriesUnlocked(at: child, folderPath: subPath, visit: visit)
            }
        }
    }

    private func walkFolderDirectoriesUnlocked(
        at directoryURL: URL,
        folderPath: String,
        visit: (String) -> Void,
    ) throws {
        let children = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
        )
        for child in children where child.hasDirectoryPath {
            let noteFile = child.appendingPathComponent(Self.noteFilename, isDirectory: false)
            if fileManager.fileExists(atPath: noteFile.path(percentEncoded: false)) {
                continue
            }
            let subPath = Self.joinedFolderPath(parent: folderPath, child: child.lastPathComponent)
            visit(subPath)
            try walkFolderDirectoriesUnlocked(at: child, folderPath: subPath, visit: visit)
        }
    }

    private func loadNoteUnlocked(from noteDirectoryURL: URL, folderPath: String = "") throws -> Note {
        let markdownURL = noteDirectoryURL.appendingPathComponent(Self.noteFilename, isDirectory: false)
        let metadataURL = noteDirectoryURL.appendingPathComponent(Self.metadataFilename, isDirectory: false)
        let markdownAttributes = try fileManager.attributesOfItem(atPath: markdownURL.path(percentEncoded: false))
        let content = try String(contentsOf: markdownURL, encoding: .utf8)

        let metadata: StoredNoteMetadata?
        if fileManager.fileExists(atPath: metadataURL.path(percentEncoded: false)) {
            let metadataData = try Data(contentsOf: metadataURL)
            metadata = try metadataDecoder.decode(StoredNoteMetadata.self, from: metadataData)
        } else {
            metadata = nil
        }

        let directoryName = noteDirectoryURL.lastPathComponent
        let directoryDerivedID = UUID(uuidString: directoryName)
        let id = metadata?.id ?? directoryDerivedID ?? UUID()
        let createdAt = metadata?.createdAt
            ?? (markdownAttributes[.creationDate] as? Date)
            ?? Date()
        let markdownUpdatedAt = (markdownAttributes[.modificationDate] as? Date) ?? createdAt
        let updatedAt = max(metadata?.updatedAt ?? createdAt, markdownUpdatedAt)

        return Note(
            id: id,
            filename: Self.noteRelativePath(forDirectoryNamed: directoryName),
            folderPath: folderPath,
            createdAt: createdAt,
            updatedAt: updatedAt,
            content: content,
            deletedAt: metadata?.deletedAt,
            originalFolderPath: metadata?.originalFolderPath,
        )
    }

    private func loadLegacyNoteUnlocked(from url: URL) throws -> Note {
        let attributes = try fileManager.attributesOfItem(atPath: url.path(percentEncoded: false))
        let content = try String(contentsOf: url, encoding: .utf8)
        let filename = url.lastPathComponent
        let id = Self.id(fromLegacyFilename: filename)
        let createdAt = (attributes[.creationDate] as? Date) ?? Self.createdAt(fromLegacyFilename: filename) ?? Date()
        let updatedAt = (attributes[.modificationDate] as? Date) ?? createdAt
        return Note(
            id: id,
            filename: Self.noteRelativePath(forDirectoryNamed: id.uuidString.lowercased()),
            createdAt: createdAt,
            updatedAt: updatedAt,
            content: content,
        )
    }

    private func migratedLegacyNote(_ note: Note, legacyShowcaseAssetURL: URL) -> Note {
        guard fileManager.fileExists(atPath: legacyShowcaseAssetURL.path(percentEncoded: false)) else {
            return note
        }

        let legacyPath = MarkdownShowcaseSeed.legacySharedImageFilename
        guard note.content.contains(legacyPath),
              !note.content.contains(MarkdownShowcaseSeed.imageAssetPath)
        else {
            return note
        }

        return Note(
            id: note.id,
            filename: Self.noteRelativePath(forDirectoryNamed: note.stableID),
            folderPath: note.folderPath,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            content: note.content
                .replacingOccurrences(of: "](\(legacyPath))", with: "](\(MarkdownShowcaseSeed.imageAssetPath))")
                .replacingOccurrences(of: "src=\"\(legacyPath)\"", with: "src=\"\(MarkdownShowcaseSeed.imageAssetPath)\""),
        )
    }

    private func persistUnlocked(_ note: Note) throws {
        let noteDirectoryURL = noteDirectoryURL(for: note)
        let markdownURL = noteURL(for: note)
        let metadataURL = noteDirectoryURL.appendingPathComponent(Self.metadataFilename, isDirectory: false)

        try fileManager.createDirectory(at: noteDirectoryURL, withIntermediateDirectories: true)
        guard let data = note.content.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: markdownURL, options: .atomic)

        let metadata = StoredNoteMetadata(
            schemaVersion: Self.storageSchemaVersion,
            id: note.id,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            deletedAt: note.deletedAt,
            originalFolderPath: note.originalFolderPath,
        )
        let metadataData = try metadataEncoder.encode(metadata)
        try metadataData.write(to: metadataURL, options: .atomic)
    }

    private func stageOrphanedAssetsUnlocked(for note: Note) throws {
        let noteDirectoryURL = noteDirectoryURL(for: note)
        let assetsDirectoryURL = noteAssetsDirectoryURL(for: note)
        let referencedAssets = Self.referencedAssetPaths(in: note.content)
        let existingAssets = try existingAssetPathsUnlocked(in: assetsDirectoryURL)
        var stagedAssets = try loadStagedOrphanedAssetsUnlocked(from: noteDirectoryURL)

        stagedAssets.formUnion(existingAssets.subtracting(referencedAssets))
        stagedAssets.subtract(referencedAssets)
        stagedAssets.formIntersection(existingAssets)

        try persistStagedOrphanedAssetsUnlocked(stagedAssets, in: noteDirectoryURL)
    }

    private func pruneStagedOrphanedAssetsUnlocked() throws {
        guard fileManager.fileExists(atPath: notesDirectory.path(percentEncoded: false)) else { return }
        for entry in try storedNoteEntriesUnlocked() {
            try pruneStagedOrphanedAssetsUnlocked(in: entry.directoryURL)
        }
    }

    private func pruneStagedOrphanedAssetsUnlocked(in noteDirectoryURL: URL) throws {
        let stagedAssets = try loadStagedOrphanedAssetsUnlocked(from: noteDirectoryURL)
        guard !stagedAssets.isEmpty else { return }

        let markdownURL = noteDirectoryURL.appendingPathComponent(Self.noteFilename, isDirectory: false)
        let content = try String(contentsOf: markdownURL, encoding: .utf8)
        let referencedAssets = Self.referencedAssetPaths(in: content)

        for relativePath in stagedAssets where !referencedAssets.contains(relativePath) {
            let assetURL = noteDirectoryURL.appendingPathComponent(relativePath, isDirectory: false)
            if fileManager.fileExists(atPath: assetURL.path(percentEncoded: false)) {
                try fileManager.removeItem(at: assetURL)
            }
        }

        try persistStagedOrphanedAssetsUnlocked([], in: noteDirectoryURL)
    }

    private func loadStagedOrphanedAssetsUnlocked(from noteDirectoryURL: URL) throws -> Set<String> {
        let manifestURL = stagedOrphanedAssetsManifestURL(for: noteDirectoryURL)
        guard fileManager.fileExists(atPath: manifestURL.path(percentEncoded: false)) else { return [] }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try metadataDecoder.decode(StagedOrphanedAssets.self, from: data)
        return Set(manifest.relativePaths)
    }

    private func persistStagedOrphanedAssetsUnlocked(_ relativePaths: Set<String>, in noteDirectoryURL: URL) throws {
        let manifestURL = stagedOrphanedAssetsManifestURL(for: noteDirectoryURL)
        if relativePaths.isEmpty {
            if fileManager.fileExists(atPath: manifestURL.path(percentEncoded: false)) {
                try fileManager.removeItem(at: manifestURL)
            }
            return
        }

        let manifest = StagedOrphanedAssets(
            schemaVersion: Self.orphanedAssetsSchemaVersion,
            relativePaths: relativePaths.sorted(),
        )
        let data = try metadataEncoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func existingAssetPathsUnlocked(in assetsDirectoryURL: URL) throws -> Set<String> {
        guard fileManager.fileExists(atPath: assetsDirectoryURL.path(percentEncoded: false)) else { return [] }
        let files = try recursiveRegularFilesUnlocked(in: assetsDirectoryURL)
        let assetRootComponents = assetsDirectoryURL.standardizedFileURL.pathComponents
        return Set(files.map { fileURL in
            let relativeComponents = fileURL.standardizedFileURL.pathComponents.dropFirst(assetRootComponents.count)
            let relativePath = relativeComponents.joined(separator: "/")
            return Self.relativeAssetPath(for: relativePath)
        })
    }

    private func stagedOrphanedAssetsManifestURL(for noteDirectoryURL: URL) -> URL {
        noteDirectoryURL.appendingPathComponent(Self.stagedOrphanedAssetsFilename, isDirectory: false)
    }

    private func persistShowcaseImageUnlockedIfNeeded(for note: Note) throws {
        let assetsDirectoryURL = noteAssetsDirectoryURL(for: note)
        let assetURL = assetsDirectoryURL.appendingPathComponent(MarkdownShowcaseSeed.imageFilename, isDirectory: false)
        guard !fileManager.fileExists(atPath: assetURL.path(percentEncoded: false)) else { return }
        try fileManager.createDirectory(at: assetsDirectoryURL, withIntermediateDirectories: true)
        let data = try MarkdownShowcaseSeed.imageData()
        try data.write(to: assetURL, options: .atomic)
    }

    private func repairShowcaseImageUnlockedIfNeeded(for note: Note) throws {
        guard note.title == "Markdown Showcase",
              note.content.contains(MarkdownShowcaseSeed.imageAssetPath) else { return }
        try persistShowcaseImageUnlockedIfNeeded(for: note)
    }

    private func copyLegacyShowcaseAssetUnlockedIfNeeded(from legacyAssetURL: URL, to note: Note) throws {
        guard fileManager.fileExists(atPath: legacyAssetURL.path(percentEncoded: false)),
              note.content.contains(MarkdownShowcaseSeed.imageAssetPath) else { return }

        let assetsDirectoryURL = noteAssetsDirectoryURL(for: note)
        let destinationURL = assetsDirectoryURL.appendingPathComponent(MarkdownShowcaseSeed.imageFilename, isDirectory: false)
        guard !fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) else { return }

        try fileManager.createDirectory(at: assetsDirectoryURL, withIntermediateDirectories: true)
        let data = try Data(contentsOf: legacyAssetURL)
        try data.write(to: destinationURL, options: .atomic)
    }

    private func copyAssetsUnlocked(from source: Note, to destination: Note) throws {
        let sourceAssetsDirectoryURL = noteAssetsDirectoryURL(for: source)
        guard fileManager.fileExists(atPath: sourceAssetsDirectoryURL.path(percentEncoded: false)) else { return }

        let destinationAssetsDirectoryURL = noteAssetsDirectoryURL(for: destination)
        try fileManager.createDirectory(at: destinationAssetsDirectoryURL, withIntermediateDirectories: true)

        let sourceContents = try fileManager.contentsOfDirectory(
            at: sourceAssetsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles],
        )
        for item in sourceContents {
            try copyDirectoryItemUnlocked(
                at: item,
                to: destinationAssetsDirectoryURL.appendingPathComponent(
                    item.lastPathComponent,
                    isDirectory: item.hasDirectoryPath,
                ),
            )
        }
    }

    private func copyDirectoryItemUnlocked(at sourceURL: URL, to destinationURL: URL) throws {
        if sourceURL.hasDirectoryPath {
            try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            let children = try fileManager.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles],
            )
            for child in children {
                try copyDirectoryItemUnlocked(
                    at: child,
                    to: destinationURL.appendingPathComponent(child.lastPathComponent, isDirectory: child.hasDirectoryPath),
                )
            }
            return
        }

        let data = try Data(contentsOf: sourceURL)
        try data.write(to: destinationURL, options: .atomic)
    }

    private func makeSnapshotEntryUnlocked(
        from noteDirectoryURL: URL,
        folderPath: String,
        includeContentFingerprint: Bool = true,
    ) throws -> NotesDirectorySnapshot.Entry {
        let files = try recursiveRegularFilesUnlocked(in: noteDirectoryURL)
            .sorted {
                $0.path.replacingOccurrences(of: noteDirectoryURL.path(percentEncoded: false) + "/", with: "")
                    < $1.path.replacingOccurrences(of: noteDirectoryURL.path(percentEncoded: false) + "/", with: "")
            }

        var modifiedAt: TimeInterval = 0
        var totalSize: UInt64 = 0
        var fingerprint: UInt64 = 14_695_981_039_346_656_037

        for fileURL in files {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path(percentEncoded: false))
            let relativePath = fileURL.path(percentEncoded: false).replacingOccurrences(of: noteDirectoryURL.path(percentEncoded: false) + "/", with: "")
            modifiedAt = max(modifiedAt, (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            totalSize += (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            if includeContentFingerprint {
                let data = try Data(contentsOf: fileURL)
                fingerprint = Self.hashing(relativePath.utf8, into: fingerprint)
                fingerprint = Self.hashing(data, into: fingerprint)
            }
        }

        return .init(
            filename: Self.joinedFolderPath(parent: folderPath, child: noteDirectoryURL.lastPathComponent),
            modifiedAt: modifiedAt,
            fileSize: totalSize,
            contentFingerprint: includeContentFingerprint ? fingerprint : 0,
        )
    }

    private func makeLegacyFlatSnapshotEntryUnlocked(from fileURL: URL) throws -> NotesDirectorySnapshot.Entry {
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path(percentEncoded: false))
        return .init(
            filename: "__legacy_flat__/\(fileURL.lastPathComponent)",
            modifiedAt: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            fileSize: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            contentFingerprint: 0,
        )
    }

    private func directoryContainsFilesUnlocked(at url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return false }
        guard let files = try? recursiveRegularFilesUnlocked(in: url) else { return false }
        return !files.isEmpty
    }

    private func copyAssetsForExportUnlocked(
        files: [URL],
        from sourceRoot: URL,
        to destinationRoot: URL,
    ) throws -> Int {
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let sourceComponentCount = sourceRoot.standardizedFileURL.pathComponents.count
        var copied = 0
        for sourceFile in files {
            let relativeComponents = sourceFile.standardizedFileURL
                .pathComponents
                .dropFirst(sourceComponentCount)
            guard !relativeComponents.isEmpty else { continue }
            let targetURL = relativeComponents.reduce(destinationRoot) { partial, component in
                partial.appendingPathComponent(component, isDirectory: false)
            }
            try fileManager.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            if fileManager.fileExists(atPath: targetURL.path(percentEncoded: false)) {
                try fileManager.removeItem(at: targetURL)
            }
            try fileManager.copyItem(at: sourceFile, to: targetURL)
            copied += 1
        }
        return copied
    }

    private func recursiveRegularFilesUnlocked(in directoryURL: URL) throws -> [URL] {
        let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
        )

        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    private func makeNewNote(content: String, createdAt: Date = Date(), folderPath: String = "") -> Note {
        let id = UUID()
        return Note(
            id: id,
            filename: Self.noteRelativePath(forDirectoryNamed: id.uuidString.lowercased()),
            folderPath: folderPath,
            createdAt: createdAt,
            updatedAt: createdAt,
            content: content,
        )
    }

    private func noteDirectoryName(for note: Note) -> String {
        let components = note.filename.split(separator: "/", omittingEmptySubsequences: true)
        if let first = components.first, !first.isEmpty {
            return String(first)
        }
        return note.stableID
    }

    private static func noteRelativePath(forDirectoryNamed directoryName: String) -> String {
        "\(directoryName)/\(noteFilename)"
    }

    static func trimmedFolderPath(_ rawPath: String) -> String {
        rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func parentFolderPath(of folderPath: String) -> String {
        let components = folderPath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else { return "" }
        return components.dropLast().joined(separator: "/")
    }

    static func joinedFolderPath(parent: String, child: String) -> String {
        parent.isEmpty ? child : "\(parent)/\(child)"
    }

    static func isPath(_ candidate: String, descendantOf ancestor: String) -> Bool {
        guard !ancestor.isEmpty else { return !candidate.isEmpty }
        return candidate == ancestor || candidate.hasPrefix("\(ancestor)/")
    }

    private func normalizedExistingFolderPathUnlocked(_ rawPath: String) throws -> String {
        let trimmed = Self.trimmedFolderPath(rawPath)
        guard !trimmed.isEmpty else { return "" }
        try ensureFolderExistsUnlocked(at: trimmed)
        try ensureNoNoteAncestorUnlocked(trimmed)
        return trimmed
    }

    private func ensureFolderExistsUnlocked(at folderPath: String) throws {
        let url = folderURL(for: folderPath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw NotesRepositoryFolderError.notFound(folderPath)
        }
    }

    /// Walks every prefix of `folderPath` (including the path itself) and
    /// rejects if any of them is a note directory — i.e. contains `note.md`.
    /// Without this guard a path like `Work/<UUID>/Sub` happily creates a
    /// directory inside a note, where the walker would never find anything
    /// stored there because it stops at the first `note.md`.
    private func ensureNoNoteAncestorUnlocked(_ folderPath: String) throws {
        let trimmed = Self.trimmedFolderPath(folderPath)
        guard !trimmed.isEmpty else { return }
        var current = ""
        for component in trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            current = Self.joinedFolderPath(parent: current, child: component)
            let noteFile = folderURL(for: current).appendingPathComponent(Self.noteFilename, isDirectory: false)
            if fileManager.fileExists(atPath: noteFile.path(percentEncoded: false)) {
                throw NotesRepositoryFolderError.cannotNestInsideNote(notePath: current)
            }
        }
    }

    private func validateFolderPathComponents(_ folderPath: String) throws {
        let components = folderPath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else {
            throw NotesRepositoryFolderError.invalidName(folderPath)
        }
        for component in components {
            try validateFolderName(String(component))
        }
    }

    private func validateFolderName(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\0")
        else {
            throw NotesRepositoryFolderError.invalidName(name)
        }
        let limit = pathconfNameMax(at: notesDirectory)
        let utf8Length = name.lengthOfBytes(using: .utf8)
        if utf8Length > limit {
            throw NotesRepositoryFolderError.nameTooLong(name, limit: limit)
        }
    }

    private func validateAbsolutePathLength(_ url: URL) throws {
        let absolutePath = url.path(percentEncoded: false)
        let limit = pathconfPathMax(at: notesDirectory)
        if absolutePath.lengthOfBytes(using: .utf8) > limit {
            throw NotesRepositoryFolderError.pathTooLong(absolutePath, limit: limit)
        }
    }

    private func pathconfNameMax(at url: URL) -> Int {
        pathconfValue(at: url, name: Int32(_PC_NAME_MAX), fallback: 255)
    }

    private func pathconfPathMax(at url: URL) -> Int {
        pathconfValue(at: url, name: Int32(_PC_PATH_MAX), fallback: 4096)
    }

    private func pathconfValue(at url: URL, name: Int32, fallback: Int) -> Int {
        #if canImport(Glibc)
        let value = url.path(percentEncoded: false).withCString { cString in
            Glibc.pathconf(cString, name)
        }
        if value > 0 { return Int(value) }
        #endif
        return fallback
    }

    private static func relativeAssetPath(for filename: String) -> String {
        "\(assetsDirectoryName)/\(filename)"
    }

    private static func referencedAssetPaths(in content: String) -> Set<String> {
        let pattern = #"assets/[A-Za-z0-9._%+\-/]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(content.startIndex ..< content.endIndex, in: content)
        let matches = regex.matches(in: content, range: range)
        return Set(matches.compactMap { match in
            guard let range = Range(match.range, in: content) else { return nil }
            return String(content[range])
        })
    }

    private static func normalizedImageExtension(for sourceURL: URL) -> String? {
        let imageExtension = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard supportedImageExtensions.contains(imageExtension) else { return nil }
        return imageExtension
    }

    private func uniqueImportedAssetFilenameUnlocked(
        baseName: String,
        imageExtension: String,
        in assetsDirectoryURL: URL,
    ) -> String {
        var index = 1
        while true {
            let suffix = index == 1 ? "" : "-\(index)"
            let filename = "\(baseName)\(suffix).\(imageExtension)"
            let candidateURL = assetsDirectoryURL.appendingPathComponent(filename, isDirectory: false)
            if !fileManager.fileExists(atPath: candidateURL.path(percentEncoded: false)) {
                return filename
            }
            index += 1
        }
    }

    private static func id(fromLegacyFilename filename: String) -> UUID {
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

    private static func createdAt(fromLegacyFilename filename: String) -> Date? {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        guard let timestamp = stem.components(separatedBy: "--").first else { return nil }
        let restored = timestamp.replacingOccurrences(of: "-", with: ":")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: restored)
    }

    private static func hashing(_ bytes: some Sequence<UInt8>, into seed: UInt64) -> UInt64 {
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func metadataDateString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func metadataDate(from value: String) -> Date? {
        let preciseFormatter = ISO8601DateFormatter()
        preciseFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let preciseDate = preciseFormatter.date(from: value) {
            return preciseDate
        }

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]
        return fallbackFormatter.date(from: value)
    }
}
