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
///   2. the MODEL wiring the right dock is gated on — that a right-docked
///      terminal panel is the state `RightDockContainer` renders for, sized by
///      its `PanelDockLayout` width (2026-08-09: the terminal is a regular
///      tool window; the old `sideTerminalColumn` special case is gone).
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

    // MARK: - model wiring the right dock is gated on (2026-08-09 rework)

    @MainActor
    func test_rightDockedTerminalPanel_isTheStateTheDockRendersFor() {
        // The terminal is a regular tool window now: a right-docked terminal
        // renders inside `RightDockContainer` (which carries the TSK-960
        // compositing recipe at its ContentView call site), gated on the
        // unified panel model. Pin that gate so a model regression that drops
        // the right-dock state is caught on the host.
        let suite = "SideDockCompositing-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = PanelLayoutStore(defaults: defaults)
        store.move(.terminal, to: .right)

        XCTAssertEqual(store.edge(of: .terminal), .right)
        XCTAssertTrue(store.isVisible(.terminal, dataPresent: false),
            "a drag onto the right dock must surface the terminal panel")
        XCTAssertEqual(
            DockResolution.visiblePanels(
                on: .right, panelLayout: store,
                presence: SidebarDataPresence.evaluate(.init())),
            [.terminal])

        // The pane is FIXED-WIDTH via the dock size (`.frame(width:)`), so it
        // never claims the flex axis from the content column. A clamped,
        // positive width is the invariant the layout depends on.
        XCTAssertGreaterThan(store.dockSize(.terminal, on: .right), 0,
            "a right-docked terminal must have a positive fixed width")
    }
}
