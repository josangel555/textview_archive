import XCTest
@testable import ViewerCore

/// TSK-1439 teeth — the SQLite browser export serializer + the CSV writer it
/// relies on. Pure logic, host-testable: given a query result, produce exactly
/// the CSV / Markdown / JSON a user copies or saves.
final class SQLiteResultExportTests: XCTestCase {

    private func result(_ columns: [String], _ rows: [[String?]], truncated: Bool = false)
        -> SQLiteReader.QueryResult {
        SQLiteReader.QueryResult(columns: columns, rows: rows, truncated: truncated)
    }

    // MARK: - CsvConvert.toCSV (the new writer)

    func test_toCSV_basic() {
        let csv = CsvConvert.toCSV(header: ["id", "name"], rows: [["1", "alice"], ["2", "bob"]])
        XCTAssertEqual(csv, "id,name\n1,alice\n2,bob")
    }

    func test_toCSV_rfc4180_quotesCommaQuoteNewline() {
        let csv = CsvConvert.toCSV(
            header: ["a", "b"],
            rows: [["has,comma", "has\"quote"], ["line1\nline2", "plain"]])
        // comma → quoted; embedded quote → quoted + doubled; newline → quoted (kept).
        XCTAssertEqual(csv,
            "a,b\n\"has,comma\",\"has\"\"quote\"\n\"line1\nline2\",plain")
    }

    func test_toCSV_padsShortRows() {
        let csv = CsvConvert.toCSV(header: ["a", "b", "c"], rows: [["1"]])
        XCTAssertEqual(csv, "a,b,c\n1,,")   // short row padded to 3 empty cells
    }

    func test_toCSV_empty() {
        XCTAssertEqual(CsvConvert.toCSV(header: [], rows: []), "")
    }

    // MARK: - SQLiteResultExport.serialize

    func test_serialize_csv_nullBecomesEmptyField() {
        let r = result(["id", "note"], [["1", nil], ["2", "hi"]])
        XCTAssertEqual(SQLiteResultExport.serialize(r, as: .csv), "id,note\n1,\n2,hi")
    }

    func test_serialize_csv_customNullPlaceholder() {
        let r = result(["id", "note"], [["1", nil]])
        XCTAssertEqual(
            SQLiteResultExport.serialize(r, as: .csv, nullPlaceholder: "NULL"),
            "id,note\n1,NULL")
    }

    func test_serialize_markdown_reusesCsvConvertTable() {
        let r = result(["Name", "Age"], [["Alice", "30"], [nil, "7"]])
        let md = SQLiteResultExport.serialize(r, as: .markdown)
        // NULL flattens to an empty cell; delegates to CsvConvert.toMarkdownTable.
        XCTAssertEqual(md, CsvConvert.toMarkdownTable(header: ["Name", "Age"],
                                                      rows: [["Alice", "30"], ["", "7"]]))
        XCTAssertTrue(md.hasPrefix("| Name"))
    }

    func test_serialize_json_arrayOfObjects() {
        let r = result(["a", "b"], [["1", nil]])
        let json = SQLiteResultExport.serialize(r, as: .json)
        XCTAssertEqual(json, """
        [
          {
            "a": "1",
            "b": ""
          }
        ]
        """)
    }

    func test_format_metadata() {
        XCTAssertEqual(SQLiteResultExport.Format.csv.fileExtension, "csv")
        XCTAssertEqual(SQLiteResultExport.Format.markdown.fileExtension, "md")
        XCTAssertEqual(SQLiteResultExport.Format.json.fileExtension, "json")
        XCTAssertEqual(SQLiteResultExport.Format.allCases.count, 3)
    }
}
