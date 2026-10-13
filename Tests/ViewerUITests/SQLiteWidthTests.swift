import XCTest
import SwiftUI
@testable import ViewerUI

/// Column-width math for the SQLite results table (Batch B,
/// commit 94fa823). Tests the pure helper that auto-sizes columns
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

    // MARK: - uiScale (Bug 1 / item 11)
    //
    // The pure width math takes `uiScale` as an explicit parameter
    // (never a global) so it stays testable. At 1.0 it must be byte-for
    // byte identical to the un-scaled path (CSVTableView relies on this);
    // at >1.0 every metric — per-char estimate, padding, and the
    // 80/220/320 clamps — must scale in lockstep with the cell font.

    func test_approxTextWidth_scales_linearly_with_uiScale() {
        // 4 chars × 7 = 28 at 1.0; doubling uiScale doubles the estimate.
        XCTAssertEqual(W.approxTextWidth("abcd", uiScale: 1.0), 28)
        XCTAssertEqual(W.approxTextWidth("abcd", uiScale: 2.0), 56)
        XCTAssertEqual(W.approxTextWidth("abcd", uiScale: 1.5), 42)
        XCTAssertEqual(W.approxTextWidth("", uiScale: 3.0), 0)
    }

    func test_default_uiScale_matches_explicit_one() {
        // CSVTableView calls computeWidths without a scale; that path
        // must be identical to passing uiScale: 1.0.
        let cols = ["alpha", "b"]
        let rows: [[String?]] = [["xxxxxx", "y"], [nil, "zz"]]
        XCTAssertEqual(
            W.computeWidths(columns: cols, rows: rows),
            W.computeWidths(columns: cols, rows: rows, uiScale: 1.0)
        )
    }

    func test_floor_scales_with_uiScale() {
        // Tiny content lands on the 80pt floor at 1.0 → 160pt at 2.0.
        let w1 = W.computeWidths(columns: ["x"], rows: [["a"]], uiScale: 1.0)
        let w2 = W.computeWidths(columns: ["x"], rows: [["a"]], uiScale: 2.0)
        XCTAssertEqual(w1[0], 80)
        XCTAssertEqual(w2[0], 160)
    }

    func test_huge_cell_cap_scales_with_uiScale() {
        // The 320pt runaway cap becomes 640pt at 2.0 — the column may
        // grow, but only proportionally; it must not blow past 2× cap.
        let huge = String(repeating: "x", count: 5000)
        let w1 = W.computeWidths(columns: ["c"], rows: [[huge]], uiScale: 1.0)
        let w2 = W.computeWidths(columns: ["c"], rows: [[huge]], uiScale: 2.0)
        XCTAssertLessThanOrEqual(w1[0], 320)
        XCTAssertLessThanOrEqual(w2[0], 640)
        XCTAssertGreaterThan(w2[0], 320,
                             "scaled cap must let the column grow with the font")
    }

    func test_whole_width_vector_scales_proportionally() {
        // For a mid-range column (not pinned to the floor or cap), every
        // width at 2.0 is exactly twice the width at 1.0 — the entire
        // formula (estimate + padding + clamps) scales together.
        let cols = ["medium_header", "id"]
        let rows: [[String?]] = [
            ["a_mid_value_here", "12"],
            ["another_mid_val",  "34"],
        ]
        let w1 = W.computeWidths(columns: cols, rows: rows, uiScale: 1.0)
        let w2 = W.computeWidths(columns: cols, rows: rows, uiScale: 2.0)
        XCTAssertEqual(w1.count, w2.count)
        for (a, b) in zip(w1, w2) {
            XCTAssertEqual(b, a * 2, accuracy: 0.001)
        }
    }
}


// MARK: - TSK-604: proportional width rescale on zoom change

extension SQLiteWidthTests {

    func test_rescaledWidths_scalesProportionally() {
        let out = ResultTableView.rescaledWidths([100, 240, 80], from: 1.0, to: 2.0)
        XCTAssertEqual(out, [200, 480, 160])
    }

    func test_rescaledWidths_preservesUserDraggedRatio_onZoomOut() {
        // A user-dragged 300pt column at 2.0× comes back to 150pt at 1.0×.
        let out = ResultTableView.rescaledWidths([300, 100], from: 2.0, to: 1.0)
        XCTAssertEqual(out, [150, 50])
    }

    func test_rescaledWidths_degenerateScales_returnInputUntouched() {
        XCTAssertEqual(ResultTableView.rescaledWidths([100], from: 0, to: 2.0), [100],
                       "zero old scale must not divide")
        XCTAssertEqual(ResultTableView.rescaledWidths([100], from: 1.0, to: 0), [100],
                       "zero new scale must not wipe widths")
        XCTAssertEqual(ResultTableView.rescaledWidths([100], from: 1.5, to: 1.5), [100],
                       "unchanged scale is a no-op")
        XCTAssertEqual(ResultTableView.rescaledWidths([], from: 1.0, to: 2.0), [],
                       "empty widths stay empty")
    }
}
