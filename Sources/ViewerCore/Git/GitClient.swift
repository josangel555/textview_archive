import Foundation

/// Typed status row used by callers that want a `.modified` / `.added`
/// enum instead of raw porcelain v1 X/Y characters. Lifted from the
/// retired `GitService` so the sidebar's badge code keeps a stable
/// public surface. `GitClient.statusEntries()` parses to this shape;
/// callers that need the raw chars (the panel's per-file status row)
/// still use `GitClient.status()` → `[StatusEntry]`.
public struct GitStatusEntry: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case modified   = "M"
        case added      = "A"
        case deleted    = "D"
        case renamed    = "R"
        case copied     = "C"
        case untracked  = "?"
        case ignored    = "!"
        case conflicted = "U"
    }

    public let path: String   // relative to repo root
    public let status: Status

    public init(path: String, status: Status) {
        self.path = path
        self.status = status
    }
}

/// Minimal git client that shells out to /usr/bin/git. Not a
/// libgit2 wrapper — for viewer-side reads we don't need
/// transactional anything, just `git status --porcelain`, `git diff`,
/// `git log`, and `git show`. Each method runs git as a Process,
/// captures stdout, parses.
///
/// All methods are synchronous + non-throwing-on-empty: a directory
/// that isn't a git repo returns empty results (no exception). Real
/// errors throw `GitClient.Error`.
public final class GitClient: Sendable {
    public let repoRoot: URL

    /// Optional wall-clock cap (seconds) applied to every `run(_:)`
    /// invocation via the existing `ProcessRunner.run(timeout:)`
    /// SIGTERM watchdog. `nil` (the default) preserves the historical
    /// "no wall-clock timeout — a slow `git status` surfaces as 'still
    /// working', not a hard truncation" behavior for the ~15 existing
    /// call sites. The multi-repo registry injects a value (5s for
    /// status/HEAD, 3s for gutter diff, 10s for the heavy graph log) so
    /// a wedged repo can't freeze badge refresh.
    ///
    /// This is the responsiveness guarantee; the 120s `RLIMIT_CPU` cap
    /// in `run(_:)` stays as the runaway-CPU backstop. The two are
    /// complementary — CPU cap defends a pinned core, wall-clock defends
    /// UI latency.
    public let statusTimeout: TimeInterval?

    public enum Error: Swift.Error, CustomStringConvertible {
        case gitNotFound
        case notARepo
        case processFailed(Int32, String)
        public var description: String {
            switch self {
            case .gitNotFound:           return "git not found (looked in /usr/bin, /opt/homebrew/bin, /usr/local/bin)"
            case .notARepo:              return "Not a git repository"
            case .processFailed(let c, let msg):
                return "git exited \(c): \(msg)"
            }
        }
    }

    public init(repoRoot: URL, statusTimeout: TimeInterval? = nil) {
        self.repoRoot = repoRoot
        self.statusTimeout = statusTimeout
    }

    /// Returns the working-tree root if any ancestor of `url` has
    /// `.git`, else nil. Useful for "is this folder a repo?".
    public static func discoverRoot(from url: URL) -> URL? {
        var cur = url.standardizedFileURL
        let fm = FileManager.default
        for _ in 0..<32 {
            let git = cur.appendingPathComponent(".git")
            if fm.fileExists(atPath: git.path) {
                return cur
            }
            let parent = cur.deletingLastPathComponent()
            if parent.path == cur.path { break }
            cur = parent
        }
        return nil
    }

    /// True iff `path` (relative to this client's `repoRoot`) is tracked
    /// in the index. Used by the File-History entry points to gate the
    /// menu item: an untracked / never-committed file has no history to
    /// show. `git ls-files --error-unmatch <path>` exits 0 when tracked,
    /// non-zero otherwise — and `run` returns nil on a non-zero exit, so
    /// we map a successful (non-nil) run to tracked.
    ///
    /// Cheap (touches the index, not the full history) so it's safe to
    /// call synchronously from the menu-visibility check.
    public func isTracked(path: String) -> Bool {
        guard !path.isEmpty else { return false }
        return (try? run(["ls-files", "--error-unmatch", "--", path])) != nil
    }

    // MARK: - status

    public struct StatusEntry: Equatable, Sendable {
        public let path: String
        public let indexStatus: Character   // X column of porcelain v1
        public let workingStatus: Character // Y column
        public var isUntracked: Bool { indexStatus == "?" && workingStatus == "?" }
    }

    /// `git status --porcelain` rows.
    public func status() -> [StatusEntry] {
        let out = (try? run(["status", "--porcelain=v1", "-uall"])) ?? ""
        var entries: [StatusEntry] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.count >= 4 else { continue }
            let chars = Array(line)
            let path = String(chars[3..<chars.count])
            entries.append(StatusEntry(
                path: path,
                indexStatus: chars[0],
                workingStatus: chars[1]
            ))
        }
        return entries
    }

    /// `git status --porcelain=v1` parsed into typed entries. This is
    /// the shape the file-tree badge consumes (one row → one enum
    /// case). Threw `GitError.commandFailed` in the old `GitService`
    /// API; here we follow the rest of `GitClient` and return `[]` on
    /// failure so the caller doesn't have to wrap every read in `try?`.
    public func statusEntries() -> [GitStatusEntry] {
        guard let out = try? run(["status", "--porcelain=v1"]) else { return [] }
        return Self.parseStatusEntries(out)
    }

    /// `statusEntries()` variant that surfaces whether the wall-clock
    /// `statusTimeout` fired. The registry store uses this to keep its
    /// prior snapshot (frozen badges) on timeout rather than blanking.
    ///
    /// On a non-timeout failure (e.g. not a repo) returns `([], false)`
    /// — same "empty on failure" contract as `statusEntries()`, so the
    /// caller still treats a genuinely-not-a-repo path as clean. Only a
    /// real timeout sets `timedOut: true`.
    public func statusEntriesResult() -> (entries: [GitStatusEntry], timedOut: Bool) {
        guard let r = try? runResult(["status", "--porcelain=v1"]) else {
            return ([], false)
        }
        return (Self.parseStatusEntries(r.output), r.timedOut)
    }

    /// Pure-logic parser. Public so tests can pin parsing semantics
    /// (the literal " -> " gating on R/C status, unicode paths, the
    /// modified-priority rule) without spawning a real git process.
    public static func parseStatusEntries(_ output: String) -> [GitStatusEntry] {
        var entries: [GitStatusEntry] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            // porcelain v1: "XY path" (X = index, Y = worktree). "?? path"
            // for untracked. Renames/copies produce "XY old -> new" — but
            // **only** when X or Y is R/C. Plain M/A/D files can legally
            // contain the literal substring " -> " in their names, so we
            // must gate the split on the status (B6).
            guard raw.count >= 3 else { continue }
            let chars = Array(raw)
            let x = chars[0]
            let y = chars[1]
            let pathRaw = String(chars.dropFirst(3))
            let isRenameOrCopy = (x == "R" || x == "C" || y == "R" || y == "C")
            let path: String
            if isRenameOrCopy, let arrow = pathRaw.range(of: " -> ") {
                path = String(pathRaw[arrow.upperBound...])
            } else {
                path = pathRaw
            }
            let trimmed = path.trimmingCharacters(in: .whitespaces)
            guard let status = mapStatus(x: x, y: y) else { continue }
            entries.append(GitStatusEntry(path: trimmed, status: status))
        }
        return entries
    }

    private static func mapStatus(x: Character, y: Character) -> GitStatusEntry.Status? {
        if x == "?" && y == "?" { return .untracked }
        if x == "!" && y == "!" { return .ignored }
        if x == "U" || y == "U" || x == "A" && y == "A" || x == "D" && y == "D" {
            return .conflicted
        }
        // Priority: worktree state, then index state.
        for ch in [y, x] {
            switch ch {
            case "M": return .modified
            case "A": return .added
            case "D": return .deleted
            case "R": return .renamed
            case "C": return .copied
            default: break
            }
        }
        return nil
    }

    // MARK: - diff

    /// `git diff HEAD -- <path>` for unified-diff text.
    public func diff(forPath path: String) -> String {
        (try? run(["diff", "--no-color", "HEAD", "--", path])) ?? ""
    }

    /// `git diff <baseRef> <tipRef>` — the unified diff between two commit-ish
    /// refs. This is the CUMULATIVE patch for a range resolved by
    /// `CumulativeDiffSelection` (base = the oldest selected commit's parent, or
    /// the empty-tree SHA for a root; tip = the newest selected commit): the NET
    /// change across the range, so intermediate states collapse. Returns "" on
    /// error. Parse with `DiffParser` for the structured form (TSK-522 slice 2).
    public func cumulativeDiff(baseRef: String, tipRef: String) -> String {
        (try? run(["diff", "--no-color", baseRef, tipRef])) ?? ""
    }

    // MARK: - identity

    /// `git config user.name` / `user.email` — the identity reviews are
    /// authored under (TSK-523). nil when neither is configured.
    public func configuredAuthor() -> (name: String, email: String)? {
        let name = (try? run(["config", "user.name"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let email = (try? run(["config", "user.email"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty && email.isEmpty { return nil }
        return (name, email)
    }

    // MARK: - log

    public struct LogEntry: Equatable, Sendable {
        public let sha: String        // short SHA (display)
        public let author: String
        public let date: String       // ISO-ish from %ad / %ai
        public let subject: String
        /// Full 40-hex object id. Empty for entries produced by the
        /// legacy `log(forPath:)` path (which only fetched `%h`); the
        /// file-history feature populates it (`fileHistory(path:)`) so
        /// two-commit diffing can use unambiguous full SHAs instead of
        /// abbreviation-collision-prone short ones. Additive field —
        /// memberwise init keeps it optional via a default so existing
        /// construction sites and tests don't break.
        public let fullSHA: String

        public init(
            sha: String, author: String, date: String, subject: String,
            fullSHA: String = ""
        ) {
            self.sha = sha
            self.author = author
            self.date = date
            self.subject = subject
            self.fullSHA = fullSHA
        }
    }

    /// Last N commits touching a single file. With nil path → repo-wide.
    public func log(forPath path: String? = nil, maxEntries: Int = 50) -> [LogEntry] {
        // Use a delimiter no plausible commit subject would contain.
        let sep = "\u{1F}"  // unit separator
        let format = "--pretty=format:%h\(sep)%an\(sep)%ai\(sep)%s"
        var args = ["log", format, "-n", "\(maxEntries)"]
        if let path { args.append(contentsOf: ["--", path]) }
        guard let out = try? run(args) else { return [] }
        var entries: [LogEntry] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: Character(sep), omittingEmptySubsequences: false)
            guard parts.count == 4 else { continue }
            entries.append(LogEntry(
                sha: String(parts[0]),
                author: String(parts[1]),
                date: String(parts[2]),
                subject: String(parts[3])
            ))
        }
        return entries
    }

    /// Per-file commit history for the File History tab. Carries BOTH
    /// the short SHA (`%h`, for compact display) and the full 40-hex id
    /// (`%H`, for unambiguous two-commit diffing). Follows renames
    /// (`--follow`) so a file's pre-rename history is reachable. With
    /// `nil` path → repo-wide history (used as a fallback / for testing).
    ///
    /// Newest-first (git's default order). Returns `[]` on any failure
    /// (not-a-repo, untracked file) — same non-throwing contract as
    /// `log(forPath:)`.
    public func fileHistory(path: String? = nil, maxEntries: Int = 200) -> [LogEntry] {
        let fs = "\u{1F}"  // unit separator
        // %H full sha, %h short, %an author, %ai author date (ISO 8601), %s subject.
        let format = "--pretty=format:%H\(fs)%h\(fs)%an\(fs)%ai\(fs)%s"
        var args = ["log", format, "-n", "\(maxEntries)"]
        // --follow is only valid with a single pathspec; gate it on path.
        if let path { args.append(contentsOf: ["--follow", "--", path]) }
        guard let out = try? run(args) else { return [] }
        var entries: [LogEntry] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            // maxSplits keeps a subject containing the separator intact
            // (defensive — the unit separator is astronomically unlikely
            // in a subject, but %s is fully user-controlled).
            let parts = line.split(
                separator: Character(fs), maxSplits: 4,
                omittingEmptySubsequences: false
            )
            guard parts.count == 5 else { continue }
            entries.append(LogEntry(
                sha: String(parts[1]),
                author: String(parts[2]),
                date: String(parts[3]),
                subject: String(parts[4]),
                fullSHA: String(parts[0])
            ))
        }
        return entries
    }

    /// Topologically-ordered log with parent shas, refs, and stats — the
    /// shape the panel's graph renderer needs. `skip` enables paging
    /// (initial 100 + scroll-to-bottom +200, capped 5000 by the caller).
    public struct GraphCommit: Equatable, Sendable {
        public let sha: String          // short
        public let parents: [String]    // short
        public let author: String
        public let timestamp: Int       // unix seconds (%ct)
        public let subject: String
        public let refs: [String]       // decoration: "HEAD -> main", "origin/foo", "tag: v1"
        public let filesChanged: Int
        public let insertions: Int
        public let deletions: Int
        public var isMerge: Bool { parents.count > 1 }
    }

    /// Record sep + field sep so commit subjects (which may contain
    /// newlines) round-trip. Shared by `graphLog` and `grepLog` so both
    /// feed the same parser.
    static let graphLogFormat = "--pretty=format:\u{1E}%h\u{1F}%p\u{1F}%an\u{1F}%ct\u{1F}%d\u{1F}%s"

    public func graphLog(maxEntries: Int = 100, skip: Int = 0) -> [GraphCommit] {
        let args = [
            "log", "--topo-order", "--shortstat", Self.graphLogFormat,
            "-n", "\(maxEntries)", "--skip", "\(skip)",
        ]
        guard let out = try? run(args) else { return [] }
        return Self.parseGraphLog(out)
    }

    /// TSK-596: full-message search over the branch history — `--grep`
    /// matches the WHOLE commit message (subject + body/description),
    /// which the loaded `GraphCommit` list can't offer (it only carries
    /// `%s`). `--fixed-strings` treats the query as a literal (no regex
    /// surprises; the arg is exec'd, never shell-interpolated, so
    /// special characters are data); `--regexp-ignore-case` makes it
    /// case-insensitive. Empty/whitespace query returns [].
    public func grepLog(query: String, maxEntries: Int = 500) -> [GraphCommit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let args = [
            "log", "--topo-order", "--shortstat", Self.graphLogFormat,
            "-n", "\(maxEntries)",
            "--fixed-strings", "--regexp-ignore-case", "--grep=\(q)",
        ]
        guard let out = try? run(args) else { return [] }
        return Self.parseGraphLog(out)
    }

    /// Parse the `graphLogFormat` + `--shortstat` output. Static + pure
    /// so the record/field-separator contract is unit-testable without
    /// a repo.
    static func parseGraphLog(_ out: String) -> [GraphCommit] {
        let rs = "\u{1E}"  // record separator
        let fs = "\u{1F}"  // unit separator
        var result: [GraphCommit] = []
        // Records are RS-prefixed; split and skip the leading empty piece.
        let records = out.components(separatedBy: rs).dropFirst()
        for record in records {
            // Within a record: line 0 is the header (one line — %s only
            // expands to the first line of the message). Any subsequent
            // lines are the `--shortstat` summary, separated by a blank
            // line between commits at the record-boundary level (which
            // our RS split already handled).
            let lines = record.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            guard let header = lines.first else { continue }
            let parts = header.components(separatedBy: fs)
            guard parts.count >= 6 else { continue }
            let sha = parts[0]
            let parents = parts[1].split(separator: " ").map(String.init)
            let author = parts[2]
            let timestamp = Int(parts[3]) ?? 0
            // Decoration is "( HEAD -> main, origin/main, tag: v1)" or
            // "" when no refs. Strip wrapping parens + leading space.
            var deco = parts[4].trimmingCharacters(in: .whitespaces)
            if deco.hasPrefix("(") && deco.hasSuffix(")") {
                deco = String(deco.dropFirst().dropLast())
            }
            let refs = deco.isEmpty
                ? []
                : deco.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let subject = parts[5]
            var files = 0, ins = 0, del = 0
            // shortstat line starts with " N file changed, …"
            let statLine = lines.dropFirst()
                .first { $0.contains(" changed") } ?? ""
            for token in statLine.split(separator: ",") {
                let s = token.trimmingCharacters(in: .whitespaces)
                if s.contains("file changed") || s.contains("files changed") {
                    files = Int(s.split(separator: " ").first ?? "0") ?? 0
                } else if s.contains("insertion") {
                    ins = Int(s.split(separator: " ").first ?? "0") ?? 0
                } else if s.contains("deletion") {
                    del = Int(s.split(separator: " ").first ?? "0") ?? 0
                }
            }
            result.append(GraphCommit(
                sha: sha, parents: parents, author: author,
                timestamp: timestamp, subject: subject, refs: refs,
                filesChanged: files, insertions: ins, deletions: del
            ))
        }
        return result
    }

    // MARK: - stash

    public struct StashEntry: Equatable, Sendable {
        public let ref: String        // "stash@{0}"
        public let timestamp: Int     // %ct
        public let subject: String    // "WIP on branch: …"
    }

    public func stashList() -> [StashEntry] {
        let fs = "\u{1F}"
        let format = "--format=%gd\(fs)%ct\(fs)%gs"
        guard let out = try? run(["stash", "list", format]) else { return [] }
        var entries: [StashEntry] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: Character(fs), omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            entries.append(StashEntry(
                ref: String(parts[0]),
                timestamp: Int(parts[1]) ?? 0,
                subject: String(parts[2])
            ))
        }
        return entries
    }

    @discardableResult
    public func stashApply(_ ref: String) -> Bool {
        (try? run(["stash", "apply", ref])) != nil
    }

    @discardableResult
    public func stashPop(_ ref: String) -> Bool {
        (try? run(["stash", "pop", ref])) != nil
    }

    @discardableResult
    public func stashDrop(_ ref: String) -> Bool {
        (try? run(["stash", "drop", ref])) != nil
    }

    public func stashShow(_ ref: String) -> String {
        (try? run(["stash", "show", "-p", "--no-color", ref])) ?? ""
    }

    // MARK: - worktree

    public struct WorktreeEntry: Equatable, Sendable {
        public enum State: Sendable, Equatable {
            case current, normal, locked, prunable
        }
        public let path: URL
        public let branch: String?    // nil = detached HEAD
        public let head: String       // sha
        public let state: State
    }

    public func worktreeList() -> [WorktreeEntry] {
        guard let out = try? run(["worktree", "list", "--porcelain"]) else { return [] }
        var entries: [WorktreeEntry] = []
        var path: URL?
        var head = ""
        var branch: String?
        var locked = false
        var prunable = false
        func flush() {
            guard let p = path else { return }
            let isCurrent = p.standardizedFileURL.path == repoRoot.standardizedFileURL.path
            let state: WorktreeEntry.State =
                prunable ? .prunable
                : locked ? .locked
                : isCurrent ? .current
                : .normal
            entries.append(WorktreeEntry(path: p, branch: branch, head: head, state: state))
            path = nil; head = ""; branch = nil; locked = false; prunable = false
        }
        for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("worktree ") {
                path = URL(fileURLWithPath: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count).prefix(7))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                // "refs/heads/foo" → "foo"
                branch = ref.hasPrefix("refs/heads/")
                    ? String(ref.dropFirst("refs/heads/".count))
                    : ref
            } else if line == "locked" || line.hasPrefix("locked ") {
                locked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                prunable = true
            }
        }
        flush()
        return entries
    }

    /// Create a linked worktree at `path` (TSK-349). Modes:
    ///   * `createBranch == true` + `branch` → `git worktree add -b <branch>
    ///     <path>` (new branch off current HEAD checked out in the worktree),
    ///   * existing `branch` → `git worktree add <path> <branch>`,
    ///   * `branch == nil` → `git worktree add <path>` (worktree at current
    ///     HEAD on an auto-named branch).
    /// Returns `false` on any git failure (path already exists, branch already
    /// checked out in another worktree, unborn HEAD, …) — non-throwing, matching
    /// the rest of the mutation API (`stashApply`/`stashPop`/…).
    @discardableResult
    public func worktreeAdd(path: URL, branch: String? = nil, createBranch: Bool = false) -> Bool {
        var args = ["worktree", "add"]
        if createBranch, let branch {
            args += ["-b", branch, path.path]
        } else if let branch {
            args += [path.path, branch]
        } else {
            args.append(path.path)
        }
        return (try? run(args)) != nil
    }

    /// Remove the worktree registered at `path` (`git worktree remove`).
    /// `force == true` adds `--force` (removes even a dirty/locked worktree).
    /// Returns `false` on failure (not a registered worktree, dirty without
    /// force, …).
    @discardableResult
    public func worktreeRemove(path: URL, force: Bool = false) -> Bool {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(path.path)
        return (try? run(args)) != nil
    }

    /// Prune administrative entries for worktrees whose directories are gone
    /// (`git worktree prune`). Returns `false` on failure.
    @discardableResult
    public func worktreePrune() -> Bool {
        (try? run(["worktree", "prune"])) != nil
    }

    // MARK: - branch switch (UX-C, #225)

    /// Local branch names (`git for-each-ref --format=%(refname:short)
    /// refs/heads/`). Newest-committed first so the footer menu surfaces
    /// the most-recently-touched branches at the top. Returns `[]` on any
    /// failure (matching the rest of the read API's non-throwing contract).
    public func localBranches() -> [String] {
        let args = [
            "for-each-ref",
            "--sort=-committerdate",
            "--format=%(refname:short)",
            "refs/heads/",
        ]
        guard let out = try? run(args) else { return [] }
        return out
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `git checkout <branch>`. The CALLER must have already cleared the
    /// `GitBranchSwitch.decide(...)` dirty-gate — this method does NOT
    /// re-check the working tree (it deliberately omits `--force`, so git
    /// is still the last line of defense: a checkout that *would* clobber
    /// a tracked file exits non-zero and we surface that as a failure
    /// rather than discarding). Returns `(ok, message)`: on failure
    /// `message` is git's stderr (trimmed) so the UI can show it.
    ///
    /// `branch` is validated not to begin with `-` (option-injection
    /// guard); `--` terminates option parsing before it as belt-and-braces.
    @discardableResult
    public func checkout(branch: String) -> (ok: Bool, message: String) {
        let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("-") else {
            return (false, "Invalid branch name.")
        }
        do {
            _ = try run(["checkout", name, "--"])
            return (true, "")
        } catch let e as Error {
            if case let .processFailed(_, msg) = e {
                return (false, msg.isEmpty ? "git checkout failed." : msg)
            }
            return (false, e.description)
        } catch {
            return (false, "git checkout failed.")
        }
    }

    /// `git stash push` (including untracked via `-u`) so a dirty tree can
    /// be parked before a branch switch — the non-destructive escape hatch
    /// the footer offers when `GitBranchSwitch.decide` refuses. Returns
    /// `(ok, message)`; on "nothing to stash" git exits 0 with a notice,
    /// which we still treat as `ok`. `message` argument is the stash label.
    @discardableResult
    public func stashPushAll(message: String) -> (ok: Bool, message: String) {
        let label = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var args = ["stash", "push", "-u"]
        if !label.isEmpty { args.append(contentsOf: ["-m", label]) }
        do {
            _ = try run(args)
            return (true, "")
        } catch let e as Error {
            if case let .processFailed(_, msg) = e {
                return (false, msg.isEmpty ? "git stash failed." : msg)
            }
            return (false, e.description)
        } catch {
            return (false, "git stash failed.")
        }
    }

    // MARK: - remote

    public struct RemoteEntry: Equatable, Sendable {
        public let name: String
        public let url: String
        public let lastFetchedAt: Date?
    }

    public func remoteList() -> [RemoteEntry] {
        guard let out = try? run(["remote", "-v"]) else { return [] }
        // `git remote -v` lists fetch + push lines per remote. Dedupe by
        // (name, url) keeping fetch.
        var seen = Set<String>()
        var entries: [RemoteEntry] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let name = String(parts[0])
            // "url (fetch)" or "url (push)"
            let urlAndKind = parts[1]
            guard urlAndKind.hasSuffix(" (fetch)") else { continue }
            let url = String(urlAndKind.dropLast(" (fetch)".count))
            let key = name + "\t" + url
            if seen.insert(key).inserted {
                let fetchHead = repoRoot
                    .appendingPathComponent(".git/refs/remotes/\(name)", isDirectory: true)
                // Better signal: .git/FETCH_HEAD mtime is the global last
                // fetch — not per-remote, but accurate enough for "fetched X ago".
                let fetchPath = repoRoot.appendingPathComponent(".git/FETCH_HEAD").path
                let attrs = try? FileManager.default.attributesOfItem(atPath: fetchPath)
                let date = attrs?[.modificationDate] as? Date
                entries.append(RemoteEntry(name: name, url: url, lastFetchedAt: date))
                _ = fetchHead  // suppress unused warning; reserved for per-remote refinement
            }
        }
        return entries
    }

    // MARK: - branch / refs

    public struct HeadInfo: Equatable, Sendable {
        public let sha: String
        public let branch: String?       // nil = detached
        public let upstream: String?     // "origin/main"
        public let ahead: Int
        public let behind: Int
    }

    public func headInfo() -> HeadInfo? {
        headInfoResult().head
    }

    /// `headInfo()` variant that surfaces the wall-clock-timeout flag.
    /// `timedOut` is true iff EITHER underlying git call tripped the
    /// `statusTimeout`. The registry pairs this with
    /// `statusEntriesResult()` so a single timeout on either freezes the
    /// snapshot.
    public func headInfoResult() -> (head: HeadInfo?, timedOut: Bool) {
        let fs = "\u{1F}"
        let format = "--format=%(HEAD)\(fs)%(refname:short)\(fs)%(upstream:short)\(fs)%(upstream:track)"
        var timedOut = false
        guard let r = try? runResult(["for-each-ref", format, "--points-at=HEAD",
                                      "refs/heads/"]) else { return (nil, false) }
        timedOut = timedOut || r.timedOut
        let out = r.output
        let shaResult = try? runResult(["rev-parse", "--short", "HEAD"])
        timedOut = timedOut || (shaResult?.timedOut ?? false)
        let shaOut = (shaResult?.output)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: Character(fs), omittingEmptySubsequences: false)
            guard parts.count == 4, parts[0] == "*" else { continue }
            let branch = String(parts[1])
            let upstream = parts[2].isEmpty ? nil : String(parts[2])
            // "[ahead 3, behind 2]" → 3, 2
            var ahead = 0, behind = 0
            let track = parts[3]
            if let m = track.range(of: #"ahead (\d+)"#, options: .regularExpression) {
                ahead = Int(track[m].dropFirst("ahead ".count)) ?? 0
            }
            if let m = track.range(of: #"behind (\d+)"#, options: .regularExpression) {
                behind = Int(track[m].dropFirst("behind ".count)) ?? 0
            }
            return (HeadInfo(sha: shaOut, branch: branch, upstream: upstream,
                             ahead: ahead, behind: behind), timedOut)
        }
        // Detached HEAD or no matching branch.
        let head = shaOut.isEmpty
            ? nil
            : HeadInfo(sha: shaOut, branch: nil, upstream: nil, ahead: 0, behind: 0)
        return (head, timedOut)
    }

    // MARK: - repo / folder stats

    /// Scope for `repoStats(scope:)`. `.repo` aggregates the whole
    /// repository; `.folder(relativePath)` limits every aggregation to a
    /// subtree via a `-- <path>` pathspec (the sidebar root may be a
    /// *subdirectory* of the repo). The relative path is repo-root-
    /// relative and must not be absolute / start with `-` (option
    /// injection guard) — an unsafe path degrades to `.repo`.
    public enum RepoStatsScope: Equatable, Sendable {
        case repo
        case folder(relativePath: String)

        /// The trailing `["--", path]` pathspec for this scope, or `[]`
        /// for the whole-repo case. Returns `[]` (whole-repo) for an
        /// unsafe relative path rather than risking option injection.
        var pathspec: [String] {
            switch self {
            case .repo:
                return []
            case .folder(let rel):
                let trimmed = rel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("-"),
                      !trimmed.hasPrefix("/") else { return [] }
                return ["--", trimmed]
            }
        }
    }

    /// One author's contribution line from `git shortlog -sne`.
    public struct AuthorStat: Equatable, Sendable {
        public let name: String       // "Jane Doe"
        public let email: String      // "jane@example.com" (may be empty)
        public let commitCount: Int
        public init(name: String, email: String, commitCount: Int) {
            self.name = name; self.email = email; self.commitCount = commitCount
        }
    }

    /// One bucket of the tracked-file extension histogram.
    public struct ExtensionStat: Equatable, Sendable {
        public let ext: String        // lowercase, no dot; "" = no extension
        public let fileCount: Int
        public init(ext: String, fileCount: Int) {
            self.ext = ext; self.fileCount = fileCount
        }
    }

    /// Aggregated repo / folder statistics for the folder-stats card.
    /// All fields are best-effort: any sub-query that fails leaves its
    /// field at its zero/empty default rather than throwing, so a
    /// partial result still renders. `Sendable` so it crosses the
    /// `Task.detached` boundary as a single value (the `Payload` pattern).
    public struct RepoStats: Equatable, Sendable {
        public let scope: RepoStatsScope
        public let totalCommits: Int
        public let firstCommitDate: Date?
        public let lastCommitDate: Date?
        /// Author leaderboard, descending by commit count. Caller can
        /// take the top N for display.
        public let authors: [AuthorStat]
        /// Tracked-file extension histogram, descending by file count.
        public let extensions: [ExtensionStat]
        public let trackedFileCount: Int

        public init(
            scope: RepoStatsScope,
            totalCommits: Int,
            firstCommitDate: Date?,
            lastCommitDate: Date?,
            authors: [AuthorStat],
            extensions: [ExtensionStat],
            trackedFileCount: Int
        ) {
            self.scope = scope
            self.totalCommits = totalCommits
            self.firstCommitDate = firstCommitDate
            self.lastCommitDate = lastCommitDate
            self.authors = authors
            self.extensions = extensions
            self.trackedFileCount = trackedFileCount
        }
    }

    /// Aggregate commit / author / file statistics for `scope`. Composed
    /// of a few cheap-ish shell-outs, each on the existing `run()` rail
    /// (so the `statusTimeout` wall-clock cap, the env-allowlist, and the
    /// 512 MB output cap all apply). Designed to be called once, OFF the
    /// main actor (it walks history — seconds on a large monorepo), with
    /// the single `RepoStats` value handed back across the actor
    /// boundary.
    ///
    /// Note: `git count-objects` (on-disk repo size) is deliberately NOT
    /// computed here — it can be slow on huge packs and should be opt-in
    /// / lazy so it never blocks first paint of the card (triage perf
    /// note). Add it as a separate method if/when the UI wants it.
    public func repoStats(scope: RepoStatsScope = .repo) -> RepoStats {
        let pathspec = scope.pathspec

        // 1) Total commit count touching the scope.
        let countOut = (try? run(["rev-list", "--count", "HEAD"] + pathspec)) ?? ""
        let totalCommits = Int(countOut.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        // 2) First / last commit dates (%ct = committer unix time).
        //    `git log --format=%ct` newest-first; first line = last
        //    commit, last line = first commit.
        var firstDate: Date?
        var lastDate: Date?
        if let ctOut = try? run(["log", "--format=%ct"] + pathspec) {
            let stamps = ctOut
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let newest = stamps.first {
                lastDate = Date(timeIntervalSince1970: TimeInterval(newest))
            }
            if let oldest = stamps.last {
                firstDate = Date(timeIntervalSince1970: TimeInterval(oldest))
            }
        }

        // 3) Author leaderboard. `git shortlog -sne HEAD` requires
        //    reading commits from a non-interactive stdin-less context;
        //    `--no-pager` + our `GIT_PAGER=cat` env keeps it batch-safe.
        let shortlogOut = (try? run(["shortlog", "-sne", "HEAD"] + pathspec)) ?? ""
        let authors = Self.parseShortlog(shortlogOut)

        // 4) Tracked-file extension histogram via `git ls-files`.
        let lsOut = (try? run(["ls-files"] + (pathspec.isEmpty ? [] : [pathspec[1]]))) ?? ""
        let (exts, fileCount) = Self.parseExtensionHistogram(lsOut)

        return RepoStats(
            scope: scope,
            totalCommits: totalCommits,
            firstCommitDate: firstDate,
            lastCommitDate: lastDate,
            authors: authors,
            extensions: exts,
            trackedFileCount: fileCount
        )
    }

    /// Parse `git shortlog -sne` output. Each line is
    /// `   <count>\t<name> <<email>>`. Pure logic — public so tests can
    /// pin the parsing (leading whitespace, tab split, the `<email>`
    /// angle-bracket extraction, names containing spaces) without a real
    /// repo. Returns descending by count (shortlog already sorts, but we
    /// re-sort defensively).
    public static func parseShortlog(_ output: String) -> [AuthorStat] {
        var stats: [AuthorStat] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            // Split count from the rest on the first tab.
            let parts = line.split(separator: "\t", maxSplits: 1,
                                   omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let count = Int(parts[0].trimmingCharacters(in: .whitespaces))
            else { continue }
            var rest = String(parts[1]).trimmingCharacters(in: .whitespaces)
            var email = ""
            // Email is the last `<…>` token.
            if let lt = rest.range(of: "<", options: .backwards),
               let gt = rest.range(of: ">", options: .backwards),
               lt.upperBound <= gt.lowerBound {
                email = String(rest[lt.upperBound..<gt.lowerBound])
                rest = String(rest[..<lt.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }
            stats.append(AuthorStat(name: rest, email: email, commitCount: count))
        }
        return stats.sorted { $0.commitCount > $1.commitCount }
    }

    /// Bucket a newline-separated `git ls-files` listing into an
    /// extension histogram (lowercase, no dot; files with no extension
    /// bucket under `""`). Returns the histogram (descending by count)
    /// plus the total tracked-file count. Pure logic — public for tests.
    public static func parseExtensionHistogram(_ output: String) -> (histogram: [ExtensionStat], total: Int) {
        var counts: [String: Int] = [:]
        var total = 0
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let path = String(raw)
            total += 1
            // Last path component, then its extension.
            let name = path.split(separator: "/", omittingEmptySubsequences: false)
                .last.map(String.init) ?? path
            // A leading-dot dotfile ("..gitignore" style aside) has no
            // extension: ".gitignore" → bucket "" not "gitignore".
            let ext: String
            if let dot = name.range(of: ".", options: .backwards),
               dot.lowerBound != name.startIndex,
               dot.upperBound != name.endIndex {
                ext = String(name[dot.upperBound...]).lowercased()
            } else {
                ext = ""
            }
            counts[ext, default: 0] += 1
        }
        let histogram = counts
            .map { ExtensionStat(ext: $0.key, fileCount: $0.value) }
            .sorted {
                $0.fileCount != $1.fileCount
                    ? $0.fileCount > $1.fileCount
                    : $0.ext < $1.ext   // stable tiebreak for deterministic tests
            }
        return (histogram, total)
    }

    // MARK: - file-scoped diff (richer than `diff(forPath:)`)

    /// Unified diff for one path at a given commit (or HEAD by default).
    /// Uses histogram diff algorithm + ws-aware to match the panel spec.
    public func fileDiff(path: String, atCommit sha: String = "HEAD") -> String {
        (try? run([
            "diff", "--no-color",
            "--diff-algorithm=histogram",
            "\(sha)~", "\(sha)",
            "--", path,
        ])) ?? ""
    }

    /// Full unified diff for a commit (all files).
    public func commitDiff(sha: String) -> String {
        (try? run([
            "show", "--no-color",
            "--diff-algorithm=histogram",
            "--format=%H%n%an <%ae>%n%ad%n%n%s%n%n%b",
            sha,
        ])) ?? ""
    }

    /// Unified diff between two revisions for a single path. ONE method
    /// covers both File-History selection modes:
    ///   - **commit vs current**: `to == nil` → `git diff <from> -- <path>`
    ///     (compares the historical commit against the working tree).
    ///     Pass `to == "HEAD"` instead for "vs HEAD" rather than vs the
    ///     (possibly dirty) working tree.
    ///   - **commit vs commit**: `to == <sha>` → `git diff <from> <to> -- <path>`
    ///     (the Cmd-click two-commit range).
    ///
    /// Revisions should be full SHAs from `fileHistory(...).fullSHA` to
    /// avoid abbreviation collisions. Both `from` and `to` are validated
    /// not to begin with `-` so a malformed value can never be
    /// interpreted as a git option (defense-in-depth — the `--` already
    /// terminates option parsing before `path`, but the revisions sit
    /// *before* `--`). Returns `""` on validation failure or git error.
    public func diff(from: String, to: String? = nil, path: String) -> String {
        guard Self.isSafeRevision(from) else { return "" }
        if let to, !Self.isSafeRevision(to) { return "" }
        var args = ["diff", "--no-color", "--diff-algorithm=histogram", from]
        if let to { args.append(to) }
        args.append(contentsOf: ["--", path])
        return (try? run(args)) ?? ""
    }

    // MARK: - review (code-review v2)

    /// Unified diff for a `ReviewScope`, composing the existing diff
    /// primitives (CODE_REVIEW_V2_DESIGN_2026-06-01.md §4). One method
    /// covers all four scope modes; the caller passes the path it wants the
    /// diff for. Returns `""` on git error or an unsafe revision (matching
    /// the rest of the diff API's "empty on failure" contract).
    ///
    /// Note: `.commit` ignores `path` and returns the full multi-file
    /// `git show` diff (that's what `commitDiff` produces); the caller
    /// parses + filters by path via `DiffParser`. The other modes are
    /// per-path. This asymmetry matches the underlying primitives.
    public func diff(scope: ReviewScope, path: String) -> String {
        switch scope {
        case .workingTree(let base):
            guard Self.isSafeRevision(base) else { return "" }
            // Generalize `diff(forPath:)` (which hardcodes HEAD) to the
            // chosen base. `diff(from:to:path:)` with `to == nil` compares
            // the base against the working tree — exactly the working-tree
            // review semantics.
            return diff(from: base, to: nil, path: path)
        case .commit(let sha):
            guard Self.isSafeRevision(sha) else { return "" }
            return commitDiff(sha: sha)
        case .range(let from, let to):
            return diff(from: from, to: to, path: path)
        case .branch(let branch, let base):
            guard Self.isSafeRevision(branch) else { return "" }
            guard let mb = mergeBase(base, branch) else { return "" }
            return diff(from: mb, to: branch, path: path)
        }
    }

    /// `git merge-base <a> <b>` → the common ancestor SHA, or `nil` on
    /// failure / unsafe revision. Resolved ONCE and frozen into a branch
    /// review's `baseSha` so the review doesn't silently re-scope when the
    /// base branch advances (§4).
    public func mergeBase(_ a: String, _ b: String) -> String? {
        guard Self.isSafeRevision(a), Self.isSafeRevision(b) else { return nil }
        guard let out = try? run(["merge-base", a, b]) else { return nil }
        let sha = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// `git rev-parse <rev>` → the resolved object id, or `nil`. Used to
    /// freeze a scope's `baseSha`/`headSha` at review-creation time (§4).
    public func revParse(_ rev: String) -> String? {
        guard Self.isSafeRevision(rev) else { return nil }
        guard let out = try? run(["rev-parse", rev]) else { return nil }
        let sha = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Blob SHA of `path` at a committed revision: `git rev-parse <rev>:<path>`
    /// (§3.1). Exact and cheap. Returns `nil` on failure (path absent at that
    /// rev, unsafe revision, git error) → staleness degrades to `.unknown`.
    ///
    /// `path` is repo-relative, forward-slash, no leading `./` (the shape
    /// `DiffParser` / `ReviewComment.filePath` use). The `<rev>:<path>`
    /// gitrevision form is a single positional token, so it can't be an
    /// option-injection vector once `rev` is validated.
    public func blobSha(rev: String, path: String) -> String? {
        guard Self.isSafeRevision(rev), !path.isEmpty else { return nil }
        guard let out = try? run(["rev-parse", "\(rev):\(path)"]) else { return nil }
        let sha = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Content hash of `path`'s CURRENT bytes in the working tree:
    /// `git hash-object -- <path>` (§3.1). Used for the working-tree side,
    /// which has no commit to resolve a blob against. Returns `nil` on
    /// failure (file gone, unreadable, git error).
    ///
    /// `path` is repo-relative; `--` terminates option parsing so a path
    /// beginning with `-` can't be read as a flag.
    public func blobShaForWorktree(path: String) -> String? {
        guard !path.isEmpty else { return nil }
        guard let out = try? run(["hash-object", "--", path]) else { return nil }
        let sha = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// A revision token is safe to pass as a positional git arg iff it
    /// is non-empty and does not start with `-` (which git would parse
    /// as an option). We deliberately do NOT whitelist to hex only —
    /// `HEAD`, `HEAD~1`, branch names, and `tag:` refs are all legitimate
    /// revisions a caller may want — we only block the option-injection
    /// shape.
    private static func isSafeRevision(_ rev: String) -> Bool {
        !rev.isEmpty && !rev.hasPrefix("-")
    }

    // MARK: - private

    /// Per-invocation `-c` flags disabling config-driven RCE vectors —
    /// matches GitService.protectiveFlags. Hooks, fsmonitor, editor,
    /// pager are the historical surface for "open a repo, get pwned".
    private static let protectiveFlags: [String] = [
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.fsmonitor=false",
        "-c", "core.editor=true",
        "-c", "core.pager=cat",
        "-c", "protocol.file.allow=user",
        "-c", "core.quotePath=false",
    ]

    /// Candidate `git` locations, probed in order on first use
    /// (MAGIC-004). GUI-launched apps don't inherit a useful shell
    /// `$PATH`, so we can't rely on a bare `git` resolving — but
    /// hard-coding `/usr/bin/git` excludes the common Homebrew install
    /// (`/opt/homebrew/bin/git` on Apple Silicon, `/usr/local/bin/git`
    /// on Intel). Mirrors `JQRunner.binaryPath`'s probe approach.
    private static let gitProbePaths: [String] = [
        "/usr/bin/git",
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
    ]

    /// Resolved `git` path, or nil if none of the probes exist. Lazy +
    /// cached for the process lifetime (`isExecutableFile` is cheap but
    /// `run` is called frequently from UI flows). A new git install
    /// requires an app relaunch to pick up — acceptable for a viewer.
    private static let resolvedGitBinary: String? = gitProbePaths.first {
        FileManager.default.isExecutableFile(atPath: $0)
    }

    private func run(_ args: [String]) throws -> String {
        try runResult(args).output
    }

    /// `run(_:)` variant that surfaces the wall-clock-timeout flag.
    /// `output` is the drained stdout (possibly partial when
    /// `timedOut == true`); `timedOut` is true iff `statusTimeout` was
    /// set and the SIGTERM watchdog fired. Used by the registry's
    /// `*Result` methods so the store can distinguish "clean tree" from
    /// "timed out" and keep the prior snapshot rather than blanking
    /// badges.
    ///
    /// A timed-out git is terminated by SIGTERM, so it exits non-zero;
    /// we DON'T throw `processFailed` in that case — we return the
    /// partial output + `timedOut: true` and let the caller decide.
    private func runResult(_ args: [String]) throws -> (output: String, timedOut: Bool) {
        AuditLog.shared.record(
            .processSpawn, action: "git",
            target: args.first ?? "?",
            meta: ["repo": repoRoot.path])
        guard let bin = Self.resolvedGitBinary else {
            throw Error.gitNotFound
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.currentDirectoryURL = repoRoot
        p.arguments = Self.protectiveFlags + args
        // Don't inherit the parent's stdin. The app's stdin can be
        // pointed at arbitrary content (e.g., `mdv -` pipe mode);
        // git inheriting that would let a hostile config / hook prompt
        // for input that the caller never sees.
        p.standardInput = FileHandle.nullDevice
        // SEC-005: build git's env from a minimal allowlist rather than
        // overlaying onto the full parent env. Inheriting the parent
        // env leaks the app's environment (`*_TOKEN` / `*_SECRET` /
        // cloud creds) into a process that runs against untrusted repo
        // data, AND — worse — lets the *parent's* own `GIT_*` control
        // vars (`GIT_DIR`, `GIT_CONFIG_GLOBAL`, `GIT_SSH`,
        // `GIT_PROXY_COMMAND`, …) redirect where git reads config /
        // which helper it spawns. We never copy `GIT_*` from the
        // parent; we set only the four hardening overrides below atop a
        // bare `PATH` + `HOME`. `protocol.file.allow=user` and the
        // disabled editors / pagers already block the RCE-on-clone
        // vectors; this closes the env-injection side.
        let home = ProcessInfo.processInfo.environment["HOME"]
        var env: [String: String] = [
            // git needs to find its own subcommands / `ssh` / `cat`;
            // keep this minimal and fixed rather than user-controlled.
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_EDITOR": "/usr/bin/true",
            "GIT_PAGER": "cat",
            "GIT_OPTIONAL_LOCKS": "0",
        ]
        // HOME is required for git to resolve `~/.gitconfig`; without it
        // git falls back to `/` and can emit noisy warnings. We pass the
        // real HOME but explicitly nothing else from the parent.
        if let home { env["HOME"] = home }
        p.environment = env
        // Drain both pipes concurrently via the shared `ProcessRunner`
        // (H, 2026-05-25). `git log` / `git diff` easily produce >64 KB;
        // a sequential read after exit would deadlock on the pipe-
        // buffer cap.
        //
        // Resource caps (S, 2026-05-29). `git log` on a large repo
        // can legitimately take 30s+ of CPU on cold cache; we set a
        // 120s CPU cap so honest operations are not regressed while a
        // wedged `git log --all --reflog` style runaway still gets
        // SIGXCPU'd. The wall-clock `statusTimeout` (when set by the
        // registry) is the responsiveness guarantee on top of that —
        // see the property doc. When `nil` we keep the historical
        // behavior: a slow `git status` surfaces as "still working",
        // not a hard truncation. File-size cap is generous (1 GB worth
        // of 512-byte blocks) so legitimate `git archive | tee` style
        // ops on large repos still succeed; open-file cap is loose
        // because git's pack reader opens many fds.
        let limits = ProcessRunner.ResourceLimits(
            cpuSeconds: 120,
            fileSizeBlocks: 2_097_152,  // ~1 GB
            openFiles: 4096
        )
        // SCALE-2/CR-05: cap buffered output at 512 MB. A pathological
        // `git log --all -p` on a huge repo (or a hostile repo crafted
        // to emit gigabytes) would otherwise be read fully into memory
        // here. 512 MB is well past any honest viewer-side git read; on
        // overflow the child is SIGTERM'd (→SIGKILL) and `truncated` is
        // surfaced below as a process failure rather than an OOM.
        // The registry's `statusTimeout` (when set) layers a wall-clock
        // bound on top, surfaced via `timedOut` below.
        let result = try ProcessRunner.run(
            p, timeout: statusTimeout, limits: limits, maxOutputBytes: 512 * 1024 * 1024
        )
        if result.truncated {
            throw Error.processFailed(
                result.terminationStatus,
                "git output exceeded the \(512)MB cap and was truncated"
            )
        }
        let out = String(data: result.stdout, encoding: .utf8) ?? ""
        // A timed-out git was SIGTERM'd → non-zero exit, but that's a
        // timeout, not a "not a repo" / hard error. Surface it via the
        // flag and return whatever partial output we drained; the caller
        // (registry) keeps its prior snapshot instead of blanking.
        if result.timedOut {
            return (out, true)
        }
        if result.terminationStatus != 0 {
            let estr = String(data: result.stderr, encoding: .utf8) ?? ""
            if estr.lowercased().contains("not a git repository") {
                throw Error.notARepo
            }
            throw Error.processFailed(
                result.terminationStatus,
                estr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return (out, false)
    }
}
