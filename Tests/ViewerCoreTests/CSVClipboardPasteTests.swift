import XCTest
@testable import ViewerCore

/// TSK-1187 — teeth for the CSV paste path: TSV clipboard → cell grid, applied
/// into the editable model (bounds-clamped).
final class CSVClipboardPasteTests: XCTestCase {

    func test_parseTSV_splitsRowsAndColumns() {
        XCTAssertEqual(CSVClipboard.parseTSV("a\tb\nc\td"), [["a", "b"], ["c", "d"]])
    }

    func test_parseTSV_dropsTrailingNewline() {
        XCTAssertEqual(CSVClipboard.parseTSV("x\ty\n"), [["x", "y"]])
    }

    func test_parseTSV_singleCellAndEmpty() {
        XCTAssertEqual(CSVClipboard.parseTSV("solo"), [["solo"]])
        XCTAssertEqual(CSVClipboard.parseTSV(""), [])
    }

    func test_paste_setsCellsAtOffset() {
        var m = EditableCSVModel(parsing: "h1,h2\n1,2\n3,4")   // header + 2 body rows, 2 cols
        let n = m.paste([["x", "y"], ["z", "w"]], atRow: 1, column: 0)
        XCTAssertEqual(n, 4, "all 4 in-bounds cells changed")
        XCTAssertEqual(m.getCell(row: 1, column: 0), "x")
        XCTAssertEqual(m.getCell(row: 2, column: 1), "w")
    }

    func test_paste_clampsOutOfBounds() {
        var m = EditableCSVModel(parsing: "h1,h2\n1,2")        // 2 columns only
        let n = m.paste([["a", "b", "c"]], atRow: 1, column: 0)   // col 2 doesn't exist
        XCTAssertEqual(n, 2, "only the two in-bounds cells changed; the 3rd is skipped")
        XCTAssertEqual(m.getCell(row: 1, column: 0), "a")
        XCTAssertEqual(m.getCell(row: 1, column: 1), "b")
    }
}
