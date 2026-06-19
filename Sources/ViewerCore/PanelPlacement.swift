import Foundation

/// Pure VALIDATE + MOVE rules for unified tool-window placement (TSK-495).
///
/// "Place ANY tool window on ANY shoulder" is the product goal — but not
/// every (panel, edge) pair is legal, and the placement engine must reject
/// the illegal ones rather than store them and let the render layer quietly
/// drop them. This type is the single, host-testable arbiter of legality:
/// every untrusted placement (drag-drop, redock menu, a future global-
/// default setting) routes its move through here so the rules live in ONE
/// place, not duplicated across the SwiftUI views.
///
/// Today the only illegal placement is "a non-dockable panel on a
/// non-`.left` edge" (the FILES tree, which is the accordion's flex-fill
/// panel and has no fixed-size tool-window form — see
/// `SidebarPanelKind.isDockable`). Encoding it as a reason ENUM rather than
/// a bare bool keeps the door open for future rules (e.g. a per-edge
/// capacity cap, mutually-exclusive panels) without churning call sites.
///
/// Pure-logic, `Sendable`, no SwiftUI / AppKit — host-testable in isolation
/// (`PanelPlacementTests`).
public enum PanelPlacement {

    /// Why a requested placement is illegal. `.ok` means "legal — apply
    /// it"; everything else names the rule that rejected it (for a future
    /// affordance: greying a redock menu item, a "can't dock Files" toast).
    public enum Result: Equatable, Sendable {
        /// The placement is legal and should be applied.
        case ok
        /// The panel cannot live on a non-`.left` shoulder (it has no
        /// free-standing tool-window form — e.g. the FILES tree).
        case notDockable
    }

    /// Validate placing `panel` on `edge` WITHOUT mutating anything.
    ///
    /// Rules (in evaluation order):
    ///   1. `.left` is always legal — every panel can live in the classic
    ///      accordion, including non-dockable ones (that's their home).
    ///   2. A non-`.left` edge requires `panel.isDockable`; otherwise
    ///      `.notDockable`.
    public static func validate(_ panel: SidebarPanelKind, to edge: PanelEdge) -> Result {
        if edge == .left { return .ok }
        return panel.isDockable ? .ok : .notDockable
    }

    /// Convenience: is this placement legal?
    public static func isLegal(_ panel: SidebarPanelKind, to edge: PanelEdge) -> Bool {
        validate(panel, to: edge) == .ok
    }

    /// Apply a placement to `assignment`, returning the (possibly
    /// unchanged) new assignment.
    ///
    /// The MOVE half of the pure engine: it validates first, and on an
    /// ILLEGAL placement returns the assignment UNCHANGED (the caller can
    /// inspect `validate` separately to surface a reason). On a legal
    /// placement it returns a copy with `panel` reassigned to `edge` — a
    /// value-in / value-out transform with no persistence side effect, so
    /// it is trivially testable and reusable from any store.
    ///
    /// Idempotent: moving a panel to the edge it already resolves to
    /// returns an equal assignment.
    public static func move(
        _ panel: SidebarPanelKind,
        to edge: PanelEdge,
        in assignment: PanelEdgeAssignment
    ) -> PanelEdgeAssignment {
        guard isLegal(panel, to: edge) else { return assignment }
        var next = assignment
        next.setEdge(panel, edge)
        return next
    }
}
