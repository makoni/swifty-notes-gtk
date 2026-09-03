import Adwaita
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
        fileManager: FileManager = .default,
    ) throws {
        try relocateInternal(
            from: sourceDirectory,
            to: destinationDirectory,
            fileManager: fileManager,
            debugFailMoveAtIndex: nil,
        )
    }

    /// Internal entry point that exposes a fault-injection knob for unit
    /// tests so they can exercise the rollback path without depending on
    /// filesystem-permission tricks. Production callers go through
    /// ``relocate(from:to:fileManager:)``.
    static func relocateInternal(
        from sourceDirectory: URL,
        to destinationDirectory: URL,
        fileManager: FileManager = .default,
        debugFailMoveAtIndex: Int? = nil,
    ) throws {
        let sourceDirectory = sourceDirectory.standardizedFileURL
        let destinationDirectory = destinationDirectory.standardizedFileURL

        guard sourceDirectory != destinationDirectory else { return }

        if destinationDirectory.path(percentEncoded: false).hasPrefix(sourceDirectory.path(percentEncoded: false) + "/") {
            throw RelocationError(
                message: "The new notes folder cannot be inside the current notes folder.".localized
            )
        }

        var sourceIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceDirectory.path(percentEncoded: false), isDirectory: &sourceIsDirectory),
              sourceIsDirectory.boolValue
        else {
            throw RelocationError(message: "The current notes folder could not be found.".localized)
        }

        let destinationExistedBeforeRelocate: Bool
        var destinationIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destinationDirectory.path(percentEncoded: false), isDirectory: &destinationIsDirectory) {
            guard destinationIsDirectory.boolValue else {
                throw RelocationError(message: "The selected destination is not a folder.".localized)
            }
            let destinationContents = try fileManager.contentsOfDirectory(
                at: destinationDirectory,
                includingPropertiesForKeys: nil,
                options: [],
            )
            guard destinationContents.isEmpty else {
                throw RelocationError(message: "Choose an empty destination folder for your notes.".localized)
            }
            destinationExistedBeforeRelocate = true
        } else {
            try fileManager.createDirectory(
                at: destinationDirectory.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            destinationExistedBeforeRelocate = false
        }

        let sourceContents = try fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil,
            options: [],
        )
        var movedItems: [(originalSource: URL, currentDestination: URL)] = []
        do {
            for (index, item) in sourceContents.enumerated() {
                if let failIndex = debugFailMoveAtIndex, failIndex == index {
                    throw RelocationError(message: "Simulated move failure for tests.")
                }
                let target = destinationDirectory.appendingPathComponent(
                    item.lastPathComponent,
                    isDirectory: item.hasDirectoryPath,
                )
                try fileManager.moveItem(at: item, to: target)
                movedItems.append((item, target))
            }
            try fileManager.removeItem(at: sourceDirectory)
        } catch {
            for (originalSource, currentDestination) in movedItems.reversed() {
                try? fileManager.moveItem(at: currentDestination, to: originalSource)
            }
            if !destinationExistedBeforeRelocate {
                try? fileManager.removeItem(at: destinationDirectory)
            }
            throw error
        }
    }
}
