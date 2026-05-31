import Foundation

/// Off-main, host-testable cache for the demand-driven multi-repo git
/// model. This is the **write side**: it owns the per-root snapshots,
/// LRU/refcount/grace bookkeeping, runs the git shell-outs (via
/// `GitClient` with a wall-clock timeout), dedups in-flight refreshes,
/// and caps concurrent git spawns.
///
/// A real Swift `actor` (not the `@MainActor`-class "actor by
/// convention" pattern `HighlightCacheActor` uses) because all of this
/// work must run off the main thread and be exercisable under
/// `ViewerCoreTests` with no `@MainActor` hops. The thin `@MainActor`
/// `TrackedReposChannel` (in ViewerUI) mirrors snapshots back for
/// SwiftUI's synchronous `body` reads + a narrow version tick — exactly
/// `HighlightCacheActor`'s shape projected onto an actor backing store.
///
/// Keys are normalized via `TrackedReposReducer.normalize` so write-side
/// (here) and read-side (channel) cannot drift.
public actor TrackedReposStore {

    /// Immutable, `Sendable` snapshot of one tracked repo's status +
    /// HEAD. Handed across the actor boundary to the channel mirror.
    /// `Equatable` so the channel's diff guard (#3) only bumps version
    /// on real change.
    public struct RepoSnapshot: Equatable, Sendable {
        /// Normalized absolute repo root.
        public let root: URL
        /// Normalized-absolute file URL → status. Badge shape
        /// (porcelain v1, NO `-uall` — preserves today's badge
        /// behavior; the panel keeps its own `-uall` detail list).
        public let statuses: [URL: GitStatusEntry.Status]
        public let head: GitClient.HeadInfo?
        /// True iff this root is itself nested inside another repo
        /// (submodule / nested worktree). Drives the subordinate glyph.
        public let isNestedRoot: Bool
        /// True iff the last refresh tripped the wall-clock timeout. The
        /// `statuses`/`head` are then the prior (frozen) values, NOT
        /// blanked — never lose badges to a slow repo.
        public let timedOut: Bool
        public let refreshedAt: Date
        /// Bumped only when (statuses, head) actually changed. The
        /// channel observes this to decide whether to re-mirror.
        public let generation: UInt64

        public init(
            root: URL,
            statuses: [URL: GitStatusEntry.Status],
            head: GitClient.HeadInfo?,
            isNestedRoot: Bool,
            timedOut: Bool,
            refreshedAt: Date,
            generation: UInt64
        ) {
            self.root = root
            self.statuses = statuses
            self.head = head
            self.isNestedRoot = isNestedRoot
            self.timedOut = timedOut
            self.refreshedAt = refreshedAt
            self.generation = generation
        }

        /// Equality for the dedup guard: a refresh is "no change" iff
        /// statuses + head match. `refreshedAt`/`generation`/`timedOut`
        /// are bookkeeping, not part of the consumer-visible payload.
        func payloadEquals(_ other: RepoSnapshot) -> Bool {
            statuses == other.statuses && head == other.head
        }
    }

    // MARK: - State

    private var byRoot: [URL: RepoSnapshot] = [:]
    /// Insertion / touch order, oldest first (mirrors prune's `order`).
    private var lru: [URL] = []
    private var refcounts: [URL: Int] = [:]
    private var zeroRefSince: [URL: Date] = [:]
    private var inFlight: Set<URL> = []
    private var pinned: Set<URL> = []
    /// Monotonic per-store generation source. Each value-changing
    /// refresh stamps the snapshot with the next value.
    private var generationCounter: UInt64 = 0

    /// Hard cap on tracked roots (live + grace). Realistic working set
    /// is 1–3; the cap only bounds a pathological "N files across N
    /// repos" session.
    public static let cap = 8
    /// Max zero-ref roots kept within the grace window.
    public static let graceSlots = 4
    /// How long a zero-ref root lingers before becoming evictable. Kills
    /// the dominant churn source (tab cycling, close-then-reopen).
    public static let graceWindow: TimeInterval = 30

    /// Wall-clock cap (seconds) injected into every `GitClient` this
    /// store builds. 5s for status/HEAD. Injected so tests can dial it
    /// down to force a timeout against a hanging fixture.
    private let statusTimeout: TimeInterval
    /// Max concurrent git spawns. Bounds the double-spawn ulimit cost
    /// (each `GitClient.run` = `/bin/sh` then `exec git`).
    private let maxConcurrentRefreshes: Int

    public init(statusTimeout: TimeInterval = 5, maxConcurrentRefreshes: Int = 2) {
        self.statusTimeout = statusTimeout
        self.maxConcurrentRefreshes = max(1, maxConcurrentRefreshes)
    }

    // MARK: - Concurrency gate

    /// Number of git refreshes currently executing their shell-out.
    private var activeRefreshes: Int = 0
    /// FIFO of continuations waiting for a refresh slot. ~15 lines, no
    /// new dependency — a counting gate, not an AsyncSemaphore package.
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireRefreshSlot() async {
        if activeRefreshes < maxConcurrentRefreshes {
            activeRefreshes += 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            refreshWaiters.append(cont)
        }
        // Resumed: the releaser already counted us into activeRefreshes.
    }

    private func releaseRefreshSlot() {
        if let next = refreshWaiters.first {
            refreshWaiters.removeFirst()
            // Hand the slot directly to the next waiter (count stays the
            // same — we don't decrement then re-increment).
            next.resume()
        } else {
            activeRefreshes -= 1
        }
    }

    // MARK: - Demand (called by RepoFocusTracker after the reducer diff)

    /// +1 the refcount for `root`. A brand-new root triggers an initial
    /// refresh; a root re-entering from grace has its `zeroRefSince`
    /// cleared (eviction cancelled — no fresh `git status`, no thrash).
    public func retain(_ root: URL) async {
        let r = TrackedReposReducer.normalize(root)
        let wasZero = (refcounts[r] ?? 0) == 0
        refcounts[r, default: 0] += 1
        zeroRefSince[r] = nil
        touchLRU(r)
        if wasZero && byRoot[r] == nil {
            // Brand-new live root → initial fetch.
            await refresh(root: r)
        }
    }

    /// -1 the refcount for `root`. At 0 the root enters grace
    /// (`zeroRefSince = now`) but is NOT evicted here — eviction is the
    /// caller's `enforceCapAndGrace` step.
    public func release(_ root: URL) {
        let r = TrackedReposReducer.normalize(root)
        guard let c = refcounts[r] else { return }
        if c <= 1 {
            refcounts[r] = nil
            zeroRefSince[r] = Date()
        } else {
            refcounts[r] = c - 1
        }
    }

    public func setPinned(_ roots: Set<URL>) {
        pinned = Set(roots.map(TrackedReposReducer.normalize))
    }

    /// Run the eviction plan and apply it. Returns the roots that were
    /// fully dropped so the caller can stop their FolderWatchers.
    /// `keepStaleWatcherless` roots also have their watchers stopped by
    /// the caller, but keep their snapshots.
    @discardableResult
    public func enforceCapAndGrace(now: Date = Date())
        -> (dropped: [URL], staleWatcherless: [URL])
    {
        let plan = TrackedReposReducer.evictionPlan(
            refcounts: refcounts,
            zeroRefSince: zeroRefSince,
            lruOrder: lru,
            pinned: pinned,
            now: now,
            graceWindow: Self.graceWindow,
            cap: Self.cap,
            graceSlots: Self.graceSlots
        )
        for r in plan.drop {
            byRoot[r] = nil
            refcounts[r] = nil
            zeroRefSince[r] = nil
            lru.removeAll { $0 == r }
        }
        return (plan.drop, plan.keepStaleWatcherless)
    }

    // MARK: - FSEvents-driven refresh

    /// Refresh `root`'s status + HEAD off-main. Deduped via `inFlight`
    /// (a second refresh of the same root while one is running is
    /// dropped — the FSEvents debounce + this guard coalesce a burst to
    /// one git pass per root). Concurrency-capped via the gate.
    ///
    /// Equality guard (churn guard #2): if the new (statuses, head)
    /// match the prior snapshot AND it's not the first fetch, the
    /// generation is NOT bumped and the channel is NOT notified — idle
    /// polls / identical FSEvents bursts are free.
    ///
    /// Timeout: on `timedOut`, KEEP the prior snapshot's statuses/head
    /// (set `timedOut = true` on the retained copy) — never blank badges.
    public func refresh(root: URL) async {
        let r = TrackedReposReducer.normalize(root)
        if inFlight.contains(r) { return }
        inFlight.insert(r)
        defer { inFlight.remove(r) }

        await acquireRefreshSlot()
        let timeout = statusTimeout
        // The git shell-outs are blocking; run them on a detached task so
        // we don't pin the actor's executor while git runs. The actor is
        // re-entered only to store the result.
        let fetch: (statuses: [URL: GitStatusEntry.Status],
                    head: GitClient.HeadInfo?,
                    timedOut: Bool) = await Task.detached(priority: .userInitiated) {
            let client = GitClient(repoRoot: r, statusTimeout: timeout)
            let statusRes = client.statusEntriesResult()
            let headRes = client.headInfoResult()
            var map: [URL: GitStatusEntry.Status] = [:]
            map.reserveCapacity(statusRes.entries.count)
            for entry in statusRes.entries {
                let url = TrackedReposReducer.normalize(
                    r.appendingPathComponent(entry.path)
                )
                map[url] = entry.status
            }
            return (map, headRes.head, statusRes.timedOut || headRes.timedOut)
        }.value
        releaseRefreshSlot()

        let isNested = TrackedReposReducer.resolveRoot(
            for: r.deletingLastPathComponent(), isDirectory: true
        ) != nil

        let prior = byRoot[r]
        let now = Date()

        if fetch.timedOut, let prior {
            // Keep frozen badges; only flip the timedOut flag. No
            // generation bump → channel sees no payload change.
            byRoot[r] = RepoSnapshot(
                root: r,
                statuses: prior.statuses,
                head: prior.head,
                isNestedRoot: prior.isNestedRoot,
                timedOut: true,
                refreshedAt: now,
                generation: prior.generation
            )
            return
        }

        // Equality guard: identical payload on a non-first fetch → no
        // generation bump, keep the existing snapshot (just refresh the
        // timestamp / clear any stale timedOut flag if it changed).
        if let prior,
           prior.statuses == fetch.statuses,
           prior.head == fetch.head,
           prior.timedOut == fetch.timedOut {
            byRoot[r] = RepoSnapshot(
                root: r,
                statuses: prior.statuses,
                head: prior.head,
                isNestedRoot: isNested,
                timedOut: fetch.timedOut,
                refreshedAt: now,
                generation: prior.generation
            )
            return
        }

        generationCounter &+= 1
        byRoot[r] = RepoSnapshot(
            root: r,
            statuses: fetch.statuses,
            head: fetch.head,
            isNestedRoot: isNested,
            timedOut: fetch.timedOut,
            refreshedAt: now,
            generation: generationCounter
        )
        touchLRU(r)
    }

    // MARK: - Reads (for the channel mirror handoff)

    public func snapshots() -> [URL: RepoSnapshot] { byRoot }

    public func snapshot(forRoot root: URL) -> RepoSnapshot? {
        byRoot[TrackedReposReducer.normalize(root)]
    }

    /// Tracked roots in LRU order (oldest first) — for the panel picker.
    public var trackedRoots: [URL] { lru }

    public func refcount(forRoot root: URL) -> Int {
        refcounts[TrackedReposReducer.normalize(root)] ?? 0
    }

    public func isInGrace(_ root: URL) -> Bool {
        zeroRefSince[TrackedReposReducer.normalize(root)] != nil
    }

    // MARK: - Test seams

    /// Install a snapshot synchronously (bypasses git). Registers it in
    /// `byRoot` + `lru` so eviction/read tests can stage state.
    public func _testInstall(_ snap: RepoSnapshot) {
        let r = TrackedReposReducer.normalize(snap.root)
        byRoot[r] = snap
        touchLRU(r)
    }

    public var _testTrackedCount: Int { byRoot.count }
    public var _testActiveRefreshes: Int { activeRefreshes }
    public var _testInFlightCount: Int { inFlight.count }
    public func _testRefcounts() -> [URL: Int] { refcounts }
    public func _testZeroRefRoots() -> Set<URL> { Set(zeroRefSince.keys) }
    public func _testSetZeroRefSince(_ root: URL, _ date: Date) {
        zeroRefSince[TrackedReposReducer.normalize(root)] = date
    }
    public var _testGeneration: UInt64 { generationCounter }
    public var _testLRU: [URL] { lru }

    // MARK: - Private

    private func touchLRU(_ root: URL) {
        lru.removeAll { $0 == root }
        lru.append(root)
    }
}
