import XCTest
@testable import ViewerCore

/// Teeth for the CSV profiler (View ▸ CSV Summary) — a pure consumer of
/// `CSVParser.parse` output.
final class CsvSummaryTests: XCTestCase {

    func test_counts_rowsAndColumns() {
        let s = CsvSummary.compute(header: ["a", "b"], rows: [["1", "x"], ["2", "y"], ["3", "z"]])
        XCTAssertEqual(s.rowCount, 3)
        XCTAssertEqual(s.columnCount, 2)
        XCTAssertEqual(s.columns.map(\.name), ["a", "b"])
    }

    func test_numericColumn_minMaxMean() {
        let s = CsvSummary.compute(header: ["age"], rows: [["25"], ["41"], ["33"]])
        let c = s.columns[0]
        XCTAssertTrue(c.isNumeric)
        XCTAssertEqual(c.numericCount, 3)
        XCTAssertEqual(c.min, 25)
        XCTAssertEqual(c.max, 41)
        XCTAssertEqual(c.mean!, 33, accuracy: 1e-9)
    }

    func test_textColumn_notNumeric_noStats() {
        let s = CsvSummary.compute(header: ["name"], rows: [["alice"], ["bob"]])
        let c = s.columns[0]
        XCTAssertFalse(c.isNumeric)
        XCTAssertEqual(c.numericCount, 0)
        XCTAssertNil(c.min); XCTAssertNil(c.max); XCTAssertNil(c.mean)
    }

    func test_mixedColumn_oneNonNumeric_makesItText_butStatsOverParsed() {
        let s = CsvSummary.compute(header: ["v"], rows: [["1"], ["2"], ["oops"]])
        let c = s.columns[0]
        XCTAssertFalse(c.isNumeric, "a single non-numeric value drops the numeric flag")
        XCTAssertEqual(c.nonEmpty, 3)
        XCTAssertEqual(c.numericCount, 2)
        XCTAssertEqual(c.min, 1); XCTAssertEqual(c.max, 2)
    }

    func test_emptyCells_counted_andSkippedForNumeric() {
        let s = CsvSummary.compute(header: ["n"], rows: [["10"], ["  "], [""], ["20"]])
        let c = s.columns[0]
        XCTAssertEqual(c.empty, 2)
        XCTAssertEqual(c.nonEmpty, 2)
        XCTAssertTrue(c.isNumeric, "empty cells don't count against the numeric check")
        XCTAssertEqual(c.mean!, 15, accuracy: 1e-9)
    }

    func test_raggedRows_shortRowYieldsEmptyForMissingColumn() {
        let s = CsvSummary.compute(header: ["a", "b"], rows: [["1", "2"], ["3"]])
        XCTAssertEqual(s.columnCount, 2)
        XCTAssertEqual(s.columns[1].empty, 1, "second row is missing column b")
        XCTAssertEqual(s.columns[1].nonEmpty, 1)
    }

    func test_widerRowThanHeader_synthesizesColumnName() {
        let s = CsvSummary.compute(header: ["a"], rows: [["1", "2"]])
        XCTAssertEqual(s.columnCount, 2)
        XCTAssertEqual(s.columns[1].name, "Column 2")
    }

    func test_empty_input() {
        let s = CsvSummary.compute(header: [], rows: [])
        XCTAssertEqual(s.rowCount, 0)
        XCTAssertEqual(s.columnCount, 0)
        XCTAssertTrue(s.columns.isEmpty)
    }

    func test_thousandsAndCurrency_notTreatedAsNumeric() {
        let s = CsvSummary.compute(header: ["v"], rows: [["1,234"], ["$5"]])
        XCTAssertFalse(s.columns[0].isNumeric)
        XCTAssertEqual(s.columns[0].numericCount, 0)
    }

    func test_negativeAndDecimal_parse() {
        let s = CsvSummary.compute(header: ["v"], rows: [["-1.5"], ["2.5"]])
        let c = s.columns[0]
        XCTAssertTrue(c.isNumeric)
        XCTAssertEqual(c.min, -1.5); XCTAssertEqual(c.max, 2.5)
        XCTAssertEqual(c.mean!, 0.5, accuracy: 1e-9)
    }

    func test_report_includesCountsAndPerColumnLines() {
        let report = CsvSummary.report(header: ["name", "age"],
                                       rows: [["alice", "30"], ["bob", "40"]])
        XCTAssertTrue(report.contains("Rows: 2"))
        XCTAssertTrue(report.contains("Columns: 2"))
        XCTAssertTrue(report.contains("name (text)"))
        XCTAssertTrue(report.contains("age (numeric)"))
        XCTAssertTrue(report.contains("min 30, max 40, mean 35"))
    }

    func test_num_dropsTrailingZeros() {
        XCTAssertEqual(CsvSummary.num(35), "35")
        XCTAssertEqual(CsvSummary.num(35.5), "35.5")
        XCTAssertEqual(CsvSummary.num(0.25), "0.25")
    }
}
