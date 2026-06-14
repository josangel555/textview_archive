import XCTest
@testable import ViewerCore

/// Teeth for JSON → CSV (View ▸ Copy as CSV) — inverse of `CsvConvert.toJSON`.
final class JsonConvertTests: XCTestCase {

    func test_basic_arrayOfObjects() {
        let json = #"[{"name":"alice","age":30},{"name":"bob","age":40}]"#
        // Columns are the sorted union of keys: age, name.
        XCTAssertEqual(JsonConvert.toCSV(json), "age,name\n30,alice\n40,bob")
    }

    func test_unionOfKeys_missingCellsEmpty() {
        let json = #"[{"a":1},{"b":2}]"#
        XCTAssertEqual(JsonConvert.toCSV(json), "a,b\n1,\n,2")
    }

    func test_numbers_integersHaveNoDecimal_floatsKept() {
        let json = #"[{"i":42,"f":1.5}]"#
        XCTAssertEqual(JsonConvert.toCSV(json), "f,i\n1.5,42")
    }

    func test_booleansAndNull() {
        let json = #"[{"ok":true,"bad":false,"n":null}]"#
        // Columns sorted: bad, n, ok.
        XCTAssertEqual(JsonConvert.toCSV(json), "bad,n,ok\nfalse,,true")
    }

    func test_quoting_commaQuoteNewline() {
        let json = #"[{"v":"a,b"},{"v":"say \"hi\""},{"v":"line1\nline2"}]"#
        let csv = JsonConvert.toCSV(json)
        XCTAssertEqual(csv, "v\n\"a,b\"\n\"say \"\"hi\"\"\"\n\"line1\nline2\"")
    }

    func test_nestedObjectAndArray_renderAsCompactJSON() {
        let json = #"[{"meta":{"b":2,"a":1},"tags":[1,2]}]"#
        // Nested values serialized with sorted keys, then the whole cell is
        // quoted because it contains commas.
        XCTAssertEqual(JsonConvert.toCSV(json),
                       #"meta,tags"# + "\n" + #""{""a"":1,""b"":2}","[1,2]""#)
    }

    func test_headerNeedingQuoting() {
        let json = #"[{"a,b":1}]"#
        XCTAssertEqual(JsonConvert.toCSV(json), "\"a,b\"\n1")
    }

    func test_rejects_notAnArray() {
        XCTAssertNil(JsonConvert.toCSV(#"{"a":1}"#))
    }

    func test_rejects_arrayOfNonObjects() {
        XCTAssertNil(JsonConvert.toCSV("[1,2,3]"))
    }

    func test_rejects_mixedArray() {
        XCTAssertNil(JsonConvert.toCSV(#"[{"a":1},5]"#))
    }

    func test_rejects_emptyArray() {
        XCTAssertNil(JsonConvert.toCSV("[]"))
    }

    func test_rejects_objectsWithNoKeys() {
        XCTAssertNil(JsonConvert.toCSV("[{},{}]"))
    }

    func test_rejects_invalidJSON() {
        XCTAssertNil(JsonConvert.toCSV("not json at all"))
    }

    func test_roundTrip_csvToJsonToCsv_stableForSortedFlatData() {
        // CsvConvert.toJSON keeps all values as strings; round-tripping back
        // through toCSV yields the same table when columns are already sorted.
        let header = ["a", "b"]
        let rows = [["1", "x"], ["2", "y"]]
        let json = CsvConvert.toJSON(header: header, rows: rows)
        XCTAssertEqual(JsonConvert.toCSV(json), "a,b\n1,x\n2,y")
    }
}
