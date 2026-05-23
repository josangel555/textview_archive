import XCTest
@testable import ViewerCore

/// Pure-logic coverage for `HexLayout` — the math the HEX viewer
/// relies on to position rows/columns at variable widths and to map
/// byte offsets back to character offsets inside the rendered dump.
final class HexLayoutTests: XCTestCase {

    func testRowCount_emptyAndPartial() {
        XCTAssertEqual(HexLayout.rowCount(byteCount: 0, width: 16), 0)
        XCTAssertEqual(HexLayout.rowCount(byteCount: 1, width: 16), 1)
        XCTAssertEqual(HexLayout.rowCount(byteCount: 16, width: 16), 1)
        XCTAssertEqual(HexLayout.rowCount(byteCount: 17, width: 16), 2)
    }

    func testRowCount_widthVariants() {
        XCTAssertEqual(HexLayout.rowCount(byteCount: 1024, width: 16), 64)
        XCTAssertEqual(HexLayout.rowCount(byteCount: 1024, width: 32), 32)
        XCTAssertEqual(HexLayout.rowCount(byteCount: 1024, width: 64), 16)
        // 4 MB cap, 64-wide: 65536 rows.
        XCTAssertEqual(
            HexLayout.rowCount(byteCount: 4 * 1024 * 1024, width: 64),
            65_536
        )
    }

    func testRowCount_guardsBadInput() {
        XCTAssertEqual(HexLayout.rowCount(byteCount: 10, width: 0), 0)
        XCTAssertEqual(HexLayout.rowCount(byteCount: -1, width: 16), 0)
    }

    func testRowAndColumn() {
        XCTAssertEqual(HexLayout.row(forOffset: 0, width: 16), 0)
        XCTAssertEqual(HexLayout.row(forOffset: 15, width: 16), 0)
        XCTAssertEqual(HexLayout.row(forOffset: 16, width: 16), 1)
        XCTAssertEqual(HexLayout.row(forOffset: 65, width: 32), 2)
        XCTAssertEqual(HexLayout.column(forOffset: 65, width: 32), 1)
        XCTAssertEqual(HexLayout.column(forOffset: 16, width: 16), 0)
    }

    func testClampWidth() {
        XCTAssertEqual(HexLayout.clampWidth(0), 16)
        XCTAssertEqual(HexLayout.clampWidth(8), 16)
        XCTAssertEqual(HexLayout.clampWidth(16), 16)
        XCTAssertEqual(HexLayout.clampWidth(17), 32)
        XCTAssertEqual(HexLayout.clampWidth(32), 32)
        XCTAssertEqual(HexLayout.clampWidth(40), 64)
        XCTAssertEqual(HexLayout.clampWidth(64), 64)
        XCTAssertEqual(HexLayout.clampWidth(128), 64)
    }

    func testAllowedWidthsAndDefault() {
        XCTAssertEqual(HexLayout.allowedWidths, [16, 32, 64])
        XCTAssertEqual(HexLayout.defaultWidth, 16)
    }

    func testRenderedRowLength() {
        // Per-row layout: 8 offset chars + 2 spaces + (width*3 - 1)
        // hex/sep chars + 2 spaces + width ascii chars + 1 newline.
        XCTAssertEqual(HexLayout.renderedRowLength(width: 16), 76)
        XCTAssertEqual(HexLayout.renderedRowLength(width: 32), 140)
        XCTAssertEqual(HexLayout.renderedRowLength(width: 64), 268)
    }

    func testHexAndAsciiCharOffsets() {
        // First hex pair starts after offset (8) + 2 spaces = column 10.
        XCTAssertEqual(HexLayout.hexCharOffset(inRowColumn: 0), 10)
        XCTAssertEqual(HexLayout.hexCharOffset(inRowColumn: 1), 13)
        XCTAssertEqual(HexLayout.hexCharOffset(inRowColumn: 15), 55)
        // ASCII column for width=16 starts at 10 + (16*3 - 1) + 2 = 59.
        XCTAssertEqual(HexLayout.asciiCharOffset(inRowColumn: 0, width: 16), 59)
        XCTAssertEqual(HexLayout.asciiCharOffset(inRowColumn: 15, width: 16), 74)
        // width=64 → 10 + 191 + 2 = 203.
        XCTAssertEqual(HexLayout.asciiCharOffset(inRowColumn: 0, width: 64), 203)
    }
}
