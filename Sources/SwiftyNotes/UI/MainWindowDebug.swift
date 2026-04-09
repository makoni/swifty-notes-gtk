import Adwaita
import CAdwaita
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

    func debugRequestCreateNote() {
        requestCreateNote()
    }

    func debugEmitNewNoteClicked() {
        g_signal_emit_by_name_no_args(UnsafeMutableRawPointer(newNoteButton.opaquePointer), "clicked")
    }

    func debugDrainMainContext(iterations: Int = 8) {
        guard let context = g_main_context_default() else { return }
        for _ in 0..<max(iterations, 1) {
            while g_main_context_pending(context) != 0 {
                _ = g_main_context_iteration(context, 0)
            }
            _ = g_main_context_iteration(context, 0)
        }
    }

    func debugEmitSaveClicked() {
        g_signal_emit_by_name_no_args(UnsafeMutableRawPointer(saveNoteButton.opaquePointer), "clicked")
    }

    func debugEmitSidebarToggleClicked() {
        g_signal_emit_by_name_no_args(UnsafeMutableRawPointer(sidebarToggle.opaquePointer), "clicked")
    }

    func debugSelectViewMode(_ mode: EditorViewMode) {
        switch mode {
        case .editor:
            editorModeToggle.active = true
        case .split:
            splitModeToggle.active = true
        case .preview:
            previewModeToggle.active = true
        }
    }

    func debugEmitSortButtonClicked() {
        g_signal_emit_by_name_no_args(UnsafeMutableRawPointer(sidebar.sortButton.opaquePointer), "clicked")
    }

    func debugSetEditorText(_ text: String) {
        editor.buffer.text = text
    }

    func debugSelectEditorRange(_ range: Range<Int>) {
        editor.select(range: range)
    }

    func debugEmitEditorFormattingButtonClicked(_ action: MarkdownFormattingAction) {
        guard let button = editorFormattingButtons[action] else { return }
        g_signal_emit_by_name_no_args(UnsafeMutableRawPointer(button.opaquePointer), "clicked")
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

    var debugHeaderSubtitle: String {
        headerTitle.subtitle
    }

    var debugWindowIconName: String? {
        window.iconName
    }

    var debugEditorText: String {
        editor.buffer.text
    }

    var debugEditorSelectionRange: Range<Int> {
        editor.selectedRange()
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

    func debugRequestSelectDisplayedNote(at index: Int) {
        requestSelectNote(at: index)
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
            "editorMode": editorModeToggle.tooltipText,
            "splitMode": splitModeToggle.tooltipText,
            "previewMode": previewModeToggle.tooltipText,
            "formatHeading": editorFormattingButtons[.heading]?.tooltipText,
            "formatBold": editorFormattingButtons[.bold]?.tooltipText,
            "formatItalic": editorFormattingButtons[.italic]?.tooltipText,
            "formatCode": editorFormattingButtons[.code]?.tooltipText,
            "formatLink": editorFormattingButtons[.link]?.tooltipText,
            "formatQuote": editorFormattingButtons[.quote]?.tooltipText,
            "formatBullet": editorFormattingButtons[.bulletList]?.tooltipText,
            "formatNumbered": editorFormattingButtons[.numberedList]?.tooltipText,
            "formatTask": editorFormattingButtons[.taskList]?.tooltipText,
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

    func debugOpenNotesFolder() {
        do {
            let folderURL = try ensureNotesDirectoryExists()
            try directoryOpener(folderURL)
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

    func debugActivateSettingsAction() {
        g_action_activate(OpaquePointer(settingsAction.pointer), nil)
    }

    func debugChangeNotesDirectory(to directory: URL) throws {
        _ = try changeNotesDirectory(to: directory)
    }

    func debugUpdateAppSettings(_ settings: AppSettings) throws {
        _ = try updateAppSettings(settings)
    }

    var debugHasAboutDialog: Bool {
        activeAboutDialog != nil
    }

    var debugHasSettingsWindow: Bool {
        activeSettingsWindow != nil
    }

    var debugSettingsWindowNotesDirectoryPath: String? {
        activeSettingsWindow?.displayedNotesDirectoryPath
    }

    var debugSettingsWindowSnapshot: SettingsWindow.Snapshot? {
        activeSettingsWindow?.snapshot
    }

    var debugSettingsWindowDefaultHeight: Int? {
        activeSettingsWindow?.debugDefaultHeight
    }

    var debugEditorWrapsLines: Bool {
        editor.view.wrapMode != .none
    }

    var debugEditorFontSize: Int {
        editor.currentFontSize
    }

    var debugEditorTabWidth: Int {
        editor.view.tabWidth
    }

    var debugEditorInsertsSpacesInsteadOfTabs: Bool {
        editor.view.insertSpacesInsteadOfTabs
    }

    var debugAutosaveDelaySeconds: Int {
        appSettings.autosaveDelaySeconds
    }

    var debugAppearanceMode: AppearanceMode {
        appSettings.appearanceMode
    }

    func debugSettingsSetWrapLines(_ value: Bool) {
        activeSettingsWindow?.debugSetWrapLines(value)
    }

    func debugSettingsSetFontSize(_ value: Int) {
        activeSettingsWindow?.debugSetFontSize(value)
    }

    func debugSettingsSetTabWidth(_ value: Int) {
        activeSettingsWindow?.debugSetTabWidth(value)
    }

    func debugSettingsSetIndentStyle(_ value: EditorIndentStyle) {
        activeSettingsWindow?.debugSetIndentStyle(value)
    }

    func debugSettingsSetAutosaveDelaySeconds(_ value: Int) {
        activeSettingsWindow?.debugSetAutosaveDelaySeconds(value)
    }

    func debugSettingsSetAppearanceMode(_ value: AppearanceMode) {
        activeSettingsWindow?.debugSetAppearanceMode(value)
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
        guard let activeAboutDialog else { return }
        self.activeAboutDialog = nil
        _ = activeAboutDialog.close()
    }

    var debugPreferredPreviewWidth: Int {
        state.preferredPreviewWidth
    }

    var debugIsPreviewPaneAttached: Bool {
        isPreviewPaneAttached
    }

    var debugViewMode: EditorViewMode {
        state.viewMode
    }
}
#endif
