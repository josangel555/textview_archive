import XCTest
@testable import ViewerCore

/// TSK-1145 — multi-sheet .ods: parseAllTables returns every `table:table`
/// (name + grid), so a multi-sheet ODS workbook shows the sheet-tab strip
/// (SpreadsheetView) like .xlsx, instead of only its first table.
final class ODSMultiSheetTests: XCTestCase {

    func test_parseAllTables_returnsEachSheet_namedWithItsOwnGrid() {
        let xml = """
        <office:document-content><office:body><office:spreadsheet>
          <table:table table:name="Alpha">
            <table:table-row><table:table-cell><text:p>a1</text:p></table:table-cell></table:table-row>
          </table:table>
          <table:table table:name="Beta">
            <table:table-row>
              <table:table-cell><text:p>b1</text:p></table:table-cell>
              <table:table-cell><text:p>b2</text:p></table:table-cell>
            </table:table-row>
          </table:table>
        </office:spreadsheet></office:body></office:document-content>
        """
        let sheets = ODSContentParser.parseAllTables(contentXML: xml)
        XCTAssertEqual(sheets.count, 2, "both tables parsed")
        XCTAssertEqual(sheets[0].name, "Alpha")
        XCTAssertEqual(sheets[0].grid, [["a1"]])
        XCTAssertEqual(sheets[1].name, "Beta")
        // TEETH: the second sheet's grid must be ISOLATED — a broken per-table
        // reset would leak Alpha's "a1" into Beta.
        XCTAssertEqual(sheets[1].grid, [["b1", "b2"]])
    }

    func test_parseAllTables_singleTable_returnsOneSheet() {
        let xml = """
        <x><table:table table:name="Only">
          <table:table-row><table:table-cell><text:p>v</text:p></table:table-cell></table:table-row>
        </table:table></x>
        """
        let sheets = ODSContentParser.parseAllTables(contentXML: xml)
        XCTAssertEqual(sheets.count, 1)
        XCTAssertEqual(sheets[0].grid, [["v"]])
    }
}
