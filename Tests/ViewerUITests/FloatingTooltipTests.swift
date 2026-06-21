import XCTest
import Combine
import ViewerKit
@testable import ViewerUI

/// UX-H (#230) — host-safe coverage for the floating-tooltip model layer:
///   * `TooltipPresenter` republish/dedupe + token-guarded dismiss,
///   * `TooltipTiming` fast-appear / re-chain policy,
///   * `TooltipPlacement` clamp-inside-window geometry.
///
/// All three are pure logic (no NSApplication / window / WKWebView), so
/// they run in the bare headless sweep. `TooltipPresenter` imports SwiftUI
/// but, like `HelpSink`, touches no main-actor UI — it's a plain
/// `ObservableObject` + Combine publisher. Run with the class filter
/// `ViewerUITests.FloatingTooltipTests`.
@MainActor
final class FloatingTooltipTests: XCTestCase {

    private let infoA = HelpInfo(title: "Save", description: "Write to disk")
    private let infoB = HelpInfo(title: "Open", description: "Open a file")
    private let r = CGRect(x: 10, y: 10, width: 40, height: 20)

    // MARK: - Presenter: republish discipline (REPUB-1)

    private func countingPublishes(of p: TooltipPresenter,
                                   _ body: () -> Void) -> Int {
        var n = 0
        let c = p.objectWillChange.sink { _ in n += 1 }
        defer { c.cancel() }
        body()
        return n
    }

    func test_show_setsActiveAndReturnsToken() {
        let p = TooltipPresenter()
        XCTAssertNil(p.active)
        let t = p.show(infoA, anchor: r)
        XCTAssertEqual(p.active?.info, infoA)
        XCTAssertEqual(p.active?.anchor, r)
        XCTAssertEqual(p.active?.token, t)
    }

    /// Re-showing the identical (content + anchor) request must NOT
    /// republish — a hover that doesn't change the bubble is a no-op, so
    /// the overlay's fade doesn't restart and nothing re-bodies.
    func test_show_identicalRequest_doesNotRepublish() {
        let p = TooltipPresenter()
        let firstToken = p.show(infoA, anchor: r)
        let n = countingPublishes(of: p) {
            let again = p.show(infoA, anchor: r)
            XCTAssertEqual(again, firstToken,
                           "identical re-show keeps the original token")
        }
        XCTAssertEqual(n, 0, "identical re-show must not republish")
    }

    func test_show_distinctContent_republishesAndRetargets() {
        let p = TooltipPresenter()
        p.show(infoA, anchor: r)
        let n = countingPublishes(of: p) {
            p.show(infoB, anchor: r)
        }
        XCTAssertEqual(n, 1)
        XCTAssertEqual(p.active?.info, infoB)
    }

    /// Same content but a moved anchor (the helped control was scrolled /
    /// relaid out) is a distinct request — re-targets + republishes.
    func test_show_sameContentMovedAnchor_retargets() {
        let p = TooltipPresenter()
        p.show(infoA, anchor: r)
        let moved = r.offsetBy(dx: 100, dy: 0)
        p.show(infoA, anchor: moved)
        XCTAssertEqual(p.active?.anchor, moved)
    }

    // MARK: - Presenter: token-guarded dismiss

    /// A stale hover-exit (carrying the OLD token) must NOT yank a bubble
    /// the pointer already re-armed for a different control. This is the
    /// chained-toolbar case: leave A (queues dismiss for A's token) while B
    /// has already shown — B must survive.
    func test_dismiss_staleToken_doesNotClearNewerBubble() {
        let p = TooltipPresenter()
        let tokenA = p.show(infoA, anchor: r)
        let tokenB = p.show(infoB, anchor: r)   // B replaces A
        XCTAssertNotEqual(tokenA, tokenB)
        p.dismiss(token: tokenA)                // A's stale exit
        XCTAssertEqual(p.active?.info, infoB, "stale dismiss must not clear B")
        p.dismiss(token: tokenB)                // B's own exit
        XCTAssertNil(p.active)
    }

    func test_dismiss_nilForceClears() {
        let p = TooltipPresenter()
        p.show(infoA, anchor: r)
        p.dismiss(token: nil)
        XCTAssertNil(p.active)
    }

    func test_dismiss_whenAlreadyEmpty_doesNotRepublish() {
        let p = TooltipPresenter()
        let n = countingPublishes(of: p) {
            p.dismiss(token: nil)
            p.dismiss(token: 999)
        }
        XCTAssertEqual(n, 0)
    }

    func test_sharedInstance_isStableSingleton() {
        XCTAssertTrue(TooltipPresenter.shared === TooltipPresenter.shared)
    }

    // MARK: - Timing policy

    /// Cold hover uses the full (but still fast) appear delay; a hover
    /// while a bubble is already up re-chains on the much shorter delay.
    func test_timing_coldVsRechain() {
        XCTAssertEqual(TooltipTiming.delay(bubbleAlreadyVisible: false),
                       TooltipTiming.appearDelay)
        XCTAssertEqual(TooltipTiming.delay(bubbleAlreadyVisible: true),
                       TooltipTiming.rechainDelay)
        XCTAssertLessThan(TooltipTiming.rechainDelay, TooltipTiming.appearDelay)
    }

    /// The whole point of UX-H: appear MUCH faster than the macOS system
    /// default (~1.5s). Pin it well under that so a regression that
    /// restores a sluggish delay fails here.
    func test_timing_appearIsFasterThanSystemDefault() {
        XCTAssertLessThanOrEqual(TooltipTiming.appearDelay, 0.8,
                                 "still well under the macOS ~1.5s default")
        XCTAssertGreaterThan(TooltipTiming.appearDelay, 0,
                             "must be >0 so a pass-through hover doesn't flash")
    }

    /// TSK-1209 — the owner found 0.3s fired too soon (transient pass-through
    /// hovers flashed a bubble); the open delay was roughly doubled to 0.6s.
    /// Pins the value so a revert to the eager 0.3s fails here.
    func test_timing_appearDelay_isDeliberatelyRelaxed() {
        XCTAssertEqual(TooltipTiming.appearDelay, 0.6, accuracy: 0.0001)
        XCTAssertGreaterThan(TooltipTiming.appearDelay, TooltipTiming.rechainDelay)
    }

    // MARK: - Placement geometry (clamp inside the window)

    /// Default placement: centered horizontally on the anchor, just BELOW
    /// it (anchor.maxY + gap), when there's room.
    func test_placement_belowAndCentered_whenRoomy() {
        let anchor = CGRect(x: 200, y: 100, width: 40, height: 20)
        let bubble = CGSize(width: 120, height: 50)
        let container = CGSize(width: 800, height: 600)
        let o = TooltipPlacement.origin(anchor: anchor, bubbleSize: bubble,
                                        container: container)
        XCTAssertEqual(o.x, anchor.midX - bubble.width / 2, accuracy: 0.5)
        XCTAssertEqual(o.y, anchor.maxY + TooltipPlacement.gap, accuracy: 0.5)
    }

    /// An anchor near the bottom edge would overflow if the bubble sat
    /// below — placement flips it ABOVE the anchor instead.
    func test_placement_flipsAbove_nearBottomEdge() {
        let container = CGSize(width: 800, height: 600)
        let bubble = CGSize(width: 120, height: 80)
        // Anchor flush against the bottom: below wouldn't fit.
        let anchor = CGRect(x: 200, y: 560, width: 40, height: 20)
        let o = TooltipPlacement.origin(anchor: anchor, bubbleSize: bubble,
                                        container: container)
        let expectedAbove = anchor.minY - TooltipPlacement.gap - bubble.height
        XCTAssertEqual(o.y, expectedAbove, accuracy: 0.5,
                       "should flip above when below overflows")
        XCTAssertGreaterThanOrEqual(o.y, 0)
    }

    /// A bubble wider than its anchor near the LEFT edge must clamp so its
    /// left edge never goes negative (off-screen).
    func test_placement_clampsLeftEdge() {
        let container = CGSize(width: 800, height: 600)
        let bubble = CGSize(width: 200, height: 40)
        let anchor = CGRect(x: 0, y: 100, width: 30, height: 20)
        let o = TooltipPlacement.origin(anchor: anchor, bubbleSize: bubble,
                                        container: container)
        XCTAssertGreaterThanOrEqual(o.x, 0)
    }

    /// Near the RIGHT edge the bubble clamps so its right edge stays inside
    /// the container.
    func test_placement_clampsRightEdge() {
        let container = CGSize(width: 800, height: 600)
        let bubble = CGSize(width: 200, height: 40)
        let anchor = CGRect(x: 790, y: 100, width: 30, height: 20)
        let o = TooltipPlacement.origin(anchor: anchor, bubbleSize: bubble,
                                        container: container)
        XCTAssertLessThanOrEqual(o.x + bubble.width, container.width + 0.5)
    }

    /// A bubble that fits neither above nor below (a tall bubble in a short
    /// window) still produces a finite, clamped origin — never NaN / a
    /// runaway off-screen position.
    func test_placement_degenerate_staysFiniteAndClamped() {
        let container = CGSize(width: 300, height: 50)
        let bubble = CGSize(width: 120, height: 90)
        let anchor = CGRect(x: 100, y: 20, width: 40, height: 20)
        let o = TooltipPlacement.origin(anchor: anchor, bubbleSize: bubble,
                                        container: container)
        XCTAssertTrue(o.x.isFinite && o.y.isFinite)
        XCTAssertGreaterThanOrEqual(o.x, 0)
        XCTAssertGreaterThanOrEqual(o.y, 0)
    }
}
