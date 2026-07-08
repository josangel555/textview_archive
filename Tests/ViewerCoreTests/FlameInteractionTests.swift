import XCTest
import CoreGraphics
@testable import ViewerCore

/// TSK-1158 — the flame-chart interaction math over a real parsed profile.
final class FlameInteractionTests: XCTestCase {

    /// main calls a(30) and b(10); a calls hot(20). Totals: main=40.
    private var profile: FlameProfile!

    override func setUpWithError() throws {
        profile = FlameProfile.parseFolded("""
        main;a;hot 20
        main;a 10
        main;b 10
        """)
        XCTAssertEqual(profile.totalWeight, 40)
    }

    // MARK: hit-test

    func test_cellAtPoint_hitsTheTiledCell() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 100)
        let cells = FlameLayout.lay(profile, in: bounds, rowHeight: 20)
        // Depth-0 row sits at the BOTTOM (y 80..100): main spans full width.
        let hit = FlameInteraction.cell(at: CGPoint(x: 200, y: 90), cells: cells)
        XCTAssertEqual(hit?.frame.name, "main")
        // Depth-1: a spans x 0..300 (30/40), b 300..400.
        let a = FlameInteraction.cell(at: CGPoint(x: 100, y: 70), cells: cells)
        XCTAssertEqual(a?.frame.name, "a")
        let b = FlameInteraction.cell(at: CGPoint(x: 350, y: 70), cells: cells)
        XCTAssertEqual(b?.frame.name, "b")
        XCTAssertNil(FlameInteraction.cell(at: CGPoint(x: 350, y: 30), cells: cells),
                     "empty canvas above b's subtree")
    }

    // MARK: id resolve + zoom

    func test_frameWithID_pathWalk() {
        XCTAssertEqual(FlameInteraction.frame(withID: "main;a;hot", in: profile)?.total, 20)
        XCTAssertEqual(FlameInteraction.frame(withID: "main;b", in: profile)?.total, 10)
        XCTAssertNil(FlameInteraction.frame(withID: "main;ghost", in: profile))
        XCTAssertNil(FlameInteraction.frame(withID: "", in: profile))
    }

    func test_zoomed_makesFrameTheFullWidthRoot_keepsIDs() throws {
        let (zoomed, crumbs) = try XCTUnwrap(
            FlameInteraction.zoomed(to: "main;a", in: profile))
        XCTAssertEqual(crumbs, ["main", "a"])
        XCTAssertEqual(zoomed.totalWeight, 30, "the zoom root is a's subtree")
        // Laying the zoomed profile spans a across the FULL width.
        let cells = FlameLayout.lay(zoomed, in: CGRect(x: 0, y: 0, width: 400, height: 100),
                                    rowHeight: 20)
        let aCell = try XCTUnwrap(cells.first { $0.frame.name == "a" })
        XCTAssertEqual(aCell.rect.width, 400, accuracy: 0.001)
        // Ids stay root-relative — the search highlight survives the zoom.
        XCTAssertEqual(aCell.frame.id, "main;a")
        XCTAssertNotNil(FlameInteraction.frame(withID: "main;a", in: profile))
    }

    // MARK: search

    func test_matches_topmostOnly_neverDoubleCounts() {
        // "a" matches frame a (total 30) AND its child would match "hot"?
        // Use a query hitting a parent and child: search "a" hits only 'a'
        // (name contains); "main" hits the root frame.
        let (ids, total) = FlameInteraction.matches(query: "a", in: profile)
        XCTAssertTrue(ids.contains("main;a"))
        XCTAssertTrue(ids.contains("main"), "'main' contains 'a'")
        XCTAssertEqual(total, 40,
                       "main (40) is the TOPMOST match; a inside it adds NOTHING")

        let (hotIDs, hotTotal) = FlameInteraction.matches(query: "hot", in: profile)
        XCTAssertEqual(hotIDs, ["main;a;hot"])
        XCTAssertEqual(hotTotal, 20)

        let (none, zero) = FlameInteraction.matches(query: "  ", in: profile)
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(zero, 0)
    }

    // MARK: tooltip

    func test_tooltip_weightsAndShares() throws {
        let hot = try XCTUnwrap(FlameInteraction.frame(withID: "main;a;hot", in: profile))
        XCTAssertEqual(
            FlameInteraction.tooltip(for: hot, profileTotal: profile.totalWeight),
            "hot — total 20 (50.0%), self 20 (50.0%)")
    }
}
