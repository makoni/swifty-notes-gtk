import Adwaita
import Foundation

/// A small 8×8 grid the user hovers + clicks to choose the dimensions of
/// a markdown table. Rendered as the child of a ``Popover`` anchored to
/// a toolbar button.
///
/// Usage:
/// ```swift
/// let picker = TableSizePicker()
/// picker.onSelect = { rows, cols in editor.insertTable(rows: rows, cols: cols) }
/// picker.popover.present(from: toolbarButton)
/// ```
///
/// A single instance is re-usable: after a selection the popover closes
/// automatically and the highlight resets so the next open starts with a
/// blank grid.
@MainActor
final class TableSizePicker {
    static let maxRows = 8
    static let maxCols = 8

    let popover = Popover()

    /// Invoked on the main actor with the chosen dimensions after the
    /// user clicks a cell. The popover closes itself first, so the
    /// handler can mutate the editor (and pull focus) without racing
    /// with the popover's own hide animation.
    var onSelect: ((_ rows: Int, _ cols: Int) -> Void)?

    private let readout: Label
    private var cells: [[Box]] = []
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

        let container = Box(orientation: .vertical, spacing: 4)
        container.setMargins(10)
        container.append(buildGrid())
        container.append(readout)

        popover.hasArrow = true
        popover.position = .bottom
        popover.autohide = true
        popover.child = container
        popover.onClosed { [weak self] in
            self?.resetHighlight()
        }

        updateReadout(rows: 0, cols: 0)
    }

    /// Programmatic entry point for tests: simulates a pointer hover over
    /// the cell at (`row`, `col`) — zero-based.
    func debugHover(row: Int, col: Int) {
        highlight(row: row, col: col)
    }

    /// Programmatic entry point for tests: simulates a click on the cell
    /// at (`row`, `col`) — zero-based.
    func debugClick(row: Int, col: Int) {
        confirmSelection(row: row, col: col)
    }

    /// The size label shown under the grid. Exposed for tests.
    var debugReadoutText: String {
        readout.text
    }

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
                    self?.confirmSelection(row: row, col: col)
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
            readout.text = "\(rows) × \(cols) table"
        } else {
            readout.text = "Hover to pick size"
        }
    }

    private func confirmSelection(row: Int, col: Int) {
        let rows = row + 1
        let cols = col + 1
        popover.popdown()
        resetHighlight()
        onSelect?(rows, cols)
    }
}
