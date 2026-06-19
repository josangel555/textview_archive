import XCTest
@testable import ViewerCore
import RustCore

/// TSK-668 — host tests for the windowed CSV data source. Exercises the paging
/// MODEL (open → header/total, window at several offsets, first/last/partial-tail
/// boundary → correct source rows, filtered windowing with the absolute
/// index → row mapping). Scroll-driven fetch + render is the VM tail.
final class CSVRowWindowSourceTests: XCTestCase {

    /// Build a deterministic CSV: header `id,name` + `n` body rows where row i
    /// is `i,row<i>`. The absolute source-row id of body row i is exactly i.
    private func makeCSV(rows n: Int) -> String {
        var s = "id,name\n"
        s.reserveCapacity(n * 12)
        for i in 0..<n { s += "\(i),row\(i)\n" }
        return s
    }

    // MARK: - open: header + total

    func testOpenExposesHeaderAndTotal() throws {
        let src = try CSVRowWindowSource(text: makeCSV(rows: 1_000))
        XCTAssertEqual(src.header, ["id", "name"])
        XCTAssertEqual(src.totalRowCount, 1_000)
        // The header probe must not have to project body rows to read the total.
        XCTAssertEqual(try src.filteredRowCount(), 1_000, "unfiltered → all rows survive")
    }

    // MARK: - windows at several offsets

    func testWindowAtSeveralOffsetsReturnsContiguousRows() throws {
        let src = try CSVRowWindowSource(text: makeCSV(rows: 1_000))
        for offset in [0, 1, 37, 500, 989] {
            let limit = 10
            let w = try src.window(offset: offset, limit: limit)
            let expectedCount = min(limit, 1_000 - offset)
            XCTAssertEqual(w.rows.count, expectedCount, "offset \(offset) count")
            XCTAssertEqual(w.offset, offset)
            XCTAssertEqual(w.totalRows, 1_000, "always the table total, not window size")
            // Contiguous: each row in the window maps to source row offset+j and
            // carries the expected cell payload.
            for j in 0..<expectedCount {
                let sourceRow = offset + j
                XCTAssertEqual(w.absoluteIndices[j], sourceRow,
                               "offset \(offset) row \(j) absolute id")
                XCTAssertEqual(w.rows[j], ["\(sourceRow)", "row\(sourceRow)"],
                               "offset \(offset) row \(j) payload")
            }
        }
    }

    // MARK: - boundaries: first, last, partial-tail

    func testFirstWindowMapsToRowZero() throws {
        let src = try CSVRowWindowSource(text: makeCSV(rows: 250))
        let w = try src.window(offset: 0, limit: 5)
        XCTAssertEqual(w.absoluteIndices, [0, 1, 2, 3, 4])
        XCTAssertEqual(w.rows.first, ["0", "row0"])
        XCTAssertEqual(w.rows.last, ["4", "row4"])
    }

    func testPartialTailWindowSaturatesAtLastRow() throws {
        // 250 rows; ask for [245, 255) → only 245..249 exist (5 rows), no error.
        let src = try CSVRowWindowSource(text: makeCSV(rows: 250))
        let w = try src.window(offset: 245, limit: 10)
        XCTAssertEqual(w.rows.count, 5, "limit saturates at the surviving end")
        XCTAssertEqual(w.absoluteIndices, [245, 246, 247, 248, 249])
        XCTAssertEqual(w.rows.last, ["249", "row249"], "last source row")
    }

    func testLastSingleRowWindow() throws {
        let src = try CSVRowWindowSource(text: makeCSV(rows: 250))
        let w = try src.window(offset: 249, limit: 1)
        XCTAssertEqual(w.rows.count, 1)
        XCTAssertEqual(w.absoluteIndices, [249])
        XCTAssertEqual(w.rows.first, ["249", "row249"])
    }

    func testWindowPastEndIsEmptyNotError() throws {
        let src = try CSVRowWindowSource(text: makeCSV(rows: 100))
        let w = try src.window(offset: 500, limit: 10)
        XCTAssertTrue(w.rows.isEmpty)
        XCTAssertTrue(w.absoluteIndices.isEmpty)
        XCTAssertEqual(w.totalRows, 100, "total still reported past the end")
    }

    func testZeroAndNegativeLimitYieldEmptyWindow() throws {
        let src = try CSVRowWindowSource(text: makeCSV(rows: 100))
        XCTAssertTrue(try src.window(offset: 10, limit: 0).rows.isEmpty)
        XCTAssertTrue(try src.window(offset: 10, limit: -5).rows.isEmpty)
    }

    func testNegativeOffsetClampsToZero() throws {
        let src = try CSVRowWindowSource(text: makeCSV(rows: 100))
        let w = try src.window(offset: -5, limit: 3)
        XCTAssertEqual(w.offset, 0)
        XCTAssertEqual(w.absoluteIndices, [0, 1, 2])
    }

    // MARK: - range convenience

    func testRangeConvenienceMatchesOffsetLimit() throws {
        let src = try CSVRowWindowSource(text: makeCSV(rows: 500))
        let byRange = try src.window(in: 100..<110)
        let byOffset = try src.window(offset: 100, limit: 10)
        XCTAssertEqual(byRange, byOffset)
        XCTAssertEqual(byRange.absoluteIndices, Array(100..<110))
    }

    func testEmptyRangeYieldsEmptyWindow() throws {
        let src = try CSVRowWindowSource(text: makeCSV(rows: 500))
        // An empty (zero-width) range yields an empty window without a core call.
        // (`Range` cannot hold reversed bounds — `60..<50` traps at construction
        // in the Swift stdlib, so the only ill-formed range a caller can build is
        // the degenerate equal-bounds one.)
        let w = try src.window(in: 50..<50)
        XCTAssertTrue(w.rows.isEmpty)
        XCTAssertEqual(w.offset, 50, "empty range still reports the requested offset")
    }

    // MARK: - filtered windowing keeps the absolute index → row map stable

    func testFilteredWindowPagesSurvivingSetWithAbsoluteIndices() throws {
        // 100 rows; filter "row1" matches row1 + row10..19 = 11 surviving rows.
        let src = try CSVRowWindowSource(text: makeCSV(rows: 100))
        try src.setFilter("row1")
        XCTAssertEqual(try src.filteredRowCount(), 11)
        XCTAssertEqual(src.totalRowCount, 100, "total stays the unfiltered table size")

        // First window of the surviving set → absolute ids 1, 10, 11.
        let head = try src.window(offset: 0, limit: 3)
        XCTAssertEqual(head.absoluteIndices, [1, 10, 11])
        XCTAssertEqual(head.rows.first, ["1", "row1"])
        XCTAssertEqual(head.rows[1], ["10", "row10"])

        // Partial-tail of the filtered set: [9, 14) → only the last 2 survive
        // (ids 18, 19), saturating at the surviving end of 11.
        let tail = try src.window(offset: 9, limit: 5)
        XCTAssertEqual(tail.rows.count, 2)
        XCTAssertEqual(tail.absoluteIndices, [18, 19])
        XCTAssertEqual(tail.rows.last, ["19", "row19"])
    }

    func testClearingFilterRestoresFullSet() throws {
        let src = try CSVRowWindowSource(text: makeCSV(rows: 100))
        try src.setFilter("row1")
        XCTAssertEqual(try src.filteredRowCount(), 11)
        try src.setFilter("")  // clear
        XCTAssertEqual(try src.filteredRowCount(), 100)
        let w = try src.window(offset: 0, limit: 3)
        XCTAssertEqual(w.absoluteIndices, [0, 1, 2], "absolute ids back to source order")
    }

    func testColumnScopedFilterPagesCorrectSurvivingRows() throws {
        // Filter the name column for an exact-ish substring; "row5" hits row5 +
        // row50..59 = 11 rows. Scope to column 1 (name) so an id match can't leak.
        let src = try CSVRowWindowSource(text: makeCSV(rows: 100))
        try src.setFilter("row5", scope: .column(1))
        XCTAssertEqual(try src.filteredRowCount(), 11)
        let w = try src.window(offset: 0, limit: 2)
        XCTAssertEqual(w.absoluteIndices, [5, 50])
    }
}
