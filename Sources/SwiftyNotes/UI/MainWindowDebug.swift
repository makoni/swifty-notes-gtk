import Adwaita
import Foundation

#if DEBUG
@MainActor
extension MainWindow {
    func debugLoadInitialNotes() {
        loadInitialNotes()
    }

    func debugCreateNote() {
        createNote()
    }

    func debugEmitNewNoteClicked() {
        g_signal_emit_by_name_no_args(UnsafeMutableRawPointer(newNoteButton.opaquePointer), "clicked")
    }

    func debugEmitSaveClicked() {
        g_signal_emit_by_name_no_args(UnsafeMutableRawPointer(saveNoteButton.opaquePointer), "clicked")
    }

    func debugEmitSidebarToggleClicked() {
        g_signal_emit_by_name_no_args(UnsafeMutableRawPointer(sidebarToggle.opaquePointer), "clicked")
    }

    func debugEmitPreviewToggleClicked() {
        g_signal_emit_by_name_no_args(UnsafeMutableRawPointer(previewToggle.opaquePointer), "clicked")
    }

    func debugEmitSortButtonClicked() {
        g_signal_emit_by_name_no_args(UnsafeMutableRawPointer(sidebar.sortButton.opaquePointer), "clicked")
    }

    func debugSetEditorText(_ text: String) {
        editor.buffer.text = text
    }

    func debugSetSearchQuery(_ text: String) {
        sidebar.searchEntry.text = text
        g_signal_emit_by_name_no_args(UnsafeMutableRawPointer(sidebar.searchEntry.opaquePointer), "search-changed")
    }

    var debugNotesCount: Int {
        state.notes.count
    }

    var debugSelectedNoteContent: String? {
        state.selectedNote?.content
    }

    var debugEditorModified: Bool {
        editor.buffer.modified
    }

    var debugPreviewText: String {
        flushPendingPreviewRefresh()
        return preview.plainText
    }

    var debugDisplayedNotesCount: Int {
        displayedNotes.count
    }

    var debugDisplayedNoteTitles: [String] {
        displayedNotes.map(\.title)
    }

    var debugSearchQuery: String {
        sidebar.searchEntry.text
    }

    var debugDisplayedNoteStableIDs: [String] {
        displayedNotes.map(\.stableID)
    }

    func debugSelectDisplayedNote(at index: Int) {
        selectNote(at: index)
    }

    func debugOpenContextMenuForDisplayedNote(at index: Int) {
        guard displayedNotes.indices.contains(index) else { return }
        let note = displayedNotes[index]
        state.select(noteID: note.id)
        renderSelection()
        noteContextDeferredAction = nil
        dismissNoteContextMenu()

        let popover = Popover()
        popover.hasArrow = true
        popover.position = .bottom
        popover.autohide = true
        popover.child = makeNoteContextPopoverContent()
        noteContextMenu = popover
    }

    func debugDismissContextMenu() {
        dismissNoteContextMenu()
    }

    var debugHasContextMenu: Bool {
        noteContextMenu != nil
    }

    var debugOverflowMenuSectionTitles: [String] {
        overflowMenuSectionTitles
    }

    var debugOverflowMenuItemsBySection: [String: [String]] {
        overflowMenuItemsBySection
    }

    var debugToolbarTooltips: [String: String?] {
        [
            "sidebar": sidebarToggle.tooltipText,
            "new": newNoteButton.tooltipText,
            "save": saveNoteButton.tooltipText,
            "delete": deleteNoteButton.tooltipText,
            "preview": previewToggle.tooltipText,
            "menu": menuButton.tooltipText
        ]
    }

    var debugNoteContextMenuLabels: [String] {
        noteContextMenuLabels
    }

    var debugSortMode: NotesSortMode {
        state.sortMode
    }

    var debugSidebarVisible: Bool {
        splitView.showSidebar
    }

    var debugSidebarSortSelection: Int {
        sidebar.selectedSortIndex
    }

    func debugSelectSidebarSort(at index: Int) {
        guard NotesSortMode.allCases.indices.contains(index) else { return }
        setSortMode(NotesSortMode.allCases[index])
    }

    @discardableResult
    func debugInvokeContextMenuAction(label: String) -> Bool {
        guard let handler = noteContextHandlers[label] else { return false }
        dismissNoteContextMenu()
        handler()
        return true
    }

    func debugSelectedNoteStableID() -> String? {
        state.selectedNote?.stableID
    }

    var debugLastCopiedNoteID: String? {
        lastCopiedNoteID
    }

    func debugPollForExternalChanges() {
        pollForExternalChanges()
    }

    func debugActivateOpenNotesFolderAction() {
        g_action_activate(OpaquePointer(openNotesFolderAction.pointer), nil)
    }

    func debugOpenNotesFolder() async {
        do {
            let folderURL = try ensureNotesDirectoryExists()
            try await directoryOpener(folderURL)
        } catch {
            presentError(
                heading: "Could not open notes folder",
                body: error.localizedDescription
            )
        }
    }

    func debugActivateAboutAction() {
        g_action_activate(OpaquePointer(aboutAction.pointer), nil)
    }

    var debugHasAboutDialog: Bool {
        activeAboutDialog != nil
    }

    struct DebugAboutDialogSnapshot: Equatable {
        let applicationName: String
        let version: String
        let developerName: String
        let copyright: String
        let website: String
        let issueURL: String
        let comments: String
    }

    var debugAboutDialogSnapshot: DebugAboutDialogSnapshot? {
        guard let activeAboutDialog else { return nil }
        return .init(
            applicationName: activeAboutDialog.applicationName,
            version: activeAboutDialog.version,
            developerName: activeAboutDialog.developerName,
            copyright: activeAboutDialog.copyright,
            website: activeAboutDialog.website,
            issueURL: activeAboutDialog.issueUrl,
            comments: activeAboutDialog.comments
        )
    }

    func debugCloseAboutDialog() {
        _ = activeAboutDialog?.close()
    }

    var debugPreferredPreviewWidth: Int {
        state.preferredPreviewWidth
    }

    var debugIsPreviewPaneAttached: Bool {
        isPreviewPaneAttached
    }
}
#endif
