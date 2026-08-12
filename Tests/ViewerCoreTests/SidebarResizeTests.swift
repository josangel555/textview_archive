import XCTest
import CoreGraphics
@testable import ViewerCore

/// TSK-440 — the pure cores behind the sidebar tool-window resize
/// fixes. The divider's drag gesture and the on-screen layout are
/// VM-lane; these pin the math the gesture calls into (exact-closure
/// rule: `ResizableSectionDivider.apply` routes drags through
/// `DividerDragSession` into `SidebarResize.redistribute[Cascading]`).
final class SidebarResizeTests: XCTestCase {

    private let floor = SidebarPanelHeights.minExpandedHeight  // 120

    // MARK: redistribute — bug (C): sum-preserving adjacent resize

    func test_redistribute_movesHeightBetweenAdjacents_sumPreserved() {
        let r = SidebarResize.redistribute(above: 200, below: 300, delta: 50)
        XCTAssertEqual(r.above, 250)
        XCTAssertEqual(r.below, 250)
        XCTAssertEqual(r.above + r.below, 500, "the drag never mints or destroys height")
    }

    func test_redistribute_negativeDelta_dragUp() {
        let r = SidebarResize.redistribute(above: 200, below: 300, delta: -60)
        XCTAssertEqual(r.above, 140)
        XCTAssertEqual(r.below, 360)
    }

    func test_redistribute_clampsAtBelowFloor() {
        // below can only give up to its floor: max delta = 300 - 120 = 180.
        let r = SidebarResize.redistribute(above: 200, below: 300, delta: 500)
        XCTAssertEqual(r.below, floor, "below stops at the expanded-section floor")
        XCTAssertEqual(r.above, 380, "above absorbs exactly what below released")
    }

    func test_redistribute_clampsAtAboveFloor() {
        let r = SidebarResize.redistribute(above: 200, below: 300, delta: -500)
        XCTAssertEqual(r.above, floor)
        XCTAssertEqual(r.below, 380)
    }

    func test_redistribute_degeneratePair_unchanged() {
        // Hand-edited defaults can hold sub-floor heights; redistribution
        // must not mint height to "fix" them mid-drag.
        let r = SidebarResize.redistribute(above: 50, below: 60, delta: 30)
        XCTAssertEqual(r.above, 50)
        XCTAssertEqual(r.below, 60)
    }

    func test_redistribute_zeroDelta_identity() {
        let r = SidebarResize.redistribute(above: 150, below: 220, delta: 0)
        XCTAssertEqual(r.above, 150)
        XCTAssertEqual(r.below, 220)
    }

    // MARK: full plan — bug (B): the FILES boundary divider

    private func vis(_ pairs: [(SidebarPanelKind, Bool)]) -> [(panel: SidebarPanelKind, isVisible: Bool)] {
        pairs.map { (panel: $0.0, isVisible: $0.1) }
    }

    func test_fullPlan_filesPlusOneTool_drawsTheFilesDivider() {
        // THE bug-B case: one visible tool used to mean ZERO dividers.
        let plan = SidebarSectionPlanner.plan(
            filesVisible: true,
            accordion: vis([(.bookmarks, true), (.git, false)])
        )
        XCTAssertTrue(plan.drawFilesDivider, "FILES↔tool boundary must be draggable")
        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertFalse(plan.entries[0].drawTrailingDivider, "nothing below the last tool")
    }

    func test_fullPlan_filesPlusTwoTools_filesDividerAndOnePairDivider() {
        let plan = SidebarSectionPlanner.plan(
            filesVisible: true,
            accordion: vis([(.bookmarks, true), (.git, true)])
        )
        XCTAssertTrue(plan.drawFilesDivider)
        XCTAssertEqual(plan.entries.map(\.drawTrailingDivider), [true, false],
                       "exactly one divider between the pair — every adjacent boundary draggable")
    }

    func test_fullPlan_loneFiles_noDividers() {
        let plan = SidebarSectionPlanner.plan(
            filesVisible: true,
            accordion: vis([(.bookmarks, false), (.git, false)])
        )
        XCTAssertFalse(plan.drawFilesDivider, "nothing below FILES — no boundary to drag")
        XCTAssertTrue(plan.entries.isEmpty)
    }

    func test_fullPlan_filesHidden_noFilesDivider() {
        let plan = SidebarSectionPlanner.plan(
            filesVisible: false,
            accordion: vis([(.bookmarks, true), (.git, true)])
        )
        XCTAssertFalse(plan.drawFilesDivider)
        XCTAssertEqual(plan.entries.count, 2)
    }

    // (The `AccordionHeightResolver` tests died with the resolver —
    // 2026-08-12 special-case sweep; the one-rule stack has no bounded
    // accordion.)

    // MARK: - DividerDragSession (owner 2026-08-12 FINAL SPEC: a divider
    // drag moves THAT boundary only — no cascade, no other boundary)

    /// Owner repro 1: "shrinking the bottom-most panel past its minimum
    /// GREW the one above." A pair drag must STOP at the shrinking side's
    /// floor — the growing side never takes from anywhere else.
    func test_session_pairDrag_stopsAtTheFloor_neverBorrowsElsewhere() {
        let session = DividerDragSession(baseAbove: 300, baseBelow: 200, slack: 999)
        // Within the pair's give: 1:1, sum-preserving.
        var t = session.pairTargets(delta: 50)!
        XCTAssertEqual(t.above, 350)
        XCTAssertEqual(t.below, 150)
        // The neighbor floors after giving 80 — the divider STOPS. The
        // slack (deliberately huge here) must be IGNORED for pairs.
        t = session.pairTargets(delta: 500)!
        XCTAssertEqual(t.above, 380, "above stops at base + the pair's give — nothing more")
        XCTAssertEqual(t.below, SidebarPanelHeights.minExpandedHeight)
        XCTAssertEqual(t.above + t.below, 500, "sum-preserving always")
    }

    /// The pair math touches exactly TWO values — a third panel moving is
    /// structurally impossible; this pins the sum for a delta sweep.
    func test_session_pairDrag_sumInvariant_acrossDeltas() {
        let session = DividerDragSession(baseAbove: 260, baseBelow: 240, slack: 0)
        for delta in stride(from: CGFloat(-400), through: 400, by: 40) {
            let t = session.pairTargets(delta: delta)!
            XCTAssertEqual(t.above + t.below, 500, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(t.above, SidebarPanelHeights.minExpandedHeight)
            XCTAssertGreaterThanOrEqual(t.below, SidebarPanelHeights.minExpandedHeight)
        }
    }

    /// Flex-adjacent boundary (flex ABOVE, stored panel below — the
    /// FILES-on-top arrangement): drag up grows the stored panel into the
    /// flex's ORIGIN give, 1:1 to the full slack (the live-budget loop
    /// stalled at half); drag down shrinks it to its floor. Only this
    /// boundary moves — the flex absorbs by layout.
    func test_session_flexAboveBoundary_tracksFullSlack_andFloors() {
        let session = DividerDragSession(baseAbove: nil, baseBelow: 200, slack: 150)
        for delta in stride(from: CGFloat(-10), through: -150, by: -10) {
            XCTAssertEqual(session.belowTarget(delta: delta)!, 200 - delta,
                           "1:1 through the FULL origin slack")
        }
        XCTAssertEqual(session.belowTarget(delta: -400)!, 350,
            "growth clamps at base + origin slack")
        XCTAssertEqual(session.belowTarget(delta: 50)!, 150)
        XCTAssertEqual(session.belowTarget(delta: 500)!,
                       SidebarPanelHeights.minExpandedHeight,
                       "shrink stops at the floor")
    }

    /// Flex-adjacent boundary (stored panel above, flex BELOW): drag down
    /// grows the stored panel into the origin give; drag up floors it.
    func test_session_flexBelowBoundary_growsIntoSlack_andFloors() {
        let session = DividerDragSession(baseAbove: 240, baseBelow: nil, slack: 160)
        XCTAssertEqual(session.aboveTarget(delta: 60)!, 300)
        XCTAssertEqual(session.aboveTarget(delta: 500)!, 400,
            "growth clamps at base + origin slack")
        XCTAssertEqual(session.aboveTarget(delta: -500)!,
                       SidebarPanelHeights.minExpandedHeight)
        XCTAssertNil(session.pairTargets(delta: 10), "no pair without both bases")
    }
}
