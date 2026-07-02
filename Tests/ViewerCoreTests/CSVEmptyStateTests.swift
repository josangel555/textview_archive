import XCTest

@testable import ViewerCore

/// CSV empty-state message logic (usability audit 2026-07-02) — the table
/// must never render a blank void; it shows the right message per state.
final class CSVEmptyStateTests: XCTestCase {

    func test_empty_file_says_no_rows() {
        XCTAssertEqual(
            CSVEmptyState.message(total: 0, shown: 0, filterActive: false),
            "This file has no rows.")
        // Empty file takes precedence even if a filter is somehow set.
        XCTAssertEqual(
            CSVEmptyState.message(total: 0, shown: 0, filterActive: true),
            "This file has no rows.")
    }

    func test_filtered_to_nothing_says_no_match() {
        XCTAssertEqual(
            CSVEmptyState.message(total: 100, shown: 0, filterActive: true),
            "No rows match the current filter.")
    }

    func test_no_rows_without_filter_is_distinct() {
        // total>0 but shown 0 with no filter (defensive — shouldn't normally
        // happen since sort doesn't drop rows) → a neutral message, NOT the
        // filter one.
        XCTAssertEqual(
            CSVEmptyState.message(total: 100, shown: 0, filterActive: false),
            "No rows to display.")
    }

    func test_rows_present_renders_the_table() {
        XCTAssertNil(CSVEmptyState.message(total: 100, shown: 100, filterActive: false))
        XCTAssertNil(CSVEmptyState.message(total: 100, shown: 5, filterActive: true))
        XCTAssertNil(CSVEmptyState.message(total: 1, shown: 1, filterActive: false))
    }
}
