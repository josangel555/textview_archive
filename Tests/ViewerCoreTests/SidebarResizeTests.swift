import XCTest
import CoreGraphics
@testable import ViewerCore

/// TSK-440 — the three pure cores behind the sidebar tool-window
/// resize/fill fixes. The divider's drag gesture and the on-screen
/// layout are VM-lane; these pin the math the gesture calls into
/// (exact-closure rule: `ResizableSectionDivider.apply` routes pair
/// drags into `SidebarResize.redistribute`, and `BoundedAccordionScroll`
/// frames itself with `AccordionHeightResolver.resolve`).
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

    // MARK: accordion height resolver — bug (A): the lone-FILES gap

    func test_resolver_measuredEmpty_collapsesToZero() {
        // THE bug-A case: an empty accordion used to fall back to the CAP
        // (~62% of the sidebar) because measured-0 looked like unmeasured.
        XCTAssertEqual(
            AccordionHeightResolver.resolve(contentHeight: 0, hasMeasured: true, cap: 400),
            0, "measured-empty must collapse so the lone FILES panel flex-fills")
    }

    func test_resolver_unmeasured_fallsBackToCap() {
        XCTAssertEqual(
            AccordionHeightResolver.resolve(contentHeight: 0, hasMeasured: false, cap: 400),
            400, "first pre-measurement pass keeps the legacy cap fallback")
    }

    func test_resolver_measuredFits_hugsContent() {
        XCTAssertEqual(
            AccordionHeightResolver.resolve(contentHeight: 250, hasMeasured: true, cap: 400),
            250)
    }

    func test_resolver_measuredOverCap_scrollsAtCap() {
        XCTAssertEqual(
            AccordionHeightResolver.resolve(contentHeight: 900, hasMeasured: true, cap: 400),
            400)
    }

    func test_resolver_noCap_unmeasured_isUnconstrained() {
        XCTAssertNil(
            AccordionHeightResolver.resolve(contentHeight: 0, hasMeasured: false, cap: nil))
    }
}
