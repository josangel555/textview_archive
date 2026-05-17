import XCTest
@testable import ViewerCore

final class GraphLayoutTests: XCTestCase {

    private func commit(_ sha: String, parents: [String] = []) -> GitClient.GraphCommit {
        GitClient.GraphCommit(
            sha: sha, parents: parents, author: "t", timestamp: 0,
            subject: sha, refs: [], filesChanged: 0, insertions: 0, deletions: 0
        )
    }

    func test_empty_input() {
        let lay = GraphLayout.layout([])
        XCTAssertEqual(lay?.rows, [])
        XCTAssertEqual(lay?.maxLane, 0)
    }

    func test_single_commit() {
        let lay = GraphLayout.layout([commit("a")])!
        XCTAssertEqual(lay.rows.count, 1)
        XCTAssertEqual(lay.rows[0].lane, 0)
        XCTAssertEqual(lay.rows[0].lanesAfter, [])
    }

    func test_linear_chain() {
        // a → b → c   (a is newest; topo order is newest-first)
        let lay = GraphLayout.layout([
            commit("a", parents: ["b"]),
            commit("b", parents: ["c"]),
            commit("c"),
        ])!
        XCTAssertEqual(lay.maxLane, 0)
        XCTAssertEqual(lay.rows.map(\.lane), [0, 0, 0])
        // First-parent inheritance keeps the same lane for the chain.
        XCTAssertEqual(lay.rows[0].lanesAfter, ["b"])
        XCTAssertEqual(lay.rows[1].lanesAfter, ["c"])
        XCTAssertEqual(lay.rows[2].lanesAfter, [])
    }

    func test_merge_creates_second_lane() {
        // m has two parents: x (kept on main lane) and y (new lane)
        let lay = GraphLayout.layout([
            commit("m", parents: ["x", "y"]),
            commit("y"),
            commit("x"),
        ])!
        XCTAssertGreaterThanOrEqual(lay.maxLane, 1)
        XCTAssertEqual(lay.rows[0].lane, 0)
        // After processing the merge, lane 0 = x, lane 1 = y
        XCTAssertEqual(lay.rows[0].lanesAfter, ["x", "y"])
        // y is on lane 1 when it appears
        XCTAssertEqual(lay.rows[1].lane, 1)
        // x is on lane 0 when it appears
        XCTAssertEqual(lay.rows[2].lane, 0)
    }

    func test_caps_at_max_lanes() {
        // Fan-out merge: one commit with 6 parents forces 6 concurrent
        // lanes (first parent inherits my lane; 5 more spawn). With
        // maxLanes=4 the layout must refuse.
        let fanOut = commit("m", parents: ["p1","p2","p3","p4","p5","p6"])
        let roots = (1...6).map { commit("p\($0)") }
        XCTAssertNil(GraphLayout.layout([fanOut] + roots, maxLanes: 4))
        // …but with maxLanes=8 it should succeed.
        XCTAssertNotNil(GraphLayout.layout([fanOut] + roots, maxLanes: 8))
    }

    func test_branch_then_rejoin_pattern() {
        // a → m → … where m has two parents that both eventually point
        // to the same root r.
        //   a (parent m)
        //   m (parents s, r)
        //   s (parent r)
        //   r
        let lay = GraphLayout.layout([
            commit("a", parents: ["m"]),
            commit("m", parents: ["s", "r"]),
            commit("s", parents: ["r"]),
            commit("r"),
        ])!
        XCTAssertEqual(lay.rows.count, 4)
        XCTAssertGreaterThanOrEqual(lay.maxLane, 1)
        // r was reserved on lane 1 by m's second parent slot. Once s
        // closes (lane 0 frees), r stays on lane 1 — the algorithm
        // doesn't shuffle existing assignments. That's correct + stable.
        XCTAssertEqual(lay.rows[3].lane, 1)
    }

    func test_lanes_compact_trailing_nils() {
        // When a side branch ends, its lane should be reclaimable by a
        // later commit (we verify by checking that maxLane stays small).
        let lay = GraphLayout.layout([
            commit("a", parents: ["b", "c"]),
            commit("c"),       // closes lane 1
            commit("b"),       // closes lane 0
            commit("z"),       // fresh root — should reuse lane 0
        ])!
        XCTAssertEqual(lay.rows[3].lane, 0)
    }
}
