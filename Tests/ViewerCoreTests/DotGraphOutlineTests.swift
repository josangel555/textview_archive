import XCTest
@testable import ViewerCore

/// TSK-508 — the no-dep DOT outline model (adjacency, roots, cycle-guarded tree).
final class DotGraphOutlineTests: XCTestCase {

    private func graph(_ src: String) -> DotGraph {
        DotGraphParser.parse(src)!
    }

    func test_adjacency_dedupedInEdgeOrder() {
        let g = graph("digraph { a -> b; a -> c; a -> b; }")
        let adj = DotGraphOutline.adjacency(g)
        XCTAssertEqual(adj["a"], ["b", "c"], "deduped, edge order preserved")
        XCTAssertEqual(adj["b"], [])
        XCTAssertEqual(adj["c"], [])
    }

    func test_inDegree_andRoots() {
        let g = graph("digraph { a -> b; b -> c; }")
        XCTAssertEqual(DotGraphOutline.inDegree(g), ["a": 0, "b": 1, "c": 1])
        XCTAssertEqual(DotGraphOutline.roots(g), ["a"], "the in-degree-0 source is the root")
    }

    func test_roots_multipleSourcesSorted() {
        let g = graph("digraph { z -> m; a -> m; }")
        XCTAssertEqual(DotGraphOutline.roots(g), ["a", "z"], "sources sorted for a stable sidebar")
    }

    func test_roots_fullyCyclic_fallsBackToSingleDeterministicRoot() {
        let g = graph("digraph { a -> b; b -> a; }")
        // No in-degree-0 node → one root (first sorted) so the outline shows
        // the component ONCE, not one tree per node.
        XCTAssertEqual(DotGraphOutline.roots(g), ["a"])
    }

    func test_outline_treeOfADAG() {
        let g = graph("digraph { a -> b; a -> c; b -> d; c -> d; }")
        let rows = DotGraphOutline.outline(g)
        // a(0) → b(1) → d(2), c(1) → d(2). d appears under both parents (tree view).
        XCTAssertEqual(rows.map(\.id), ["a", "b", "d", "c", "d"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 1, 2])
        XCTAssertTrue(rows.allSatisfy { !$0.isCycle })
    }

    func test_outline_cycleGuard() {
        let g = graph("digraph { a -> b; b -> c; c -> a; }")
        let rows = DotGraphOutline.outline(g)
        // a → b → c → (a: cycle, not re-expanded).
        XCTAssertEqual(rows.map(\.id), ["a", "b", "c", "a"])
        XCTAssertEqual(rows.last?.isCycle, true)
        XCTAssertEqual(rows.filter { !$0.isCycle }.count, 3, "each node expanded once")
    }

    func test_outline_isBounded() {
        // A self-loop can't blow up; the cycle guard + cap hold.
        let g = graph("digraph { a -> a; }")
        let rows = DotGraphOutline.outline(g, maxRows: 100)
        XCTAssertEqual(rows.map(\.id), ["a", "a"])
        XCTAssertEqual(rows.last?.isCycle, true)
    }

    func test_isolatedNode_appearsAsItsOwnRoot() {
        let g = graph("digraph { solo; a -> b; }")
        XCTAssertTrue(DotGraphOutline.roots(g).contains("solo"))
        XCTAssertEqual(DotGraphOutline.adjacency(g)["solo"], [])
    }
}
