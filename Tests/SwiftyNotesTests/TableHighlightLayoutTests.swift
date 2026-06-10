#if !os(macOS)
import Foundation
@testable import SwiftyNotes
import Testing

/// Pure-logic tests for ``MarkdownPreview/tableLayout(headers:rows:alignments:)``
/// — the offset map that translates a search match (in the engine's flat,
/// "\n"-joined cell space) into a `Character` range inside the rendered
/// table's column-aligned monospace `Label`. No GTK, no window, no render:
/// the map is pure arithmetic over the cell strings, so it's asserted
/// directly — `labelPlainText[labelOffset ..< labelOffset+length]` must equal
/// the cell's plain text, and `searchableOffset` must match the engine's
/// cell ordering. This is the bug-prone heart of the table-highlight feature.
@MainActor
struct TableHighlightLayoutTests {
    /// Assert a cell's `labelOffset` slices the expected substring out of the
    /// aligned label text.
    private func expectCell(
        _ cells: [MarkdownPreview.TableCellGeometry],
        _ index: Int,
        labelText: String,
        equals expected: String,
        sourceLocation: SourceLocation = #_sourceLocation,
    ) {
        let cell = cells[index]
        guard let labelOffset = cell.labelOffset else {
            Issue.record("cell \(index) has no labelOffset", sourceLocation: sourceLocation)
            return
        }
        guard labelOffset >= 0, labelOffset + cell.length <= labelText.count else {
            Issue.record(
                "cell \(index) range \(labelOffset)..<\(labelOffset + cell.length) out of bounds (len \(labelText.count))",
                sourceLocation: sourceLocation,
            )
            return
        }
        let start = labelText.index(labelText.startIndex, offsetBy: labelOffset)
        let end = labelText.index(start, offsetBy: cell.length)
        #expect(String(labelText[start ..< end]) == expected, sourceLocation: sourceLocation)
    }

    @Test("Header cells map to their padded positions in the label text") func headerCellsMapToTheirPaddedPositionsInTheLabelText() {
        let layout = MarkdownPreview.tableLayout(
            headers: [.plain("Area"), .plain("Note")],
            rows: [[.plain("A1"), .plain("B1")]],
            alignments: [.leading, .leading],
        )
        // cells: [Area, Note, A1, B1]
        expectCell(layout.cells, 0, labelText: layout.labelPlainText, equals: "Area")
        expectCell(layout.cells, 1, labelText: layout.labelPlainText, equals: "Note")
    }

    @Test("Body cell offset skips the injected divider line") func bodyCellOffsetSkipsTheInjectedDividerLine() {
        let layout = MarkdownPreview.tableLayout(
            headers: [.plain("Area"), .plain("Note")],
            rows: [[.plain("A1"), .plain("B1")]],
            alignments: [.leading, .leading],
        )
        // The first body cell must land AFTER the header line + the divider
        // line (neither of which exists in searchable space).
        let firstBody = layout.cells[2]
        let headerLineLength = layout.labelPlainText.split(separator: "\n", omittingEmptySubsequences: false)[0].count
        #expect(firstBody.labelOffset != nil)
        #expect((firstBody.labelOffset ?? 0) > headerLineLength * 2) // past header + divider
        expectCell(layout.cells, 2, labelText: layout.labelPlainText, equals: "A1")
        expectCell(layout.cells, 3, labelText: layout.labelPlainText, equals: "B1")
    }

    @Test("Ragged row with fewer cells than headers still maps its cells") func raggedRowWithFewerCellsThanHeadersStillMapsItsCells() {
        let layout = MarkdownPreview.tableLayout(
            headers: [.plain("Col1"), .plain("Col2"), .plain("Col3")],
            rows: [[.plain("only")]], // 1 cell in a 3-column table
            alignments: [.leading, .leading, .leading],
        )
        // cells: [Col1, Col2, Col3, only] — the lone body cell is index 3.
        #expect(layout.cells.count == 4)
        expectCell(layout.cells, 3, labelText: layout.labelPlainText, equals: "only")
    }

    @Test("Over-long row's extra cell is searchable but has no label field") func overLongRowsExtraCellIsSearchableButHasNoLabelField() {
        let layout = MarkdownPreview.tableLayout(
            headers: [.plain("A"), .plain("B")],
            rows: [[.plain("x"), .plain("y"), .plain("z")]], // 3 cells, 2 columns
            alignments: [.leading, .leading],
        )
        // cells: [A, B, x, y, z]; z is column 2 ≥ columnCount 2 → no field.
        #expect(layout.cells.count == 5)
        #expect(layout.cells[4].labelOffset == nil)
        // …but it still carries a searchableOffset so the engine's match
        // ranges (which include it) line up.
        #expect(layout.cells[4].searchableOffset > layout.cells[3].searchableOffset)
    }

    @Test("Empty cell is zero-length and the following cell still maps") func emptyCellIsZeroLengthAndTheFollowingCellStillMaps() {
        let layout = MarkdownPreview.tableLayout(
            headers: [.plain("H1"), .plain("H2")],
            rows: [[.plain(""), .plain("val")]],
            alignments: [.leading, .leading],
        )
        // cells: [H1, H2, "", val]
        #expect(layout.cells[2].length == 0)
        expectCell(layout.cells, 3, labelText: layout.labelPlainText, equals: "val")
    }

    @Test("Single-column table needs no inter-cell padding in offsets") func singleColumnTableNeedsNoInterCellPaddingInOffsets() {
        let layout = MarkdownPreview.tableLayout(
            headers: [.plain("Header")],
            rows: [[.plain("body")]],
            alignments: [.leading],
        )
        expectCell(layout.cells, 0, labelText: layout.labelPlainText, equals: "Header")
        expectCell(layout.cells, 1, labelText: layout.labelPlainText, equals: "body")
    }

    @Test("Header-only table maps header cells and has no body entries") func headerOnlyTableMapsHeaderCellsAndHasNoBodyEntries() {
        let layout = MarkdownPreview.tableLayout(
            headers: [.plain("Only"), .plain("Headers")],
            rows: [],
            alignments: [.leading, .leading],
        )
        #expect(layout.cells.count == 2)
        expectCell(layout.cells, 0, labelText: layout.labelPlainText, equals: "Only")
        expectCell(layout.cells, 1, labelText: layout.labelPlainText, equals: "Headers")
    }

    @Test("Trailing-aligned column offset includes the left pad") func trailingAlignedColumnOffsetIncludesTheLeftPad() {
        let layout = MarkdownPreview.tableLayout(
            headers: [.plain("Width")], // 5 chars sets the column width
            rows: [[.plain("x")]], // 1 char, right-aligned → 4 leading spaces
            alignments: [.trailing],
        )
        // The body cell's labelOffset must point at "x", not the leading pad.
        expectCell(layout.cells, 1, labelText: layout.labelPlainText, equals: "x")
    }

    @Test("Center-aligned column offset uses the floor-division left pad") func centerAlignedColumnOffsetUsesTheFloorDivisionLeftPad() {
        // Odd pad so floor (2) and ceil (3) diverge: width 6, "x" → pad 5,
        // left = 5/2 = 2. A ceil-rounding bug would shift the offset and the
        // sliced substring would no longer be exactly "x".
        let layout = MarkdownPreview.tableLayout(
            headers: [.plain("ABCDEF")], // width 6
            rows: [[.plain("x")]], // pad 5, left = 2, right = 3
            alignments: [.center],
        )
        let cell = layout.cells[1]
        #expect(cell.labelOffset != nil)
        // Body line starts at lineStart(2); the "x" sits 2 spaces in.
        expectCell(layout.cells, 1, labelText: layout.labelPlainText, equals: "x")
        // Pin the exact left pad: the two chars before "x" on its line are spaces.
        if let labelOffset = cell.labelOffset, labelOffset >= 2 {
            let xIndex = layout.labelPlainText.index(layout.labelPlainText.startIndex, offsetBy: labelOffset)
            let twoBefore = layout.labelPlainText.index(xIndex, offsetBy: -2)
            #expect(layout.labelPlainText[twoBefore ..< xIndex] == "  ")
        }
    }

    @Test("Last body cell maps to the largest label offset") func lastBodyCellMapsToTheLargestLabelOffset() {
        let layout = MarkdownPreview.tableLayout(
            headers: [.plain("A"), .plain("B")],
            rows: [
                [.plain("r1c1"), .plain("r1c2")],
                [.plain("r2c1"), .plain("last")],
            ],
            alignments: [.leading, .leading],
        )
        // Last cell is "last", index 5.
        expectCell(layout.cells, 5, labelText: layout.labelPlainText, equals: "last")
        let maxOffset = layout.cells.compactMap(\.labelOffset).max()
        #expect(layout.cells[5].labelOffset == maxOffset)
    }

    @Test("Emoji cell content maps by character count not byte count") func emojiCellContentMapsByCharacterCountNotByteCount() {
        let layout = MarkdownPreview.tableLayout(
            headers: [.plain("Mood"), .plain("Icon")],
            rows: [[.plain("happy"), .plain("😀")]],
            alignments: [.leading, .leading],
        )
        // The emoji is one Character; the offset map counts Characters, so the
        // sliced substring must round-trip even though it is 4 UTF-8 bytes.
        expectCell(layout.cells, 3, labelText: layout.labelPlainText, equals: "😀")
    }

    @Test("Searchable offsets match the engine cell ordering") func searchableOffsetsMatchTheEngineCellOrdering() {
        let headers: [RenderedText] = [.plain("Area"), .plain("Note")]
        let rows: [[RenderedText]] = [[.plain("A1"), .plain("B1")]]
        let layout = MarkdownPreview.tableLayout(headers: headers, rows: rows, alignments: [.leading, .leading])

        // Reconstruct the engine's flat searchable string and verify each
        // cell's searchableOffset slices back the original cell text.
        let flat = (["Area\nNote"] + ["A1", "B1"]).joined(separator: "\n")
        let expectedCellText = ["Area", "Note", "A1", "B1"]
        for (index, cell) in layout.cells.enumerated() {
            let start = flat.index(flat.startIndex, offsetBy: cell.searchableOffset)
            let end = flat.index(start, offsetBy: cell.length)
            #expect(String(flat[start ..< end]) == expectedCellText[index])
        }
        // Concretely: Area@0, Note@5, A1@10, B1@13.
        #expect(layout.cells.map(\.searchableOffset) == [0, 5, 10, 13])
    }
}
#endif
