import XCTest
import SwiftUI
import ViewerCore
@testable import ViewerUI

/// TSK-1177 — the terminal tab strip's shoulder-border edge follows the strip
/// position: the OUTER edge facing the content (top strip → top, left column →
/// leading, right column → trailing), never the surface-facing edge (which
/// already carries a Divider — a border there would be redundant). Pure host
/// test of the placement decision; the on-screen pixel is the T5/owner tail.
final class TerminalTabShoulderEdgeTests: XCTestCase {
    func test_shoulderEdge_isTheOuterEdge_perPosition() {
        XCTAssertEqual(terminalTabShoulderEdge(for: .top), .top,
                       "a top strip's shoulder is its top edge")
        XCTAssertEqual(terminalTabShoulderEdge(for: .left), .leading,
                       "a left column's shoulder is its leading edge (away from the surface)")
        XCTAssertEqual(terminalTabShoulderEdge(for: .right), .trailing,
                       "a right column's shoulder is its trailing edge (away from the surface)")
    }
}
