import Foundation

/// One row visible in the notes sidebar.
///
/// Headers vs notes are intermixed at the same depth — folders come first
/// at each level, then the notes that live at that level. ``depth`` drives
/// the leading indentation in the row widget.
@MainActor
enum SidebarItem: Equatable {
    case folder(SidebarFolder)
    case note(SidebarNote)
    case trashHeader(SidebarTrashHeader)
    case trashedNote(SidebarTrashedNote)

    var depth: Int {
        switch self {
        case let .folder(folder):
            folder.depth
        case let .note(note):
            note.depth
        case .trashHeader:
            0
        case .trashedNote:
            1
        }
    }
}

@MainActor
struct SidebarFolder: Equatable {
    let path: String
    let displayName: String
    let depth: Int
    let isExpanded: Bool
    let hasChildren: Bool
    let noteCount: Int
}

@MainActor
struct SidebarNote: Equatable {
    let note: Note
    let depth: Int
}

@MainActor
struct SidebarTrashHeader: Equatable {
    let isExpanded: Bool
    let count: Int
}

@MainActor
struct SidebarTrashedNote: Equatable {
    let note: Note
}

/// Flattens the (notes + folders + expanded set) into the visual list a
/// sidebar can render row-by-row.
///
/// When `searchQuery` is non-empty the result collapses to a flat list of
/// matching notes — folder structure isn't useful while searching, and the
/// existing search behaviour stays intact.
@MainActor
enum SidebarTreeFlattener {
    static func flatten(
        notes: [Note],
        folders: [String],
        expandedFolders: Set<String>,
        searchQuery: String,
        sortMode: NotesSortMode,
        trashedNotes: [Note] = [],
        trashExpanded: Bool = false,
    ) -> [SidebarItem] {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let sortedNotes = sortMode.sort(notes: notes)

        if !trimmedQuery.isEmpty {
            return sortedNotes
                .filter { $0.matches(searchQuery: trimmedQuery) }
                .map { .note(SidebarNote(note: $0, depth: 0)) }
        }

        let normalizedFolders = folders.map { NotesRepository.trimmedFolderPath($0) }
            .filter { !$0.isEmpty }
        let folderSet = Set(normalizedFolders)
        let notesByFolder = Dictionary(grouping: sortedNotes) { $0.folderPath }

        var result: [SidebarItem] = []
        emitChildren(
            of: "",
            depth: 0,
            folders: normalizedFolders,
            folderSet: folderSet,
            expanded: expandedFolders,
            notesByFolder: notesByFolder,
            into: &result,
        )

        // Trash sits at the bottom of the sidebar, always shown so
        // the user has a discoverable signpost for soft-deleted
        // notes — even when it's empty, surfacing the slot tells
        // them where things land if they delete something later.
        result.append(.trashHeader(SidebarTrashHeader(
            isExpanded: trashExpanded,
            count: trashedNotes.count,
        )))
        if trashExpanded {
            let sortedTrashed = trashedNotes.sorted {
                ($0.deletedAt ?? Date.distantPast) > ($1.deletedAt ?? Date.distantPast)
            }
            for note in sortedTrashed {
                result.append(.trashedNote(SidebarTrashedNote(note: note)))
            }
        }
        return result
    }

    private static func emitChildren(
        of parent: String,
        depth: Int,
        folders: [String],
        folderSet: Set<String>,
        expanded: Set<String>,
        notesByFolder: [String: [Note]],
        into result: inout [SidebarItem],
    ) {
        let childFolderPaths = folders
            .filter { NotesRepository.parentFolderPath(of: $0) == parent }
            .sorted { lhs, rhs in
                let lhsName = (lhs as NSString).lastPathComponent
                let rhsName = (rhs as NSString).lastPathComponent
                return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
            }

        for path in childFolderPaths {
            let isExpanded = expanded.contains(path)
            let directNotes = notesByFolder[path]?.count ?? 0
            let hasChildFolders = folders.contains { NotesRepository.parentFolderPath(of: $0) == path }
            result.append(.folder(SidebarFolder(
                path: path,
                displayName: (path as NSString).lastPathComponent,
                depth: depth,
                isExpanded: isExpanded,
                hasChildren: directNotes > 0 || hasChildFolders,
                noteCount: directNotes,
            )))
            if isExpanded {
                emitChildren(
                    of: path,
                    depth: depth + 1,
                    folders: folders,
                    folderSet: folderSet,
                    expanded: expanded,
                    notesByFolder: notesByFolder,
                    into: &result,
                )
            }
        }

        for note in notesByFolder[parent] ?? [] {
            result.append(.note(SidebarNote(note: note, depth: depth)))
        }
    }
}
