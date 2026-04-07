import Foundation

public final class WorkspaceStateStore {
    private let stateFileURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        stateFileURL: URL = WorkspaceStateStore.defaultStateFileURL(),
        fileManager: FileManager = .default
    ) {
        self.stateFileURL = stateFileURL
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() throws -> WorkspaceState {
        try migrateLegacyStateIfNeeded()
        guard fileManager.fileExists(atPath: stateFileURL.path()) else {
            return .default
        }
        let data = try Data(contentsOf: stateFileURL)
        return try decoder.decode(WorkspaceState.self, from: data)
    }

    public func save(_ state: WorkspaceState) throws {
        try migrateLegacyStateIfNeeded()
        let directory = stateFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(state)
        try data.write(to: stateFileURL, options: .atomic)
    }

    public static func defaultStateFileURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        let base: URL
        if let xdgStateHome = env["XDG_STATE_HOME"], !xdgStateHome.isEmpty {
            base = URL(fileURLWithPath: xdgStateHome, isDirectory: true)
        } else {
            base = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("state", isDirectory: true)
        }
        return AppIdentity.applicationDirectory(in: base)
            .appendingPathComponent("workspace.json", isDirectory: false)
    }

    private func migrateLegacyStateIfNeeded() throws {
        guard stateFileURL.lastPathComponent == "workspace.json" else { return }
        let appDirectory = stateFileURL.deletingLastPathComponent()
        guard appDirectory.lastPathComponent == AppIdentity.identifier else { return }

        let baseDirectory = appDirectory.deletingLastPathComponent()
        let legacyAppDirectory = AppIdentity.applicationDirectory(
            in: baseDirectory,
            identifier: AppIdentity.legacyIdentifier
        )

        guard !fileManager.fileExists(atPath: appDirectory.path()),
              fileManager.fileExists(atPath: legacyAppDirectory.path()) else { return }

        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try fileManager.moveItem(at: legacyAppDirectory, to: appDirectory)
    }
}
