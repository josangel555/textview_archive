import XCTest
@testable import ViewerUI

/// Pure-logic coverage for the hex viewer's match-list cap (SCALE-7) and
/// the VoiceOver dump-label formatting (A11Y-03). Neither helper touches
/// AppKit/SwiftUI, so this suite is host-safe — it does not launch an
/// `NSApplication`.
final class HexMatchCapTests: XCTestCase {

    // MARK: - HexMatchCap.cap

    func test_cap_belowLimit_passesThroughUncapped() {
        let offsets = [0, 5, 10]
        let (out, capped) = HexMatchCap.cap(offsets, to: 50)
        XCTAssertEqual(out, offsets)
        XCTAssertFalse(capped)
    }

    func test_cap_atExactLimit_isNotCapped() {
        let offsets = Array(0..<10)
        let (out, capped) = HexMatchCap.cap(offsets, to: 10)
        XCTAssertEqual(out, offsets)
        XCTAssertFalse(capped, "count == limit must not be flagged as capped")
    }

    func test_cap_aboveLimit_keepsFirstNAndFlags() {
        let offsets = Array(0..<1000)
        let (out, capped) = HexMatchCap.cap(offsets, to: 100)
        XCTAssertEqual(out.count, 100)
        XCTAssertEqual(out, Array(0..<100), "must keep the FIRST N offsets")
        XCTAssertTrue(capped)
    }

    func test_cap_emptyInput_isNeverCapped() {
        let (out, capped) = HexMatchCap.cap([], to: 50)
        XCTAssertTrue(out.isEmpty)
        XCTAssertFalse(capped)
    }

    func test_cap_zeroLimit_dropsEverythingAndFlagsWhenNonEmpty() {
        let (outEmpty, cappedEmpty) = HexMatchCap.cap([], to: 0)
        XCTAssertTrue(outEmpty.isEmpty)
        XCTAssertFalse(cappedEmpty)

        let (out, capped) = HexMatchCap.cap([1, 2, 3], to: 0)
        XCTAssertTrue(out.isEmpty)
        XCTAssertTrue(capped)
    }

    func test_cap_negativeLimit_treatedAsZero() {
        let (out, capped) = HexMatchCap.cap([1, 2], to: -5)
        XCTAssertTrue(out.isEmpty)
        XCTAssertTrue(capped)
    }

    /// Pins the production cap so a future bump is a deliberate edit, and
    /// confirms a list one past the cap is flagged.
    func test_cap_productionLimit_50k() {
        XCTAssertEqual(HexView.matchCap, 50_000)
        let justOver = Array(0..<(HexView.matchCap + 1))
        let (out, capped) = HexMatchCap.cap(justOver, to: HexView.matchCap)
        XCTAssertEqual(out.count, HexView.matchCap)
        XCTAssertTrue(capped)
    }

    // MARK: - HexAccessibility.dumpLabel

    func test_dumpLabel_notTruncated_reportsByteCount() {
        let label = HexAccessibility.dumpLabel(
            byteCount: 6, totalByteCount: 6, isTruncated: false)
        XCTAssertEqual(label, "Hex dump, 6 bytes")
    }

    func test_dumpLabel_truncated_isExplicitAboutPartialView() {
        let label = HexAccessibility.dumpLabel(
            byteCount: 4_194_304, totalByteCount: 10_000_000,
            isTruncated: true)
        XCTAssertEqual(
            label, "Hex dump, showing first 4194304 of 10000000 bytes")
    }

    func test_dumpLabel_emptyFile() {
        let label = HexAccessibility.dumpLabel(
            byteCount: 0, totalByteCount: 0, isTruncated: false)
        XCTAssertEqual(label, "Hex dump, 0 bytes")
    }
}
