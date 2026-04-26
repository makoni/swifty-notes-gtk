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

        func debugRequestCreateNote() {
            requestCreateNote()
        }

        func debugEmitNewNoteClicked() {
            newNoteButton.emitClicked()
        }

        func debugEmitSaveClicked() {
            saveNoteButton.emitClicked()
        }

        func debugEmitSidebarToggleClicked() {
            sidebarToggle.emitClicked()
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
            sidebar.sortButton.emitClicked()
        }

        func debugSetEditorText(_ text: String) {
            editor.buffer.text = text
        }

        func debugSelectEditorRange(_ range: Range<Int>) {
            editor.select(range: range)
        }

        func debugEmitEditorFormattingButtonClicked(_ action: MarkdownFormattingAction) {
            guard let button = editorFormattingButtons[action] else { return }
            button.emitClicked()
        }

        var debugTableSizePicker: TableSizePicker? {
            tableSizePicker
        }

        /// Drives the table picker from tests: ensures the picker has
        /// been built, walks it through both phases (size → alignment
        /// → insert), and cycles the requested per-column alignments
        /// along the way.
        ///
        /// Skips the `popover.present(from:)` call on purpose — under
        /// headless test harnesses the host button isn't attached to a
        /// live root, which makes actually presenting the popover flaky
        /// (and sometimes crashes during teardown on certain GTK /
        /// platform combinations). The click path covered here is the
        /// one that mutates the editor, which is what the test is
        /// about.
        func debugPickTableSize(
            rows: Int,
            cols: Int,
            alignments: [MarkdownTableAlignment] = [],
        ) {
            guard rows > 0, cols > 0 else { return }
            let picker = ensureTableSizePicker()
            picker.prepareForPresentation(
                rows: state.lastTableRows,
                cols: state.lastTableCols,
                alignments: state.lastTableAlignments,
            )
            picker.debugClickSize(row: rows - 1, col: cols - 1)
            for (col, target) in alignments.enumerated() where col < cols {
                var current = MarkdownTableAlignment.left
                while current != target {
                    picker.debugCycleAlignment(col: col)
                    current = current.next()
                }
            }
            picker.debugConfirmInsert()
        }

        func debugSetSearchQuery(_ text: String) {
            sidebar.searchEntry.text = text
            sidebar.searchEntry.emitSearchChanged()
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
                "menu": menuButton.tooltipText,
            ]
        }

        struct DebugEditorFormattingToolbarSnapshot: Equatable {
            let isCompact: Bool
            let usesTwoRows: Bool
            let labelsByAction: [MarkdownFormattingAction: String?]
        }

        var debugEditorFormattingToolbarSnapshot: DebugEditorFormattingToolbarSnapshot {
            .init(
                isCompact: isEditorFormattingToolbarCompact,
                usesTwoRows: isEditorFormattingToolbarUsingTwoRows,
                labelsByAction: editorFormattingToolbarLabels(),
            )
        }

        func debugSetEditorFormattingToolbarWidth(_ width: Int) {
            updateEditorFormattingToolbarLayout(forWidth: width)
        }

        /// The pixel width at which the formatting toolbar will flip between
        /// its full-label and compact-icon layouts for the current widget
        /// tree. Delegates to the toolbar so tests don't have to duplicate
        /// the measurement logic.
        var debugEditorFormattingToolbarCompactThreshold: Int {
            editorFormattingToolbar.compactThreshold(
                fallback: Self.editorFormattingCompactWidthThreshold,
            )
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
            openNotesFolderAction.activate()
        }

        func debugOpenNotesFolder() {
            do {
                let folderURL = try ensureNotesDirectoryExists()
                try directoryOpener(folderURL)
            } catch {
                presentError(
                    heading: "Could not open notes folder",
                    body: NotesDirectoryErrorMessage.userFriendly(for: error),
                )
            }
        }

        func debugActivateAboutAction() {
            aboutAction.activate()
        }

        func debugActivateSettingsAction() {
            settingsAction.activate()
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
                comments: activeAboutDialog.comments,
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
