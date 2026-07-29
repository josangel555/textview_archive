import Foundation

/// TSK-1600 (owner 2026-07-24) — the Git Log search is MULTI-FIELD: one query
/// box matches a commit-id prefix, a branch-name prefix, a worktree-name
/// prefix, the commit message subject, or the message body/description.
///
/// Split in two on purpose:
///   - `GitLogSearchQuery` (here) is the PURE matcher over already-loaded
///     `GraphCommit`s + the worktree map: sha/branch/worktree prefixes and
///     subject substrings resolve INSTANTLY with no subprocess, so typing
///     stays responsive.
///   - the body/description search still needs `git log --grep` (the loaded
///     rows carry only the subject) — `GitPanelModel` unions the two.
///
/// Matching rules (all case-insensitive):
///   - **commit id**: PREFIX of the abbreviated or full sha ("3f2a").
///   - **branch / tag / remote ref**: PREFIX of any ref name on the commit,
///     or of a path COMPONENT of it ("b6" matches "feature/b6-grooming").
///   - **worktree**: PREFIX of a worktree's directory name or its checked-out
///     branch; matches every commit reachable-as-head of that worktree (the
///     head commit itself — the cheap, honest signal without a graph walk).
///   - **message**: case-insensitive SUBSTRING of the subject.
public enum GitLogSearchQuery {

    /// Which field produced a hit — drives the search-result annotation and
    /// lets tests assert the intent, not just the count.
    public enum Field: String, Sendable, Equatable, CaseIterable {
        case commitID, ref, worktree, subject
    }

    /// A worktree as the matcher sees it: the directory NAME (not the whole
    /// path — that's what users type) plus its checked-out branch and head.
    public struct Worktree: Sendable, Equatable {
        public let name: String
        public let branch: String?
        public let head: String
        public init(name: String, branch: String?, head: String) {
            self.name = name
            self.branch = branch
            self.head = head
        }
    }

    /// True when `candidate` starts with `query` (case-insensitive).
    static func hasPrefix(_ candidate: String, _ query: String) -> Bool {
        candidate.lowercased().hasPrefix(query)
    }

    /// Ref-name match: whole-name prefix OR any `/`-separated component
    /// prefix, so "b6" finds "feature/b6-grooming" and "origin/b6-x".
    static func refMatches(_ ref: String, _ query: String) -> Bool {
        if hasPrefix(ref, query) { return true }
        return ref.split(separator: "/").contains { hasPrefix(String($0), query) }
    }

    /// The fields of `commit` that match `rawQuery`, given the worktree map.
    /// Empty result = no match. `refs` are the commit's decoration names
    /// (already stripped of "HEAD -> " / "tag: " by the caller's parser).
    public static func matchingFields(
        commit: GitClient.GraphCommit,
        refs: [String],
        worktrees: [Worktree],
        rawQuery: String
    ) -> Set<Field> {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var fields: Set<Field> = []
        if hasPrefix(commit.sha, q) { fields.insert(.commitID) }
        if refs.contains(where: { refMatches($0, q) }) { fields.insert(.ref) }
        if commit.subject.lowercased().contains(q) { fields.insert(.subject) }
        for wt in worktrees {
            let nameHit = hasPrefix(wt.name, q)
                || wt.name.split(separator: "-").contains { hasPrefix(String($0), q) }
            let branchHit = wt.branch.map { refMatches($0, q) } ?? false
            guard nameHit || branchHit else { continue }
            // A worktree query surfaces the commit its HEAD points at.
            if hasPrefix(commit.sha, wt.head.lowercased())
                || hasPrefix(wt.head, commit.sha.lowercased()) {
                fields.insert(.worktree)
            }
        }
        return fields
    }

    /// Filter loaded rows to those matching `rawQuery` (order preserved).
    public static func filter(
        commits: [GitClient.GraphCommit],
        worktrees: [Worktree],
        refsFor: (GitClient.GraphCommit) -> [String],
        rawQuery: String
    ) -> [GitClient.GraphCommit] {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return commits.filter {
            !matchingFields(commit: $0, refs: refsFor($0),
                            worktrees: worktrees, rawQuery: q).isEmpty
        }
    }

    /// Merge the instant local hits with the `--grep` body hits, preserving
    /// the LOCAL order first (those are the rows the user already sees) and
    /// appending body-only hits, deduped by sha.
    public static func merge(
        local: [GitClient.GraphCommit], body: [GitClient.GraphCommit]
    ) -> [GitClient.GraphCommit] {
        var seen = Set(local.map(\.sha))
        var out = local
        for c in body where !seen.contains(c.sha) {
            seen.insert(c.sha)
            out.append(c)
        }
        return out
    }
}
