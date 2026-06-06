import XCTest
@testable import ViewerUI

/// Coverage for `LogTimestamp.string(_:)` — the nanos-since-epoch →
/// `"HH:mm:ss.SSS"` formatter behind the observability logs view. Was
/// untested.
///
/// Assertions are deliberately timezone-independent: the `HH:mm` fields
/// shift with the local zone (and some zones carry :30/:45 offsets), but
/// the seconds-of-minute and the millisecond fraction do NOT — no modern
/// zone has a sub-minute UTC offset. So we pin the format shape and the
/// `ss.SSS` tail (the non-obvious millisecond precision + zero-padding
/// this formatter exists to provide), not the wall-clock hour.
final class LogTimestampTests: XCTestCase {

    private let ns: UInt64 = 1_000_000_000

    func test_formatShape_isHHmmssMillis() {
        let s = LogTimestamp.string(123_456 * ns + 250_000_000)
        XCTAssertNotNil(s.range(of: #"^\d{2}:\d{2}:\d{2}\.\d{3}$"#, options: .regularExpression),
                        "expected HH:mm:ss.SSS, got \(s)")
    }

    func test_secondsAndMillis_areTimezoneIndependent() {
        // epoch + 30.250s → 30 seconds past a whole minute, 250 ms.
        XCTAssertTrue(LogTimestamp.string(30 * ns + 250_000_000).hasSuffix("30.250"),
                      "ss.SSS tail must be stable across zones")
    }

    func test_millis_zeroPadded() {
        // 7.007s → "...07.007": both the seconds and millis fields zero-pad.
        XCTAssertTrue(LogTimestamp.string(7 * ns + 7_000_000).hasSuffix("07.007"))
        // exact whole second → ".000"
        XCTAssertTrue(LogTimestamp.string(5 * ns).hasSuffix("05.000"))
    }

    func test_oneMillisecondApart_rendersDistinctly() {
        let a = LogTimestamp.string(42 * ns + 100_000_000) // .100
        let b = LogTimestamp.string(42 * ns + 101_000_000) // .101
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasSuffix(".100"))
        XCTAssertTrue(b.hasSuffix(".101"))
    }

    func test_zero_isWellFormed() {
        // The epoch instant must still format to the HH:mm:ss.SSS shape
        // (no crash, no empty string) — millis are .000.
        let s = LogTimestamp.string(0)
        XCTAssertNotNil(s.range(of: #"^\d{2}:\d{2}:\d{2}\.000$"#, options: .regularExpression),
                        "epoch should format cleanly, got \(s)")
    }
}
