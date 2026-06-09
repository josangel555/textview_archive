import Foundation

/// Pure, host-testable resolver for the "select multiple commits in the Git Log
/// and view their CUMULATIVE diff" feature (TSK-522). Given a set of selected
/// commits it computes the `git diff <baseRef> <tipRef>` range whose patch IS the
/// net change across the selection, and reports whether the selection is
/// contiguous — so the UI can warn when unselected commits sit between the
/// endpoints and are therefore swept into the cumulative range.
///
/// SwiftUI/AppKit-free and it performs NO git invocation — this is the
/// correctness-critical range math, pinned with tests BEFORE the
/// `GitClient.cumulativeDiff(baseRef:tipRef:)` integration and the multi-select
/// `DiffView` UI (both ticketed under TSK-522).
public enum CumulativeDiffSelection {

    /// One selected commit. `topoIndex` is its position in log order
    /// (0 = newest / HEAD-most, larger = older) as produced by
    /// `GitClient.graphLog`. `parents` are the parent SHAs (empty ⇒ a root
    /// commit with no parent).
    public struct Commit: Equatable, Sendable {
        public let sha: String
        public let topoIndex: Int
        public let parents: [String]
        public init(sha: String, topoIndex: Int, parents: [String]) {
            self.sha = sha
            self.topoIndex = topoIndex
            self.parents = parents
        }
    }

    /// The resolved `git diff baseRef tipRef` range for the cumulative patch.
    public struct Range: Equatable, Sendable {
        /// Left side of `git diff` — the (first) parent of the OLDEST selected
        /// commit, so the oldest commit's own changes are included; or the
        /// empty-tree object when the oldest is a root commit (no parent).
        public let baseRef: String
        /// Right side — the NEWEST selected commit.
        public let tipRef: String
        /// True when the selection forms an unbroken run (no unselected commit
        /// sits between the endpoints). When false, `spannedCount > selectedCount`:
        /// the cumulative diff necessarily includes the in-between commits, which
        /// the UI should surface (e.g. "includes N intermediate commits").
        public let isContiguous: Bool
        /// How many distinct commits the user selected.
        public let selectedCount: Int
        /// How many commits the base..tip range actually spans (inclusive).
        public let spannedCount: Int
        public init(baseRef: String, tipRef: String, isContiguous: Bool,
                    selectedCount: Int, spannedCount: Int) {
            self.baseRef = baseRef
            self.tipRef = tipRef
            self.isContiguous = isContiguous
            self.selectedCount = selectedCount
            self.spannedCount = spannedCount
        }
    }

    /// Git's canonical empty-tree object SHA — used as the diff base when the
    /// oldest selected commit is a root (so `git diff <emptyTree> <tip>` renders
    /// the root commit's content as an all-add patch instead of failing on `^`).
    public static let emptyTreeSHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    /// Resolve the cumulative-diff range for `selected`. Returns `nil` for an
    /// empty selection. Duplicate SHAs are de-duplicated; input order is
    /// irrelevant (endpoints are chosen by `topoIndex`).
    public static func resolve(_ selected: [Commit]) -> Range? {
        var seen = Set<String>()
        let unique = selected.filter { seen.insert($0.sha).inserted }
        guard let first = unique.first else { return nil }

        // Newest = smallest topoIndex; oldest = largest.
        var newest = first
        var oldest = first
        for c in unique.dropFirst() {
            if c.topoIndex < newest.topoIndex { newest = c }
            if c.topoIndex > oldest.topoIndex { oldest = c }
        }

        let base = oldest.parents.first ?? emptyTreeSHA
        let spanned = (oldest.topoIndex - newest.topoIndex) + 1

        return Range(
            baseRef: base,
            tipRef: newest.sha,
            isContiguous: spanned == unique.count,
            selectedCount: unique.count,
            spannedCount: spanned
        )
    }
}
