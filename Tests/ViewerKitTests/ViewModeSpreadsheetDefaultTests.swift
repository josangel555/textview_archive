import XCTest
import ViewerKit

/// TSK-1141/1145 reachability bug: `.xlsx`/`.ods` are loaded as a grid
/// (TextFileLoader retains sheets + emits TSV; the loader comment says
/// "xlsx/ods → grid"), but they were NOT in `tableExtensions`, so `.table` was
/// never offered → they opened as raw TSV *text* in the source view and the
/// multi-sheet SpreadsheetView (ContentView's `.table` branch) was UNREACHABLE.
/// These pin that a spreadsheet workbook opens as a TABLE.
final class ViewModeSpreadsheetDefaultTests: XCTestCase {

    func test_xlsx_defaultsToTable() {
        XCTAssertEqual(ViewModeOptions.defaultMode(for: URL(fileURLWithPath: "/x/book.xlsx")),
                       ViewMode.table, ".xlsx opens as a grid/table (not raw TSV text)")
    }

    func test_ods_defaultsToTable() {
        XCTAssertEqual(ViewModeOptions.defaultMode(for: URL(fileURLWithPath: "/x/book.ods")),
                       ViewMode.table, ".ods opens as a grid/table (not raw TSV text)")
    }
}
