import Foundation

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

    public enum Error: Swift.Error, CustomStringConvertible {
        case gitNotFound
        case notARepo
        case processFailed(Int32, String)
        public var description: String {
            switch self {
            case .gitNotFound:           return "/usr/bin/git not available"
            case .notARepo:              return "Not a git repository"
            case .processFailed(let c, let msg):
                return "git exited \(c): \(msg)"
            }
        }
    }

    public init(repoRoot: URL) {
        self.repoRoot = repoRoot
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

    // MARK: - diff

    /// `git diff HEAD -- <path>` for unified-diff text.
    public func diff(forPath path: String) -> String {
        (try? run(["diff", "--no-color", "HEAD", "--", path])) ?? ""
    }

    // MARK: - log

    public struct LogEntry: Equatable, Sendable {
        public let sha: String        // short SHA
        public let author: String
        public let date: String       // ISO-ish from %ad
        public let subject: String
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

    public func graphLog(maxEntries: Int = 100, skip: Int = 0) -> [GraphCommit] {
        // Record sep + field sep so commit subjects (which may contain
        // newlines) round-trip.
        let rs = "\u{1E}"  // record separator
        let fs = "\u{1F}"  // unit separator
        let format = "--pretty=format:\(rs)%h\(fs)%p\(fs)%an\(fs)%ct\(fs)%d\(fs)%s"
        let args = [
            "log", "--topo-order", "--shortstat", format,
            "-n", "\(maxEntries)", "--skip", "\(skip)",
        ]
        guard let out = try? run(args) else { return [] }
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
        let fs = "\u{1F}"
        let format = "--format=%(HEAD)\(fs)%(refname:short)\(fs)%(upstream:short)\(fs)%(upstream:track)"
        guard let out = try? run(["for-each-ref", format, "--points-at=HEAD",
                                  "refs/heads/"]) else { return nil }
        let shaOut = (try? run(["rev-parse", "--short", "HEAD"]))?
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
            return HeadInfo(sha: shaOut, branch: branch, upstream: upstream,
                            ahead: ahead, behind: behind)
        }
        // Detached HEAD or no matching branch.
        return shaOut.isEmpty
            ? nil
            : HeadInfo(sha: shaOut, branch: nil, upstream: nil, ahead: 0, behind: 0)
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

    private func run(_ args: [String]) throws -> String {
        let bin = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            throw Error.gitNotFound
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.currentDirectoryURL = repoRoot
        p.arguments = Self.protectiveFlags + args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        // Don't inherit the parent's stdin. The app's stdin can be
        // pointed at arbitrary content (e.g., `mdv -` pipe mode);
        // git inheriting that would let a hostile config / hook prompt
        // for input that the caller never sees.
        p.standardInput = FileHandle.nullDevice
        // Defense against malicious repo configs: never honor a
        // .git/config from the working tree. `safe.directory = *` skips
        // the safety prompt only; `protocol.file.allow=user` and
        // disabling external editors / pagers blocks the common
        // RCE-on-clone vectors. We treat repos as untrusted data.
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "/usr/bin/true"
        env["GIT_PAGER"] = "cat"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        p.environment = env
        // Drain both pipes concurrently with `git`'s run. `git log`,
        // `git diff`, and friends easily produce >64 KB; if we waited
        // for exit before reading, `git` would block writing into a
        // full pipe (kernel buffer is ~64 KB) and `waitUntilExit()`
        // would hang forever. Same shape as GitService.run() and
        // JQRunner.run().
        //
        // S4.4 (2026-05-25): the captured vars used to be plain `var
        // outData = Data()` mutated from escaping closures. Swift 6
        // strict-concurrency tolerates that today only because
        // DispatchQueue.async closures aren't `@Sendable`-marked;
        // align with the `_Box` pattern from JQRunner + GitService so
        // a future refactor doesn't reintroduce the race.
        final class _DataBox: @unchecked Sendable { var data = Data() }
        let outBox = _DataBox()
        let errBox = _DataBox()
        let outQ = DispatchQueue(label: "gitclient.stdout")
        let errQ = DispatchQueue(label: "gitclient.stderr")
        let group = DispatchGroup()
        group.enter()
        outQ.async {
            outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        errQ.async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        try p.run()
        p.waitUntilExit()
        group.wait()
        let out = String(data: outBox.data, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            let estr = String(data: errBox.data, encoding: .utf8) ?? ""
            if estr.lowercased().contains("not a git repository") {
                throw Error.notARepo
            }
            throw Error.processFailed(p.terminationStatus, estr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }
}
