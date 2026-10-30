import Adwaita
import Foundation

@MainActor
extension MainWindow {
    func configureViewModeToggleContent() {
        setToggleContent(
            editorModeToggle,
            label: EditorViewMode.editor.displayName,
            iconName: "document-edit-symbolic",
        )
        setToggleContent(
            splitModeToggle,
            label: EditorViewMode.split.displayName,
            iconName: "view-dual-symbolic",
        )
        setToggleContent(
            previewModeToggle,
            label: EditorViewMode.preview.displayName,
            iconName: "text-x-generic-symbolic",
        )
    }

    func applyEditorFormatting(_ action: MarkdownFormattingAction) {
        guard state.selectedNote != nil else { return }
        if action == .table {
            presentTableSizePicker()
            return
        }
        editor.applyFormatting(action)
    }

    /// Keyboard-accelerator entry point for the formatting actions (see
    /// `SwiftyNotesLauncher.installFormattingActions`). Same path as the
    /// toolbar, except it does nothing while only the preview is showing:
    /// the edit would land in text the user cannot see.
    func performFormattingShortcut(_ action: MarkdownFormattingAction) {
        guard state.viewMode != .preview else { return }
        applyEditorFormatting(action)
    }

    func presentTableSizePicker() {
        guard let button = editorFormattingToolbar.buttons[.table] else { return }
        let picker = ensureTableSizePicker()
        picker.prepareForPresentation(
            rows: state.lastTableRows,
            cols: state.lastTableCols,
            alignments: state.lastTableAlignments,
        )
        picker.popover.present(from: button)
    }

    func ensureTableSizePicker() -> TableSizePicker {
        if let picker = tableSizePicker { return picker }
        let picker = TableSizePicker()
        picker.onSelect = { [weak self] rows, cols, alignments in
            guard let self else { return }
            state.setLastTableSize(rows: rows, cols: cols, alignments: alignments)
            persistWorkspaceState()
            editor.insertTable(rows: rows, cols: cols, alignments: alignments)
        }
        tableSizePicker = picker
        return picker
    }

    func updateEditorFormattingToolbarLayout(forWidth width: Int) {
        editorFormattingToolbar.updateLayout(
            forWidth: width,
            fallbackThreshold: Self.editorFormattingCompactWidthThreshold,
        )
    }

    func refreshEditorFormattingToolbarLayout() {
        updateEditorFormattingToolbarLayout(forWidth: resolvedEditorFormattingToolbarWidth())
    }

    func editorFormattingToolbarLabels() -> [MarkdownFormattingAction: String?] {
        editorFormattingToolbar.currentLabels()
    }

    private func setToggleContent(_ toggle: ToggleButton, label: String, iconName: String) {
        toggle.child = ToolbarButtonContent.make(
            configuration: ToolbarButtonContentConfiguration(
                primaryText: label,
                iconName: iconName,
                prefersCompactLabel: false,
                hidesLabelWhenCompact: false,
            ),
            isCompact: false,
        )
    }

    private func resolvedEditorFormattingToolbarWidth() -> Int {
        if state.viewMode == .split {
            return previewPaneDivider.editorWidth(forRoom: currentPreviewContainerWidth)
        }

        let allocatedWidth = max(editorFormattingToolbar.scrolled.width, editorContent.width, editorPreviewPane.width)
        if allocatedWidth > 0 {
            return allocatedWidth
        }
        return currentPreviewContainerWidth
    }
}
