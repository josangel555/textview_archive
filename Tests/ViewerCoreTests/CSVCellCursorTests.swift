import XCTest
@testable import ViewerCore

/// Teeth for `CSVCellCursor` (TSK-302) — the pure cell-focus model behind the
/// CSV grid's arrow-key navigation and whole-cell copy. Movement is clamped
/// (non-wrapping); movers report whether the cursor moved; `cell(in:)` is a
/// safe bounded read. Pure value logic — no UI.
final class CSVCellCursorTests: XCTestCase {

    // MARK: - Init + clamping

    func test_init_clampsStartIntoRange() {
        let c = CSVCellCursor(rowCount: 3, columnCount: 4, row: 99, column: -5)
        XCTAssertEqual(c.row, 2)
        XCTAssertEqual(c.column, 0)
        XCTAssertFalse(c.isEmpty)
    }

    func test_init_defaultsToOrigin() {
        let c = CSVCellCursor(rowCount: 3, columnCount: 4)
        XCTAssertEqual(c.row, 0)
        XCTAssertEqual(c.column, 0)
    }

    func test_emptyGrid_whenNoRowsOrNoColumns() {
        XCTAssertTrue(CSVCellCursor(rowCount: 0, columnCount: 4).isEmpty)
        XCTAssertTrue(CSVCellCursor(rowCount: 3, columnCount: 0).isEmpty)
        // Negative counts normalize to 0 → empty, no crash.
        XCTAssertTrue(CSVCellCursor(rowCount: -1, columnCount: -1).isEmpty)
    }

    // MARK: - Movement: clamps at edges, reports moved

    func test_moveDownUp_clampsAtVerticalEdges() {
        var c = CSVCellCursor(rowCount: 3, columnCount: 2)
        XCTAssertTrue(c.moveDown());  XCTAssertEqual(c.row, 1)
        XCTAssertTrue(c.moveDown());  XCTAssertEqual(c.row, 2)
        XCTAssertFalse(c.moveDown(), "at last row → no move"); XCTAssertEqual(c.row, 2)
        XCTAssertTrue(c.moveUp());    XCTAssertEqual(c.row, 1)
        XCTAssertTrue(c.moveUp());    XCTAssertEqual(c.row, 0)
        XCTAssertFalse(c.moveUp(), "at first row → no move"); XCTAssertEqual(c.row, 0)
    }

    func test_moveRightLeft_clampsAtHorizontalEdges() {
        var c = CSVCellCursor(rowCount: 2, columnCount: 3)
        XCTAssertTrue(c.moveRight()); XCTAssertEqual(c.column, 1)
        XCTAssertTrue(c.moveRight()); XCTAssertEqual(c.column, 2)
        XCTAssertFalse(c.moveRight(), "at last column → no move"); XCTAssertEqual(c.column, 2)
        XCTAssertTrue(c.moveLeft());  XCTAssertEqual(c.column, 1)
        XCTAssertTrue(c.moveLeft());  XCTAssertEqual(c.column, 0)
        XCTAssertFalse(c.moveLeft(), "at first column → no move"); XCTAssertEqual(c.column, 0)
    }

    func test_rowStartEnd_and_topBottom() {
        var c = CSVCellCursor(rowCount: 4, columnCount: 5, row: 2, column: 2)
        XCTAssertTrue(c.moveToRowEnd());   XCTAssertEqual(c.column, 4)
        XCTAssertFalse(c.moveToRowEnd(), "already at end"); XCTAssertEqual(c.column, 4)
        XCTAssertTrue(c.moveToRowStart()); XCTAssertEqual(c.column, 0)
        XCTAssertTrue(c.moveToBottom());   XCTAssertEqual(c.row, 3)
        XCTAssertTrue(c.moveToTop());      XCTAssertEqual(c.row, 0)
        // Row moves leave the column unchanged.
        XCTAssertEqual(c.column, 0)
    }

    func test_pageDownUp_jumpsByPageAndClampsAtEdges() {
        var c = CSVCellCursor(rowCount: 20, columnCount: 3, row: 0, column: 1)
        // One page = 8 visible rows.
        XCTAssertTrue(c.movePageDown(pageRows: 8)); XCTAssertEqual(c.row, 8)
        XCTAssertTrue(c.movePageDown(pageRows: 8)); XCTAssertEqual(c.row, 16)
        // Last page clamps to the final row rather than overshooting.
        XCTAssertTrue(c.movePageDown(pageRows: 8)); XCTAssertEqual(c.row, 19)
        XCTAssertFalse(c.movePageDown(pageRows: 8), "already at last row → no move")
        XCTAssertEqual(c.row, 19)
        // Back up by pages, clamping at the top.
        XCTAssertTrue(c.movePageUp(pageRows: 8)); XCTAssertEqual(c.row, 11)
        XCTAssertTrue(c.movePageUp(pageRows: 8)); XCTAssertEqual(c.row, 3)
        XCTAssertTrue(c.movePageUp(pageRows: 8)); XCTAssertEqual(c.row, 0)
        XCTAssertFalse(c.movePageUp(pageRows: 8), "already at first row → no move")
        XCTAssertEqual(c.row, 0)
        // Paging leaves the column untouched.
        XCTAssertEqual(c.column, 1)
    }

    func test_pageMoves_normalizeNonPositivePageToOneRow() {
        // A degenerate page size (0 or negative) still steps one row so the
        // verb is never a silent no-op away from an edge.
        var c = CSVCellCursor(rowCount: 5, columnCount: 2, row: 2, column: 0)
        XCTAssertTrue(c.movePageDown(pageRows: 0)); XCTAssertEqual(c.row, 3)
        XCTAssertTrue(c.movePageUp(pageRows: -10)); XCTAssertEqual(c.row, 2)
    }

    func test_pageMoves_areNoOpsOnEmptyGrid() {
        var c = CSVCellCursor(rowCount: 0, columnCount: 0)
        XCTAssertFalse(c.movePageDown(pageRows: 5))
        XCTAssertFalse(c.movePageUp(pageRows: 5))
        XCTAssertEqual(c.row, 0); XCTAssertEqual(c.column, 0)
    }

    func test_moveTo_clampsAndReportsChange() {
        var c = CSVCellCursor(rowCount: 3, columnCount: 3)
        XCTAssertTrue(c.move(toRow: 5, column: 1)) // clamps row to 2
        XCTAssertEqual(c.row, 2); XCTAssertEqual(c.column, 1)
        XCTAssertFalse(c.move(toRow: 2, column: 1), "same cell → no change")
        XCTAssertTrue(c.move(toRow: -3, column: -3)) // clamps to origin
        XCTAssertEqual(c.row, 0); XCTAssertEqual(c.column, 0)
    }

    func test_movesAreNoOpsOnEmptyGrid() {
        var c = CSVCellCursor(rowCount: 0, columnCount: 0)
        XCTAssertFalse(c.moveDown())
        XCTAssertFalse(c.moveRight())
        XCTAssertFalse(c.moveToRowEnd())
        XCTAssertFalse(c.moveToBottom())
        XCTAssertFalse(c.move(toRow: 1, column: 1))
        XCTAssertEqual(c.row, 0); XCTAssertEqual(c.column, 0)
    }

    // MARK: - Bounded cell access (the whole-cell copy payload)

    func test_cellInRows_returnsValueAtCursor() {
        let rows = [["a", "b", "c"], ["d", "e", "f"]]
        var c = CSVCellCursor(rowCount: 2, columnCount: 3)
        XCTAssertEqual(c.cell(in: rows), "a")
        c.moveDown(); c.moveRight(); c.moveRight()
        XCTAssertEqual(c.cell(in: rows), "f")
    }

    func test_cellInRows_nilOnEmptyGrid() {
        let c = CSVCellCursor(rowCount: 0, columnCount: 0)
        XCTAssertNil(c.cell(in: []))
    }

    func test_cellInRows_nilWhenRowIsRaggedShorterThanColumn() {
        // The cursor thinks the grid is 2×3, but the data row is ragged (2 cols).
        let rows = [["a", "b"], ["d", "e", "f"]]
        var c = CSVCellCursor(rowCount: 2, columnCount: 3, row: 0, column: 2)
        XCTAssertNil(c.cell(in: rows), "column 2 missing in the ragged first row")
        // The full row still reads fine.
        XCTAssertTrue(c.moveDown())
        XCTAssertEqual(c.cell(in: rows), "f")
    }

    func test_cellInRows_nilWhenRowsShorterThanGrid() {
        // Cursor row beyond the actual data (stale rows array).
        let rows = [["a", "b", "c"]]
        let c = CSVCellCursor(rowCount: 3, columnCount: 3, row: 2, column: 0)
        XCTAssertNil(c.cell(in: rows))
    }

    // MARK: - copyText is an alias of the bounded read

    func test_copyText_matchesCellInRows() {
        let rows = [["a", "b", "c"], ["d", "e", "f"]]
        var c = CSVCellCursor(rowCount: 2, columnCount: 3)
        XCTAssertEqual(c.copyText(from: rows), "a")
        c.moveDown(); c.moveRight()
        XCTAssertEqual(c.copyText(from: rows), "e")
        XCTAssertEqual(c.copyText(from: rows), c.cell(in: rows))
    }

    func test_copyText_nilWhenCursorAddressesNoCell() {
        // Ragged row shorter than the cursor column → no cell → nil copy.
        let rows = [["a", "b"], ["d", "e", "f"]]
        let c = CSVCellCursor(rowCount: 2, columnCount: 3, row: 0, column: 2)
        XCTAssertNil(c.copyText(from: rows))
    }

    // MARK: - End-to-end: copy returns the UNESCAPED cell value (TSK-302)
    //
    // The whole-cell ⌘C contract is that the pasteboard gets the decoded
    // value, not the raw RFC-4180 source. `CSVParser` unescapes during
    // tokenization, so navigating to a quoted cell and reading copyText
    // must yield the literal contents — no surrounding quotes, embedded
    // delimiters intact, `""` collapsed to one `"`, embedded newline kept.

    func test_copyText_returnsUnescapedValue_overParsedQuotedCells() {
        // Row 1, col 1: embedded comma inside quotes.
        // Row 1, col 2: escaped quotes ("" -> ") wrapping inner text.
        // Row 2, col 0: embedded newline inside quotes.
        // Built by concatenation rather than a multi-line literal: a CSV
        // line ending in `"""` (escaped quote + closing quote) collides
        // with Swift's multi-line string closing delimiter.
        let csv = "h0,h1,h2\n"
            + "plain,\"a,b\",\"say \"\"hi\"\"\"\n"
            + "\"line1\nline2\",x,y"
        let result = CSVParser.parse(csv)
        XCTAssertEqual(result.header, ["h0", "h1", "h2"])
        XCTAssertEqual(result.rows.count, 2)

        let cursor = CSVCellCursor(
            rowCount: result.rows.count, columnCount: result.header.count)

        // (0,0) plain cell.
        var c = cursor
        XCTAssertEqual(c.copyText(from: result.rows), "plain")

        // (0,1) embedded delimiter survives, surrounding quotes stripped.
        c = cursor
        XCTAssertTrue(c.moveRight())
        XCTAssertEqual(c.copyText(from: result.rows), "a,b")

        // (0,2) escaped quotes decode to a single literal quote.
        c = cursor
        XCTAssertTrue(c.moveRight()); XCTAssertTrue(c.moveRight())
        XCTAssertEqual(c.copyText(from: result.rows), "say \"hi\"")

        // (1,0) embedded newline preserved in the unescaped value.
        c = cursor
        XCTAssertTrue(c.moveDown())
        XCTAssertEqual(c.copyText(from: result.rows), "line1\nline2")
    }

    // MARK: - Equatable

    func test_equatable_distinguishesPosition() {
        let a = CSVCellCursor(rowCount: 3, columnCount: 3, row: 1, column: 1)
        var b = CSVCellCursor(rowCount: 3, columnCount: 3, row: 1, column: 1)
        XCTAssertEqual(a, b)
        b.moveRight()
        XCTAssertNotEqual(a, b)
    }
}
