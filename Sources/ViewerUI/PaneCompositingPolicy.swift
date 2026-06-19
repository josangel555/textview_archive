import CoreGraphics

/// The per-pane compositing / visibility contract for the retained-pane content
/// `ZStack` (TSK-839 — per-nav CoreAnimation commit stall).
///
/// WHY THIS EXISTS AS A NAMED, HOST-TESTABLE TYPE
/// ----------------------------------------------
/// `ContentView.content` renders a `ZStack` of every MOUNTED tab pane (the
/// `MountedPanesLRU`, up to 4). Only the active pane is visible; the inactive
/// ones stay mounted at `opacity(0)` so switching back is a pure visibility flip
/// (no `WKWebView` teardown + reload — the perf Fix#1 invariant). The price of
/// that retention is that EVERY pane's layer subtree is a sibling in the same
/// container, so each navigation action's CoreAnimation commit can re-walk /
/// re-composite all of them.
///
/// The perf-explore trace (`docs/research/perf-latency-explore-2026-06-14/
/// app-latency.md` finding #2) measured the result: every nav action triggers a
/// 30–366 ms main-thread CA commit stall (43 stalls / 3.35 s over a 17 s sweep),
/// while the model call itself is ≤12 ms. The retained panes each host an
/// opaque, layer-backed `NSViewRepresentable` (rendered-markdown / CodeMirror
/// WebView), exactly the surface the LESSONS / CLAUDE.md compositor rule
/// (TSK-488) is about: an unisolated opaque sibling forces the compositor to
/// reconcile it against its neighbours on each commit.
///
/// The fix this contract drives: give EACH pane its own compositing group so a
/// sibling pane's (or the surrounding chrome's) re-layout cannot pull every
/// pane's layer into the same commit reconciliation — isolating each pane's
/// cached layer tree so an inactive pane contributes a cheap composited bitmap,
/// not a fresh layer walk, per nav commit.
///
/// WHAT THE HOST CAN AND CAN'T PROVE
/// --------------------------------
/// The actual CA-commit cost reduction is a WindowServer-stage-④ measurement —
/// the host cannot see CoreAnimation commit time (CLAUDE.md: `ImageRenderer` /
/// `cacheDisplay` are FALSE GREEN for this class; only a VM Time-Profiler trace
/// under a stall window is authoritative). So this type does NOT claim to prove
/// the stall shrank. What it PINS on the host is the per-pane compositing
/// DECISION — the same regression-detectable-logic strategy as
/// `SideDockCompositing`: `ContentView` drives the pane's `.opacity`,
/// `.allowsHitTesting`, `.accessibilityHidden`, `.zIndex` and the
/// compositing-isolation flag from this one contract, so a future edit that
/// drops the isolation, makes an inactive pane hit-testable, or collapses the
/// active/inactive z onto the same layer fails on the host gate even though the
/// pixel/commit proof stays VM-only. The VM win is re-traced via
/// `scripts/vm-profile.sh <file> 22 nav release` (before/after stall totals).
enum PaneCompositingPolicy {

    /// The active (front, visible, interactive) pane's z layer. Strictly above
    /// every inactive pane so it is never occluded by a retained sibling.
    static let activeZIndex: Double = 1

    /// The inactive (retained-but-hidden) panes' z layer. Below the active pane.
    static let inactiveZIndex: Double = 0

    /// The fully-resolved render attributes for ONE mounted pane, given whether
    /// it is the currently-active pane. `ContentView` applies each field to the
    /// corresponding SwiftUI modifier so the whole decision is one tested call.
    struct PaneRender: Equatable {
        /// `1` for the active pane, `0` for retained-but-hidden panes. NOTE we
        /// use opacity 0 (NOT `.hidden()` / removal): keeping the inactive
        /// `WKWebView` nominally "visible" to WebKit stops it firing
        /// `visibilitychange` and self-reloading — the perf Fix#1 invariant.
        let opacity: Double
        /// Only the active pane takes hit-testing; inactive retained panes must
        /// not intercept events or fight for first-responder focus.
        let hitTesting: Bool
        /// Inactive panes are hidden from accessibility (a hidden pane is not a
        /// navigable element).
        let accessibilityHidden: Bool
        /// The pane's z layer (see `activeZIndex` / `inactiveZIndex`).
        let zIndex: Double
        /// Whether the pane gets its OWN compositing group. ALWAYS true — every
        /// retained pane is layer-isolated so a sibling/chrome re-layout cannot
        /// fold every pane's opaque-representable subtree into one CA commit
        /// reconciliation (TSK-839). Pinned as a field (rather than implied) so
        /// a regression that drops `.compositingGroup()` from a pane fails the
        /// host contract test.
        let isolatesCompositing: Bool
    }

    /// Resolve the render attributes for a pane. `isActive` is the only input:
    /// the active pane is visible/interactive/front, inactive panes are
    /// retained-but-hidden/below. Both are compositing-isolated.
    static func render(isActive: Bool) -> PaneRender {
        PaneRender(
            opacity: isActive ? 1 : 0,
            hitTesting: isActive,
            accessibilityHidden: !isActive,
            zIndex: isActive ? activeZIndex : inactiveZIndex,
            isolatesCompositing: true
        )
    }

    /// The invariant the ZStack relies on: the active pane composites strictly
    /// ABOVE any inactive retained pane. Pinned by the host test; if this is
    /// ever false a retained inactive pane could occlude the visible one.
    static var activeIsAboveInactive: Bool {
        activeZIndex > inactiveZIndex
    }
}
