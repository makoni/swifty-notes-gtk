import Adwaita
import Foundation

/// Drag-and-drop payload encoded as a string content provider.
///
/// `GtkDragSource.setTextContent` is the simplest way to ship arbitrary
/// data through GTK's clipboard plumbing. We prefix with `swiftynotes/`
/// so unrelated text drops (e.g. dragged URLs from a browser) get
/// rejected cleanly.
enum SidebarDragPayload {
    case note(UUID)
    case folder(path: String)

    var encoded: String {
        switch self {
        case let .note(id):
            "swiftynotes/note/\(id.uuidString.lowercased())"
        case let .folder(path):
            "swiftynotes/folder/\(path)"
        }
    }

    static func parse(_ raw: String) -> SidebarDragPayload? {
        let notePrefix = "swiftynotes/note/"
        let folderPrefix = "swiftynotes/folder/"
        if raw.hasPrefix(notePrefix) {
            let suffix = String(raw.dropFirst(notePrefix.count))
            return UUID(uuidString: suffix).map { .note($0) }
        }
        if raw.hasPrefix(folderPrefix) {
            let path = String(raw.dropFirst(folderPrefix.count))
            return .folder(path: path)
        }
        return nil
    }
}

@MainActor
extension MainWindow {
    /// Wires drag-source + drop-target controllers onto every visible row
    /// based on the items currently rendered in the sidebar. Called from
    /// ``refreshSidebar`` so attachments rebind on every render.
    func attachSidebarDnD() {
        for (index, item) in sidebar.renderedItems.enumerated() {
            guard let row = sidebar.list.rowAt(index) else { continue }

            // Trash header / trashed-note rows aren't part of the
            // user's draggable tree — they live in their own pseudo
            // section and the right-click menu handles their actions.
            let payload: SidebarDragPayload
            switch item {
            case let .note(noteItem):
                payload = .note(noteItem.note.id)
            case let .folder(folder):
                payload = .folder(path: folder.path)
            case .trashHeader, .trashedNote:
                continue
            }
            attachDragSource(to: row, payload: payload)

            if case let .folder(folder) = item {
                attachDropTarget(to: row, destinationFolder: folder.path)
            }
        }
        attachRootDropTarget()
    }

    private func attachDragSource(to row: ListBoxRow, payload: SidebarDragPayload) {
        let source = DragSource()
        source.actions = GDK_ACTION_MOVE
        source.setTextContent(payload.encoded)
        row.addController(source)
    }

    private func attachDropTarget(to row: ListBoxRow, destinationFolder: String) {
        let target = DropTarget.forText(actions: GDK_ACTION_MOVE)
        target.preload = true
        target.onEnter(preferredAction: { [weak self] _, _ in
            self?.scheduleHoverExpand(folder: destinationFolder)
            return GDK_ACTION_MOVE
        })
        target.onLeave { [weak self] in
            self?.cancelHoverExpand(folder: destinationFolder)
        }
        target.onDrop { [weak self] text in
            guard let self,
                  let raw = text,
                  let payload = SidebarDragPayload.parse(raw)
            else { return false }
            cancelHoverExpand(folder: destinationFolder)
            return acceptSidebarDrop(payload: payload, into: destinationFolder)
        }
        row.addController(target)
    }

    private func attachRootDropTarget() {
        // The ListBox widget itself catches drops that miss every row,
        // routing them to the root ("") folder. We only attach once per
        // sidebar render; previous controllers are released along with
        // the rebuilt rows.
        let target = DropTarget.forText(actions: GDK_ACTION_MOVE)
        target.preload = true
        target.onDrop { [weak self] text in
            guard let self,
                  let raw = text,
                  let payload = SidebarDragPayload.parse(raw)
            else { return false }
            return acceptSidebarDrop(payload: payload, into: "")
        }
        sidebar.list.addController(target)
    }

    /// Validates the drop and, if valid, schedules the move on the next
    /// idle tick. Running the move synchronously inside the drop handler
    /// tears the source row down before GTK's drag gesture finishes its
    /// release transition, which leaves rows stuck in GTK_STATE_FLAG_ACTIVE
    /// and produces a "Broken accounting of active state" warning cascade.
    private func acceptSidebarDrop(payload: SidebarDragPayload, into folderPath: String) -> Bool {
        switch payload {
        case let .note(uuid):
            guard let note = state.notes.first(where: { $0.id == uuid }) else { return false }
            if note.folderPath == folderPath { return false }
            MainContext.idle { [weak self] in
                self?.moveNote(note, to: folderPath)
            }
            return true
        case let .folder(sourcePath):
            if sourcePath == folderPath { return false }
            if NotesRepository.isPath(folderPath, descendantOf: sourcePath) { return false }
            // Reject when the drop target is already the source's parent —
            // moving Work into "" when Work is already at root is a no-op.
            if NotesRepository.parentFolderPath(of: sourcePath) == folderPath { return false }
            MainContext.idle { [weak self] in
                self?.moveDraggedFolder(sourcePath: sourcePath, into: folderPath)
            }
            return true
        }
    }

    private func moveDraggedFolder(sourcePath: String, into newParent: String) {
        do {
            try repository.moveFolder(at: sourcePath, to: newParent)
            let notes = try repository.loadNotes()
            state.setNotes(notes)
            refreshFolderList()

            // Rewrite expanded entries that pointed inside the moved branch.
            let lastComponent = (sourcePath as NSString).lastPathComponent
            let newPath = newParent.isEmpty ? lastComponent : "\(newParent)/\(lastComponent)"
            let migrated = state.expandedFolders.map { entry -> String in
                if entry == sourcePath { return newPath }
                if entry.hasPrefix("\(sourcePath)/") {
                    return newPath + entry.dropFirst(sourcePath.count)
                }
                return entry
            }
            state.setExpandedFolders(Set(migrated))
            if !newParent.isEmpty {
                state.setFolderExpanded(newParent, expanded: true)
            }
            refreshSidebar()
            refreshDirectorySnapshot()
            persistWorkspaceState()
            toastOverlay.showToast("Folder moved")
        } catch {
            presentError(
                heading: "Could not move folder",
                body: error.localizedDescription,
            )
        }
    }

    private func scheduleHoverExpand(folder: String) {
        guard !state.expandedFolders.contains(folder) else { return }
        cancelHoverExpand(folder: nil)
        sidebarHoverExpandFolder = folder
        sidebarHoverExpandTimer = MainContext.timeout(intervalMs: 500) { [weak self] in
            guard let self, sidebarHoverExpandFolder == folder else { return false }
            state.setFolderExpanded(folder, expanded: true)
            refreshSidebar()
            sidebarHoverExpandTimer = nil
            sidebarHoverExpandFolder = nil
            return false
        }
    }

    private func cancelHoverExpand(folder: String?) {
        if let folder, sidebarHoverExpandFolder != folder { return }
        if let id = sidebarHoverExpandTimer {
            MainContext.cancel(sourceId: id)
        }
        sidebarHoverExpandTimer = nil
        sidebarHoverExpandFolder = nil
    }
}
