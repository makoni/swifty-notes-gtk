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
        guard fileManager.fileExists(atPath: stateFileURL.path()) else {
            return .default
        }
        let data = try Data(contentsOf: stateFileURL)
        return try decoder.decode(WorkspaceState.self, from: data)
    }

    public func save(_ state: WorkspaceState) throws {
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
        return base
            .appendingPathComponent("io.github.makoni.SwiftyNotes", isDirectory: true)
            .appendingPathComponent("workspace.json", isDirectory: false)
    }
}
