import Foundation

enum AppIdentity {
    static let identifier = "me.spaceinbox.swiftynotes"
    static let legacyIdentifier = "me.spaceinbox.SwiftyNotes"
    static let oldestLegacyIdentifier = "io.github.makoni.SwiftyNotes"
    static let legacyIdentifiers = [legacyIdentifier, oldestLegacyIdentifier]
    static let notesRepositoryQueueLabel = "\(identifier).notes-repository"

    static func applicationDirectory(in base: URL, identifier: String = identifier) -> URL {
        base.appendingPathComponent(identifier, isDirectory: true)
    }

    static func migrateApplicationDirectoryIfNeeded(
        currentDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        guard currentDirectory.lastPathComponent == identifier else { return }
        guard !fileManager.fileExists(atPath: currentDirectory.path(percentEncoded: false)) else { return }

        let baseDirectory = currentDirectory.deletingLastPathComponent()
        for legacyIdentifier in legacyIdentifiers {
            let legacyDirectory = applicationDirectory(in: baseDirectory, identifier: legacyIdentifier)
            guard fileManager.fileExists(atPath: legacyDirectory.path(percentEncoded: false)) else { continue }

            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            try fileManager.moveItem(at: legacyDirectory, to: currentDirectory)
            return
        }
    }
}
