import Foundation

public enum NotesSortMode: String, Codable, CaseIterable, Sendable {
    case newestFirst
    case oldestFirst
    case title

    public var displayName: String {
        switch self {
        case .newestFirst:
            "Newest first"
        case .oldestFirst:
            "Oldest first"
        case .title:
            "Title"
        }
    }

    public func sort(notes: [Note]) -> [Note] {
        notes.sorted { lhs, rhs in
            switch self {
            case .newestFirst:
                if lhs.createdAt == rhs.createdAt {
                    return lhs.stableID > rhs.stableID
                }
                return lhs.createdAt > rhs.createdAt
            case .oldestFirst:
                if lhs.createdAt == rhs.createdAt {
                    return lhs.stableID < rhs.stableID
                }
                return lhs.createdAt < rhs.createdAt
            case .title:
                let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if comparison == .orderedSame {
                    return lhs.createdAt > rhs.createdAt
                }
                return comparison == .orderedAscending
            }
        }
    }
}

public enum EditorViewMode: String, Codable, CaseIterable, Sendable {
    case editor
    case split
    case preview

    var isPreviewVisible: Bool {
        self != .editor
    }
}

public struct WorkspaceState: Codable, Equatable, Sendable {
    public static let legacyDefaultPreviewWidth = 440
    public static let defaultPreviewWidth = 560
    public static let defaultLastTableRows = 3
    public static let defaultLastTableCols = 3

    public var selectedNoteID: UUID?
    public var isSidebarVisible: Bool
    public var viewMode: EditorViewMode
    public var searchQuery: String
    public var sortMode: NotesSortMode
    public var windowWidth: Int
    public var windowHeight: Int
    public var previewWidth: Int
    public var lastTableRows: Int
    public var lastTableCols: Int
    public var lastTableAlignments: [MarkdownTableAlignment]
    /// Folder paths the sidebar tree should restore as expanded.
    /// Empty by default; sidebar guarantees the entries are valid folders
    /// before opening them, so stale entries from renamed/deleted folders
    /// silently no-op.
    public var expandedFolders: [String]
    /// Whether the Trash row in the sidebar is expanded. Persisted so
    /// users who keep the bin open between sessions don't have to keep
    /// re-expanding it.
    public var isTrashExpanded: Bool

    public var isPreviewVisible: Bool {
        viewMode.isPreviewVisible
    }

    public init(
        selectedNoteID: UUID? = nil,
        isSidebarVisible: Bool = true,
        isPreviewVisible: Bool = true,
        viewMode: EditorViewMode? = nil,
        searchQuery: String = "",
        sortMode: NotesSortMode = .newestFirst,
        windowWidth: Int = 1200,
        windowHeight: Int = 800,
        previewWidth: Int = WorkspaceState.defaultPreviewWidth,
        lastTableRows: Int = WorkspaceState.defaultLastTableRows,
        lastTableCols: Int = WorkspaceState.defaultLastTableCols,
        lastTableAlignments: [MarkdownTableAlignment] = [],
        expandedFolders: [String] = [],
        isTrashExpanded: Bool = false,
    ) {
        self.selectedNoteID = selectedNoteID
        self.isSidebarVisible = isSidebarVisible
        self.viewMode = viewMode ?? (isPreviewVisible ? .split : .editor)
        self.searchQuery = searchQuery
        self.sortMode = sortMode
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
        self.previewWidth = previewWidth
        self.lastTableRows = max(1, lastTableRows)
        self.lastTableCols = max(1, lastTableCols)
        self.lastTableAlignments = lastTableAlignments
        self.expandedFolders = Self.deduplicatedFolderPaths(expandedFolders)
        self.isTrashExpanded = isTrashExpanded
    }

    private static func deduplicatedFolderPaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    public static let `default` = WorkspaceState()

    private enum CodingKeys: String, CodingKey {
        case selectedNoteID
        case isSidebarVisible
        case viewMode
        case isPreviewVisible
        case searchQuery
        case sortMode
        case windowWidth
        case windowHeight
        case previewWidth
        case lastTableRows
        case lastTableCols
        case lastTableAlignments
        case expandedFolders
        case isTrashExpanded
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedNoteID = try container.decodeIfPresent(UUID.self, forKey: .selectedNoteID)
        isSidebarVisible = try container.decodeIfPresent(Bool.self, forKey: .isSidebarVisible) ?? true
        if let viewMode = try container.decodeIfPresent(EditorViewMode.self, forKey: .viewMode) {
            self.viewMode = viewMode
        } else {
            viewMode = try (container.decodeIfPresent(Bool.self, forKey: .isPreviewVisible) ?? true) ? .split : .editor
        }
        searchQuery = try container.decodeIfPresent(String.self, forKey: .searchQuery) ?? ""
        sortMode = try container.decodeIfPresent(NotesSortMode.self, forKey: .sortMode) ?? .newestFirst
        windowWidth = try container.decodeIfPresent(Int.self, forKey: .windowWidth) ?? 1200
        windowHeight = try container.decodeIfPresent(Int.self, forKey: .windowHeight) ?? 800
        previewWidth = try container.decodeIfPresent(Int.self, forKey: .previewWidth) ?? WorkspaceState.defaultPreviewWidth
        lastTableRows = try max(1, container.decodeIfPresent(Int.self, forKey: .lastTableRows) ?? WorkspaceState.defaultLastTableRows)
        lastTableCols = try max(1, container.decodeIfPresent(Int.self, forKey: .lastTableCols) ?? WorkspaceState.defaultLastTableCols)
        lastTableAlignments = try container.decodeIfPresent([MarkdownTableAlignment].self, forKey: .lastTableAlignments) ?? []
        expandedFolders = Self.deduplicatedFolderPaths(
            try container.decodeIfPresent([String].self, forKey: .expandedFolders) ?? [],
        )
        isTrashExpanded = try container.decodeIfPresent(Bool.self, forKey: .isTrashExpanded) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(selectedNoteID, forKey: .selectedNoteID)
        try container.encode(isSidebarVisible, forKey: .isSidebarVisible)
        try container.encode(viewMode, forKey: .viewMode)
        try container.encode(isPreviewVisible, forKey: .isPreviewVisible)
        try container.encode(searchQuery, forKey: .searchQuery)
        try container.encode(sortMode, forKey: .sortMode)
        try container.encode(windowWidth, forKey: .windowWidth)
        try container.encode(windowHeight, forKey: .windowHeight)
        try container.encode(previewWidth, forKey: .previewWidth)
        try container.encode(lastTableRows, forKey: .lastTableRows)
        try container.encode(lastTableCols, forKey: .lastTableCols)
        try container.encode(lastTableAlignments, forKey: .lastTableAlignments)
        try container.encode(expandedFolders, forKey: .expandedFolders)
        try container.encode(isTrashExpanded, forKey: .isTrashExpanded)
    }
}
