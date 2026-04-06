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
                    return lhs.filename > rhs.filename
                }
                return lhs.createdAt > rhs.createdAt
            case .oldestFirst:
                if lhs.createdAt == rhs.createdAt {
                    return lhs.filename < rhs.filename
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

public struct WorkspaceState: Codable, Equatable, Sendable {
    public static let legacyDefaultPreviewWidth = 440
    public static let defaultPreviewWidth = 560

    public var selectedNoteID: UUID?
    public var isPreviewVisible: Bool
    public var searchQuery: String
    public var sortMode: NotesSortMode
    public var windowWidth: Int
    public var windowHeight: Int
    public var previewWidth: Int

    public init(
        selectedNoteID: UUID? = nil,
        isPreviewVisible: Bool = true,
        searchQuery: String = "",
        sortMode: NotesSortMode = .newestFirst,
        windowWidth: Int = 1200,
        windowHeight: Int = 800,
        previewWidth: Int = WorkspaceState.defaultPreviewWidth
    ) {
        self.selectedNoteID = selectedNoteID
        self.isPreviewVisible = isPreviewVisible
        self.searchQuery = searchQuery
        self.sortMode = sortMode
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
        self.previewWidth = previewWidth
    }

    public static let `default` = WorkspaceState()

    private enum CodingKeys: String, CodingKey {
        case selectedNoteID
        case isPreviewVisible
        case searchQuery
        case sortMode
        case windowWidth
        case windowHeight
        case previewWidth
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedNoteID = try container.decodeIfPresent(UUID.self, forKey: .selectedNoteID)
        isPreviewVisible = try container.decodeIfPresent(Bool.self, forKey: .isPreviewVisible) ?? true
        searchQuery = try container.decodeIfPresent(String.self, forKey: .searchQuery) ?? ""
        sortMode = try container.decodeIfPresent(NotesSortMode.self, forKey: .sortMode) ?? .newestFirst
        windowWidth = try container.decodeIfPresent(Int.self, forKey: .windowWidth) ?? 1200
        windowHeight = try container.decodeIfPresent(Int.self, forKey: .windowHeight) ?? 800
        previewWidth = try container.decodeIfPresent(Int.self, forKey: .previewWidth) ?? WorkspaceState.defaultPreviewWidth
    }
}
