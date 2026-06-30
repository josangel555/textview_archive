import XCTest
@testable import ViewerCore

/// TSK-1141 (slices 1+2, host model) — a multi-sheet `.xlsx` retains ALL sheets on
/// the TextFile, and `withActiveSheet(_:)` re-derives `contents` (the active sheet's
/// TAB-separated text) so the existing CSV/table parse renders the chosen sheet —
/// while `contents` stays a valid String (save/find/dirty unchanged). The sheet-tabs
/// view is the render-VM tail (docs/SPREADSHEET_MULTISHEET_DESIGN.md).
final class TextFileMultiSheetTests: XCTestCase {

    private func file(sheets: [XLSXSheet], active: String) -> TextFile {
        TextFile(url: URL(fileURLWithPath: "/wb.xlsx"), contents: active,
                 encoding: .utf8, byteCount: 0, isExtractedReadOnly: true, xlsxSheets: sheets)
    }

    func test_withActiveSheet_reDerivesContentsFromTheChosenSheet() {
        let f = file(
            sheets: [XLSXSheet(name: "One", rows: [["a", "b"], ["c", "d"]]),
                     XLSXSheet(name: "Two", rows: [["x", "y"]])],
            active: "a\tb\nc\td")   // sheet-0 TSV, matching the loader's tabSeparated
        XCTAssertEqual(f.xlsxSheets?.count, 2)
        XCTAssertEqual(f.contents, "a\tb\nc\td", "contents starts as the active (first) sheet")

        let two = f.withActiveSheet(1)
        XCTAssertEqual(two.contents, "x\ty", "switching re-derives contents from sheet 2")
        XCTAssertEqual(two.xlsxSheets?.count, 2, "all sheets retained across the switch")
        XCTAssertEqual(f.withActiveSheet(0).contents, "a\tb\nc\td", "sheet 0 round-trips")
    }

    func test_withActiveSheet_outOfRange_isUnchanged() {
        let f = file(sheets: [XLSXSheet(name: "Only", rows: [["1"]])], active: "1")
        XCTAssertEqual(f.withActiveSheet(5).contents, "1", "out-of-range → unchanged")
        XCTAssertEqual(f.withActiveSheet(-1).contents, "1", "negative index → unchanged")
    }

    func test_nonSpreadsheet_hasNoSheets_andSwitchIsNoOp() {
        let f = TextFile(url: URL(fileURLWithPath: "/x.txt"), contents: "hello",
                         encoding: .utf8, byteCount: 5)
        XCTAssertNil(f.xlsxSheets, "a plain text file carries no sheets")
        XCTAssertEqual(f.withActiveSheet(0).contents, "hello", "no sheets → switch is a no-op")
    }
}
