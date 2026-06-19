import Foundation

/// The mutation + read surface of `GitClient` that the worktree manager needs.
/// Extracted as a protocol so `WorktreeManagerModel` can be driven by a stub
/// in host tests (no `git` spawned) — the model carries the UX *logic* that the
/// raw `GitClient` lacks (validation, default derivation, classification,
/// safe-vs-force removal), and that logic is what we want under test, not the
/// subprocess plumbing. `GitClient` conforms to it for production use.
///
/// All methods mirror `GitClient`'s existing non-throwing-on-empty contract:
/// reads return `[]`/best-effort, mutations return `Bool` success.
public protocol WorktreeGitOps: AnyObject {
    /// Repo root of the *main* working tree (the one `GitClient` was rooted at).
    var repoRoot: URL { get }
    func worktreeList() -> [GitClient.WorktreeEntry]
    @discardableResult
    func worktreeAdd(path: URL, branch: String?, createBranch: Bool) -> Bool
    @discardableResult
    func worktreeRemove(path: URL, force: Bool) -> Bool
    @discardableResult
    func worktreePrune() -> Bool
}

extension GitClient: WorktreeGitOps {}

/// Pure, subprocess-free decision logic for the worktree manager UX. Mirrors
/// `GitBranchSwitch`'s shape: every entry point is a value transform so it is
/// host-testable (T1m) without spawning git. `WorktreeManagerModel` composes
/// these with a `WorktreeGitOps` to perform the real mutations.
public enum WorktreePlanner {

    // MARK: - row classification

    /// An actionable classification of a worktree entry for the manager UI.
    /// Richer than `GitClient.WorktreeEntry.State`: it folds in whether a
    /// remove is safe (a plain `git worktree remove`) or needs `--force`
    /// (locked / would-discard), and whether the row is the main/current
    /// worktree (which must never be removed).
    public struct Row: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable {
            /// The worktree the app is rooted at — never removable here.
            case current
            /// A linked worktree in a clean, ordinary state.
            case normal
            /// Administratively locked — removal requires `--force`.
            case locked
            /// Directory is gone; only a `prune` (or `remove --force`) applies.
            case prunable
        }

        public let entry: GitClient.WorktreeEntry
        public let kind: Kind
        /// True when this row can be removed at all (everything except the
        /// current/main worktree).
        public let isRemovable: Bool
        /// True when a removal must pass `--force` (locked or prunable). A
        /// `.normal` row removes cleanly; the caller still lets git be the
        /// final arbiter for an unexpectedly-dirty tree.
        public let requiresForceToRemove: Bool

        public var path: URL { entry.path }
        public var branch: String? { entry.branch }
    }

    /// Classify the raw `worktreeList()` output into actionable rows. The
    /// row whose path equals `mainRepoRoot` is the current/main worktree and
    /// is marked non-removable; everything else is removable, with force
    /// required for locked/prunable entries.
    public static func classify(
        _ entries: [GitClient.WorktreeEntry],
        mainRepoRoot: URL
    ) -> [Row] {
        let rootPath = mainRepoRoot.standardizedFileURL.path
        return entries.map { e in
            let isMain = e.path.standardizedFileURL.path == rootPath
            let kind: Row.Kind
            if isMain {
                kind = .current
            } else {
                switch e.state {
                case .current: kind = .current   // git flagged it current too
                case .normal:  kind = .normal
                case .locked:  kind = .locked
                case .prunable: kind = .prunable
                }
            }
            let isCurrent = (kind == .current)
            let force = (kind == .locked || kind == .prunable)
            return Row(
                entry: e,
                kind: kind,
                isRemovable: !isCurrent,
                requiresForceToRemove: force
            )
        }
    }

    /// The subset of rows whose backing directory is gone — candidates for
    /// `git worktree prune`. Surfacing this lets the UI enable/disable a
    /// "Prune" affordance instead of running a no-op git call.
    public static func pruneCandidates(_ rows: [Row]) -> [Row] {
        rows.filter { $0.kind == .prunable }
    }

    // MARK: - default name / path derivation

    /// Sanitize an arbitrary branch name into a filesystem-friendly directory
    /// leaf: a `refs/heads/` prefix is stripped, path separators and other
    /// awkward characters collapse to `-`, and runs of `-` coalesce. Empty
    /// input yields `"worktree"`. Used to suggest a default worktree directory
    /// for a given branch (e.g. `feature/login` → `feature-login`).
    public static func directoryLeaf(forBranch branch: String) -> String {
        var name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("refs/heads/") {
            name = String(name.dropFirst("refs/heads/".count))
        }
        let mapped = name.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            if c.isLetter || c.isNumber || c == "." || c == "_" { return c }
            return "-"
        }
        var out = ""
        var lastWasDash = false
        for c in mapped {
            if c == "-" {
                if lastWasDash { continue }
                lastWasDash = true
            } else {
                lastWasDash = false
            }
            out.append(c)
        }
        // Trim leading/trailing dashes/dots that would make an ugly leaf.
        while let f = out.first, f == "-" || f == "." { out.removeFirst() }
        while let l = out.last, l == "-" { out.removeLast() }
        return out.isEmpty ? "worktree" : out
    }

    /// Suggest a default absolute worktree path for `branch`, sibling to the
    /// main repo root (the common `git worktree add ../<repo>-<branch>`
    /// convention). `mainRepoRoot` is `/work/myrepo`, branch `feature/x` →
    /// `/work/myrepo-feature-x`. Disambiguates against `existing` paths by
    /// appending `-2`, `-3`, … so a repeated suggestion never collides.
    public static func defaultPath(
        forBranch branch: String,
        mainRepoRoot: URL,
        existing: [URL] = []
    ) -> URL {
        let root = mainRepoRoot.standardizedFileURL
        let parent = root.deletingLastPathComponent()
        let repoLeaf = root.lastPathComponent
        let branchLeaf = directoryLeaf(forBranch: branch)
        let base = "\(repoLeaf)-\(branchLeaf)"
        let existingPaths = Set(existing.map { $0.standardizedFileURL.path })
        var candidate = parent.appendingPathComponent(base).standardizedFileURL
        var n = 2
        while existingPaths.contains(candidate.path) {
            candidate = parent.appendingPathComponent("\(base)-\(n)").standardizedFileURL
            n += 1
        }
        return candidate
    }

    // MARK: - path validation

    /// The verdict for a proposed new-worktree path. Carries a human message
    /// for the UI to surface inline rather than a bare bool.
    public enum PathValidation: Equatable, Sendable {
        case ok
        case empty
        /// Already registered as a worktree (the porcelain list contains it).
        case alreadyWorktree
        /// A file/dir already exists at the path — `git worktree add` refuses.
        case alreadyExists
        /// The parent directory does not exist.
        case parentMissing
        /// The parent directory exists but isn't writable.
        case parentNotWritable

        public var isValid: Bool { self == .ok }

        public var message: String {
            switch self {
            case .ok:               return ""
            case .empty:            return "Enter a path for the new worktree."
            case .alreadyWorktree:  return "That path is already a registered worktree."
            case .alreadyExists:    return "Something already exists at that path."
            case .parentMissing:    return "The parent directory does not exist."
            case .parentNotWritable: return "The parent directory isn't writable."
            }
        }
    }

    /// A thin filesystem probe so `validatePath` can be exercised in host tests
    /// without touching the real disk. `GitClient`/production pass the
    /// `FileManager`-backed default.
    public struct FileProbe: Sendable {
        public let exists: @Sendable (URL) -> Bool
        public let isDirectory: @Sendable (URL) -> Bool
        public let isWritable: @Sendable (URL) -> Bool
        public init(
            exists: @escaping @Sendable (URL) -> Bool,
            isDirectory: @escaping @Sendable (URL) -> Bool,
            isWritable: @escaping @Sendable (URL) -> Bool
        ) {
            self.exists = exists
            self.isDirectory = isDirectory
            self.isWritable = isWritable
        }

        /// Real `FileManager`-backed probe.
        public static let live = FileProbe(
            exists: { FileManager.default.fileExists(atPath: $0.path) },
            isDirectory: { url in
                var isDir: ObjCBool = false
                let ok = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                return ok && isDir.boolValue
            },
            isWritable: { FileManager.default.isWritableFile(atPath: $0.path) }
        )
    }

    /// Validate a proposed worktree path (raw user input) against: non-empty,
    /// not already a registered worktree, nothing already at the path, parent
    /// exists and is writable. `existingWorktrees` is the current
    /// `worktreeList()` output.
    ///
    /// Takes a `String` (not a `URL`) deliberately: `URL(fileURLWithPath:)`
    /// silently resolves an empty/whitespace string to the *current directory*,
    /// so emptiness can only be detected before the URL is built. The UI has
    /// the raw text field value, so it passes it straight through.
    public static func validatePath(
        rawPath: String,
        existingWorktrees: [GitClient.WorktreeEntry],
        probe: FileProbe = .live
    ) -> PathValidation {
        let raw = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .empty }
        return validatePath(
            URL(fileURLWithPath: raw),
            existingWorktrees: existingWorktrees,
            probe: probe
        )
    }

    /// URL-typed variant for callers that already hold a non-empty `URL`
    /// (e.g. a row's path). Does NOT perform the empty check — see
    /// `validatePath(rawPath:…)`.
    public static func validatePath(
        _ proposed: URL,
        existingWorktrees: [GitClient.WorktreeEntry],
        probe: FileProbe = .live
    ) -> PathValidation {
        let target = proposed.standardizedFileURL
        let targetPath = target.path

        // Already a registered worktree?
        let known = Set(existingWorktrees.map { $0.path.standardizedFileURL.path })
        if known.contains(targetPath) { return .alreadyWorktree }

        // Something already at the path?
        if probe.exists(target) { return .alreadyExists }

        // Parent must exist, be a directory, and be writable.
        let parent = target.deletingLastPathComponent()
        guard probe.exists(parent), probe.isDirectory(parent) else {
            return .parentMissing
        }
        guard probe.isWritable(parent) else { return .parentNotWritable }

        return .ok
    }
}

/// Stateful model wrapping a `WorktreeGitOps` (production: `GitClient`) with the
/// worktree-manager UX logic. Owns the classified-row list and exposes
/// intention-revealing operations (`addWorktree`, `removeRow`, `prune`) that
/// fold the `WorktreePlanner` decisions into the right git arguments. The UI
/// (`GitWorktreesTab`) observes `rows` and calls these; host tests inject a
/// stub `WorktreeGitOps` to assert the exact arguments dispatched.
public final class WorktreeManagerModel {
    private let git: WorktreeGitOps
    private let probe: WorktreePlanner.FileProbe

    /// Classified rows from the last `refresh()`. The UI renders these.
    public private(set) var rows: [WorktreePlanner.Row] = []

    public init(git: WorktreeGitOps, probe: WorktreePlanner.FileProbe = .live) {
        self.git = git
        self.probe = probe
    }

    /// Re-read the worktree list and re-classify. Returns the fresh rows.
    @discardableResult
    public func refresh() -> [WorktreePlanner.Row] {
        rows = WorktreePlanner.classify(git.worktreeList(), mainRepoRoot: git.repoRoot)
        return rows
    }

    /// Rows whose directory is gone — `prune` (or force-remove) candidates.
    public var pruneCandidates: [WorktreePlanner.Row] {
        WorktreePlanner.pruneCandidates(rows)
    }

    /// Whether the "Prune" affordance should be enabled.
    public var canPrune: Bool { !pruneCandidates.isEmpty }

    /// Suggest a default path for `branch`, disambiguated against the known
    /// worktrees. Convenience over `WorktreePlanner.defaultPath`.
    public func suggestedPath(forBranch branch: String) -> URL {
        WorktreePlanner.defaultPath(
            forBranch: branch,
            mainRepoRoot: git.repoRoot,
            existing: rows.map { $0.path }
        )
    }

    /// Validate a proposed path (URL) against the current (cached) worktree
    /// rows. Use `validate(rawPath:)` for raw text-field input so emptiness is
    /// detected (an empty string resolves to cwd once it becomes a URL).
    public func validate(path: URL) -> WorktreePlanner.PathValidation {
        WorktreePlanner.validatePath(
            path,
            existingWorktrees: rows.map { $0.entry },
            probe: probe
        )
    }

    /// Validate raw text-field input against the current (cached) rows.
    public func validate(rawPath: String) -> WorktreePlanner.PathValidation {
        WorktreePlanner.validatePath(
            rawPath: rawPath,
            existingWorktrees: rows.map { $0.entry },
            probe: probe
        )
    }

    /// Result of an attempted add — validation can refuse before git runs.
    public enum AddResult: Equatable, Sendable {
        case invalid(WorktreePlanner.PathValidation)
        case gitFailed
        case added
    }

    /// Add a worktree at `path`. Validates first (refusing without spawning
    /// git on a bad path), then dispatches `worktreeAdd`. `branch == nil`
    /// checks out current HEAD on an auto-named branch; `createBranch == true`
    /// creates a new branch. On success, `refresh()` runs so `rows` is current.
    @discardableResult
    public func addWorktree(
        path: URL,
        branch: String? = nil,
        createBranch: Bool = false
    ) -> AddResult {
        let verdict = validate(path: path)
        return dispatchAdd(verdict: verdict, path: path, branch: branch, createBranch: createBranch)
    }

    /// Raw-text-field variant: validates the input string (catching empty),
    /// then dispatches like `addWorktree(path:…)`.
    @discardableResult
    public func addWorktree(
        rawPath: String,
        branch: String? = nil,
        createBranch: Bool = false
    ) -> AddResult {
        let verdict = validate(rawPath: rawPath)
        let url = URL(fileURLWithPath: rawPath.trimmingCharacters(in: .whitespacesAndNewlines))
        return dispatchAdd(verdict: verdict, path: url, branch: branch, createBranch: createBranch)
    }

    private func dispatchAdd(
        verdict: WorktreePlanner.PathValidation,
        path: URL,
        branch: String?,
        createBranch: Bool
    ) -> AddResult {
        guard verdict.isValid else { return .invalid(verdict) }
        let ok = git.worktreeAdd(path: path, branch: branch, createBranch: createBranch)
        guard ok else { return .gitFailed }
        refresh()
        return .added
    }

    /// Result of an attempted remove.
    public enum RemoveResult: Equatable, Sendable {
        /// The current/main worktree is never removable here.
        case notRemovable
        case gitFailed
        case removed
    }

    /// Remove the worktree backing `row`. The current/main worktree refuses.
    /// `--force` is applied automatically when the row's state requires it
    /// (locked/prunable). A caller can also force a `.normal` removal (e.g.
    /// after a "remove anyway" confirmation for a dirty tree) via `force`.
    @discardableResult
    public func removeRow(_ row: WorktreePlanner.Row, force: Bool = false) -> RemoveResult {
        guard row.isRemovable else { return .notRemovable }
        let useForce = force || row.requiresForceToRemove
        let ok = git.worktreeRemove(path: row.path, force: useForce)
        guard ok else { return .gitFailed }
        refresh()
        return .removed
    }

    /// Run `git worktree prune` (administrative cleanup of gone directories),
    /// then refresh. Returns false if git failed.
    @discardableResult
    public func prune() -> Bool {
        let ok = git.worktreePrune()
        if ok { refresh() }
        return ok
    }
}
