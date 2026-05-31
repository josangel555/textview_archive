import Foundation
import SwiftUI
import ViewerCore

/// Repo-root classification for a directory row, driven by a cheap
/// `.git`-existence stat (NOT git status). `.repo` = a top-level repo
/// root; `.nested` = a repo root that is itself inside another repo
/// (submodule / nested worktree); `.none` = an ordinary folder.
public enum RepoRootKind: Equatable, Sendable {
    case none
    case repo
    case nested
}

/// THE observation surface for the multi-repo git registry. Held by
/// `DocumentModel` as `public let trackedRepos`. Mirrors
/// `HighlightCacheActor` exactly: ONE `@Published` (`version`), all
/// consumer reads synchronous (safe from a SwiftUI `body`), the heavy
/// work + cache owned by the off-main `TrackedReposStore` actor.
///
/// Views (SidebarView, GitPanelView) observe THIS object directly via
/// `@ObservedObject`. They must NEVER forward `channel.objectWillChange`
/// into `DocumentModel.objectWillChange` — that would re-introduce the
/// republish storm, now amplified by FSEvents firing on every external
/// write across multiple repos. `TrackedReposRepublishInvariantTests`
/// pins this as acceptance criteria.
///
/// Why two objects (this + the store actor) not one: a Swift `actor`
/// can't be `@MainActor`-observed cheaply, and SwiftUI bodies need sync
/// reads. The actor owns cache + git off-main (host-testable); this is
/// the thin sync mirror + version tick.
@MainActor
public final class TrackedReposChannel: ObservableObject {

    /// The ONLY published property. Monotonic; SwiftUI re-evals
    /// observers on each bump and they re-read via the sync accessors.
    /// `&+=` so wraparound is safe (SwiftUI diffs by inequality).
    @Published public private(set) var version: UInt64 = 0

    private let store: TrackedReposStore

    /// Main-actor mirror of the store's snapshots. Read synchronously by
    /// `status(for:)` etc. Refreshed via `applyMirror` after the store
    /// changes.
    private var snapshot: [URL: TrackedReposStore.RepoSnapshot] = [:]

    /// Tracked roots in LRU order (for the panel picker / section
    /// visibility). Mirrored alongside `snapshot`.
    public private(set) var trackedRoots: [URL] = []

    /// Read-side normalizer cache (moved from SidebarModel). Bounded —
    /// sidebar churns row URLs as it scrolls, but the visible set +
    /// recently-scrolled-out is bounded.
    private var normCache: [URL: URL] = [:]

    /// `dir → .git exists` cache. One stat per visible dir row,
    /// invalidated on an FSEvents touch of that dir. Bounded. NEVER
    /// spawns git.
    private var rootIconCache: [URL: Bool] = [:]

    private static let cacheCap = 2048

    public init(store: TrackedReposStore) {
        self.store = store
    }

    // MARK: - Consumer reads (all synchronous, safe from SwiftUI body)

    /// Status for a file URL, resolving its enclosing tracked repo. nil
    /// = clean / untracked-by-registry / not in any tracked repo.
    ///
    /// Multi-repo by construction: a file in repo A and a file in repo B
    /// each resolve to their own snapshot; A's refresh cannot affect B's
    /// entries (separate per-root snapshots).
    public func status(for fileURL: URL) -> GitStatusEntry.Status? {
        let url = norm(fileURL)
        guard let root = repoRoot(enclosing: url) else { return nil }
        return snapshot[root]?.statuses[url]
    }

    /// Innermost tracked repo root enclosing `fileURL`, via prefix match
    /// against the bounded tracked set. nil if under no tracked root.
    /// Cheap (no stat / no git) — pure prefix scan over ≤ cap roots.
    public func repoRoot(enclosing fileURL: URL) -> URL? {
        TrackedReposReducer.trackedRoot(
            enclosing: norm(fileURL), trackedRoots: trackedRoots
        )
    }

    public func snapshot(forRoot root: URL) -> TrackedReposStore.RepoSnapshot? {
        snapshot[norm(root)]
    }

    /// True iff `dir` is currently a tracked (active) repo root. Drives
    /// the sidebar's "this repo is live in the tracked set" treatment.
    public func isTrackedRoot(_ dir: URL) -> Bool {
        snapshot[norm(dir)] != nil
    }

    /// Cheap bounded-cached `.git`-existence stat for a directory row.
    /// NOT git status — a single `FileManager.fileExists` per visible
    /// dir, memoized, invalidated on an FSEvents touch of that dir.
    /// NEVER spawns git.
    public func isRepoRoot(_ dir: URL) -> Bool {
        let d = norm(dir)
        if let hit = rootIconCache[d] { return hit }
        let exists = Self.fileExistsProbe(d.appendingPathComponent(".git").path)
        if rootIconCache.count > Self.cacheCap {
            rootIconCache.removeAll(keepingCapacity: true)
        }
        rootIconCache[d] = exists
        return exists
    }

    /// `.none` / `.repo` / `.nested` for a directory row. `.nested` when
    /// the dir is a repo root AND has an enclosing repo above it
    /// (submodule / nested worktree). Gated on `isRepoRoot` so the
    /// (slightly) costlier parent-walk only runs for rows that already
    /// passed the cheap `.git` check.
    public func repoRootKind(_ dir: URL) -> RepoRootKind {
        guard isRepoRoot(dir) else { return .none }
        // Is there an enclosing repo above this one?
        let parent = norm(dir).deletingLastPathComponent()
        if TrackedReposReducer.resolveRoot(for: parent, isDirectory: true) != nil {
            return .nested
        }
        return .repo
    }

    // MARK: - Mirror handoff (internal — store → channel on main actor)

    /// Diff the incoming mirror against the current one; bump `version`
    /// ONLY on value inequality (churn guard #3 — the third equality
    /// guard after the desired-set diff and the store's snapshot guard).
    /// `roots` is the store's LRU order for the picker / section
    /// visibility.
    func applyMirror(
        _ mirror: [URL: TrackedReposStore.RepoSnapshot],
        roots: [URL]
    ) {
        let rootsChanged = roots != trackedRoots
        let payloadChanged = !snapshotsPayloadEqual(snapshot, mirror)
        // Always adopt the new mirror so reads are current, but only
        // tick the version (and thus re-eval observers) when something a
        // consumer can see actually changed.
        snapshot = mirror
        trackedRoots = roots
        if payloadChanged || rootsChanged {
            version &+= 1
        }
    }

    /// Invalidate the cheap `.git`-existence cache for a directory (an
    /// FSEvents `.git` create/delete flipped its repo-root status).
    func invalidateRootIconCache(for dir: URL) {
        rootIconCache[norm(dir)] = nil
    }

    func invalidateAllRootIconCache() {
        rootIconCache.removeAll(keepingCapacity: true)
    }

    // MARK: - Test seams

    /// Install snapshots synchronously and bump the version as if a real
    /// store handoff occurred. Used by read-tests + republish-invariant
    /// tests.
    public func _testBump(installing mirror: [URL: TrackedReposStore.RepoSnapshot]) {
        snapshot = mirror
        trackedRoots = mirror.keys.sorted { $0.path < $1.path }
        version &+= 1
    }

    /// Test-only injectable file-exists probe so read-tests can assert a
    /// single stat per dir (cache hit on the second call) without a real
    /// filesystem dependency.
    nonisolated(unsafe) static var fileExistsProbe: (String) -> Bool = {
        FileManager.default.fileExists(atPath: $0)
    }

    public var _testRootIconCacheCount: Int { rootIconCache.count }
    public func _testNormalize(_ url: URL) -> URL { norm(url) }

    // MARK: - Private

    private func norm(_ url: URL) -> URL {
        if let hit = normCache[url] { return hit }
        let resolved = TrackedReposReducer.normalize(url)
        if normCache.count > Self.cacheCap {
            normCache.removeAll(keepingCapacity: true)
        }
        normCache[url] = resolved
        return resolved
    }

    private func snapshotsPayloadEqual(
        _ a: [URL: TrackedReposStore.RepoSnapshot],
        _ b: [URL: TrackedReposStore.RepoSnapshot]
    ) -> Bool {
        guard a.count == b.count else { return false }
        for (k, va) in a {
            guard let vb = b[k] else { return false }
            // Consumer-visible payload only: statuses + head. (Frozen
            // timeouts / timestamps must not tick the version.)
            if va.statuses != vb.statuses || va.head != vb.head { return false }
        }
        return true
    }
}
