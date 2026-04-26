import Foundation

public enum EditorIndentStyle: String, Codable, CaseIterable, Equatable, Sendable {
    case spaces
    case tabs

    public var displayName: String {
        switch self {
        case .spaces:
            "Spaces"
        case .tabs:
            "Tabs"
        }
    }
}

public enum AppearanceMode: String, Codable, CaseIterable, Equatable, Sendable {
    case system
    case light
    case dark

    public var displayName: String {
        switch self {
        case .system:
            "Follow system"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let defaultEditorFontSize = 14
    public static let defaultEditorTabWidth = 4
    public static let defaultAutosaveDelaySeconds = 2

    public var customNotesDirectoryPath: String?
    public var wrapsEditorLines: Bool
    public var editorFontSize: Int
    public var editorTabWidth: Int
    public var editorIndentStyle: EditorIndentStyle
    public var autosaveDelaySeconds: Int
    public var appearanceMode: AppearanceMode

    public init(
        customNotesDirectoryPath: String? = nil,
        wrapsEditorLines: Bool = true,
        editorFontSize: Int = AppSettings.defaultEditorFontSize,
        editorTabWidth: Int = AppSettings.defaultEditorTabWidth,
        editorIndentStyle: EditorIndentStyle = .spaces,
        autosaveDelaySeconds: Int = AppSettings.defaultAutosaveDelaySeconds,
        appearanceMode: AppearanceMode = .system,
    ) {
        self.customNotesDirectoryPath = customNotesDirectoryPath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.wrapsEditorLines = wrapsEditorLines
        self.editorFontSize = Self.clampedEditorFontSize(editorFontSize)
        self.editorTabWidth = Self.clampedEditorTabWidth(editorTabWidth)
        self.editorIndentStyle = editorIndentStyle
        self.autosaveDelaySeconds = Self.clampedAutosaveDelaySeconds(autosaveDelaySeconds)
        self.appearanceMode = appearanceMode
    }

    public static let `default` = AppSettings()

    public var customNotesDirectoryURL: URL? {
        guard let customNotesDirectoryPath, !customNotesDirectoryPath.isEmpty else { return nil }
        return URL(fileURLWithPath: customNotesDirectoryPath, isDirectory: true).standardizedFileURL
    }

    public func resolvedNotesDirectory(
        defaultDirectory: URL = NotesRepository.fallbackNotesDirectory(),
    ) -> URL {
        customNotesDirectoryURL ?? defaultDirectory.standardizedFileURL
    }

    public func updatingNotesDirectory(
        _ directory: URL,
        defaultDirectory: URL = NotesRepository.fallbackNotesDirectory(),
    ) -> AppSettings {
        let standardizedDirectory = directory.standardizedFileURL
        let standardizedDefault = defaultDirectory.standardizedFileURL
        if standardizedDirectory == standardizedDefault {
            return AppSettings(
                customNotesDirectoryPath: nil,
                wrapsEditorLines: wrapsEditorLines,
                editorFontSize: editorFontSize,
                editorTabWidth: editorTabWidth,
                editorIndentStyle: editorIndentStyle,
                autosaveDelaySeconds: autosaveDelaySeconds,
                appearanceMode: appearanceMode,
            )
        }
        return AppSettings(
            customNotesDirectoryPath: standardizedDirectory.path(percentEncoded: false),
            wrapsEditorLines: wrapsEditorLines,
            editorFontSize: editorFontSize,
            editorTabWidth: editorTabWidth,
            editorIndentStyle: editorIndentStyle,
            autosaveDelaySeconds: autosaveDelaySeconds,
            appearanceMode: appearanceMode,
        )
    }

    public func normalized(
        defaultDirectory: URL = NotesRepository.fallbackNotesDirectory(),
    ) -> AppSettings {
        updatingNotesDirectory(
            resolvedNotesDirectory(defaultDirectory: defaultDirectory),
            defaultDirectory: defaultDirectory,
        )
    }

    /// Drops `customNotesDirectoryPath` if the directory it points to no
    /// longer exists on disk (or no longer is a directory).
    ///
    /// Used at launch to recover from settings that reference a since-removed
    /// location. The common case is an XDG Document Portal bind-mount path
    /// (`/run/user/UID/doc/HASH/...`) saved in an older Flatpak build before
    /// the `home` filesystem permission was granted — those mounts are
    /// per-session and disappear (or get a different HASH) between runs,
    /// which would otherwise leave the user stuck on a notes folder that
    /// doesn't exist anymore.
    public func normalizedAgainstFilesystem(
        fileManager: FileManager = .default,
    ) -> AppSettings {
        guard let customPath = customNotesDirectoryPath, !customPath.isEmpty else {
            return self
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: customPath, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return self
        }
        return AppSettings(
            customNotesDirectoryPath: nil,
            wrapsEditorLines: wrapsEditorLines,
            editorFontSize: editorFontSize,
            editorTabWidth: editorTabWidth,
            editorIndentStyle: editorIndentStyle,
            autosaveDelaySeconds: autosaveDelaySeconds,
            appearanceMode: appearanceMode,
        )
    }

    private enum CodingKeys: String, CodingKey {
        case customNotesDirectoryPath
        case wrapsEditorLines
        case editorFontSize
        case editorTabWidth
        case editorIndentStyle
        case autosaveDelaySeconds
        case appearanceMode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            customNotesDirectoryPath: container.decodeIfPresent(String.self, forKey: .customNotesDirectoryPath),
            wrapsEditorLines: container.decodeIfPresent(Bool.self, forKey: .wrapsEditorLines) ?? true,
            editorFontSize: container.decodeIfPresent(Int.self, forKey: .editorFontSize) ?? Self.defaultEditorFontSize,
            editorTabWidth: container.decodeIfPresent(Int.self, forKey: .editorTabWidth) ?? Self.defaultEditorTabWidth,
            editorIndentStyle: container.decodeIfPresent(EditorIndentStyle.self, forKey: .editorIndentStyle) ?? .spaces,
            autosaveDelaySeconds: container.decodeIfPresent(Int.self, forKey: .autosaveDelaySeconds) ?? Self.defaultAutosaveDelaySeconds,
            appearanceMode: container.decodeIfPresent(AppearanceMode.self, forKey: .appearanceMode) ?? .system,
        )
    }

    private static func clampedEditorFontSize(_ value: Int) -> Int {
        min(max(value, 10), 32)
    }

    private static func clampedEditorTabWidth(_ value: Int) -> Int {
        min(max(value, 1), 8)
    }

    private static func clampedAutosaveDelaySeconds(_ value: Int) -> Int {
        min(max(value, 1), 60)
    }
}
