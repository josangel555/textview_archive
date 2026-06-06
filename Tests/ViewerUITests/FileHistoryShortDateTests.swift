import XCTest
@testable import ViewerUI

/// Coverage for `FileHistoryView.shortDate(_:)` — compacts a git `%ai`
/// timestamp ("2026-05-31 08:12:03 -0700") to "YYYY-MM-DD HH:MM" for the
/// history list cell. Was untested. Pure string slicing with a
/// pass-through fallback for anything that isn't space-separated.
@MainActor
final class FileHistoryShortDateTests: XCTestCase {

    private func sd(_ s: String) -> String { FileHistoryView.shortDate(s) }

    func test_fullGitTimestamp_dropsSecondsAndTimezone() {
        XCTAssertEqual(sd("2026-05-31 08:12:03 -0700"), "2026-05-31 08:12")
    }

    func test_noTimezone_stillTrimsToMinutes() {
        XCTAssertEqual(sd("2026-05-31 08:12:03"), "2026-05-31 08:12")
    }

    func test_alreadyMinutePrecision_isUnchangedShape() {
        XCTAssertEqual(sd("2026-05-31 08:12 -0700"), "2026-05-31 08:12")
    }

    func test_collapsesRepeatedSpaces() {
        // split(separator:) drops empty subsequences, so double spaces are fine.
        XCTAssertEqual(sd("2026-05-31  08:12:03  -0700"), "2026-05-31 08:12")
    }

    func test_timeWithoutColon_keptAsIs() {
        XCTAssertEqual(sd("2026-05-31 08"), "2026-05-31 08")
    }

    func test_malformedSingleToken_passesThroughUnchanged() {
        XCTAssertEqual(sd("garbage"), "garbage")
        XCTAssertEqual(sd(""), "")
        XCTAssertEqual(sd("2026-05-31"), "2026-05-31", "date-only (no space) is returned verbatim")
    }
}
