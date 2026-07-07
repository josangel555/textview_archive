import XCTest
@testable import ViewerCore

/// TSK-1123 — the terminal↔panel edge bridge (bijective, round-trip stable).
final class TerminalPanelEdgeBridgeTests: XCTestCase {

    func test_terminalToPanel_mapsEachEdge() {
        XCTAssertEqual(TerminalPanelEdgeBridge.panelEdge(for: .bottom), .bottom)
        XCTAssertEqual(TerminalPanelEdgeBridge.panelEdge(for: .left), .left)
        XCTAssertEqual(TerminalPanelEdgeBridge.panelEdge(for: .right), .right)
    }

    func test_panelToTerminal_mapsEachEdge() {
        XCTAssertEqual(TerminalPanelEdgeBridge.terminalEdge(for: .bottom), .bottom)
        XCTAssertEqual(TerminalPanelEdgeBridge.terminalEdge(for: .left), .left)
        XCTAssertEqual(TerminalPanelEdgeBridge.terminalEdge(for: .right), .right)
    }

    func test_roundTrip_terminalEdge_stableBothWays() {
        // Every TerminalPaneEdge survives terminal→panel→terminal.
        for t in TerminalPaneEdge.allCases {
            XCTAssertEqual(
                TerminalPanelEdgeBridge.terminalEdge(
                    for: TerminalPanelEdgeBridge.panelEdge(for: t)),
                t, "round-trip lost \(t)")
        }
        // And every PanelEdge survives panel→terminal→panel (total, no case
        // the terminal lacks).
        for p in PanelEdge.allCases {
            XCTAssertEqual(
                TerminalPanelEdgeBridge.panelEdge(
                    for: TerminalPanelEdgeBridge.terminalEdge(for: p)),
                p, "round-trip lost \(p)")
        }
    }

    func test_bothEnums_coverTheSameEdgeSet() {
        // The bijection is only valid because neither enum has an edge the
        // other lacks — a guard so adding a case (e.g. terminal `.top`)
        // fails here loudly instead of silently mis-mapping.
        XCTAssertEqual(Set(TerminalPaneEdge.allCases.map(\.rawValue)),
                       Set(PanelEdge.allCases.map(\.rawValue)),
                       "edge sets diverged — the bridge must be updated")
    }
}
