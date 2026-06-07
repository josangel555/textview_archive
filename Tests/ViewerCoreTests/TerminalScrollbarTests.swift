import XCTest
@testable import ViewerCore

/// Pure geometry for the terminal scrollback scrollbar (thumb sizing +
/// click/drag inverse). Headless — no AppKit.
final class TerminalScrollbarTests: XCTestCase {

    func test_noScrollbar_whenNoScrollback() {
        XCTAssertNil(TerminalScrollbar.thumb(rows: 24, scrollback: 0, offset: 0))
    }

    func test_thumbHeight_isVisibleFraction() {
        // 24 visible of 24+76=100 → 0.24 of the track.
        let t = TerminalScrollbar.thumb(rows: 24, scrollback: 76, offset: 0)
        XCTAssertNotNil(t)
        XCTAssertEqual(t!.height, 0.24, accuracy: 0.0001)
    }

    func test_thumbHeight_hasGrabbableFloor() {
        // Huge scrollback → tiny true fraction, floored to 0.06.
        let t = TerminalScrollbar.thumb(rows: 1, scrollback: 100_000, offset: 0)
        XCTAssertEqual(t!.height, 0.06, accuracy: 0.0001)
    }

    func test_position_bottomAtLiveOffsetZero_topAtMax() {
        let bottom = TerminalScrollbar.thumb(rows: 10, scrollback: 100, offset: 0)!
        XCTAssertEqual(bottom.position, 1.0, accuracy: 0.0001, "offset 0 (live) → thumb at bottom")
        let top = TerminalScrollbar.thumb(rows: 10, scrollback: 100, offset: 100)!
        XCTAssertEqual(top.position, 0.0, accuracy: 0.0001, "max offset (oldest) → thumb at top")
        let mid = TerminalScrollbar.thumb(rows: 10, scrollback: 100, offset: 50)!
        XCTAssertEqual(mid.position, 0.5, accuracy: 0.0001)
    }

    func test_thumb_clampsOutOfRangeOffset() {
        let t = TerminalScrollbar.thumb(rows: 10, scrollback: 100, offset: 999)!
        XCTAssertEqual(t.position, 0.0, accuracy: 0.0001)
    }

    func test_offsetForYFraction_isInverseOfPosition() {
        // top (y=0) → max offset; bottom (y=1) → 0 (live).
        XCTAssertEqual(TerminalScrollbar.offset(forYFraction: 0, rows: 10, scrollback: 100), 100)
        XCTAssertEqual(TerminalScrollbar.offset(forYFraction: 1, rows: 10, scrollback: 100), 0)
        XCTAssertEqual(TerminalScrollbar.offset(forYFraction: 0.5, rows: 10, scrollback: 100), 50)
    }

    func test_offsetForYFraction_clampsAndHandlesNoScrollback() {
        XCTAssertEqual(TerminalScrollbar.offset(forYFraction: -3, rows: 10, scrollback: 100), 100)
        XCTAssertEqual(TerminalScrollbar.offset(forYFraction: 9, rows: 10, scrollback: 100), 0)
        XCTAssertEqual(TerminalScrollbar.offset(forYFraction: 0.5, rows: 10, scrollback: 0), 0)
    }
}
