import CoreGraphics
import XCTest
@testable import ViewerCore

final class DependencyGraphLayoutTests: XCTestCase {

    private func graph(nodeCount: Int, edges: [(Int, Int)] = []) -> DependencyGraph.Graph {
        let nodes = (0..<nodeCount).map {
            DependencyGraph.Node(id: "n\($0)", label: "n\($0)", kind: .file)
        }
        let e = edges.map { DependencyGraph.Edge(from: "n\($0.0)", to: "n\($0.1)") }
        return DependencyGraph.Graph(nodes: nodes, edges: e)
    }

    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

    // MARK: - circle

    func test_circle_empty_graph() {
        XCTAssertTrue(DependencyGraphLayout.circle(graph(nodeCount: 0), in: bounds).isEmpty)
    }

    func test_circle_single_node_centered() {
        let pos = DependencyGraphLayout.circle(graph(nodeCount: 1), in: bounds)
        XCTAssertEqual(pos.count, 1)
        XCTAssertEqual(pos[0].point.x, bounds.midX, accuracy: 0.001)
        XCTAssertEqual(pos[0].point.y, bounds.midY, accuracy: 0.001)
    }

    func test_circle_positions_within_bounds_and_one_per_node() {
        let g = graph(nodeCount: 8)
        let pos = DependencyGraphLayout.circle(g, in: bounds)
        XCTAssertEqual(pos.count, 8)
        XCTAssertEqual(Set(pos.map(\.id)), Set(g.nodes.map(\.id)))
        for p in pos {
            XCTAssertGreaterThanOrEqual(p.point.x, bounds.minX)
            XCTAssertLessThanOrEqual(p.point.x, bounds.maxX)
            XCTAssertGreaterThanOrEqual(p.point.y, bounds.minY)
            XCTAssertLessThanOrEqual(p.point.y, bounds.maxY)
        }
    }

    func test_circle_nodes_are_distinct_points() {
        let pos = DependencyGraphLayout.circle(graph(nodeCount: 6), in: bounds)
        let uniquePoints = Set(pos.map { "\($0.point.x.rounded())|\($0.point.y.rounded())" })
        XCTAssertEqual(uniquePoints.count, 6, "ring nodes should not coincide")
    }

    // MARK: - forceDirected

    func test_forceDirected_deterministic() {
        let g = graph(nodeCount: 7, edges: [(0, 1), (1, 2), (2, 3), (3, 0), (0, 4), (4, 5), (5, 6)])
        let a = DependencyGraphLayout.forceDirected(g, in: bounds)
        let b = DependencyGraphLayout.forceDirected(g, in: bounds)
        XCTAssertEqual(a.count, b.count)
        for (pa, pb) in zip(a, b) {
            XCTAssertEqual(pa.id, pb.id)
            XCTAssertEqual(pa.point.x, pb.point.x, accuracy: 1e-9)
            XCTAssertEqual(pa.point.y, pb.point.y, accuracy: 1e-9)
        }
    }

    func test_forceDirected_stays_in_bounds() {
        let g = graph(nodeCount: 10, edges: [(0, 1), (0, 2), (0, 3), (0, 4), (0, 5)])
        let pos = DependencyGraphLayout.forceDirected(g, in: bounds)
        for p in pos {
            XCTAssertGreaterThanOrEqual(p.point.x, bounds.minX)
            XCTAssertLessThanOrEqual(p.point.x, bounds.maxX)
            XCTAssertGreaterThanOrEqual(p.point.y, bounds.minY)
            XCTAssertLessThanOrEqual(p.point.y, bounds.maxY)
            XCTAssertTrue(p.point.x.isFinite)
            XCTAssertTrue(p.point.y.isFinite)
        }
    }

    func test_forceDirected_covers_every_node_once() {
        let g = graph(nodeCount: 5, edges: [(0, 1), (1, 2)])
        let pos = DependencyGraphLayout.forceDirected(g, in: bounds)
        XCTAssertEqual(Set(pos.map(\.id)), Set(g.nodes.map(\.id)))
        XCTAssertEqual(pos.count, 5)
    }

    func test_forceDirected_single_node_is_circle_result() {
        let pos = DependencyGraphLayout.forceDirected(graph(nodeCount: 1), in: bounds)
        XCTAssertEqual(pos.count, 1)
        XCTAssertEqual(pos[0].point.x, bounds.midX, accuracy: 0.001)
    }

    func test_forceDirected_ignores_edges_to_missing_nodes() {
        // Edge references a node id not in the layout — must not crash/throw.
        let g = DependencyGraph.Graph(
            nodes: [
                DependencyGraph.Node(id: "a", label: "a", kind: .file),
                DependencyGraph.Node(id: "b", label: "b", kind: .file),
            ],
            edges: [DependencyGraph.Edge(from: "a", to: "ghost")])
        let pos = DependencyGraphLayout.forceDirected(g, in: bounds)
        XCTAssertEqual(pos.count, 2)
    }
}
