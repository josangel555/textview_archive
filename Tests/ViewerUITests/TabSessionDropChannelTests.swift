import Combine
import XCTest
import ViewerCore
@testable import ViewerUI

/// Tab → session-pill drag (TSK-274's affordance, back as a real gesture
/// 2026-07-31). The gesture itself is pointer-driven (AX-lane), so the host
/// tier pins the DECISION layer end-to-end:
///   - `TabSessionDropChannel` — which pill a global point targets (the
///     active session excluded, dead sessions pruned, hover deduped);
///   - `StripFrameBox.globalPoint(fromStrip:)` — the strip→global
///     conversion the hit-test consumes;
///   - `StripReorderState` — the reorder caret hides while an external
///     target is hovered (the pill highlight replaces it);
///   - the wiring greps — both strips actually mount the channel, or the
///     whole feature is inert on screen.
/// The commit path (`SessionsAppCoordinator.moveTab`) keeps its own
/// behavior tests in `TabToNewSessionTests`.
@MainActor
final class TabSessionDropChannelTests: HeadlessUITestCase {

    private func pill(_ x: CGFloat) -> CGRect {
        CGRect(x: x, y: 0, width: 190, height: 46)
    }

    // MARK: hit-testing ------------------------------------------------

    func test_pointOverAPill_returnsThatSession() {
        let a = UUID(), b = UUID()
        let ch = TabSessionDropChannel()
        ch.recordPill(id: a, rect: pill(0))
        ch.recordPill(id: b, rect: pill(200))
        XCTAssertEqual(
            ch.sessionID(at: CGPoint(x: 250, y: 20), live: [a, b], excluding: nil), b)
    }

    func test_pointOutsideEveryPill_returnsNil() {
        let a = UUID()
        let ch = TabSessionDropChannel()
        ch.recordPill(id: a, rect: pill(0))
        XCTAssertNil(ch.sessionID(at: CGPoint(x: 500, y: 20), live: [a], excluding: nil))
        XCTAssertNil(ch.sessionID(at: CGPoint(x: 50, y: 300), live: [a], excluding: nil),
                     "a point below the strip (over the content area) is no target")
    }

    /// Dropping a tab on the session it's already in is a no-op by
    /// `moveTab`'s contract — the active pill must never register, else it
    /// lights up promising a move that won't happen.
    func test_activeSessionPill_isExcluded() {
        let active = UUID()
        let ch = TabSessionDropChannel()
        ch.recordPill(id: active, rect: pill(0))
        XCTAssertNil(ch.sessionID(
            at: CGPoint(x: 50, y: 20), live: [active], excluding: active))
    }

    /// The channel outlives sessions; a closed session's stale rect must
    /// not hijack drops aimed at the empty space it left behind.
    func test_deadSessionRects_arePruned() {
        let a = UUID(), dead = UUID()
        let ch = TabSessionDropChannel()
        ch.recordPill(id: a, rect: pill(0))
        ch.recordPill(id: dead, rect: pill(200))
        XCTAssertNil(ch.sessionID(
            at: CGPoint(x: 250, y: 20), live: [a], excluding: nil),
            "a rect for a session no longer in the live list must not hit")
    }

    // MARK: hover / highlight state -------------------------------------

    func test_removePill_clearsItsOwnHover_butNotAnothers() {
        let a = UUID(), b = UUID()
        let ch = TabSessionDropChannel()
        ch.recordPill(id: a, rect: pill(0))
        ch.recordPill(id: b, rect: pill(200))
        ch.setHovered(a)
        ch.removePill(id: b)
        XCTAssertEqual(ch.hoveredSessionID, a, "removing another pill keeps the hover")
        ch.removePill(id: a)
        XCTAssertNil(ch.hoveredSessionID,
                     "a session closed mid-drag must not stay lit as a target")
    }

    /// The gesture calls `setHovered` once per pointer SAMPLE; the strip
    /// must re-body once per target CHANGE (the chrome re-body budget).
    func test_setHovered_publishesOnlyOnChange() {
        let a = UUID()
        let ch = TabSessionDropChannel()
        var publishes = 0
        let sub = ch.objectWillChange.sink { publishes += 1 }
        defer { sub.cancel() }
        ch.setHovered(a)
        ch.setHovered(a)
        ch.setHovered(a)
        XCTAssertEqual(publishes, 1, "re-hovering the same pill must not republish")
        ch.setHovered(nil)
        XCTAssertEqual(publishes, 2)
        ch.setHovered(nil)
        XCTAssertEqual(publishes, 2)
    }

    // MARK: strip→global conversion --------------------------------------

    func test_globalPoint_addsTheRecordedContentOrigin() {
        let box = StripFrameBox()
        box.recordContentOrigin(CGPoint(x: 40, y: 76))
        let g = box.globalPoint(fromStrip: CGPoint(x: 100, y: -60))
        XCTAssertEqual(g.x, 140)
        XCTAssertEqual(g.y, 16,
            "a drag ABOVE the tab strip (negative strip-y) lands in the "
            + "session strip's global band — the cross-strip case itself")
    }

    // MARK: caret vs external target -------------------------------------

    /// While the pointer hovers a pill, the drop leaves the strip — an
    /// insertion caret would promise a reorder that isn't going to happen.
    func test_caretHides_whileAnExternalTargetIsHovered() {
        let ids = [UUID(), UUID(), UUID()]
        let frames = ids.enumerated().map {
            StripReorder.ItemFrame(id: $1, minX: CGFloat($0) * 100,
                                   maxX: CGFloat($0) * 100 + 100)
        }
        var state = StripReorderState(
            itemID: ids[0], sourceIndex: 0, translation: 150, gap: 2, frames: frames)
        XCTAssertNotNil(state.caretX, "sanity: a real move shows the caret")
        state.externalTargetID = UUID()
        XCTAssertNil(state.caretX, "hovering a session pill must hide the caret")
        state.externalTargetID = nil
        XCTAssertNotNil(state.caretX, "leaving the pill brings the caret back")
    }

    // MARK: wiring ------------------------------------------------------

    /// The model layer above is inert unless both strips actually mount it:
    /// the tab strip must offer the external target (+ record its global
    /// origin), the session strip must publish pill frames and render the
    /// highlight. Source-level pins, same pattern as
    /// `StripFrameBoxTests.test_bothStrips_gateSelectOnTheSuppression`.
    func test_bothStrips_mountTheCrossStripChannel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let tabBar = try String(
            contentsOf: root.appendingPathComponent("Sources/ViewerUI/TabBar.swift"),
            encoding: .utf8)
        XCTAssertTrue(tabBar.contains("sessionDropTarget(for: tab)"),
                      "TabBar: the drag must offer the session pills as targets")
        XCTAssertTrue(tabBar.contains("stripContentGlobalOrigin(into: frameBox)"),
                      "TabBar: without the global origin, hit-tests are garbage")
        XCTAssertTrue(tabBar.contains("moveTab(withID: tabID, toSessionID: sessionID)"),
                      "TabBar: the drop must commit through the tested moveTab path")
        let sessionBar = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/ViewerUI/Sessions/SessionTabBar.swift"),
            encoding: .utf8)
        XCTAssertTrue(sessionBar.contains("sessionDropTargetFrame(id: snap.id"),
                      "SessionTabBar: pills must publish their frames to be hittable")
        XCTAssertTrue(sessionBar.contains("isDropTarget: dropChannel.hoveredSessionID == snap.id"),
                      "SessionTabBar: the hovered pill must render the highlight")
    }
}
