import XCTest
@testable import ViewerCore

/// TSK-1139 — the owner's resolution (2026-07-04): "measure the perf,
/// profile it and confirm/deny" whether viewport paging is needed, instead
/// of picking a skip/degraded/big-build option on theory.
///
/// This measures the FULL-MATERIALIZATION path a huge CSV pays today (the
/// render is already LazyVStack-virtualized; data memory + feature
/// wall-clocks are the open question): phys_footprint deltas via
/// `ProcessMemory.sample()` around parse/model-build, and wall-clocks for
/// parse/sort/filter. The numbers print to the log and land on the ticket;
/// the assertions are loose CLIFF guards only (this is a measurement, not a
/// perf gate).
final class CSVMaterializationBenchTests: XCTestCase {

    /// ~500k rows × 6 columns ≈ 27 MB of CSV text — the "huge CSV" class the
    /// windowing debate is about (well past anything usually opened).
    private func makeHugeCSV(rows: Int) -> String {
        var s = "id,name,city,score,flag,note\n"
        s.reserveCapacity(rows * 56)
        for i in 0..<rows {
            s += "\(i),person-\(i),city-\(i % 977),\(i % 100_000),\(i % 2 == 0),note \(i)\n"
        }
        return s
    }

    func test_measure_fullMaterialization_hugeCSV() {
        let rows = 500_000
        let text = makeHugeCSV(rows: rows)
        let textMB = Double(text.utf8.count) / 1_048_576

        func footprintMB() -> Double {
            Double(ProcessMemory.sample().appFootprintBytes ?? 0) / 1_048_576
        }

        let before = footprintMB()
        let t0 = Date()
        let parsed = RustCSVAdapter.parse(text)
        let parseMs = Date().timeIntervalSince(t0) * 1000
        let afterParse = footprintMB()
        XCTAssertEqual(parsed.rows.count, rows)

        let t1 = Date()
        let sorted = CsvSort.sorted(rows: parsed.rows, column: 3, ascending: true)
        let sortMs = Date().timeIntervalSince(t1) * 1000
        XCTAssertEqual(sorted.count, rows)

        let t2 = Date()
        let filter = CSVFilter(globalQuery: "city-500", globalScope: .all)
        let filtered = filter.apply(to: parsed)
        let filterMs = Date().timeIntervalSince(t2) * 1000
        XCTAssertFalse(filtered.rows.isEmpty)

        let afterAll = footprintMB()
        print("""
        [CSVMaterializationBench] TSK-1139 confirm/deny numbers
          input:            \(rows) rows, \(String(format: "%.1f", textMB)) MB text
          parse:            \(String(format: "%.0f", parseMs)) ms
          footprint:        \(String(format: "%.0f", before)) → \(String(format: "%.0f", afterParse)) MB after parse; \(String(format: "%.0f", afterAll)) MB after sort+filter
          materialization:  ≈\(String(format: "%.0f", afterParse - before)) MB for the [[String]] grid (\(String(format: "%.1f", (afterParse - before) / textMB))× text size)
          sort(col=3):      \(String(format: "%.0f", sortMs)) ms
          filter(substr):   \(String(format: "%.0f", filterMs)) ms
        """)

        // Cliff guards only — 10× headroom over anything acceptable.
        XCTAssertLessThan(parseMs, 30_000)
        XCTAssertLessThan(sortMs, 30_000)
        XCTAssertLessThan(filterMs, 30_000)
    }

    /// REGRESSION TOOTH for the finding this measurement surfaced: a CSV
    /// whose table frame exceeds the FFI cap (input > ~4 MB) used to come
    /// back as an EMPTY grid after Stage-B (the deleted Swift parser had
    /// silently absorbed the fault). The windowed-assembly path must keep
    /// every row + the sniffed delimiter.
    func test_bigCSV_survivesTheFrameCap() {
        let rows = 120_000                       // ≈6 MB → over wholeTableByteLimit
        let text = makeHugeCSV(rows: rows)
        XCTAssertGreaterThan(text.utf8.count, RustCSVAdapter.wholeTableByteLimit)
        let parsed = RustCSVAdapter.parse(text)
        XCTAssertEqual(parsed.rows.count, rows, "no silent truncation, no blank grid")
        XCTAssertEqual(parsed.header, ["id", "name", "city", "score", "flag", "note"])
        XCTAssertEqual(parsed.delimiter, ",", "the prefix sniff carries the delimiter")
        XCTAssertEqual(parsed.rows[rows - 1].first, "\(rows - 1)", "the tail row survives")
    }
}
