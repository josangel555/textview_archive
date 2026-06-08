import Foundation

/// Tree-narrowing for the Files pane's inline filter row (TSK-310): given the
/// file tree and a per-node match predicate, compute which nodes stay visible.
/// This is the pure traversal — the ancestor/subtree-preservation rule — kept
/// separate from *how* a node matches (the caller supplies `isMatch`, typically
/// `FuzzyMatcher.match(query, against: node.name) != nil`), so the narrowing
/// behaviour is host-testable without the live SwiftUI `FileNode` or a window.
///
/// **Visibility rule.** A node is visible when any of:
///   - it matches (`isMatch` true), or
///   - an *ancestor* matches — so a matched folder reveals its whole subtree
///     (expanding a hit isn't an empty pane), or
///   - a *descendant* matches — so the path down to every match stays on screen.
///
/// In short: matches, the subtree under each match, and the ancestor chain to
/// each match. Generic over the caller's own node type via closures; returns the
/// set of surviving node ids. The caller treats an empty query as "no filter"
/// (show everything) and simply doesn't call this.
public enum FileTreeFilter {

    /// The surviving node ids under `roots` for the given match predicate.
    ///
    /// `id` must be stable + unique per node; `children` yields a node's
    /// children (empty for leaves); `isMatch` decides whether a node matches on
    /// its own. Pure: one depth-first pass, no IO, no allocation beyond the
    /// result set + recursion stack.
    public static func visibleIDs<Node, ID: Hashable>(
        roots: [Node],
        id: (Node) -> ID,
        children: (Node) -> [Node],
        isMatch: (Node) -> Bool
    ) -> Set<ID> {
        var keep: Set<ID> = []
        for root in roots {
            _ = walk(root, ancestorMatched: false,
                     id: id, children: children, isMatch: isMatch, keep: &keep)
        }
        return keep
    }

    /// Returns whether this subtree contained a real match (so the parent knows
    /// to keep itself as an ancestor-of-match). A node is *kept* when it sits in
    /// a matched subtree (`ancestorMatched || selfMatch`) or has a matching
    /// descendant — but only a real `selfMatch`/descendant-match propagates
    /// upward, so siblings of a matched folder don't get falsely retained.
    private static func walk<Node, ID: Hashable>(
        _ node: Node,
        ancestorMatched: Bool,
        id: (Node) -> ID,
        children: (Node) -> [Node],
        isMatch: (Node) -> Bool,
        keep: inout Set<ID>
    ) -> Bool {
        let selfMatch = isMatch(node)
        let inMatchedSubtree = ancestorMatched || selfMatch

        var descendantMatch = false
        for child in children(node) {
            let childHadMatch = walk(child, ancestorMatched: inMatchedSubtree,
                                     id: id, children: children, isMatch: isMatch,
                                     keep: &keep)
            if childHadMatch { descendantMatch = true }
        }

        if inMatchedSubtree || descendantMatch {
            keep.insert(id(node))
        }
        return selfMatch || descendantMatch
    }
}
