import Foundation

/// TSK-1601 (owner 2026-07-24) — classify a git-log DECORATION entry so the
/// log row can color each ref KIND distinctly. Previously every ref (and the
/// commit id, and HEAD) rendered in `Color.accentColor` — one blue wash where
/// the user needs to tell "which of these is a tag / a remote / my checked-out
/// branch / another worktree's branch" at a glance.
///
/// Input is a raw `%d` decoration entry as `GitClient.parseGraphLog` splits it:
///   "HEAD -> main" · "HEAD" · "main" · "origin/main" · "tag: v1.2" ·
///   "refs/stash" · "grafted" / "replaced" (git's synthetic markers)
public enum GitRefKind: String, Sendable, Equatable, CaseIterable {
    /// The checked-out ref of the CURRENT worktree ("HEAD" / "HEAD -> x").
    case head
    /// A local branch.
    case localBranch
    /// A remote-tracking branch ("origin/…").
    case remoteBranch
    /// An annotated or lightweight tag ("tag: …").
    case tag
    /// A local branch that is checked out in ANOTHER worktree (TSK-1602 —
    /// resolved by the caller, which knows the worktree map).
    case worktreeBranch
    /// Anything else git decorated (stash, grafted, replaced).
    case other

    /// A decoration entry split into its display NAME and KIND.
    public struct Ref: Sendable, Equatable {
        public let name: String
        public let kind: GitRefKind
        /// For `.worktreeBranch`, the worktree directory name (chip subtitle).
        public let worktreeName: String?
        public init(name: String, kind: GitRefKind, worktreeName: String? = nil) {
            self.name = name
            self.kind = kind
            self.worktreeName = worktreeName
        }
    }

    /// Names of git's synthetic decorations that aren't refs.
    static let syntheticMarkers: Set<String> = ["grafted", "replaced", "rewritten"]

    /// Classify ONE raw decoration entry. `remoteNames` lets a repo with a
    /// non-"origin" remote classify correctly; when empty, the standard
    /// "<name>/<rest>" shape is treated as remote only for known prefixes.
    /// `worktreeBranches` maps a local branch → the OTHER worktree holding it.
    public static func classify(
        _ raw: String,
        remoteNames: Set<String> = ["origin", "upstream"],
        worktreeBranches: [String: String] = [:]
    ) -> Ref {
        let entry = raw.trimmingCharacters(in: .whitespaces)
        if entry.isEmpty { return Ref(name: entry, kind: .other) }
        if entry.hasPrefix("tag: ") {
            return Ref(name: String(entry.dropFirst("tag: ".count)), kind: .tag)
        }
        if entry == "HEAD" { return Ref(name: "HEAD", kind: .head) }
        if entry.hasPrefix("HEAD -> ") {
            // The checked-out branch of THIS worktree — one chip, HEAD-colored,
            // named for the branch (the arrow form is noise in a chip).
            return Ref(name: String(entry.dropFirst("HEAD -> ".count)), kind: .head)
        }
        if syntheticMarkers.contains(entry.lowercased()) {
            return Ref(name: entry, kind: .other)
        }
        if entry == "refs/stash" || entry.hasPrefix("refs/stash") {
            return Ref(name: "stash", kind: .other)
        }
        if let slash = entry.firstIndex(of: "/") {
            let prefix = String(entry[entry.startIndex..<slash])
            if remoteNames.contains(prefix) {
                return Ref(name: entry, kind: .remoteBranch)
            }
        }
        // A local branch — possibly checked out in another worktree.
        if let wt = worktreeBranches[entry] {
            return Ref(name: entry, kind: .worktreeBranch, worktreeName: wt)
        }
        return Ref(name: entry, kind: .localBranch)
    }

    /// Classify a whole decoration list, dropping empties. Order preserved so
    /// the row's chips read in git's own decoration order.
    public static func classifyAll(
        _ raws: [String],
        remoteNames: Set<String> = ["origin", "upstream"],
        worktreeBranches: [String: String] = [:]
    ) -> [Ref] {
        raws.map {
            classify($0, remoteNames: remoteNames, worktreeBranches: worktreeBranches)
        }.filter { !$0.name.isEmpty }
    }
}
