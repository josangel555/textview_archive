import Foundation

/// TSK-508 phase-2 (no-dep first cut) — turn a parsed `DotGraph` into a
/// sidebar-ready OUTLINE: adjacency, in/out degrees, roots, and a
/// cycle-guarded outline tree. This is the dependency-FREE structure the
/// recommended outline view consumes (a real graphical node-link LAYOUT
/// needs a layout-engine dep = the owner-gated part; this needs none). Pure
/// + host-tested; the SwiftUI sidebar list is the render tail.
public enum DotGraphOutline {

    /// Adjacency: node id → its outgoing-neighbor ids, in first-seen edge
    /// order (deduped). Isolated nodes map to `[]`.
    public static func adjacency(_ g: DotGraph) -> [String: [String]] {
        var adj: [String: [String]] = [:]
        for node in g.nodes { adj[node] = [] }
        for edge in g.edges {
            adj[edge.from, default: []].append(edge.to)
            if adj[edge.to] == nil { adj[edge.to] = [] }   // an edge can name a node not in `nodes`
        }
        // Dedup while preserving order.
        for (k, v) in adj {
            var seen = Set<String>()
            adj[k] = v.filter { seen.insert($0).inserted }
        }
        return adj
    }

    /// In-degree per node (how many edges point AT it). A directed graph's
    /// roots are the in-degree-0 nodes.
    public static func inDegree(_ g: DotGraph) -> [String: Int] {
        var deg: [String: Int] = [:]
        for node in g.nodes { deg[node] = 0 }
        for edge in g.edges {
            deg[edge.to, default: 0] += 1
            if deg[edge.from] == nil { deg[edge.from] = 0 }
        }
        return deg
    }

    /// The natural outline top level: nodes with in-degree 0 (sources),
    /// sorted for a stable sidebar. If EVERY node has an incoming edge (a
    /// fully-cyclic graph with no source), fall back to a SINGLE
    /// deterministic root (the first sorted node) so the outline is never
    /// empty and a cyclic graph shows ONCE (not one tree per node) — the
    /// cycle guard then walks the whole component from there.
    public static func roots(_ g: DotGraph) -> [String] {
        let deg = inDegree(g)
        let sources = deg.filter { $0.value == 0 }.keys.sorted()
        if !sources.isEmpty { return sources }
        return deg.keys.sorted().first.map { [$0] } ?? []
    }

    /// One outline row: a node at a depth, flagged if it's a back-reference
    /// to an ancestor (a cycle — shown but not re-expanded).
    public struct Row: Equatable, Sendable {
        public let id: String
        public let depth: Int
        public let isCycle: Bool
        public init(id: String, depth: Int, isCycle: Bool) {
            self.id = id
            self.depth = depth
            self.isCycle = isCycle
        }
    }

    /// A flattened, cycle-guarded outline (DFS from each root). A node
    /// revisited on the CURRENT path is emitted once as `isCycle` and not
    /// re-expanded (so a cyclic graph never loops); a node reachable by more
    /// than one path appears under each parent (a tree view of a DAG).
    public static func outline(_ g: DotGraph, maxRows: Int = 10_000) -> [Row] {
        let adj = adjacency(g)
        var rows: [Row] = []
        func visit(_ id: String, depth: Int, path: Set<String>) {
            if rows.count >= maxRows { return }
            if path.contains(id) {
                rows.append(Row(id: id, depth: depth, isCycle: true))
                return
            }
            rows.append(Row(id: id, depth: depth, isCycle: false))
            var nextPath = path
            nextPath.insert(id)
            for child in adj[id] ?? [] {
                visit(child, depth: depth + 1, path: nextPath)
            }
        }
        for root in roots(g) {
            visit(root, depth: 0, path: [])
        }
        return rows
    }
}
