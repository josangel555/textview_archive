import Foundation

/// The dependency-graph algorithms over a set of ``WorkItemModel/Item`` —
/// distinct algorithms over distinct edge sets (§2.4 of
/// `docs/PROJECT_MANAGEMENT_DESIGN_v2.md`):
///
///   - `dependsOn` (ORDERING) and `parent` (CONTAINMENT) are acyclic DAGs; the
///     store must *reject* a cycle transactionally rather than silently write
///     one, so cycle detection is a first-class operation here.
///   - `consumes` (DATA) is the reverse-ripple edge: when an upstream's output
///     changes, every transitive downstream that consumed it must have its
///     "done" invalidated (§1.7).
///   - `touches` (CONCURRENCY) is undirected contention used by the queue.
public enum WorkItemGraph {

    public typealias Item = WorkItemModel.Item

    /// Why a graph mutation was rejected.
    public enum GraphError: Equatable, Sendable {
        /// Adding/keeping this edge would create a cycle in the named edge set.
        case wouldCreateCycle(edge: WorkItemModel.EdgeKind, path: [String])
        /// An edge references an id not present in the item set.
        case danglingReference(id: String)
        /// A self-edge (id depends on / contains itself).
        case selfReference(id: String)
    }

    // MARK: - Cycle detection (depends_on + parent are acyclic)

    /// Detect a cycle in the directed edge set selected by `select` (each item's
    /// outgoing edges). Returns the offending cycle path if one exists, else nil.
    /// Pure DFS with a recursion stack; O(V+E).
    public static func cycle(
        in items: [Item],
        select: (Item) -> [String]
    ) -> [String]? {
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var color: [String: Int] = [:] // 0=white,1=gray,2=black
        var stack: [String] = []

        func dfs(_ id: String) -> [String]? {
            color[id] = 1
            stack.append(id)
            if let item = byId[id] {
                for next in select(item) {
                    // Ignore dangling refs here; validate() reports those separately.
                    guard byId[next] != nil else { continue }
                    switch color[next] ?? 0 {
                    case 0:
                        if let found = dfs(next) { return found }
                    case 1:
                        // Back-edge: extract the cycle from the recursion stack.
                        if let start = stack.firstIndex(of: next) {
                            return Array(stack[start...]) + [next]
                        }
                        return [next]
                    default:
                        break
                    }
                }
            }
            stack.removeLast()
            color[id] = 2
            return nil
        }

        for item in items where (color[item.id] ?? 0) == 0 {
            if let found = dfs(item.id) { return found }
        }
        return nil
    }

    /// Validate the whole graph: no self-references, no dangling references in
    /// any directed edge set, and no cycle in `dependsOn` or `parent`. Returns
    /// the first error found, or `nil` if the graph is well-formed.
    public static func validate(_ items: [Item]) -> GraphError? {
        let ids = Set(items.map(\.id))

        for item in items {
            // Self-reference.
            if item.dependsOn.contains(item.id) || item.consumes.contains(item.id)
                || item.touches.contains(item.id) || item.parent == item.id {
                return .selfReference(id: item.id)
            }
            // Dangling references across every edge set.
            for ref in item.dependsOn + item.consumes + item.touches {
                if !ids.contains(ref) { return .danglingReference(id: ref) }
            }
            if let p = item.parent, !ids.contains(p) {
                return .danglingReference(id: p)
            }
        }

        if let path = cycle(in: items, select: { $0.dependsOn }) {
            return .wouldCreateCycle(edge: .dependsOn, path: path)
        }
        if let path = cycle(in: items, select: { $0.parent.map { [$0] } ?? [] }) {
            return .wouldCreateCycle(edge: .parent, path: path)
        }
        return nil
    }

    // MARK: - Reverse-ripple invalidation (§1.7)

    /// Given that `changedIds` upstream outputs changed, return the ids of every
    /// item that should move to `assumptionsInvalidated`: the transitive set of
    /// items reachable by following `consumes` edges *backwards* (a downstream
    /// consumes an upstream, so a change ripples down to consumers), restricted
    /// to those currently in `verifiedDone` (only a verified-done item can be
    /// invalidated). The changed items themselves are not included.
    public static func invalidatedDownstream(
        of changedIds: Set<String>,
        in items: [Item]
    ) -> Set<String> {
        // Build upstream -> [consumers] adjacency (reverse of the consumes edge).
        var consumers: [String: [String]] = [:]
        for item in items {
            for upstream in item.consumes {
                consumers[upstream, default: []].append(item.id)
            }
        }
        let stateById = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.state) })

        var result: Set<String> = []
        var frontier = Array(changedIds)
        while let current = frontier.popLast() {
            for consumer in consumers[current] ?? [] where !result.contains(consumer) {
                // Only verified-done work can be invalidated; a still-open
                // consumer will re-read fresh inputs anyway.
                if stateById[consumer] == .verifiedDone {
                    result.insert(consumer)
                }
                // Ripple continues regardless: a consumer's *own* output may be
                // consumed further downstream even if the consumer isn't itself
                // verified-done yet.
                frontier.append(consumer)
            }
        }
        // Never invalidate the changed items themselves.
        return result.subtracting(changedIds)
    }
}
