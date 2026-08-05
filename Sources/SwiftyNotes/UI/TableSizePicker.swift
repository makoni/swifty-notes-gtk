import Adwaita
import Foundation

/// A two-phase picker for inserting markdown tables.
///
/// **Phase 1** — the user hovers an 8×8 grid to pick the number of rows
/// and columns; clicking a cell confirms the size.
///
/// **Phase 2** — one row of per-column alignment buttons appears (each
/// button cycles left → center → right on click), followed by an
/// "Insert" action. A "Back" link returns to the size grid.
///
/// Usage:
/// ```swift
/// let picker = TableSizePicker()
/// picker.onSelect = { rows, cols, alignments in
///     editor.insertTable(rows: rows, cols: cols, alignments: alignments)
/// }
/// picker.prepareForPresentation(rows: lastRows, cols: lastCols, alignments: lastAlignments)
/// picker.popover.present(from: toolbarButton)
/// ```
@MainActor
final class TableSizePicker {
    static let maxRows = 8
    static let maxCols = 8

    let popover = Popover()

    /// Invoked on the main actor with the user's confirmed size and
    /// alignments. The popover closes itself first.
    var onSelect: ((_ rows: Int, _ cols: Int, _ alignments: [MarkdownTableAlignment]) -> Void)?

    private let sizePhase: Box
    private let alignmentPhase: Box
    private let readout: Label
    private let alignmentPhaseRowsLabel: Label
    private let alignmentRow: Box
    private let backButton: Button
    private let insertButton: Button

    private var cells: [[Box]] = []
    private var alignmentButtons: [Button] = []

    private var selectedRows: Int = WorkspaceState.defaultLastTableRows
    private var selectedCols: Int = WorkspaceState.defaultLastTableCols
    private var currentAlignments: [MarkdownTableAlignment] = []
    private var highlightedRow: Int = -1
    private var highlightedCol: Int = -1

    private static let css = CSSProvider.loadGlobal("""
    .table-picker-cell {
        background-color: alpha(@theme_fg_color, 0.08);
        border: 1px solid alpha(@borders, 0.6);
        border-radius: 2px;
        min-width: 16px;
        min-height: 16px;
    }

    .table-picker-cell-filled {
        background-color: @theme_selected_bg_color;
        border-color: @theme_selected_bg_color;
    }

    .table-picker-readout {
        margin-top: 6px;
        font-size: 11pt;
    }
    """)

    init() {
        _ = Self.css
        readout = Label("")
        readout.addCSSClass(.dimLabel)
        readout.addCSSClass("table-picker-readout")
        readout.xalign = 0.5

        alignmentPhaseRowsLabel = Label("")
        alignmentPhaseRowsLabel.addCSSClass(.dimLabel)
        alignmentPhaseRowsLabel.xalign = 0

        alignmentRow = Box(orientation: .horizontal, spacing: 4)
        alignmentRow.halign = .center

        backButton = Button()
        backButton.child = Self.makeBackButtonContent()
        backButton.addCSSClass(.flat)
        backButton.tooltipText = "Back to size picker".localized
        backButton.halign = .start

        insertButton = Button(label: "Insert".localized)
        insertButton.addCSSClass("suggested-action")
        insertButton.halign = .end

        sizePhase = Box(orientation: .vertical, spacing: 4)
        sizePhase.setMargins(10)

        alignmentPhase = Box(orientation: .vertical, spacing: 8)
        alignmentPhase.setMargins(10)

        let container = Box(orientation: .vertical, spacing: 0)
        container.append(sizePhase)
        container.append(alignmentPhase)

        sizePhase.append(buildGrid())
        sizePhase.append(readout)

        let headerRow = Box(orientation: .horizontal, spacing: 8)
        headerRow.append(backButton)
        let spacer = Label("")
        spacer.hexpand = true
        headerRow.append(spacer)
        alignmentPhase.append(headerRow)
        alignmentPhase.append(alignmentPhaseRowsLabel)
        alignmentPhase.append(alignmentRow)

        let actionsRow = Box(orientation: .horizontal, spacing: 8)
        let actionsSpacer = Label("")
        actionsSpacer.hexpand = true
        actionsRow.append(actionsSpacer)
        actionsRow.append(insertButton)
        alignmentPhase.append(actionsRow)

        alignmentPhase.visible = false

        popover.hasArrow = true
        popover.position = .bottom
        popover.autohide = true
        popover.child = container
        popover.onClosed { [weak self] in
            self?.showSizePhase()
        }

        backButton.onClicked { [weak self] in
            self?.showSizePhase()
        }
        insertButton.onClicked { [weak self] in
            self?.confirmInsert()
        }

        updateReadout(rows: 0, cols: 0)
    }

    /// Seeds the picker with a remembered size + alignments so the next
    /// popup opens with that cell already highlighted on the grid.
    func prepareForPresentation(
        rows: Int,
        cols: Int,
        alignments: [MarkdownTableAlignment],
    ) {
        selectedRows = clampedRows(rows)
        selectedCols = clampedCols(cols)
        currentAlignments = alignments
        showSizePhase()
        highlight(row: selectedRows - 1, col: selectedCols - 1)
    }

    // MARK: - Debug entry points

    /// Programmatic entry point for tests: simulates a pointer hover
    /// over the cell at (`row`, `col`) — zero-based.
    func debugHover(row: Int, col: Int) {
        highlight(row: row, col: col)
    }

    /// Programmatic entry point for tests: simulates a click on the
    /// size-phase cell at (`row`, `col`) — zero-based. Advances the
    /// picker into the alignment phase.
    func debugClickSize(row: Int, col: Int) {
        confirmSize(row: row, col: col)
    }

    /// Programmatic entry point for tests: cycles the alignment of the
    /// `col`-th column (zero-based). Each call advances left → centre
    /// → right → left.
    func debugCycleAlignment(col: Int) {
        cycleAlignment(at: col)
    }

    /// Programmatic entry point for tests: fires the "Insert" action.
    func debugConfirmInsert() {
        confirmInsert()
    }

    /// The current readout label text. Exposed for tests.
    var debugReadoutText: String {
        readout.text
    }

    /// The current alignments shown in the alignment phase.
    var debugAlignments: [MarkdownTableAlignment] {
        currentAlignments
    }

    // MARK: - Size phase

    private func buildGrid() -> Widget {
        let grid = Box(orientation: .vertical, spacing: 2)
        cells.removeAll()
        for row in 0 ..< Self.maxRows {
            let rowBox = Box(orientation: .horizontal, spacing: 2)
            var rowCells: [Box] = []
            for col in 0 ..< Self.maxCols {
                let cell = Box(orientation: .horizontal, spacing: 0)
                cell.addCSSClass("table-picker-cell")
                cell.setSizeRequest(width: 18, height: 18)

                let motion = EventControllerMotion()
                motion.onEnter { [weak self] _, _ in
                    self?.highlight(row: row, col: col)
                }
                cell.addController(motion)

                let click = GestureClick()
                click.onReleased { [weak self] _, _, _ in
                    self?.confirmSize(row: row, col: col)
                }
                cell.addController(click)

                rowBox.append(cell)
                rowCells.append(cell)
            }
            grid.append(rowBox)
            cells.append(rowCells)
        }
        return grid
    }

    private func highlight(row: Int, col: Int) {
        guard row != highlightedRow || col != highlightedCol else { return }
        highlightedRow = row
        highlightedCol = col
        for r in 0 ..< Self.maxRows {
            for c in 0 ..< Self.maxCols {
                let cell = cells[r][c]
                let filled = r <= row && c <= col
                if filled {
                    cell.addCSSClass("table-picker-cell-filled")
                } else {
                    cell.removeCSSClass("table-picker-cell-filled")
                }
            }
        }
        updateReadout(rows: row + 1, cols: col + 1)
    }

    private func resetHighlight() {
        highlightedRow = -1
        highlightedCol = -1
        for row in cells {
            for cell in row {
                cell.removeCSSClass("table-picker-cell-filled")
            }
        }
        updateReadout(rows: 0, cols: 0)
    }

    private func updateReadout(rows: Int, cols: Int) {
        if rows > 0, cols > 0 {
            readout.text = String(format: "%d × %d table".localized, rows, cols)
        } else {
            readout.text = "Hover to pick size".localized
        }
    }

    private func confirmSize(row: Int, col: Int) {
        selectedRows = row + 1
        selectedCols = col + 1
        showAlignmentPhase()
    }

    // MARK: - Alignment phase

    private func showAlignmentPhase() {
        alignmentPhaseRowsLabel.text = String(format: "%d × %d table — column alignment".localized, selectedRows, selectedCols)
        rebuildAlignmentRow()
        sizePhase.visible = false
        alignmentPhase.visible = true
    }

    private func showSizePhase() {
        alignmentPhase.visible = false
        sizePhase.visible = true
        resetHighlight()
        if selectedRows > 0, selectedCols > 0 {
            highlight(row: selectedRows - 1, col: selectedCols - 1)
        }
    }

    private func rebuildAlignmentRow() {
        // Fresh row. Dropping the old children is fine: the wrappers
        // leave GTK, the signal handlers they held are disconnected.
        for child in alignmentRow.children() {
            alignmentRow.remove(child)
        }
        alignmentButtons.removeAll()

        // Extend or trim alignments to match selectedCols.
        if currentAlignments.count < selectedCols {
            currentAlignments += Array(
                repeating: MarkdownTableAlignment.left,
                count: selectedCols - currentAlignments.count,
            )
        } else if currentAlignments.count > selectedCols {
            currentAlignments = Array(currentAlignments.prefix(selectedCols))
        }

        for col in 0 ..< selectedCols {
            let button = Button()
            button.addCSSClass(.flat)
            button.addCSSClass("preview-code-copy") // reuse compact circular style? no — plain flat button is fine
            button.removeCSSClass("preview-code-copy")
            let alignment = currentAlignments[col]
            button.iconName = Self.iconName(for: alignment)
            button.tooltipText = Self.tooltip(for: alignment, column: col + 1)
            button.setAccessibleLabel(Self.tooltip(for: alignment, column: col + 1))
            button.onClicked { [weak self] in
                self?.cycleAlignment(at: col)
            }
            alignmentRow.append(button)
            alignmentButtons.append(button)
        }
    }

    private func cycleAlignment(at col: Int) {
        guard col >= 0, col < currentAlignments.count else { return }
        let next = currentAlignments[col].next()
        currentAlignments[col] = next
        guard col < alignmentButtons.count else { return }
        let button = alignmentButtons[col]
        button.iconName = Self.iconName(for: next)
        button.tooltipText = Self.tooltip(for: next, column: col + 1)
        button.setAccessibleLabel(Self.tooltip(for: next, column: col + 1))
    }

    private func confirmInsert() {
        let rows = selectedRows
        let cols = selectedCols
        let alignments = Array(currentAlignments.prefix(cols))
        popover.popdown()
        showSizePhase()
        onSelect?(rows, cols, alignments)
    }

    // MARK: - Helpers

    private func clampedRows(_ rows: Int) -> Int {
        max(1, min(Self.maxRows, rows))
    }

    private func clampedCols(_ cols: Int) -> Int {
        max(1, min(Self.maxCols, cols))
    }

    private static func iconName(for alignment: MarkdownTableAlignment) -> String {
        switch alignment {
        case .left: "format-justify-left-symbolic"
        case .center: "format-justify-center-symbolic"
        case .right: "format-justify-right-symbolic"
        }
    }

    private static func tooltip(for alignment: MarkdownTableAlignment, column: Int) -> String {
        let base: String = switch alignment {
        case .left: "Left-aligned".localized
        case .center: "Centred".localized
        case .right: "Right-aligned".localized
        }
        return String(format: "Column %d: %@ — click to change".localized, column, base)
    }

    private static func makeBackButtonContent() -> Widget {
        let box = Box(orientation: .horizontal, spacing: 6)
        box.marginStart = 2
        box.marginEnd = 6
        let icon = Image(iconName: "go-previous-symbolic")
        icon.pixelSize = 14
        let label = Label("Size".localized)
        box.append(icon)
        box.append(label)
        return box
    }
}
