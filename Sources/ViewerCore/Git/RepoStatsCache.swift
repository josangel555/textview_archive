import Foundation

/// Abstraction over the two blocking git probes `RepoStatsCache` needs:
/// the current HEAD sha (cache key) and the aggregate `RepoStats` walk.
///
/// Extracted so the cache can be host-tested without spawning real git
/// (inject a fake/slow provider) and so the blocking work has one place
/// to be off-loaded. Conformers MUST be `Sendable` — the cache hops the
/// provider onto a `Task.detached` (off the actor's serial executor), so
/// it crosses an isolation boundary. Both methods are blocking +
/// best-effort (return a zero/empty result rather than throwing) to match
/// `GitClient`'s existing contract.
public protocol RepoStatsProviding: Sendable {
    /// The repo's current short HEAD sha, or "" if it can't be read
    /// (not a repo / no commits). Cheap-ish git call.
    func headSHA(repoRoot: URL, statusTimeout: TimeInterval?) -> String

    /// Aggregate commit/author/file statistics for `scope`. Walks
    /// history — seconds on a large monorepo — hence off-actor.
    func repoStats(
        repoRoot: URL,
        scope: GitClient.RepoStatsScope,
        statusTimeout: TimeInterval?
    ) -> GitClient.RepoStats
}

/// Production provider: drives the real `GitClient` shell-outs.
public struct GitClientStatsProvider: RepoStatsProviding {
    public init() {}

    public func headSHA(repoRoot: URL, statusTimeout: TimeInterval?) -> String {
        GitClient(repoRoot: repoRoot, statusTimeout: statusTimeout)
            .headInfo()?.sha ?? ""
    }

    public func repoStats(
        repoRoot: URL,
        scope: GitClient.RepoStatsScope,
        statusTimeout: TimeInterval?
    ) -> GitClient.RepoStats {
        GitClient(repoRoot: repoRoot, statusTimeout: statusTimeout)
            .repoStats(scope: scope)
    }
}

/// HEAD-invalidated cache in front of `GitClient.repoStats(scope:)`.
///
/// `repoStats` walks the whole history (`rev-list --count`,
/// `shortlog -sne`) — seconds on a large monorepo — so it must run off
/// the main actor AND be cached aggressively: history changes rarely.
/// The right invalidation key is the repo's HEAD sha, not a timer
/// (triage perf note): the aggregates only move when a commit lands.
///
/// This is an `actor` (not a `Sendable` class with a lock) so callers
/// `await` it from the off-main `Task.detached` the UI already uses for
/// git work. It is Foundation-only and holds no SwiftUI/AppKit types,
/// per the ViewerCore layering rule.
///
/// **Off-actor walks + in-flight coalescing (TSK-970).** The HEAD probe
/// and history walk are *blocking*; running them inline on the actor's
/// serial executor head-of-line-blocks EVERY other `stats()`/`invalidate*`
/// call for the multiple seconds a monorepo walk takes. So we hop the
/// blocking work onto a `Task.detached` (mirrors `TrackedReposStore.refresh`),
/// `await`-ing its `.value` — the actor is re-entered only to read/store
/// the cache, leaving its executor free to interleave other methods.
/// Concurrent `stats(...)` for the SAME key share ONE walk via an
/// `inFlight` table keyed by `(repoPath, scope)`: a second caller awaits
/// the already-running `Task` instead of spawning a duplicate walk. Without
/// this, N `FolderStatsView` instances over one repo would serialize N
/// multi-second walks.
///
/// Usage (UI side):
/// ```
/// let stats = await cache.stats(repoRoot: root, scope: .folder(...))
/// ```
/// The cache is keyed by `(repoRoot, scope)`; a HEAD change for that key
/// recomputes, a HEAD match returns the cached value. Different scopes
/// of the same repo cache independently.
public actor RepoStatsCache {

    private struct Key: Hashable {
        let repoPath: String
        let scope: ScopeKey
    }

    /// `RepoStatsScope` isn't `Hashable` (it carries a `String`
    /// associated value but we don't want to widen its public API for
    /// the cache), so we project it to a hashable token here.
    private enum ScopeKey: Hashable {
        case repo
        case folder(String)

        init(_ scope: GitClient.RepoStatsScope) {
            switch scope {
            case .repo: self = .repo
            case .folder(let rel): self = .folder(rel)
            }
        }
    }

    private struct Entry {
        let headSHA: String      // the HEAD the cached stats were computed at
        let stats: GitClient.RepoStats
    }

    private let provider: RepoStatsProviding
    private var entries: [Key: Entry] = [:]

    /// One coalesced off-actor load: HEAD probe + the (conditional)
    /// history walk. `cacheHit == true` means the HEAD matched the
    /// snapshot passed in and `stats` is the cached value (no walk ran).
    private struct Load: Sendable {
        let headSHA: String
        let stats: GitClient.RepoStats
        let cacheHit: Bool
    }

    /// In-flight loads keyed by `(repoPath, scope)`. A concurrent
    /// `stats(...)` for a key already present awaits the existing task
    /// rather than launching a duplicate off-actor probe+walk; the slot
    /// is cleared when the task completes. Coalescing the WHOLE load (not
    /// just the walk) means the underlying provider — both `headSHA` and
    /// the expensive `repoStats` — is invoked exactly once per group.
    private var inFlight: [Key: Task<Load, Never>] = [:]

    public init(provider: RepoStatsProviding = GitClientStatsProvider()) {
        self.provider = provider
    }

    /// Return cached stats for `(repoRoot, scope)` if the repo's current
    /// HEAD matches the cached one; otherwise (re)compute and cache.
    ///
    /// The blocking HEAD probe + history walk run on a `Task.detached`,
    /// so the actor's executor is free for other `stats()`/`invalidate*`
    /// calls while git runs. Concurrent calls for the same key coalesce
    /// onto ONE in-flight walk (see `inFlight`).
    ///
    /// If HEAD can't be read (not a repo / detached with no commits), we
    /// fall through to a fresh compute and DON'T cache (empty `headSHA`
    /// would never match, so caching it is pointless and would mask a
    /// later real HEAD).
    public func stats(
        repoRoot: URL,
        scope: GitClient.RepoStatsScope = .repo,
        statusTimeout: TimeInterval? = nil
    ) async -> GitClient.RepoStats {
        let key = Key(repoPath: repoRoot.standardizedFileURL.path,
                      scope: ScopeKey(scope))

        // Coalesce: if an identical load is already running, await it
        // instead of spawning a duplicate probe+walk.
        if let existing = inFlight[key] {
            return await existing.value.stats
        }

        // Snapshot the cached entry (if any) so the off-actor task can
        // short-circuit the history walk on a HEAD match. Captured by
        // value — the task never touches actor state.
        let cached = entries[key]
        let provider = self.provider

        // The HEAD probe AND the (conditional) history walk are blocking,
        // so the whole thing runs on a detached task — the actor's
        // executor stays free for other methods while git runs. Registered
        // in `inFlight` so concurrent callers share this one load.
        let load = Task.detached(priority: .userInitiated) { () -> Load in
            let head = provider.headSHA(repoRoot: repoRoot, statusTimeout: statusTimeout)
            if !head.isEmpty, let cached, cached.headSHA == head {
                return Load(headSHA: head, stats: cached.stats, cacheHit: true)
            }
            let fresh = provider.repoStats(repoRoot: repoRoot, scope: scope, statusTimeout: statusTimeout)
            return Load(headSHA: head, stats: fresh, cacheHit: false)
        }
        inFlight[key] = load

        let result = await load.value
        inFlight[key] = nil

        // Persist a freshly-walked result (skip empty HEAD: it would never
        // match, so caching it is pointless and masks a later real HEAD).
        if !result.cacheHit, !result.headSHA.isEmpty {
            entries[key] = Entry(headSHA: result.headSHA, stats: result.stats)
        }
        return result.stats
    }

    /// Drop everything (e.g. on repo-root change in the UI). Cheap; the
    /// next `stats(...)` recomputes lazily. Does not cancel in-flight
    /// walks — they simply won't repopulate a dropped slot any more than a
    /// fresh call would (the entry write races the clear, but a stale
    /// entry self-heals on the next HEAD-mismatch).
    public func invalidateAll() {
        entries.removeAll()
    }

    /// Drop the cache for one repo (all scopes).
    public func invalidate(repoRoot: URL) {
        let path = repoRoot.standardizedFileURL.path
        entries = entries.filter { $0.key.repoPath != path }
    }
}
