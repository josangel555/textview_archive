import XCTest
@testable import ViewerUI

/// Host-safe coverage for `ByteFormat` (in
/// `Sources/ViewerUI/Observability/TabMemoryProxy.swift`) — the byte
/// formatting shared by the memory + logs readouts (5 call sites in
/// `MemoryView`). Pure Foundation string math, was untested. Pins the
/// edge cases: the `unit == 0` no-decimal path, the exact 1024 boundary,
/// the GB ceiling (no TB unit), and the `Int` overload's negative clamp.
final class ByteFormatTests: XCTestCase {

    // MARK: - human(UInt64) — adaptive B/KB/MB/GB ladder

    func test_human_bytesUnder1024_areRawWithNoDecimal() {
        // The unit == 0 branch returns "\(bytes) B" — integer, no "%.1f".
        XCTAssertEqual(ByteFormat.human(UInt64(0)), "0 B")
        XCTAssertEqual(ByteFormat.human(UInt64(1)), "1 B")
        XCTAssertEqual(ByteFormat.human(UInt64(1023)), "1023 B")
    }

    func test_human_exactBoundary_promotesToNextUnit() {
        XCTAssertEqual(ByteFormat.human(UInt64(1024)), "1.0 KB")
        XCTAssertEqual(ByteFormat.human(UInt64(1536)), "1.5 KB") // 1.5 KiB rounds clean
        XCTAssertEqual(ByteFormat.human(UInt64(1024 * 1024)), "1.0 MB")
        XCTAssertEqual(ByteFormat.human(UInt64(1024 * 1024 * 1024)), "1.0 GB")
    }

    func test_human_cappsAtGB_noTerabyteUnit() {
        // 1024 GiB: the unit index is capped at GB (units.count - 1), so it
        // reads "1024.0 GB" rather than rolling over to a (nonexistent) TB.
        let oneTiB: UInt64 = 1024 * 1024 * 1024 * 1024
        XCTAssertEqual(ByteFormat.human(oneTiB), "1024.0 GB")
    }

    // MARK: - human(Int) — negative clamp + parity with the UInt64 path

    func test_human_int_negativeClampsToZero() {
        XCTAssertEqual(ByteFormat.human(-5), "0 B", "negative bytes clamp to 0 via max(0,)")
        XCTAssertEqual(ByteFormat.human(Int.min), "0 B")
    }

    func test_human_int_matchesUInt64Overload() {
        XCTAssertEqual(ByteFormat.human(2048), ByteFormat.human(UInt64(2048)))
        XCTAssertEqual(ByteFormat.human(2048), "2.0 KB")
    }

    // MARK: - mib(UInt64) — always-MiB math, "MB" label (Activity-Monitor parity)

    func test_mib_rendersBinaryMegabytesWithOneDecimal() {
        XCTAssertEqual(ByteFormat.mib(UInt64(0)), "0.0 MB")
        XCTAssertEqual(ByteFormat.mib(UInt64(1024 * 1024)), "1.0 MB")
        XCTAssertEqual(ByteFormat.mib(UInt64(1024 * 1024 * 3 / 2)), "1.5 MB") // 1.5 MiB
    }
}
