import XCTest
@testable import ViewerCore

/// T1 (host-safe, pure-logic): the shared file-date formatter must render a
/// known `Date` as the exact `yyyy-MM-dd HH:mm` 24-hour string. Time zone is
/// pinned so the assertion is deterministic regardless of host locale/zone.
final class DisplayDateFormatterTests: XCTestCase {

    /// 2026-06-03 14:07:42 UTC. Seconds are intentionally non-zero to prove
    /// they are dropped (minute precision).
    private static let known = Date(timeIntervalSince1970: 1_780_495_662)

    private func pinnedFormatter(zone: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: zone)
        return f
    }

    func test_rendersExact24HourString_UTC() {
        let formatter = pinnedFormatter(zone: "UTC")
        XCTAssertEqual(formatter.string(from: Self.known), "2026-06-03 14:07")
    }

    /// Same instant, different zone: confirms the shared helper uses the
    /// current time zone (here forced) and the 24h pattern holds in the PM.
    func test_rendersExact24HourString_NewYork() {
        // 14:07 UTC == 10:07 EDT on 2026-06-03.
        let formatter = pinnedFormatter(zone: "America/New_York")
        XCTAssertEqual(formatter.string(from: Self.known), "2026-06-03 10:07")
    }

    /// The production helper (current time zone) must agree with a formatter
    /// pinned to that same zone — i.e. it really is `yyyy-MM-dd HH:mm`/POSIX.
    func test_sharedHelperMatchesPinnedCurrentZone() {
        let expected = pinnedFormatter(zone: TimeZone.current.identifier)
            .string(from: Self.known)
        XCTAssertEqual(DisplayDateFormatter.string(from: Self.known), expected)
        XCTAssertEqual(Self.known.fileDisplayString, expected)
    }

    /// 24-hour clock: an afternoon time renders as 14:..,, never 02:.. PM.
    func test_uses24HourClock_noAMPM() {
        let s = pinnedFormatter(zone: "UTC").string(from: Self.known)
        XCTAssertTrue(s.hasSuffix(" 14:07"))
        XCTAssertFalse(s.localizedCaseInsensitiveContains("PM"))
        XCTAssertFalse(s.localizedCaseInsensitiveContains("AM"))
    }
}
