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

    // MARK: - Equatable

    func test_equatable_distinguishesPosition() {
        let a = CSVCellCursor(rowCount: 3, columnCount: 3, row: 1, column: 1)
        var b = CSVCellCursor(rowCount: 3, columnCount: 3, row: 1, column: 1)
        XCTAssertEqual(a, b)
        b.moveRight()
        XCTAssertNotEqual(a, b)
    }
}
