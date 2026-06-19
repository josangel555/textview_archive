import XCTest
@testable import ViewerCore

/// TSK-888 — per-file match-row cap for global search results. Pure, host-safe.
final class SearchResultCapTests: XCTestCase {

    func test_visible_clampsToCap() {
        XCTAssertEqual(SearchResultCap.visible(total: 10, cap: 50), 10, "under cap → all")
        XCTAssertEqual(SearchResultCap.visible(total: 50, cap: 50), 50, "at cap → all")
        XCTAssertEqual(SearchResultCap.visible(total: 500, cap: 50), 50, "over cap → capped")
        XCTAssertEqual(SearchResultCap.visible(total: 0, cap: 50), 0)
    }

    func test_overflow_isTheHiddenRemainder() {
        XCTAssertEqual(SearchResultCap.overflow(total: 10, cap: 50), 0, "under cap → nothing hidden")
        XCTAssertEqual(SearchResultCap.overflow(total: 50, cap: 50), 0)
        XCTAssertEqual(SearchResultCap.overflow(total: 500, cap: 50), 450)
    }

    func test_visiblePlusOverflow_equalsTotal() {
        for total in [0, 1, 49, 50, 51, 1234] {
            XCTAssertEqual(SearchResultCap.visible(total: total) + SearchResultCap.overflow(total: total),
                           total, "the cap partitions the matches with no loss")
        }
    }
}
