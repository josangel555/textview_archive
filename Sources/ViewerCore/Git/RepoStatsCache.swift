import Foundation

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

    private var entries: [Key: Entry] = [:]

    public init() {}

    /// Return cached stats for `(repoRoot, scope)` if the repo's current
    /// HEAD matches the cached one; otherwise (re)compute and cache.
    ///
    /// The HEAD probe (`headInfo().sha`) is itself a cheap git call on
    /// the same `statusTimeout`-bounded rail. If HEAD can't be read
    /// (not a repo / detached with no commits), we fall through to a
    /// fresh compute and DON'T cache (empty `headSHA` would never match,
    /// so caching it is pointless and would mask a later real HEAD).
    public func stats(
        repoRoot: URL,
        scope: GitClient.RepoStatsScope = .repo,
        statusTimeout: TimeInterval? = nil
    ) -> GitClient.RepoStats {
        let client = GitClient(repoRoot: repoRoot, statusTimeout: statusTimeout)
        let key = Key(repoPath: repoRoot.standardizedFileURL.path,
                      scope: ScopeKey(scope))
        let head = client.headInfo()?.sha ?? ""

        if !head.isEmpty, let cached = entries[key], cached.headSHA == head {
            return cached.stats
        }
        let fresh = client.repoStats(scope: scope)
        if !head.isEmpty {
            entries[key] = Entry(headSHA: head, stats: fresh)
        }
        return fresh
    }

    /// Drop everything (e.g. on repo-root change in the UI). Cheap; the
    /// next `stats(...)` recomputes lazily.
    public func invalidateAll() {
        entries.removeAll()
    }

    /// Drop the cache for one repo (all scopes).
    public func invalidate(repoRoot: URL) {
        let path = repoRoot.standardizedFileURL.path
        entries = entries.filter { $0.key.repoPath != path }
    }
}
