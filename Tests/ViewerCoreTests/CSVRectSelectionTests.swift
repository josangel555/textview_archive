import XCTest
@testable import ViewerCore

/// TSK-1187 — teeth for the CSV rectangular selection → TSV extract.
final class CSVRectSelectionTests: XCTestCase {

    private let grid = [
        ["a1", "b1", "c1"],
        ["a2", "b2", "c2"],
        ["a3", "b3", "c3"],
    ]

    func test_singleCell() {
        let sel = CSVRectSelection(anchorRow: 1, anchorCol: 1, focusRow: 1, focusCol: 1)
        XCTAssertTrue(sel.isSingleCell)
        XCTAssertEqual(sel.tsv(in: grid), "b2")
    }

    func test_rectangle_tabAndNewlineDelimited() {
        // (0,0)..(1,1) → a1 b1 / a2 b2
        let sel = CSVRectSelection(anchorRow: 0, anchorCol: 0, focusRow: 1, focusCol: 1)
        XCTAssertEqual(sel.tsv(in: grid), "a1\tb1\na2\tb2")
    }

    func test_reversedDragNormalises() {
        // focus before anchor → same rectangle
        let sel = CSVRectSelection(anchorRow: 2, anchorCol: 2, focusRow: 1, focusCol: 1)
        XCTAssertEqual(sel.rowRange, 1...2)
        XCTAssertEqual(sel.colRange, 1...2)
        XCTAssertEqual(sel.tsv(in: grid), "b2\tc2\nb3\tc3")
    }

    func test_outOfBounds_clamped() {
        // a rect extending past the grid contributes only the in-bounds cells
        let sel = CSVRectSelection(anchorRow: 2, anchorCol: 2, focusRow: 9, focusCol: 9)
        XCTAssertEqual(sel.tsv(in: grid), "c3")
    }

    func test_jaggedRow_skipsMissingCells() {
        let jagged = [["x", "y", "z"], ["only"]]
        let sel = CSVRectSelection(anchorRow: 0, anchorCol: 0, focusRow: 1, focusCol: 2)
        XCTAssertEqual(sel.tsv(in: jagged), "x\ty\tz\nonly")
    }
}
