import XCTest
@testable import ViewerCore

/// Coverage for the pure "Insert Date & Time" formatter (TSK-299).
final class DateTimeStampTests: XCTestCase {

    private func fixedDate() -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 7; c.hour = 14; c.minute = 34
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "GMT")!
        return cal.date(from: c)!
    }

    func test_enUS_containsDatePiecesAndTime() {
        let s = DateTimeStamp.string(
            for: fixedDate(),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "GMT")!)
        XCTAssertTrue(s.contains("2026"), "year present — got \(s)")
        XCTAssertTrue(s.contains("Jun"), "abbreviated month present — got \(s)")
        XCTAssertTrue(s.contains("34"), "minute present — got \(s)")
    }

    func test_distinctDates_produceDistinctStrings() {
        let a = DateTimeStamp.string(for: Date(timeIntervalSince1970: 0),
                                     locale: Locale(identifier: "en_US"),
                                     timeZone: TimeZone(identifier: "GMT")!)
        let b = DateTimeStamp.string(for: Date(timeIntervalSince1970: 86_400),
                                     locale: Locale(identifier: "en_US"),
                                     timeZone: TimeZone(identifier: "GMT")!)
        XCTAssertNotEqual(a, b)
    }

    func test_neverEmpty() {
        XCTAssertFalse(DateTimeStamp.string(for: fixedDate()).isEmpty)
    }
}
