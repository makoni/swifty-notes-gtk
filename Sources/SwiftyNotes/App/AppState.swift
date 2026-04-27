import Foundation

@MainActor
public final class AppState {
    public private(set) var notes: [Note] = []
    public private(set) var folders: [String] = []
    public private(set) var expandedFolders: Set<String> = []
    public private(set) var selectedNoteID: UUID?
    public var isSidebarVisible: Bool
    public var viewMode: EditorViewMode
    public var searchQuery: String
    public var sortMode: NotesSortMode
    public var preferredWindowWidth: Int
    public var preferredWindowHeight: Int
    public var preferredPreviewWidth: Int
    public var lastTableRows: Int
    public var lastTableCols: Int
    public var lastTableAlignments: [MarkdownTableAlignment]

    public var isPreviewVisible: Bool {
        viewMode.isPreviewVisible
    }

    public var isEditorVisible: Bool {
        viewMode != .preview
    }

    public init(persistedState: WorkspaceState = .default) {
        selectedNoteID = persistedState.selectedNoteID
        isSidebarVisible = persistedState.isSidebarVisible
        viewMode = persistedState.viewMode
        searchQuery = persistedState.searchQuery
        sortMode = persistedState.sortMode
        preferredWindowWidth = persistedState.windowWidth
        preferredWindowHeight = persistedState.windowHeight
        preferredPreviewWidth = persistedState.previewWidth
        lastTableRows = persistedState.lastTableRows
        lastTableCols = persistedState.lastTableCols
        lastTableAlignments = persistedState.lastTableAlignments
        expandedFolders = Set(persistedState.expandedFolders)
    }

    public func setLastTableSize(rows: Int, cols: Int, alignments: [MarkdownTableAlignment]) {
        lastTableRows = max(1, rows)
        lastTableCols = max(1, cols)
        lastTableAlignments = alignments
    }

    public var selectedNote: Note? {
        guard let selectedNoteID else { return nil }
        return notes.first(where: { $0.id == selectedNoteID })
    }

    public func setNotes(_ notes: [Note]) {
        self.notes = notes
        if let selectedNoteID, notes.contains(where: { $0.id == selectedNoteID }) {
            return
        }
        selectedNoteID = notes.first?.id
    }

    public func setFolders(_ folders: [String]) {
        self.folders = folders
        let valid = Set(folders)
        // Prune entries whose folder no longer exists so the persisted set
        // doesn't keep growing across renames/deletes.
        expandedFolders.formIntersection(valid)
    }

    public func setFolderExpanded(_ folderPath: String, expanded: Bool) {
        if expanded {
            expandedFolders.insert(folderPath)
        } else {
            expandedFolders.remove(folderPath)
        }
    }

    public func setExpandedFolders(_ folders: Set<String>) {
        expandedFolders = folders
    }

    public func select(noteID: UUID?) {
        selectedNoteID = noteID
    }

    public func setSearchQuery(_ query: String) {
        searchQuery = query
    }

    public func setSortMode(_ mode: NotesSortMode) {
        sortMode = mode
    }

    public func setPreferredPreviewWidth(_ width: Int) {
        preferredPreviewWidth = max(width, 320)
    }

    public func upsert(_ note: Note) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        } else {
            notes.insert(note, at: 0)
        }
        sortStoredNotes()
        selectedNoteID = note.id
    }

    public func remove(noteID: UUID) {
        notes.removeAll { $0.id == noteID }
        if selectedNoteID == noteID {
            selectedNoteID = notes.first?.id
        }
    }

    @discardableResult
    public func replace(_ note: Note, ifCurrentContentMatches expectedContent: String) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else {
            return false
        }
        guard notes[index].content == expectedContent else {
            return false
        }
        notes[index] = note
        sortStoredNotes()
        return true
    }

    public func persistedState(windowWidth: Int, windowHeight: Int) -> WorkspaceState {
        WorkspaceState(
            selectedNoteID: selectedNoteID,
            isSidebarVisible: isSidebarVisible,
            viewMode: viewMode,
            searchQuery: searchQuery,
            sortMode: sortMode,
            windowWidth: windowWidth,
            windowHeight: windowHeight,
            previewWidth: preferredPreviewWidth,
            lastTableRows: lastTableRows,
            lastTableCols: lastTableCols,
            lastTableAlignments: lastTableAlignments,
            expandedFolders: expandedFolders.sorted(),
        )
    }

    private func sortStoredNotes() {
        notes.sort {
            if $0.createdAt == $1.createdAt {
                return $0.stableID > $1.stableID
            }
            return $0.createdAt > $1.createdAt
        }
    }
}
