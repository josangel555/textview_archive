import XCTest
@testable import ViewerCore

/// TSK-924 — clipboard serialization for CSV row/column copy. Pure, host-safe.
final class CSVCopyTests: XCTestCase {

    func test_rowTSV_joinsCellsWithTabs() {
        XCTAssertEqual(CSVCopy.rowTSV(["a", "b", "c"]), "a\tb\tc")
        XCTAssertEqual(CSVCopy.rowTSV([]), "")
        XCTAssertEqual(CSVCopy.rowTSV(["only"]), "only")
    }

    func test_columnText_joinsColumnCellsWithNewlines_padsShortRows() {
        let rows = [["a1", "b1"], ["a2", "b2"], ["a3"]]   // last row is missing column 1
        XCTAssertEqual(CSVCopy.columnText(0, in: rows), "a1\na2\na3")
        XCTAssertEqual(CSVCopy.columnText(1, in: rows), "b1\nb2\n",
                       "short row contributes an empty cell so the column stays row-aligned")
    }

    func test_columnText_outOfRangeColumn_yieldsEmptyCells() {
        let rows = [["a"], ["b"]]
        XCTAssertEqual(CSVCopy.columnText(5, in: rows), "\n", "2 rows → 2 empty cells")
        XCTAssertEqual(CSVCopy.columnText(-1, in: rows), "")
        XCTAssertEqual(CSVCopy.columnText(0, in: []), "")
    }
}
