import Foundation

/// TSK-1123 (terminal unification, model slice) — the pure, BIDIRECTIONAL
/// bridge between the terminal's own `TerminalPaneEdge` and the unified
/// `PanelEdge` that `PanelPlacement` arbitrates. The terminal predates the
/// unified tool-window placement system (its own `TerminalPaneEdge` /
/// `TerminalPaneStore`), so it doesn't participate — which is the owner's
/// literal pain ("can't get the terminal to the right" via the unified
/// Settings matrix / drag-drop). Both enums are total over {left, right,
/// bottom} — a clean bijection — so a Settings-matrix Picker can render the
/// terminal's current edge as a `PanelEdge` and route a change through the
/// same `PanelPlacement` seam every other tool window uses. The actual
/// Settings binding + the move wiring are the render tail; this is the pure,
/// host-tested seam they call.
public enum TerminalPanelEdgeBridge {

    /// The unified `PanelEdge` for a `TerminalPaneEdge` (so the terminal
    /// reads through the same arbiter as every panel).
    public static func panelEdge(for terminal: TerminalPaneEdge) -> PanelEdge {
        switch terminal {
        case .bottom: return .bottom
        case .left: return .left
        case .right: return .right
        }
    }

    /// The `TerminalPaneEdge` for a unified `PanelEdge` (so a Settings-matrix
    /// / drag-drop change lands on the terminal's own store). `PanelEdge` has
    /// no case the terminal lacks (both are {left, right, bottom}), so this
    /// is total — no lossy fallback.
    public static func terminalEdge(for panel: PanelEdge) -> TerminalPaneEdge {
        switch panel {
        case .bottom: return .bottom
        case .left: return .left
        case .right: return .right
        }
    }
}
