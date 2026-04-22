import Foundation

public enum NotesDirectoryRelocator {
    public struct RelocationError: LocalizedError {
        public let message: String

        public init(message: String) {
            self.message = message
        }

        public var errorDescription: String? {
            message
        }
    }

    public static func relocate(
        from sourceDirectory: URL,
        to destinationDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let sourceDirectory = sourceDirectory.standardizedFileURL
        let destinationDirectory = destinationDirectory.standardizedFileURL

        guard sourceDirectory != destinationDirectory else { return }

        if destinationDirectory.path(percentEncoded: false).hasPrefix(sourceDirectory.path(percentEncoded: false) + "/") {
            throw RelocationError(
                message: "The new notes folder cannot be inside the current notes folder."
            )
        }

        var sourceIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceDirectory.path(percentEncoded: false), isDirectory: &sourceIsDirectory),
              sourceIsDirectory.boolValue else {
            throw RelocationError(message: "The current notes folder could not be found.")
        }

        var destinationIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destinationDirectory.path(percentEncoded: false), isDirectory: &destinationIsDirectory) {
            guard destinationIsDirectory.boolValue else {
                throw RelocationError(message: "The selected destination is not a folder.")
            }
            let destinationContents = try fileManager.contentsOfDirectory(
                at: destinationDirectory,
                includingPropertiesForKeys: nil,
                options: []
            )
            guard destinationContents.isEmpty else {
                throw RelocationError(message: "Choose an empty destination folder for your notes.")
            }

            let sourceContents = try fileManager.contentsOfDirectory(
                at: sourceDirectory,
                includingPropertiesForKeys: nil,
                options: []
            )
            for item in sourceContents {
                try fileManager.moveItem(
                    at: item,
                    to: destinationDirectory.appendingPathComponent(
                        item.lastPathComponent,
                        isDirectory: item.hasDirectoryPath
                    )
                )
            }
            try fileManager.removeItem(at: sourceDirectory)
            return
        }

        try fileManager.createDirectory(
            at: destinationDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: sourceDirectory, to: destinationDirectory)
    }
}
