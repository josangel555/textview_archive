import XCTest
import ViewerCore
@testable import ViewerUI

/// Host guard for the retained-pane compositing/visibility contract
/// (`PaneCompositingPolicy`, TSK-839 — per-nav CoreAnimation commit stall).
///
/// WHAT THIS TIER CAN AND CAN'T PROVE
/// ----------------------------------
/// The actual win — a shorter main-thread CA commit per nav action — is a
/// WindowServer-stage-④ measurement the host CANNOT see (CLAUDE.md: `ImageRenderer`
/// / `cacheDisplay` are FALSE GREEN for opaque-representable compositing; only a
/// VM Time-Profiler trace under a stall window is authoritative — re-capture via
/// `scripts/vm-profile.sh <file> 22 nav release`). So this suite does NOT claim
/// the stall shrank. What it PINS, exactly like `SideDockCompositingTests`, is
/// the per-pane render DECISION that `ContentView.content` drives every pane's
/// modifiers from: visibility, hit-testing, accessibility, z-order, and the
/// per-pane compositing isolation. A regression that drops `.compositingGroup()`
/// from a pane, makes an inactive pane hit-testable, or collapses the
/// active/inactive z onto one layer fails HERE on the host gate even though the
/// commit-cost proof is VM-only (CLAUDE.md change→tests mandate, rule 6).
final class PaneCompositingPolicyTests: XCTestCase {

    // MARK: - active pane

    func test_activePane_isVisible_interactive_andFront() {
        let r = PaneCompositingPolicy.render(isActive: true)
        XCTAssertEqual(r.opacity, 1, "active pane must be fully visible")
        XCTAssertTrue(r.hitTesting, "active pane must take events")
        XCTAssertFalse(r.accessibilityHidden,
                       "active pane must be accessibility-visible")
        XCTAssertEqual(r.zIndex, PaneCompositingPolicy.activeZIndex,
                       "active pane must sit on the active z layer (front)")
    }

    // MARK: - inactive (retained-but-hidden) pane

    func test_inactivePane_isHidden_nonInteractive_andBehind() {
        let r = PaneCompositingPolicy.render(isActive: false)
        // opacity 0 — NOT `.hidden()`/removed — so the retained WKWebView stays
        // nominally "visible" to WebKit and never self-reloads (perf Fix#1).
        XCTAssertEqual(r.opacity, 0,
                       "inactive retained pane must be opacity 0 (not removed) " +
                       "so its WKWebView never fires visibilitychange + reloads")
        XCTAssertFalse(r.hitTesting,
                       "inactive pane must NOT intercept events / first responder")
        XCTAssertTrue(r.accessibilityHidden,
                      "inactive pane must be hidden from accessibility")
        XCTAssertEqual(r.zIndex, PaneCompositingPolicy.inactiveZIndex,
                       "inactive pane must sit on the inactive z layer (behind)")
    }

    // MARK: - compositing isolation (the TSK-839 fix)

    func test_everyPane_isolatesCompositing() {
        // THE fix: each retained pane gets its OWN compositing group so a
        // sibling/chrome re-layout cannot fold every pane's opaque-representable
        // subtree into one CA commit reconciliation per nav action. Both the
        // active AND inactive panes must isolate — dropping it on either reopens
        // the per-nav stall (LESSONS compositor rule, TSK-488/839).
        XCTAssertTrue(PaneCompositingPolicy.render(isActive: true).isolatesCompositing,
                      "active pane must be compositing-isolated")
        XCTAssertTrue(PaneCompositingPolicy.render(isActive: false).isolatesCompositing,
                      "inactive retained pane must be compositing-isolated")
    }

    // MARK: - z-order contract

    func test_activePane_composites_strictlyAbove_inactivePanes() {
        XCTAssertGreaterThan(
            PaneCompositingPolicy.activeZIndex,
            PaneCompositingPolicy.inactiveZIndex,
            "the active pane must composite ABOVE retained inactive panes — " +
            "equal/inverted z lets a hidden retained pane occlude the visible one")
        XCTAssertTrue(PaneCompositingPolicy.activeIsAboveInactive)
    }

    func test_zIndices_areDistinct_noLayerCollision() {
        XCTAssertNotEqual(
            PaneCompositingPolicy.activeZIndex,
            PaneCompositingPolicy.inactiveZIndex,
            "active and inactive panes must be on DISTINCT z layers")
    }

    // MARK: - active vs inactive differ on every gated field

    func test_activeAndInactive_differ_onAllVisibilityFields() {
        let active = PaneCompositingPolicy.render(isActive: true)
        let inactive = PaneCompositingPolicy.render(isActive: false)
        XCTAssertNotEqual(active.opacity, inactive.opacity)
        XCTAssertNotEqual(active.hitTesting, inactive.hitTesting)
        XCTAssertNotEqual(active.accessibilityHidden, inactive.accessibilityHidden)
        XCTAssertNotEqual(active.zIndex, inactive.zIndex)
        // ...but they AGREE on compositing isolation (both isolated).
        XCTAssertEqual(active.isolatesCompositing, inactive.isolatesCompositing)
    }

    func test_render_isPure_sameInputSameOutput() {
        XCTAssertEqual(PaneCompositingPolicy.render(isActive: true),
                       PaneCompositingPolicy.render(isActive: true))
        XCTAssertEqual(PaneCompositingPolicy.render(isActive: false),
                       PaneCompositingPolicy.render(isActive: false))
    }
}
