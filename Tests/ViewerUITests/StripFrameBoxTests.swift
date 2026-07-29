import XCTest
import ViewerCore
@testable import ViewerUI

/// `StripFrameBox` decides WHICH item a drag is aiming at: it returns the
/// measured frames in model order, and `StripReorder`'s gap arithmetic
/// assumes array index == model index. A mis-ordered or short array silently
/// moves the wrong tab, so the contract is pinned here rather than left to
/// the (unautomatable) live drag.
@MainActor
final class StripFrameBoxTests: HeadlessUITestCase {

    private func box(_ entries: [(UUID, CGFloat)]) -> StripFrameBox {
        let b = StripFrameBox()
        for (id, minX) in entries {
            b.record(id: id, minX: minX, maxX: minX + 100)
        }
        return b
    }

    /// Frames come back in the order the CALLER asked for (model order),
    /// not measurement order — items are measured as SwiftUI lays them out,
    /// which is not guaranteed to match the tab order.
    func test_framesFollowRequestedOrder_notRecordingOrder() {
        let ids = [UUID(), UUID(), UUID()]
        // Recorded out of order on purpose.
        let b = box([(ids[2], 200), (ids[0], 0), (ids[1], 100)])
        let frames = b.frames(for: ids)
        XCTAssertEqual(frames?.map(\.id), ids)
        XCTAssertEqual(frames?.map(\.minX), [0, 100, 200])
    }

    /// Before the first layout pass some items have no frame. Returning a
    /// PARTIAL array would shift every index and drop the tab in the wrong
    /// slot, so the box refuses and the drag simply doesn't start.
    func test_anyUnmeasuredItem_returnsNil() {
        let ids = [UUID(), UUID(), UUID()]
        let b = box([(ids[0], 0), (ids[2], 200)])   // ids[1] never measured
        XCTAssertNil(b.frames(for: ids),
                     "a partial frame list must not be used for reordering")
    }

    func test_emptyStrip_returnsEmptyNotNil() {
        XCTAssertEqual(StripFrameBox().frames(for: [])?.count, 0)
    }

    /// The box outlives individual tabs, so a closed tab's frame must not
    /// linger and shift later gap arithmetic.
    func test_closedItemsArePruned_andRemainingOrderIsCorrect() {
        let ids = [UUID(), UUID(), UUID()]
        let b = box([(ids[0], 0), (ids[1], 100), (ids[2], 200)])
        let survivors = [ids[0], ids[2]]
        let frames = b.frames(for: survivors)
        XCTAssertEqual(frames?.map(\.id), survivors)
        XCTAssertEqual(frames?.map(\.minX), [0, 200])
    }

    /// Re-measuring the same id (a resize / zoom change) overwrites rather
    /// than appending a stale duplicate.
    func test_reRecordingSameID_overwrites() {
        let id = UUID()
        let b = StripFrameBox()
        b.record(id: id, minX: 0, maxX: 100)
        b.record(id: id, minX: 300, maxX: 420)
        let frames = b.frames(for: [id])
        XCTAssertEqual(frames?.count, 1)
        XCTAssertEqual(frames?.first?.minX, 300)
        XCTAssertEqual(frames?.first?.maxX, 420)
    }

    // MARK: click-vs-drag arbitration ---------------------------------
    //
    // Owner-reported (2026-07-28): "after move, it selects the tab I moved
    // over, not the one I moved. I want to remain in the same tab." The
    // Button's action still fires on the mouse-up that ends a drag, by which
    // point the strip has reordered — so the click selects whatever is now
    // under the pointer. These pin the swallow.

    func test_selectIsNotSuppressed_whenNoDragHasHappened() {
        // A plain click must always select — the whole point of the strip.
        XCTAssertFalse(StripFrameBox().shouldSuppressSelect())
    }

    func test_armingSuppressesTheClickThatEndsADrag() {
        let b = StripFrameBox()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        b.armSelectSuppression(now: t0)
        // The trailing click arrives in the same runloop turn as the drop.
        XCTAssertTrue(b.shouldSuppressSelect(now: t0))
        XCTAssertTrue(b.shouldSuppressSelect(now: t0.addingTimeInterval(0.1)))
    }

    /// Self-expiring: a drag that never delivers its mouse-up (pointer left
    /// the window, gesture cancelled) must NOT leave tab clicks dead.
    func test_suppressionExpires_soClicksAreNeverPermanentlyDead() {
        let b = StripFrameBox()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        b.armSelectSuppression(now: t0)
        let after = t0.addingTimeInterval(StripFrameBox.selectSuppressionWindow + 0.01)
        XCTAssertFalse(b.shouldSuppressSelect(now: after),
                       "a stuck suppression would make the strip unclickable")
    }

    /// Re-arming on every drag update keeps a SLOW drag covered — the window
    /// is measured from the last movement, not from the first.
    func test_reArmingExtendsTheWindowAcrossALongDrag() {
        let b = StripFrameBox()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        b.armSelectSuppression(now: t0)
        let late = t0.addingTimeInterval(5)          // a 5-second drag
        b.armSelectSuppression(now: late)
        XCTAssertTrue(b.shouldSuppressSelect(now: late.addingTimeInterval(0.1)))
    }

    /// Both strips must ROUTE their select through the gate, or the fix is
    /// inert where it matters.
    func test_bothStrips_gateSelectOnTheSuppression() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        for rel in ["Sources/ViewerUI/TabBar.swift",
                    "Sources/ViewerUI/Sessions/SessionTabBar.swift"] {
            let src = try String(contentsOf: root.appendingPathComponent(rel),
                                 encoding: .utf8)
            XCTAssertTrue(src.contains("shouldSuppressSelect()"),
                          "\(rel): onSelect must be gated, else a reorder "
                          + "switches you to the tab you dragged over")
        }
    }

    /// End-to-end on the real geometry: the frames the box hands back must
    /// produce the gap the caret was drawn at.
    func test_boxFeedsStripReorder_gapMatchesPointer() throws {
        let ids = [UUID(), UUID(), UUID()]
        let b = box([(ids[0], 0), (ids[1], 100), (ids[2], 200)])
        let frames = try XCTUnwrap(b.frames(for: ids))
        // Pointer past item 1's midpoint (150) → gap 2.
        XCTAssertEqual(StripReorder.insertionGap(pointerX: 160, frames: frames), 2)
        XCTAssertEqual(StripReorder.caretX(gap: 2, frames: frames), 200)
    }
}
