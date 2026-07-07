import Foundation

/// TSK-1196 — cross-agent worktree overlap detection (owner feedback #6). Git
/// worktrees isolate the FILESYSTEM (no concurrent-edit clobber) but NOT
/// SEMANTIC overlap: two agents each adding a snapshot-hook to the same
/// `DocumentModel.saveEditor` in separate worktrees produce a DUPLICATE at
/// merge. This is the pure detection core — `who_touches(path)` + a
/// dashboard that flags files touched by ≥2 active worktrees so dispatch can
/// sequence/scope agents. The `git worktree list` / `git diff --name-only`
/// scan that produces the `Worktree` values is a thin shell wrapper; this
/// logic is host-tested.
public enum WorktreeOverlap {

    /// One active worktree's state for the dashboard.
    public struct Worktree: Equatable, Sendable {
        public let branch: String
        public let path: String
        /// Files changed vs the merge base (`git diff --name-only main...`).
        public let changedFiles: Set<String>
        public let commitsAhead: Int
        public let merged: Bool
        public let buildSizeBytes: Int?

        public init(branch: String, path: String, changedFiles: Set<String>,
                    commitsAhead: Int = 0, merged: Bool = false, buildSizeBytes: Int? = nil) {
            self.branch = branch
            self.path = path
            self.changedFiles = changedFiles
            self.commitsAhead = commitsAhead
            self.merged = merged
            self.buildSizeBytes = buildSizeBytes
        }
    }

    /// A file changed by more than one worktree — the semantic-overlap
    /// warning dispatch acts on.
    public struct Overlap: Equatable, Sendable {
        public let path: String
        /// Branches touching it, sorted for a stable report.
        public let branches: [String]
        public init(path: String, branches: [String]) {
            self.path = path
            self.branches = branches
        }
    }

    /// Which UNMERGED worktrees have changed `path`. A merged worktree is
    /// excluded — its changes are already on the trunk, so a fresh worktree
    /// touching the same file is building ON it, not colliding with it.
    public static func whoTouches(_ path: String, in worktrees: [Worktree]) -> [String] {
        worktrees
            .filter { !$0.merged && $0.changedFiles.contains(path) }
            .map(\.branch)
            .sorted()
    }

    /// Every file changed by ≥2 unmerged worktrees, with the branches. The
    /// overlap set dispatch should sequence rather than run in parallel.
    public static func overlaps(_ worktrees: [Worktree]) -> [Overlap] {
        let active = worktrees.filter { !$0.merged }
        var byFile: [String: [String]] = [:]
        for wt in active {
            for file in wt.changedFiles {
                byFile[file, default: []].append(wt.branch)
            }
        }
        return byFile
            .filter { $0.value.count >= 2 }
            .map { Overlap(path: $0.key, branches: $0.value.sorted()) }
            .sorted { $0.path < $1.path }
    }

    /// A one-line-per-overlap report (empty when clean) for the dashboard /
    /// dispatch log.
    public static func report(_ worktrees: [Worktree]) -> String {
        let hits = overlaps(worktrees)
        guard !hits.isEmpty else { return "no cross-worktree file overlap" }
        return hits
            .map { "⚠︎ \($0.path) — \($0.branches.joined(separator: ", "))" }
            .joined(separator: "\n")
    }
}
