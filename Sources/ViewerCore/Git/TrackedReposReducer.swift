import Foundation

/// Pure policy for the demand-driven multi-repo git model. **No state,
/// no I/O beyond a `.git` stat-walk.** Every set-membership / eviction /
/// resolution decision lives here so it can be exercised under
/// `ViewerCoreTests` with temp-dir git fixtures — no `@MainActor`, no
/// FSEvents stream, no live git process.
///
/// Design (canonical): this is the testable heart of the registry. The
/// off-main `TrackedReposStore` actor and the `@MainActor`
/// `TrackedReposChannel` both call into here so the write-side (store)
/// and read-side (channel) cannot drift on the one thing that must
/// stay byte-identical: URL normalization (`normalize(_:)`).
public enum TrackedReposReducer {

    // MARK: - Normalization (the single source of truth)

    /// Canonical key form for every URL the registry stores or looks
    /// up. Centralized here so the store's write-side keys and the
    /// channel's read-side lookups are guaranteed to agree even for
    /// symlinked or non-standardized inputs.
    ///
    /// `.standardizedFileURL` collapses `..`/`.`; `resolvingSymlinksInPath`
    /// canonicalizes through symlinks (e.g. `/var` → `/private/var` on
    /// macOS, which bites `FileManager.temporaryDirectory` test scratch).
    ///
    /// We then RECONSTRUCT the URL from the resolved `.path`. Two URLs
    /// can have an equal `.path` yet compare unequal as `URL` values
    /// (different base/relative internal representation, trailing-slash
    /// directory bit) — a footgun when these are dictionary KEYS. A path
    /// walk (`deletingLastPathComponent`) and an `appendingPathComponent`
    /// build of the same directory must hash + compare identically, so
    /// we canonicalize to a single representation here.
    public static func normalize(_ url: URL) -> URL {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        return URL(fileURLWithPath: resolved.path)
    }

    // MARK: - Root resolution

    /// Innermost enclosing git repo root for a file/folder URL, or nil
    /// if none. Wraps `GitClient.discoverRoot`, but takes an
    /// `isDirectory` flag so a FILE walks from its parent directory and
    /// a FOLDER walks from itself.
    ///
    /// "Innermost wins" falls out of `discoverRoot` stopping at the
    /// FIRST ancestor with a `.git` (dir OR file — a submodule/worktree
    /// `.git` file stops the walk correctly). Outer `git status`
    /// excludes nested-repo files by git's own behavior, so mapping a
    /// file to its innermost root IS the no-double-coloring resolution.
    public static func resolveRoot(for url: URL, isDirectory: Bool) -> URL? {
        let start = isDirectory ? url : url.deletingLastPathComponent()
        guard let root = GitClient.discoverRoot(from: start) else { return nil }
        return normalize(root)
    }

    // MARK: - Demand set

    /// Map every demand source to the innermost enclosing repo and
    /// accumulate a refcount per normalized root. Pure (only `.git`
    /// stat-walks via `resolveRoot`).
    ///
    /// Contributors (each +1 to its innermost root):
    ///   - every open tab URL (a file)
    ///   - the split pane URL, if any (a file)
    ///   - the sidebar folder (a directory) — selected node or root
    ///   - every pinned root (already a directory; contributes itself
    ///     when it is a repo root, else its enclosing repo)
    ///
    /// A repo is "live" while its refcount ≥ 1. Switching tabs *within*
    /// one repo leaves the map unchanged → the caller's churn guard #1
    /// sees `desired == previous` and does nothing.
    public static func desiredRepoSet(
        tabURLs: [URL],
        splitURL: URL?,
        sidebarFolder: URL?,
        pinned: Set<URL>
    ) -> [URL: Int] {
        var counts: [URL: Int] = [:]
        func bump(_ url: URL?, isDirectory: Bool) {
            guard let url, let root = resolveRoot(for: url, isDirectory: isDirectory) else { return }
            counts[root, default: 0] += 1
        }
        for tab in tabURLs { bump(tab, isDirectory: false) }
        bump(splitURL, isDirectory: false)
        bump(sidebarFolder, isDirectory: true)
        // Pinned roots are directories. A pin on a non-repo folder
        // resolves to its enclosing repo (so "pin this monorepo subdir"
        // keeps the enclosing repo tracked). A pin on an actual repo
        // root resolves to itself.
        for p in pinned { bump(p, isDirectory: true) }
        return counts
    }

    // MARK: - Eviction

    /// Deterministic eviction plan. Mirrors `HighlightCacheActor.prune`:
    /// insertion-ordered, drops down to ~2/3 capacity in one batch so we
    /// don't churn eviction on every insert.
    ///
    /// Returns:
    ///   - `drop`: roots to fully evict (drop snapshot + stop watcher).
    ///   - `keepStaleWatcherless`: referenced roots over cap whose
    ///     watcher we stop to bound FSEvents fan-out, but whose snapshot
    ///     we KEEP (correctness > memory — never blank a referenced
    ///     repo's badges). Frozen at last-known; refetched on next nav.
    ///
    /// Invariants:
    ///   - A root with refcount ≥ 1 is NEVER in `drop`.
    ///   - A pinned root is NEVER in `drop` and NEVER stale-watcherless.
    ///   - Only zero-ref roots past the grace window (or past the
    ///     grace-slot count) are dropped; ties broken by `lruOrder`
    ///     (oldest first).
    ///
    /// - Parameters:
    ///   - refcounts: live demand counts per root.
    ///   - zeroRefSince: when each currently-zero-ref root hit zero.
    ///   - lruOrder: insertion / touch order, oldest first.
    ///   - pinned: never-evicted roots.
    ///   - now: clock (injected for tests).
    ///   - graceWindow: zero-ref roots older than this are eligible.
    ///   - cap: hard cap on tracked roots (live + grace).
    ///   - graceSlots: max zero-ref roots kept within the window.
    public static func evictionPlan(
        refcounts: [URL: Int],
        zeroRefSince: [URL: Date],
        lruOrder: [URL],
        pinned: Set<URL>,
        now: Date,
        graceWindow: TimeInterval,
        cap: Int,
        graceSlots: Int
    ) -> (drop: [URL], keepStaleWatcherless: [URL]) {
        let pinnedNorm = Set(pinned.map(normalize))
        func isLive(_ r: URL) -> Bool { (refcounts[r] ?? 0) >= 1 }
        func isPinned(_ r: URL) -> Bool { pinnedNorm.contains(r) }

        // All known roots, in deterministic (LRU) order.
        var ordered = lruOrder
        // Defensive: include any root present in refcounts/zeroRefSince
        // but missing from lruOrder, appended deterministically.
        let known = Set(lruOrder)
        for r in refcounts.keys.sorted(by: { $0.path < $1.path })
        where !known.contains(r) { ordered.append(r) }
        for r in zeroRefSince.keys.sorted(by: { $0.path < $1.path })
        where !known.contains(r) && !ordered.contains(r) { ordered.append(r) }

        var drop: [URL] = []
        var dropped = Set<URL>()

        // --- Phase 1: grace expiry + grace-slot overflow ---
        // Zero-ref, non-pinned roots whose grace window has elapsed are
        // dropped outright. Among those still within the window, keep at
        // most `graceSlots` (oldest-first eviction beyond that).
        let zeroRefOrdered = ordered.filter {
            !isLive($0) && !isPinned($0) && zeroRefSince[$0] != nil
        }
        var survivingZeroRef: [URL] = []
        for r in zeroRefOrdered {
            let since = zeroRefSince[r]!
            if now.timeIntervalSince(since) >= graceWindow {
                drop.append(r); dropped.insert(r)
            } else {
                survivingZeroRef.append(r)
            }
        }
        // survivingZeroRef is oldest-first (it preserves `ordered`).
        // Keep the newest `graceSlots`, drop the older overflow.
        if survivingZeroRef.count > graceSlots {
            let overflow = survivingZeroRef.count - graceSlots
            for r in survivingZeroRef.prefix(overflow) {
                drop.append(r); dropped.insert(r)
            }
        }

        // --- Phase 2: hard cap ---
        // After phase 1, count what remains. If still over cap, drop the
        // oldest remaining zero-ref roots first; if none remain and we're
        // still over cap, the overage is all live/pinned — those become
        // `keepStaleWatcherless` (watcher stopped, snapshot kept).
        var remaining = ordered.filter { !dropped.contains($0) }
        if remaining.count > cap {
            // Oldest-first zero-ref roots still standing.
            let evictable = remaining.filter {
                !isLive($0) && !isPinned($0)
            }
            for r in evictable {
                guard remaining.count > cap else { break }
                drop.append(r); dropped.insert(r)
                remaining.removeAll { $0 == r }
            }
        }
        var keepStaleWatcherless: [URL] = []
        if remaining.count > cap {
            // Everything left is live or pinned. Bound watcher fan-out
            // by freezing the oldest *non-pinned* live roots. Pinned
            // roots are last to lose their watcher.
            let overage = remaining.count - cap
            let freezeCandidates = remaining.filter { !isPinned($0) }
            for r in freezeCandidates.prefix(overage) {
                keepStaleWatcherless.append(r)
            }
        }

        return (drop, keepStaleWatcherless)
    }

    // MARK: - FSEvents dir → tracked root

    /// Map an FSEvents-reported changed directory to the enclosing
    /// tracked root via prefix match against the bounded tracked set.
    /// Returns the LONGEST matching root (innermost wins for nested
    /// tracked repos). nil if the dir is under no tracked root.
    ///
    /// Cheap: a prefix scan over ≤ `cap` roots, no stat, no git.
    public static func trackedRoot(enclosing dir: URL, trackedRoots: [URL]) -> URL? {
        let d = normalize(dir).path
        var best: URL?
        var bestLen = -1
        for root in trackedRoots {
            let rp = normalize(root).path
            // Exact match or a `rp/`-prefixed descendant.
            if d == rp || d.hasPrefix(rp.hasSuffix("/") ? rp : rp + "/") {
                if rp.count > bestLen {
                    bestLen = rp.count
                    best = root
                }
            }
        }
        return best
    }

    // MARK: - .git event-storm filter

    /// `.git`-internal noise filter for an FSEvents-resolved changed
    /// path. `true` = refresh-worthy (status/HEAD may have changed).
    ///
    /// Keep:
    ///   - any worktree file (outside `.git/`)
    ///   - `.git/HEAD`            (branch switch / detach)
    ///   - `.git/index`           (stage / unstage / checkout)
    ///   - `.git/refs/**`         (commit / branch / tag moves)
    ///   - `.git/packed-refs`     (ref compaction touches branch tips)
    ///   - `.git/MERGE_HEAD`,`ORIG_HEAD` etc. (merge/rebase state)
    /// Drop:
    ///   - `.git/objects/**`      (a `git gc`/`fetch` writes thousands)
    ///   - `.git/lfs/**`          (LFS object churn)
    ///   - any `*.lock`           (our own writes + git's own locks)
    ///
    /// The drop set is the feedback-loop guard: without it, `git fetch`/
    /// `gc` writing object files — or our own `git status` touching
    /// index-adjacent lock state — feeds a refresh→refresh storm.
    public static func isRefreshWorthy(changedPath: String, repoRoot: URL) -> Bool {
        let rootPath = normalize(repoRoot).path
        let path = normalize(URL(fileURLWithPath: changedPath)).path

        // Lock files are never worthy regardless of location.
        if path.hasSuffix(".lock") { return false }

        let gitDir = rootPath.hasSuffix("/") ? rootPath + ".git" : rootPath + "/.git"
        // Worktree change (outside `.git/`): always worthy.
        if path != gitDir && !path.hasPrefix(gitDir + "/") {
            return true
        }
        // Inside `.git/`. The `.git` dir/file itself (e.g. a submodule
        // `.git` FILE rewrite) is worthy.
        if path == gitDir { return true }

        let rel = String(path.dropFirst((gitDir + "/").count))
        // Noisy interior: object/LFS churn.
        if rel.hasPrefix("objects/") || rel == "objects" { return false }
        if rel.hasPrefix("lfs/") || rel == "lfs" { return false }

        // Status/HEAD-affecting interior files.
        if rel == "HEAD" || rel == "index" || rel == "packed-refs" { return true }
        if rel.hasPrefix("refs/") { return true }
        // Merge/rebase/cherry-pick state pseudo-refs that move HEAD.
        let stateFiles: Set<String> = [
            "MERGE_HEAD", "ORIG_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD",
            "FETCH_HEAD", "REBASE_HEAD",
        ]
        if stateFiles.contains(rel) { return true }
        // Everything else in `.git/` (logs/, config, hooks/, COMMIT_EDITMSG,
        // sequencer/, rebase-merge/ internals…) is not status-worthy on
        // its own — the HEAD/index/refs writes that accompany the real
        // state change already cover us.
        return false
    }

    /// True iff the changed path indicates a `.git` create/delete at the
    /// directory level — i.e. a freshly `git init`'d folder or a
    /// `rm -rf .git`. Used to invalidate the `discoverRoot` memo +
    /// `isRepoRoot` cache so a new/removed repo is (re)discovered.
    public static func touchesDotGitExistence(changedPath: String) -> Bool {
        let last = URL(fileURLWithPath: changedPath).lastPathComponent
        return last == ".git"
    }
}
