import XCTest
import SwiftUI
@testable import ViewerUI

/// Column-width math for the SQLite results table (Batch B,
/// commit 2457015). Tests the pure helper that auto-sizes columns
/// from header + cell samples and caps the runaway-wide case.
@MainActor
final class SQLiteWidthTests: XCTestCase {

    private typealias W = ResultTableView

    func test_widths_have_one_entry_per_column() {
        let widths = W.computeWidths(
            columns: ["a", "b", "c"],
            rows: []
        )
        XCTAssertEqual(widths.count, 3)
    }

    func test_minimum_width_is_80() {
        let widths = W.computeWidths(
            columns: ["x"],
            rows: [["a"], ["b"]]
        )
        XCTAssertGreaterThanOrEqual(widths[0], 80)
    }

    func test_header_only_drives_width_when_rows_empty() {
        // Header text "AVeryLongColumnName" = 19 chars × 7 = 133, +24
        // padding = 157, but the header branch caps at 220 → 157.
        // Either way, > 80.
        let widths = W.computeWidths(
            columns: ["AVeryLongColumnName"],
            rows: []
        )
        XCTAssertGreaterThan(widths[0], 80)
        XCTAssertLessThanOrEqual(widths[0], 220)
    }

    func test_huge_cell_is_capped_at_320() {
        let huge = String(repeating: "x", count: 5000)
        let widths = W.computeWidths(
            columns: ["c"],
            rows: [[huge]]
        )
        XCTAssertLessThanOrEqual(widths[0], 320,
                                  "single huge cell must not blow out the column")
    }

    func test_nil_cells_are_skipped() {
        // Just NULL cells shouldn't widen anything — header alone wins.
        let widths = W.computeWidths(
            columns: ["c"],
            rows: [[nil], [nil], [nil]]
        )
        XCTAssertGreaterThanOrEqual(widths[0], 80)
    }

    func test_sample_size_bounds_work_done() {
        // Build 10k rows of "x" but only sample 5; result must be tiny
        // (5 × "x" = 7px × 1 char = 7, +24 = 31, clamped to 80).
        let rows: [[String?]] = Array(repeating: ["x"], count: 10_000)
        let widths = W.computeWidths(columns: ["c"], rows: rows, sampleRows: 5)
        XCTAssertEqual(widths[0], 80, "header + tiny cells should land on the 80pt floor")
    }

    func test_widths_handle_ragged_rows_safely() {
        // Some rows shorter than column count → no crash, no spurious widths.
        let widths = W.computeWidths(
            columns: ["a", "b", "c"],
            rows: [
                ["1"],            // shorter
                ["1", "22"],      // shorter
                ["1", "22", "333"]
            ]
        )
        XCTAssertEqual(widths.count, 3)
        // All within sane bounds.
        for w in widths {
            XCTAssertGreaterThanOrEqual(w, 80)
            XCTAssertLessThanOrEqual(w, 320)
        }
    }

    func test_approxTextWidth_is_seven_pt_per_char() {
        XCTAssertEqual(W.approxTextWidth(""), 0)
        XCTAssertEqual(W.approxTextWidth("abcd"), 28)
    }
}

