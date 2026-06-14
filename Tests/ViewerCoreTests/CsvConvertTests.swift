import XCTest
@testable import ViewerCore

/// Teeth for CSV → Markdown table / JSON conversion (Copy as …). Pure consumers
/// of parsed CSV (header + rows).
final class CsvConvertTests: XCTestCase {

    // MARK: Markdown table

    func test_markdownTable_paddedAndAligned() {
        let md = CsvConvert.toMarkdownTable(header: ["Name", "Age"], rows: [["Alice", "30"], ["Bo", "7"]])
        XCTAssertEqual(md, """
        | Name  | Age |
        | ----- | --- |
        | Alice | 30  |
        | Bo    | 7   |
        """)
    }

    func test_markdownTable_escapesPipesAndCollapsesNewlines() {
        let md = CsvConvert.toMarkdownTable(header: ["a"], rows: [["x|y"], ["line1\nline2"]])
        XCTAssertTrue(md.contains("x\\|y"), "pipe escaped")
        XCTAssertTrue(md.contains("line1 line2"), "newline collapsed to space")
        XCTAssertFalse(md.contains("line1\nline2"), "no raw newline inside a cell")
    }

    func test_markdownTable_padsShortRows() {
        let md = CsvConvert.toMarkdownTable(header: ["a", "b"], rows: [["1"]])
        // the short row gets an empty 2nd column; still a valid 2-col table
        let lines = md.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)   // header + separator + 1 row
        XCTAssertTrue(lines[2].hasPrefix("| 1"), "data row present; cells padded to width")
        XCTAssertEqual(lines[2].filter { $0 == "|" }.count, 3, "2 columns → 3 pipes")
    }

    func test_markdownTable_empty() {
        XCTAssertEqual(CsvConvert.toMarkdownTable(header: [], rows: []), "")
    }

    // MARK: JSON

    func test_json_arrayOfObjects_preservesColumnOrder() {
        let json = CsvConvert.toJSON(header: ["b", "a"], rows: [["1", "2"]])
        XCTAssertEqual(json, """
        [
          {
            "b": "1",
            "a": "2"
          }
        ]
        """)
    }

    func test_json_escapesValues() {
        let json = CsvConvert.toJSON(header: ["k"], rows: [["he said \"hi\"\tand\\done"]])
        XCTAssertTrue(json.contains("\"he said \\\"hi\\\"\\tand\\\\done\""))
    }

    func test_json_shortRow_fillsEmpty() {
        let json = CsvConvert.toJSON(header: ["a", "b"], rows: [["x"]])
        XCTAssertTrue(json.contains("\"a\": \"x\""))
        XCTAssertTrue(json.contains("\"b\": \"\""))
    }

    func test_json_emptyHeader() {
        XCTAssertEqual(CsvConvert.toJSON(header: [], rows: [["x"]]), "[]")
    }

    func test_json_isParseable() throws {
        let json = CsvConvert.toJSON(header: ["name", "n"], rows: [["A,B", "1"], ["C\"D", "2"]])
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]]
        XCTAssertEqual(obj?.count, 2)
        XCTAssertEqual(obj?[0]["name"], "A,B")
        XCTAssertEqual(obj?[1]["name"], "C\"D")
    }
}
