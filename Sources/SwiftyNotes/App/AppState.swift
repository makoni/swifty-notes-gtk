import Foundation

@MainActor
public final class AppState {
    public private(set) var notes: [Note] = []
    public private(set) var selectedNoteID: UUID?
    public var isPreviewVisible: Bool
    public var searchQuery: String
    public var sortMode: NotesSortMode
    public var preferredWindowWidth: Int
    public var preferredWindowHeight: Int
    public var preferredPreviewWidth: Int

    public init(persistedState: WorkspaceState = .default) {
        selectedNoteID = persistedState.selectedNoteID
        isPreviewVisible = persistedState.isPreviewVisible
        searchQuery = persistedState.searchQuery
        sortMode = persistedState.sortMode
        preferredWindowWidth = persistedState.windowWidth
        preferredWindowHeight = persistedState.windowHeight
        preferredPreviewWidth = persistedState.previewWidth
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
            isPreviewVisible: isPreviewVisible,
            searchQuery: searchQuery,
            sortMode: sortMode,
            windowWidth: windowWidth,
            windowHeight: windowHeight,
            previewWidth: preferredPreviewWidth
        )
    }

    private func sortStoredNotes() {
        notes.sort {
            if $0.createdAt == $1.createdAt {
                return $0.filename > $1.filename
            }
            return $0.createdAt > $1.createdAt
        }
    }
}
