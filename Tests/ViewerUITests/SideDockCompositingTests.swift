import XCTest
import ViewerCore
@testable import ViewerUI

/// Host guard for the side-docked terminal compositing z-order (TSK-960 —
/// regression of TSK-491: the right-docked terminal stopped compositing in its
/// column because `sideTerminalColumn` shared the outer `HStack` with the
/// opaque content WebView and had NO `.compositingGroup().zIndex(...)`
/// ordering, so the later-painted opaque surface occluded the other).
///
/// WHAT THIS TIER CAN AND CAN'T PROVE
/// ----------------------------------
/// The actual on-screen composite (chip in the right column + center content
/// NOT blank) is the VM T5 guard `TerminalTabStripVisualRegressionTests`
/// (`test_rightDockedPane_terminalComposites_andContentNotBlank`, scene
/// `terminal-paneright`). `ImageRenderer` is a documented FALSE GREEN for this
/// occlusion class (it never instantiates the opaque AppKit layer), so the host
/// cannot prove the pixels reached the screen. What the host PINS is:
///   1. the compositing-order CONTRACT (`SideDockCompositing`) — the terminal
///      column's layer must sit strictly ABOVE the content column. `ContentView`
///      drives both `.zIndex(...)` modifiers from these constants, so flipping
///      the order or collapsing them onto the same z fails here.
///   2. the MODEL wiring `sideTerminalColumn` is gated on — that a right-docked,
///      open pane is the state the column renders for, sized by `sideWidth`.
/// Together these make the logic regression-detectable on the host even though
/// the pixel proof is VM-only (CLAUDE.md change→tests mandate, rule 6).
final class SideDockCompositingTests: XCTestCase {

    // MARK: - z-order contract (TSK-960)

    func test_terminalColumnComposites_strictlyAbove_contentColumn() {
        // The whole fix: the terminal column's own compositing layer is ordered
        // ABOVE the content surface so neither opaque NSViewRepresentable
        // occludes the other regardless of HStack paint order.
        XCTAssertGreaterThan(
            SideDockCompositing.terminalColumnZIndex,
            SideDockCompositing.contentColumnZIndex,
            "terminal side column must composite ABOVE the content column " +
            "(TSK-960) — equal/inverted z lets the opaque WebView occlude the " +
            "terminal surface in the right-dock branch")
        XCTAssertTrue(SideDockCompositing.terminalIsAboveContent)
    }

    func test_zIndices_areDistinct_noLayerCollision() {
        // Two opaque representables on the SAME z composite by paint order — the
        // exact ambiguity the fix removes. Guard against a future edit that
        // accidentally sets both to the same value.
        XCTAssertNotEqual(
            SideDockCompositing.terminalColumnZIndex,
            SideDockCompositing.contentColumnZIndex,
            "the two opaque columns must be on DISTINCT z layers (TSK-960)")
    }

    func test_contentColumn_isBaseLayer() {
        // The center content column is the base layer (zIndex 0); the side
        // additions order above it. Documents the intended baseline so the
        // contract reads unambiguously.
        XCTAssertEqual(SideDockCompositing.contentColumnZIndex, 0,
            "the center content column is the base compositing layer")
    }

    // MARK: - model wiring the column is gated on (paneEdge == .right)

    @MainActor
    func test_rightDockedOpenPane_isTheStateTheColumnRendersFor() {
        let suite = "SideDockCompositing-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = TerminalPaneStore(defaults: defaults)
        defer { store.shutdown() }

        store.setOpen(true)
        store.setPaneEdge(.right)

        // `ContentView` renders `sideTerminalColumn` only when
        // `terminalPane.isOpen && terminalPane.paneEdge == .right` (the
        // line-214 call site). Pin that gate so a model regression that drops
        // the right-dock state is caught on the host.
        XCTAssertTrue(store.isOpen)
        XCTAssertEqual(store.paneEdge, .right)

        // The column is FIXED-WIDTH via `sideWidth` (`.frame(width:)`), so it
        // never claims the flex axis from the content column. A clamped,
        // positive width is the invariant the layout depends on.
        XCTAssertGreaterThan(store.sideWidth, 0,
            "the side column must have a positive fixed width to reserve its " +
            "column (TSK-491)")
        XCTAssertEqual(store.sideWidth, TerminalPaneLayout.clampWidth(store.sideWidth),
            "sideWidth must already be clamped into [minWidth, maxWidth]")
    }

    @MainActor
    func test_paneEdge_leftAndRight_bothDriveTheSideColumn() {
        // The fix applies in BOTH side-dock branches (the single
        // `sideTerminalColumn` helper is used for left AND right). Pin that both
        // edges are reachable model states distinct from the bottom dock.
        let suite = "SideDockCompositing-edges-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = TerminalPaneStore(defaults: defaults)
        defer { store.shutdown() }
        store.setOpen(true)

        store.setPaneEdge(.left)
        XCTAssertEqual(store.paneEdge, .left)

        store.setPaneEdge(.right)
        XCTAssertEqual(store.paneEdge, .right)

        store.setPaneEdge(.bottom)
        XCTAssertEqual(store.paneEdge, .bottom,
            "bottom dock is the non-side branch (no side column)")
    }
}
