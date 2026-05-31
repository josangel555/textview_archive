import XCTest
import Combine
import ViewerKit
@testable import ViewerUI

/// Tests for `HelpSink` (0c) and the status-bar `formatDate` helper.
/// Host-safe (no NSApplication / window). Run with a class filter.
@MainActor
final class HelpSinkTests: XCTestCase {

    // The sink must dedupe on equal value so a hover that doesn't change the
    // displayed info is a no-op — else hovering re-publishes the StatusBar on
    // every pointer move (REPUB-1).
    func test_set_dedupesEqualValue() {
        let sink = HelpSink()
        var publishCount = 0
        let c = sink.objectWillChange.sink { _ in publishCount += 1 }
        defer { c.cancel() }

        let info = HelpInfo(title: "T", description: "D")
        sink.set(info)             // change nil → info: publishes
        sink.set(info)             // same value: must NOT publish
        sink.set(HelpInfo(title: "T", description: "D"))  // equal value: no publish
        XCTAssertEqual(publishCount, 1, "equal-value set must not republish the sink")
        XCTAssertEqual(sink.hovered, info)
    }

    func test_set_nilClearsAndPublishesOnce() {
        let sink = HelpSink()
        sink.set(HelpInfo(title: "T", description: "D"))
        var publishCount = 0
        let c = sink.objectWillChange.sink { _ in publishCount += 1 }
        defer { c.cancel() }

        sink.set(nil)              // info → nil: publishes
        sink.set(nil)              // nil → nil: no publish
        XCTAssertEqual(publishCount, 1)
        XCTAssertNil(sink.hovered)
    }

    // formatDate: time-only when the date is today, medium date otherwise.
    func test_formatDate_todayIsTimeOnly() {
        let cal = Calendar.current
        let now = Date()
        let formatted = StatusBar.formatDate(now, now: now, calendar: cal)
        // Time-only output never contains a 4-digit year.
        XCTAssertFalse(formatted.contains(String(cal.component(.year, from: now))),
            "a today date should format time-only (no year): \(formatted)")
    }

    func test_formatDate_pastIncludesDate() {
        let cal = Calendar.current
        let now = Date()
        let lastYear = cal.date(byAdding: .day, value: -400, to: now)!
        let formatted = StatusBar.formatDate(lastYear, now: now, calendar: cal)
        let year = cal.component(.year, from: lastYear)
        XCTAssertTrue(formatted.contains(String(year)),
            "a date over a year ago should include the year: \(formatted)")
    }
}
