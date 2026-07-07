import XCTest
@testable import ViewerCore

/// TSK-1485 — the edit-location ring: capture/coalesce/jump ordering + the
/// snapshot round-trip.
final class EditLocationHistoryTests: XCTestCase {

    func test_recordsDistinctSites_inOrder() {
        var h = EditLocationHistory()
        h.recordEdit(line: 10)
        h.recordEdit(line: 40)
        h.recordEdit(line: 100)
        XCTAssertEqual(h.lines, [10, 40, 100])
        XCTAssertEqual(h.current, 100)
    }

    func test_coalescesAdjacentEdits() {
        var h = EditLocationHistory(coalesceRadius: 2)
        h.recordEdit(line: 10)
        h.recordEdit(line: 11)   // within radius → coalesce
        h.recordEdit(line: 12)   // still within radius of 11
        XCTAssertEqual(h.lines, [12], "a typed run collapses to one stop (latest line)")
        h.recordEdit(line: 40)   // far → new stop
        XCTAssertEqual(h.lines, [12, 40])
    }

    func test_jumpBackForward_walksSites() {
        var h = EditLocationHistory()
        [10, 40, 100].forEach { h.recordEdit(line: $0) }
        XCTAssertEqual(h.jumpBack(), 40)
        XCTAssertEqual(h.jumpBack(), 10)
        XCTAssertNil(h.jumpBack(), "at the oldest → nil")
        XCTAssertEqual(h.jumpForward(), 40)
        XCTAssertEqual(h.jumpForward(), 100)
        XCTAssertNil(h.jumpForward(), "at the newest → nil")
    }

    func test_editAfterJump_truncatesForward_browserSemantics() {
        var h = EditLocationHistory()
        [10, 40, 100].forEach { h.recordEdit(line: $0) }
        _ = h.jumpBack()          // now at 40
        h.recordEdit(line: 55)    // new edit from here → 100 is dropped
        XCTAssertEqual(h.lines, [10, 40, 55])
        XCTAssertNil(h.jumpForward(), "forward history was truncated")
    }

    func test_capacityEvictsOldest() {
        var h = EditLocationHistory(capacity: 3, coalesceRadius: 0)
        [10, 20, 30, 40].forEach { h.recordEdit(line: $0) }
        XCTAssertEqual(h.lines, [20, 30, 40], "oldest dropped at capacity")
        XCTAssertEqual(h.current, 40)
    }

    func test_snapshotRoundTrip_survivesEncodeDecode() throws {
        var h = EditLocationHistory()
        [10, 40, 100].forEach { h.recordEdit(line: $0) }
        _ = h.jumpBack()   // cursor at index 1 (line 40)
        let data = try JSONEncoder().encode(h)
        let restored = try JSONDecoder().decode(EditLocationHistory.self, from: data)
        XCTAssertEqual(restored.lines, [10, 40, 100])
        XCTAssertEqual(restored.current, 40, "the cursor position persists across a session switch")
    }

    func test_decodeRepairsOutOfRangeCursor() throws {
        // A tampered/old snapshot with a cursor past the end.
        let json = #"{"lines":[5,9],"cursor":99}"#.data(using: .utf8)!
        let h = try JSONDecoder().decode(EditLocationHistory.self, from: json)
        XCTAssertEqual(h.current, 9, "cursor clamped into range")
    }

    func test_ignoresInvalidLines() {
        var h = EditLocationHistory()
        h.recordEdit(line: 0)
        h.recordEdit(line: -5)
        XCTAssertTrue(h.isEmpty)
    }
}
