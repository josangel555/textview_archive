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

    // MARK: - Cascading redistribution (owner 2026-08-09: "the third one
    // doesn't even move" — grow takes from the neighbor first, then from
    // the flex panel's slack; shrink stays pair-only)

    func test_cascade_neighborFirst_thenFlex() {
        // Neighbor can give 80 (200→120); the remaining 70 comes from flex.
        let r = SidebarResize.redistributeCascading(
            above: 300, below: 200, delta: 150, flexSlack: 500)
        XCTAssertEqual(r.above, 450)
        XCTAssertEqual(r.below, 120, "the neighbor gives down to its floor")
    }

    func test_cascade_flexSlackCapsTheOverflow() {
        // Neighbor gives 80; flex can only give 30 → total growth 110.
        let r = SidebarResize.redistributeCascading(
            above: 300, below: 200, delta: 150, flexSlack: 30)
        XCTAssertEqual(r.above, 410)
        XCTAssertEqual(r.below, 120)
    }

    func test_cascade_flooredNeighbor_growsEntirelyFromFlex() {
        // The exact owner repro: the neighbor is ALREADY at its floor, so
        // the old pair-only math moved nothing; the cascade grows from flex.
        let r = SidebarResize.redistributeCascading(
            above: 250, below: 120, delta: 100, flexSlack: 400)
        XCTAssertEqual(r.above, 350)
        XCTAssertEqual(r.below, 120)
    }

    func test_cascade_shrinkDirection_staysPairOnly() {
        let r = SidebarResize.redistributeCascading(
            above: 300, below: 200, delta: -50, flexSlack: 400)
        XCTAssertEqual(r.above, 250)
        XCTAssertEqual(r.below, 250, "shrink is sum-preserving, flex untouched")
    }

    func test_cascade_zeroSlack_matchesPairMath() {
        let a = SidebarResize.redistribute(above: 300, below: 200, delta: 150)
        let b = SidebarResize.redistributeCascading(
            above: 300, below: 200, delta: 150, flexSlack: 0)
        XCTAssertEqual(a.above, b.above)
        XCTAssertEqual(a.below, b.below)
    }

    // MARK: - DividerDragSession (owner 2026-08-12: the halving loop)

    /// The regression that motivated the frozen session: with the flex
    /// budget read LIVE per delta (shrinking by what the drag already
    /// consumed), a monotone grow drag converges at HALF the original
    /// slack. The session freezes the budget at origin — a monotone drag
    /// must track 1:1 for the FULL slack.
    func test_session_monotoneGrowDrag_tracksOneToOne_forTheFullSlack() {
        // Neighbor already floored: growth comes entirely from the flex
        // budget (300pt available at origin).
        let session = DividerDragSession(baseAbove: 250, baseBelow: 120, slack: 300)
        var previous: CGFloat = 250
        for delta in stride(from: CGFloat(20), through: 300, by: 20) {
            let t = session.pairTargets(delta: delta)!
            XCTAssertEqual(t.above, 250 + delta, accuracy: 0.01,
                "delta \(delta): the handle must track the pointer 1:1 "
                + "(the live-budget loop stalled at slack/2 = +150)")
            XCTAssertEqual(t.below, 120)
            XCTAssertGreaterThanOrEqual(t.above, previous)
            previous = t.above
        }
        // Past the budget: clamps at base + slack, never beyond.
        let over = session.pairTargets(delta: 500)!
        XCTAssertEqual(over.above, 250 + 300)
    }

    /// The OLD bug, executable: simulate the live-budget wiring (slack
    /// re-read after each write = origin slack minus what's consumed) and
    /// show it stalls at half. This documents WHY the session exists — if
    /// someone reverts to a live budget, the 1:1 test above goes red.
    func test_liveBudgetSimulation_demonstratesTheHalvingStall() {
        let base: CGFloat = 250, slack0: CGFloat = 300
        var above = base
        for delta in stride(from: CGFloat(20), through: 600, by: 20) {
            let liveSlack = slack0 - (above - base)   // what a re-body would see
            let t = SidebarResize.redistributeCascading(
                above: base, below: 120, delta: delta, flexSlack: liveSlack)
            above = t.above
        }
        // Converges to an oscillation around slack₀/2 (±one mouse step) —
        // nowhere near the full 300pt the user could SEE. The owner's
        // "can't resize above 50%".
        XCTAssertLessThanOrEqual(above, base + slack0 * 0.6,
            "the live-budget feedback loop stalls near HALF the slack")
        XCTAssertGreaterThanOrEqual(above, base + slack0 * 0.4)
    }

    func test_session_belowBoundary_growsAgainstOriginSlack_andClamps() {
        let session = DividerDragSession(baseAbove: nil, baseBelow: 200, slack: 150)
        // Drag UP (negative delta) grows the below panel from the flex.
        XCTAssertEqual(session.belowTarget(delta: -100)!, 300)
        XCTAssertEqual(session.belowTarget(delta: -400)!, 350,
            "growth clamps at base + origin slack")
        // Drag down shrinks it (the floor clamp is the view's `bounded`).
        XCTAssertEqual(session.belowTarget(delta: 50)!, 150)
    }

    func test_session_aboveOnly_isBasePlusDelta() {
        let session = DividerDragSession(baseAbove: 240, baseBelow: nil, slack: 0)
        XCTAssertEqual(session.aboveTarget(delta: 60)!, 300)
        XCTAssertNil(session.pairTargets(delta: 10), "no pair without both bases")
    }
}
