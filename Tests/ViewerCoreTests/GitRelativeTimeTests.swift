import XCTest
@testable import ViewerCore

/// Pure coverage for the shared Git "x ago" formatter. Pins the bug the
/// dedup fixed: the old GitStashTab copy collapsed every 1–7-day age to the
/// literal "yesterday" instead of "N d ago".
final class GitRelativeTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)
    private func ago(_ seconds: Int) -> String {
        GitRelativeTime.format(unix: Int(now.timeIntervalSince1970) - seconds, now: now)
    }

    func test_buckets() {
        XCTAssertEqual(ago(0), "just now")
        XCTAssertEqual(ago(59), "just now")
        XCTAssertEqual(ago(60), "1 min ago")
        XCTAssertEqual(ago(3599), "59 min ago")
        XCTAssertEqual(ago(3600), "1 h ago")
        XCTAssertEqual(ago(86_399), "23 h ago")
        XCTAssertEqual(ago(86_400), "1 d ago")
    }

    func test_fiveDays_isDaysAgo_notYesterday() {
        // The exact regression: 5 days must read "5 d ago", never "yesterday".
        XCTAssertEqual(ago(5 * 86_400), "5 d ago")
        XCTAssertEqual(ago(6 * 86_400), "6 d ago")
    }

    func test_weeks() {
        XCTAssertEqual(ago(7 * 86_400), "1 wk ago")
        XCTAssertEqual(ago(21 * 86_400), "3 wk ago")
    }

    func test_futureTimestamp_isJustNow() {
        XCTAssertEqual(ago(-500), "just now")
    }
}
