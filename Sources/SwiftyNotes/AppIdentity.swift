import Foundation

enum AppIdentity {
    static let identifier = "me.spaceinbox.SwiftyNotes"
    static let legacyIdentifier = "io.github.makoni.SwiftyNotes"
    static let notesRepositoryQueueLabel = "\(identifier).notes-repository"

    static func applicationDirectory(in base: URL, identifier: String = identifier) -> URL {
        base.appendingPathComponent(identifier, isDirectory: true)
    }
}
