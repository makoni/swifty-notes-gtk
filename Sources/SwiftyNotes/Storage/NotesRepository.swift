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

private struct StoredNoteMetadata: Codable {
    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
}

private struct StagedOrphanedAssets: Codable {
    let schemaVersion: Int
    let relativePaths: [String]
}

private enum NotesRepositoryAssetImportError: LocalizedError {
    case unsupportedImageType(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedImageType(filename):
            return "Unsupported image type for \(filename)."
        }
    }
}

public final class NotesRepository: @unchecked Sendable {
    private static let noteFilename = "note.md"
    private static let metadataFilename = "meta.json"
    private static let assetsDirectoryName = "assets"
    private static let stagedOrphanedAssetsFilename = ".orphaned-assets.json"
    private static let storageSchemaVersion = 1
    private static let orphanedAssetsSchemaVersion = 1
    private static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff"
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
        fileManager: FileManager = .default
    ) {
        self.notesDirectory = notesDirectory
        self.fileManager = fileManager
        self.formatter = ISO8601DateFormatter()
        self.queue = DispatchQueue(label: AppIdentity.notesRepositoryQueueLabel)
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
        let base: URL
        if let xdgDataHome = env["XDG_DATA_HOME"], !xdgDataHome.isEmpty {
            base = URL(fileURLWithPath: xdgDataHome, isDirectory: true)
        } else {
            base = fm.homeDirectoryForCurrentUser
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
            let notes = try storedNoteDirectoriesUnlocked().map(loadNoteUnlocked(from:))
            for note in notes {
                try repairShowcaseImageUnlockedIfNeeded(for: note)
            }
            return notes.sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.stableID > $1.stableID
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
            try copyAssetsUnlocked(from: note, to: duplicated)
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

    public func importImageAsset(from sourceURL: URL, for note: Note) throws -> String {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            guard let imageExtension = Self.normalizedImageExtension(for: sourceURL) else {
                throw NotesRepositoryAssetImportError.unsupportedImageType(sourceURL.lastPathComponent)
            }

            let assetsDirectoryURL = noteAssetsDirectoryURL(for: note)
            try fileManager.createDirectory(at: assetsDirectoryURL, withIntermediateDirectories: true)

            let stem = Note.sanitizedFilenameStem(
                from: sourceURL.deletingPathExtension().lastPathComponent,
                defaultStem: "image"
            )
            let filename = uniqueImportedAssetFilenameUnlocked(
                baseName: stem,
                imageExtension: imageExtension,
                in: assetsDirectoryURL
            )
            let destinationURL = assetsDirectoryURL.appendingPathComponent(filename, isDirectory: false)
            let data = try Data(contentsOf: sourceURL)
            try data.write(to: destinationURL, options: .atomic)
            return Self.relativeAssetPath(for: filename)
        }
    }

    public func save(note: Note) throws -> Note {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            let updated = Note(
                id: note.id,
                filename: Self.noteRelativePath(forDirectoryNamed: noteDirectoryName(for: note)),
                createdAt: note.createdAt,
                updatedAt: Date(),
                content: note.content
            )
            try persistUnlocked(updated)
            try stageOrphanedAssetsUnlocked(for: updated)
            return updated
        }
    }

    public func delete(note: Note) throws {
        try queue.sync {
            let directoryURL = noteDirectoryURL(for: note)
            if fileManager.fileExists(atPath: directoryURL.path()) {
                try fileManager.removeItem(at: directoryURL)
                return
            }

            let markdownURL = noteURL(for: note)
            if fileManager.fileExists(atPath: markdownURL.path()) {
                try fileManager.removeItem(at: markdownURL)
            }
        }
    }

    public func directorySnapshot() throws -> NotesDirectorySnapshot {
        try queue.sync {
            try ensureNotesDirectoryUnlocked()
            let entries = try storedNoteDirectoriesUnlocked()
                .map(makeSnapshotEntryUnlocked(from:))
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
        notesDirectory.appendingPathComponent(noteDirectoryName(for: note), isDirectory: true)
    }

    public func noteAssetsDirectoryURL(for note: Note) -> URL {
        noteDirectoryURL(for: note).appendingPathComponent(Self.assetsDirectoryName, isDirectory: true)
    }

    @discardableResult
    public func seedMarkdownShowcaseIfNeeded(createdAt: Date = Date()) throws -> Note? {
        try queue.sync { () throws -> Note? in
            try ensureNotesDirectoryUnlocked()
            if try !storedNoteDirectoriesUnlocked().isEmpty {
                return nil
            }

            let note = makeNewNote(content: MarkdownShowcaseSeed.content, createdAt: createdAt)
            try persistUnlocked(note)
            try persistShowcaseImageUnlockedIfNeeded(for: note)
            return note
        }
    }

    @discardableResult
    public func seedDefaultNotesIfNeeded(createdAt: Date = Date()) throws -> [Note] {
        try queue.sync { () throws -> [Note] in
            try ensureNotesDirectoryUnlocked()
            if try !storedNoteDirectoriesUnlocked().isEmpty {
                return []
            }

            let showcase = makeNewNote(content: MarkdownShowcaseSeed.content, createdAt: createdAt)
            try persistUnlocked(showcase)
            try persistShowcaseImageUnlockedIfNeeded(for: showcase)

            let overview = makeNewNote(
                content: SwiftyNotesOverviewSeed.content,
                createdAt: createdAt.addingTimeInterval(-1)
            )
            try persistUnlocked(overview)

            let cliGuide = makeNewNote(
                content: SwiftyNotesCLISeed.content,
                createdAt: createdAt.addingTimeInterval(-2)
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

    private func migrateLegacyStorageIfNeededUnlocked() throws {
        guard notesDirectory.lastPathComponent == "notes" else { return }
        let appDirectory = notesDirectory.deletingLastPathComponent()
        try AppIdentity.migrateApplicationDirectoryIfNeeded(currentDirectory: appDirectory, fileManager: fileManager)
    }

    private func migrateLegacyFlatNoteLayoutIfNeededUnlocked() throws {
        let rootContents = try fileManager.contentsOfDirectory(
            at: notesDirectory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let legacyMarkdownFiles = rootContents
            .filter { !$0.hasDirectoryPath && $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !legacyMarkdownFiles.isEmpty else { return }

        let legacyShowcaseAssetURL = notesDirectory.appendingPathComponent(
            MarkdownShowcaseSeed.legacySharedImageFilename,
            isDirectory: false
        )

        for legacyMarkdownFile in legacyMarkdownFiles {
            var note = try loadLegacyNoteUnlocked(from: legacyMarkdownFile)
            note = migratedLegacyNote(note, legacyShowcaseAssetURL: legacyShowcaseAssetURL)
            try persistUnlocked(note)
            try copyLegacyShowcaseAssetUnlockedIfNeeded(from: legacyShowcaseAssetURL, to: note)
            if fileManager.fileExists(atPath: legacyMarkdownFile.path()) {
                try fileManager.removeItem(at: legacyMarkdownFile)
            }
        }

        if fileManager.fileExists(atPath: legacyShowcaseAssetURL.path()) {
            try fileManager.removeItem(at: legacyShowcaseAssetURL)
        }
    }

    private func storedNoteDirectoriesUnlocked() throws -> [URL] {
        let urls = try fileManager.contentsOfDirectory(
            at: notesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return urls.filter { url in
            guard url.hasDirectoryPath else { return false }
            return fileManager.fileExists(
                atPath: url.appendingPathComponent(Self.noteFilename, isDirectory: false).path()
            )
        }
    }

    private func loadNoteUnlocked(from noteDirectoryURL: URL) throws -> Note {
        let markdownURL = noteDirectoryURL.appendingPathComponent(Self.noteFilename, isDirectory: false)
        let metadataURL = noteDirectoryURL.appendingPathComponent(Self.metadataFilename, isDirectory: false)
        let markdownAttributes = try fileManager.attributesOfItem(atPath: markdownURL.path())
        let content = try String(contentsOf: markdownURL, encoding: .utf8)

        let metadata: StoredNoteMetadata?
        if fileManager.fileExists(atPath: metadataURL.path()) {
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
            createdAt: createdAt,
            updatedAt: updatedAt,
            content: content
        )
    }

    private func loadLegacyNoteUnlocked(from url: URL) throws -> Note {
        let attributes = try fileManager.attributesOfItem(atPath: url.path())
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
            content: content
        )
    }

    private func migratedLegacyNote(_ note: Note, legacyShowcaseAssetURL: URL) -> Note {
        guard fileManager.fileExists(atPath: legacyShowcaseAssetURL.path()) else {
            return note
        }

        let legacyPath = MarkdownShowcaseSeed.legacySharedImageFilename
        guard note.content.contains(legacyPath),
              !note.content.contains(MarkdownShowcaseSeed.imageAssetPath) else {
            return note
        }

        return Note(
            id: note.id,
            filename: Self.noteRelativePath(forDirectoryNamed: note.stableID),
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            content: note.content
                .replacingOccurrences(of: "](\(legacyPath))", with: "](\(MarkdownShowcaseSeed.imageAssetPath))")
                .replacingOccurrences(of: "src=\"\(legacyPath)\"", with: "src=\"\(MarkdownShowcaseSeed.imageAssetPath)\"")
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
            updatedAt: note.updatedAt
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
        guard fileManager.fileExists(atPath: notesDirectory.path()) else { return }
        for noteDirectoryURL in try storedNoteDirectoriesUnlocked() {
            try pruneStagedOrphanedAssetsUnlocked(in: noteDirectoryURL)
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
            if fileManager.fileExists(atPath: assetURL.path()) {
                try fileManager.removeItem(at: assetURL)
            }
        }

        try persistStagedOrphanedAssetsUnlocked([], in: noteDirectoryURL)
    }

    private func loadStagedOrphanedAssetsUnlocked(from noteDirectoryURL: URL) throws -> Set<String> {
        let manifestURL = stagedOrphanedAssetsManifestURL(for: noteDirectoryURL)
        guard fileManager.fileExists(atPath: manifestURL.path()) else { return [] }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try metadataDecoder.decode(StagedOrphanedAssets.self, from: data)
        return Set(manifest.relativePaths)
    }

    private func persistStagedOrphanedAssetsUnlocked(_ relativePaths: Set<String>, in noteDirectoryURL: URL) throws {
        let manifestURL = stagedOrphanedAssetsManifestURL(for: noteDirectoryURL)
        if relativePaths.isEmpty {
            if fileManager.fileExists(atPath: manifestURL.path()) {
                try fileManager.removeItem(at: manifestURL)
            }
            return
        }

        let manifest = StagedOrphanedAssets(
            schemaVersion: Self.orphanedAssetsSchemaVersion,
            relativePaths: relativePaths.sorted()
        )
        let data = try metadataEncoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func existingAssetPathsUnlocked(in assetsDirectoryURL: URL) throws -> Set<String> {
        guard fileManager.fileExists(atPath: assetsDirectoryURL.path()) else { return [] }
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
        guard !fileManager.fileExists(atPath: assetURL.path()) else { return }
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
        guard fileManager.fileExists(atPath: legacyAssetURL.path()),
              note.content.contains(MarkdownShowcaseSeed.imageAssetPath) else { return }

        let assetsDirectoryURL = noteAssetsDirectoryURL(for: note)
        let destinationURL = assetsDirectoryURL.appendingPathComponent(MarkdownShowcaseSeed.imageFilename, isDirectory: false)
        guard !fileManager.fileExists(atPath: destinationURL.path()) else { return }

        try fileManager.createDirectory(at: assetsDirectoryURL, withIntermediateDirectories: true)
        let data = try Data(contentsOf: legacyAssetURL)
        try data.write(to: destinationURL, options: .atomic)
    }

    private func copyAssetsUnlocked(from source: Note, to destination: Note) throws {
        let sourceAssetsDirectoryURL = noteAssetsDirectoryURL(for: source)
        guard fileManager.fileExists(atPath: sourceAssetsDirectoryURL.path()) else { return }

        let destinationAssetsDirectoryURL = noteAssetsDirectoryURL(for: destination)
        try fileManager.createDirectory(at: destinationAssetsDirectoryURL, withIntermediateDirectories: true)

        let sourceContents = try fileManager.contentsOfDirectory(
            at: sourceAssetsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for item in sourceContents {
            try copyDirectoryItemUnlocked(
                at: item,
                to: destinationAssetsDirectoryURL.appendingPathComponent(
                    item.lastPathComponent,
                    isDirectory: item.hasDirectoryPath
                )
            )
        }
    }

    private func copyDirectoryItemUnlocked(at sourceURL: URL, to destinationURL: URL) throws {
        if sourceURL.hasDirectoryPath {
            try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            let children = try fileManager.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for child in children {
                try copyDirectoryItemUnlocked(
                    at: child,
                    to: destinationURL.appendingPathComponent(child.lastPathComponent, isDirectory: child.hasDirectoryPath)
                )
            }
            return
        }

        let data = try Data(contentsOf: sourceURL)
        try data.write(to: destinationURL, options: .atomic)
    }

    private func makeSnapshotEntryUnlocked(from noteDirectoryURL: URL) throws -> NotesDirectorySnapshot.Entry {
        let files = try recursiveRegularFilesUnlocked(in: noteDirectoryURL)
            .sorted {
                $0.path.replacingOccurrences(of: noteDirectoryURL.path() + "/", with: "")
                    < $1.path.replacingOccurrences(of: noteDirectoryURL.path() + "/", with: "")
            }

        var modifiedAt: TimeInterval = 0
        var totalSize: UInt64 = 0
        var fingerprint: UInt64 = 14_695_981_039_346_656_037

        for fileURL in files {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path())
            let relativePath = fileURL.path().replacingOccurrences(of: noteDirectoryURL.path() + "/", with: "")
            let data = try Data(contentsOf: fileURL)
            modifiedAt = max(modifiedAt, (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            totalSize += (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            fingerprint = Self.hashing(relativePath.utf8, into: fingerprint)
            fingerprint = Self.hashing(data, into: fingerprint)
        }

        return .init(
            filename: noteDirectoryURL.lastPathComponent,
            modifiedAt: modifiedAt,
            fileSize: totalSize,
            contentFingerprint: fingerprint
        )
    }

    private func recursiveRegularFilesUnlocked(in directoryURL: URL) throws -> [URL] {
        let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
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

    private func makeNewNote(content: String, createdAt: Date = Date()) -> Note {
        let id = UUID()
        return Note(
            id: id,
            filename: Self.noteRelativePath(forDirectoryNamed: id.uuidString.lowercased()),
            createdAt: createdAt,
            updatedAt: createdAt,
            content: content
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

    private static func relativeAssetPath(for filename: String) -> String {
        "\(assetsDirectoryName)/\(filename)"
    }

    private static func referencedAssetPaths(in content: String) -> Set<String> {
        let pattern = #"assets/[A-Za-z0-9._%+\-/]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
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
        in assetsDirectoryURL: URL
    ) -> String {
        var index = 1
        while true {
            let suffix = index == 1 ? "" : "-\(index)"
            let filename = "\(baseName)\(suffix).\(imageExtension)"
            let candidateURL = assetsDirectoryURL.appendingPathComponent(filename, isDirectory: false)
            if !fileManager.fileExists(atPath: candidateURL.path()) {
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

    private static func hashing<S: Sequence>(_ bytes: S, into seed: UInt64) -> UInt64 where S.Element == UInt8 {
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
