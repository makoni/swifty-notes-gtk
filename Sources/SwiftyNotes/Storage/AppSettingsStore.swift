import Foundation

public final class AppSettingsStore {
    private let settingsFileURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        settingsFileURL: URL = AppSettingsStore.defaultSettingsFileURL(),
        fileManager: FileManager = .default
    ) {
        self.settingsFileURL = settingsFileURL
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() throws -> AppSettings {
        try migrateLegacySettingsIfNeeded()
        guard fileManager.fileExists(atPath: settingsFileURL.path(percentEncoded: false)) else {
            return .default
        }
        let data = try Data(contentsOf: settingsFileURL)
        return try decoder.decode(AppSettings.self, from: data)
    }

    public func save(_ settings: AppSettings) throws {
        try migrateLegacySettingsIfNeeded()
        let directory = settingsFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(settings)
        try data.write(to: settingsFileURL, options: .atomic)
    }

    public static func defaultSettingsFileURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        let base: URL
        if let xdgConfigHome = env["XDG_CONFIG_HOME"], !xdgConfigHome.isEmpty {
            base = URL(fileURLWithPath: xdgConfigHome, isDirectory: true)
        } else {
            base = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
        }
        return AppIdentity.applicationDirectory(in: base)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    private func migrateLegacySettingsIfNeeded() throws {
        guard settingsFileURL.lastPathComponent == "settings.json" else { return }
        let appDirectory = settingsFileURL.deletingLastPathComponent()
        try AppIdentity.migrateApplicationDirectoryIfNeeded(currentDirectory: appDirectory, fileManager: fileManager)
    }
}
