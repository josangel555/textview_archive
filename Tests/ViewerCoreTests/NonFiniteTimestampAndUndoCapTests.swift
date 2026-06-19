import XCTest
@testable import ViewerCore

/// Host regression coverage for two host-fixable findings from the
/// 2026-06-18 adversarial review:
///  - TSK-1013: `ClaudeLogParser`/`ClaudeMonitorLog.parseTimestamp` must reject
///    non-finite (NaN / ±Inf) seconds instead of minting a garbage/distant Date.
///  - TSK-1004: `HexEditBuffer.undoStack` must be bounded so a long edit
///    session can't grow undo history without limit.
final class NonFiniteTimestampTests: XCTestCase {

    func test_logParser_parseTimestamp_rejectsNonFinite() {
        XCTAssertNil(ClaudeLogParser.parseTimestamp(Double.nan))
        XCTAssertNil(ClaudeLogParser.parseTimestamp(Double.infinity))
        XCTAssertNil(ClaudeLogParser.parseTimestamp(-Double.infinity))
    }

    func test_logParser_parseTimestamp_acceptsFinite() {
        XCTAssertEqual(
            ClaudeLogParser.parseTimestamp(1_700_000_000.0),
            Date(timeIntervalSince1970: 1_700_000_000.0)
        )
    }

    func test_monitorLog_parseTimestamp_rejectsNonFinite() {
        XCTAssertNil(ClaudeMonitorLog.parseTimestamp(NSNumber(value: Double.nan)))
        XCTAssertNil(ClaudeMonitorLog.parseTimestamp(NSNumber(value: Double.infinity)))
        XCTAssertNil(ClaudeMonitorLog.parseTimestamp(NSNumber(value: -Double.infinity)))
    }

    func test_monitorLog_parseTimestamp_acceptsFinite() {
        XCTAssertEqual(
            ClaudeMonitorLog.parseTimestamp(NSNumber(value: 1_700_000_000.0)),
            Date(timeIntervalSince1970: 1_700_000_000.0)
        )
    }
}

final class HexEditBufferUndoCapTests: XCTestCase {

    /// TEETH: without the cap the depth would equal the push count
    /// (`maxUndoDepth + 1000`), blowing past the asserted upper bound.
    func test_undoStack_isBounded_underManyEdits() {
        var buf = HexEditBuffer(original: [UInt8](repeating: 0, count: 4))
        let pushes = HexEditBuffer.maxUndoDepth + 1000
        for i in 0..<pushes {
            // Alternate two distinct values so every overwrite truly changes
            // the byte (a same-value re-type is a no-op and wouldn't push).
            buf.setByte(byte: 0, value: i % 2 == 0 ? 0xAA : 0x55)
        }
        // Bounded: depth stays near the cap, never the full push count.
        XCTAssertLessThanOrEqual(buf.undoDepth, HexEditBuffer.maxUndoDepth + 300)
        XCTAssertGreaterThanOrEqual(buf.undoDepth, HexEditBuffer.maxUndoDepth - 300)
        // Still functional after capping.
        XCTAssertTrue(buf.canUndo)
        XCTAssertNotNil(buf.undo())
    }

    func test_undoStack_unbounded_belowCap() {
        var buf = HexEditBuffer(original: [UInt8](repeating: 0, count: 4))
        for i in 0..<100 {
            buf.setByte(byte: 0, value: i % 2 == 0 ? 0xAA : 0x55)
        }
        // Below the cap nothing is trimmed.
        XCTAssertEqual(buf.undoDepth, 100)
    }
}
