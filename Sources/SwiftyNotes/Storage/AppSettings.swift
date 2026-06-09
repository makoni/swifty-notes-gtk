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

/// Density of the right-hand Outline panel. `comfortable` matches the
/// design's default with full padding and full-size H2 / H3 labels;
/// `compact` tightens row padding and trims label sizes one step so
/// dense documents fit more rows on screen.
public enum OutlineDensity: String, Codable, CaseIterable, Equatable, Sendable {
    case comfortable
    case compact

    public var displayName: String {
        switch self {
        case .comfortable:
            "Comfortable"
        case .compact:
            "Compact"
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
    public var spellCheckEnabled: Bool
    /// IETF-style language tag (`en_US`, `de_DE`, ...) for the
    /// spell-check dictionary. `nil` keeps the libspelling default,
    /// which follows the system locale and the first installed
    /// dictionary that matches it.
    public var spellCheckLanguage: String?
    public var trashRetention: TrashRetention
    /// Outline panel row density. Defaults to ``OutlineDensity.comfortable``,
    /// matching the design.
    public var outlineDensity: OutlineDensity
    /// Whether the outline panel draws vertical tree-lines under each
    /// H2 section. Decorative; defaults to `true`.
    public var outlineTreeLines: Bool
    /// Whether outline rows show a drag-handle on hover. Defaults to
    /// `true`. The drag interaction itself is the Phase 14 follow-up;
    /// this toggle just controls whether the affordance is visible.
    public var outlineDragHandles: Bool
    /// Whether the breadcrumb strip above the editor is visible.
    /// Defaults to `true`. Hidden when the user wants the editor
    /// chrome quieter or runs in a tight window.
    public var outlineBreadcrumbVisible: Bool
    /// Whether `:shortcode:` emoji aliases (the GitHub gemoji vocabulary,
    /// e.g. `:rocket:`) are rendered as their emoji in the preview. The
    /// source text on disk is never changed, and code spans / code blocks
    /// are left literal. Defaults to `true`.
    public var renderEmojiShortcodes: Bool

    public init(
        customNotesDirectoryPath: String? = nil,
        wrapsEditorLines: Bool = true,
        editorFontSize: Int = AppSettings.defaultEditorFontSize,
        editorTabWidth: Int = AppSettings.defaultEditorTabWidth,
        editorIndentStyle: EditorIndentStyle = .spaces,
        autosaveDelaySeconds: Int = AppSettings.defaultAutosaveDelaySeconds,
        appearanceMode: AppearanceMode = .system,
        spellCheckEnabled: Bool = true,
        spellCheckLanguage: String? = nil,
        trashRetention: TrashRetention = .days(30),
        outlineDensity: OutlineDensity = .comfortable,
        outlineTreeLines: Bool = true,
        outlineDragHandles: Bool = true,
        outlineBreadcrumbVisible: Bool = true,
        renderEmojiShortcodes: Bool = true,
    ) {
        self.customNotesDirectoryPath = customNotesDirectoryPath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.wrapsEditorLines = wrapsEditorLines
        self.editorFontSize = Self.clampedEditorFontSize(editorFontSize)
        self.editorTabWidth = Self.clampedEditorTabWidth(editorTabWidth)
        self.editorIndentStyle = editorIndentStyle
        self.autosaveDelaySeconds = Self.clampedAutosaveDelaySeconds(autosaveDelaySeconds)
        self.appearanceMode = appearanceMode
        self.spellCheckEnabled = spellCheckEnabled
        self.spellCheckLanguage = spellCheckLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.trashRetention = trashRetention
        self.outlineDensity = outlineDensity
        self.outlineTreeLines = outlineTreeLines
        self.outlineDragHandles = outlineDragHandles
        self.outlineBreadcrumbVisible = outlineBreadcrumbVisible
        self.renderEmojiShortcodes = renderEmojiShortcodes
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
                spellCheckEnabled: spellCheckEnabled,
                spellCheckLanguage: spellCheckLanguage,
                trashRetention: trashRetention,
                outlineDensity: outlineDensity,
                outlineTreeLines: outlineTreeLines,
                outlineDragHandles: outlineDragHandles,
                outlineBreadcrumbVisible: outlineBreadcrumbVisible,
                renderEmojiShortcodes: renderEmojiShortcodes,
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
            spellCheckEnabled: spellCheckEnabled,
            spellCheckLanguage: spellCheckLanguage,
            trashRetention: trashRetention,
            outlineDensity: outlineDensity,
            outlineTreeLines: outlineTreeLines,
            outlineDragHandles: outlineDragHandles,
            outlineBreadcrumbVisible: outlineBreadcrumbVisible,
            renderEmojiShortcodes: renderEmojiShortcodes,
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
            spellCheckEnabled: spellCheckEnabled,
            spellCheckLanguage: spellCheckLanguage,
            trashRetention: trashRetention,
            outlineDensity: outlineDensity,
            outlineTreeLines: outlineTreeLines,
            outlineDragHandles: outlineDragHandles,
            outlineBreadcrumbVisible: outlineBreadcrumbVisible,
            renderEmojiShortcodes: renderEmojiShortcodes,
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
        case spellCheckEnabled
        case spellCheckLanguage
        case trashRetention
        case outlineDensity
        case outlineTreeLines
        case outlineDragHandles
        case outlineBreadcrumbVisible
        case renderEmojiShortcodes
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
            spellCheckEnabled: container.decodeIfPresent(Bool.self, forKey: .spellCheckEnabled) ?? true,
            spellCheckLanguage: container.decodeIfPresent(String.self, forKey: .spellCheckLanguage),
            trashRetention: container.decodeIfPresent(TrashRetention.self, forKey: .trashRetention) ?? .days(30),
            outlineDensity: container.decodeIfPresent(OutlineDensity.self, forKey: .outlineDensity) ?? .comfortable,
            outlineTreeLines: container.decodeIfPresent(Bool.self, forKey: .outlineTreeLines) ?? true,
            outlineDragHandles: container.decodeIfPresent(Bool.self, forKey: .outlineDragHandles) ?? true,
            outlineBreadcrumbVisible: container.decodeIfPresent(Bool.self, forKey: .outlineBreadcrumbVisible) ?? true,
            renderEmojiShortcodes: container.decodeIfPresent(Bool.self, forKey: .renderEmojiShortcodes) ?? true,
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
