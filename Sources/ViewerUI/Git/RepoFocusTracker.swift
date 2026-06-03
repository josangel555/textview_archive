import Foundation
import Combine
import ViewerCore

/// Owns demand resolution for the multi-repo git registry. A sibling
/// coordinator (like `EditorCoordinator`), held by `DocumentModel` as
/// `public let repoFocus`. It DRIVES the store + channel; views never
/// observe it directly — they observe the `channel` (the version tick).
///
/// Declarative entry point: `recompute()`. It gathers demand (open tabs
/// + split + sidebar folder + pins), runs the pure reducer, diffs
/// against the previous desired set, and drives the store (retain /
/// release / refresh) + per-root FolderWatchers. Recomputing — rather
/// than imperative acquire/release — eliminates refcount-leak bugs.
///
/// Observation discipline: this subscribes to `tabCoordinator` /
/// `sidebar` `@Published` streams the views ALREADY observe. As a
/// sibling coordinator (not the parent model), that is NOT "forwarding
/// child objectWillChange into parent." The store/channel republish
/// path is entirely separate (`channel.version`) and never touches
/// `DocumentModel.objectWillChange`.
@MainActor
public final class RepoFocusTracker {

    /// The off-main cache + git worker.
    public let store: TrackedReposStore
    /// THE observation surface consumers read.
    public let channel: TrackedReposChannel

    /// Pinned roots (the `gitRootOverride` successor — multi-pin). Never
    /// evicted, never enter grace. Persisted nowhere (matches "nothing
    /// git-related persists today").
    public private(set) var pinned: Set<URL> = []

    /// The repo the Git panel should follow. Recomputed at the end of
    /// every `recompute()`. nil when nothing is tracked.
    public private(set) var focusedRoot: URL?

    /// Memoized `parentDir → root?` to avoid re-walking `.git` on every
    /// recompute. Invalidated for a dir on a `.git` create/delete
    /// FSEvent (so a freshly `git init`'d folder is discovered, and a
    /// `rm -rf .git` stops showing as tracked).
    private var rootCache: [URL: URL?] = [:]
    private static let rootCacheCap = 4096

    /// Per-tracked-root FSEvents watcher. ≤ cap streams, one per tracked
    /// root — covers roots reached by opening a file OUTSIDE the sidebar
    /// tree (`mdv /other/repo/file.md`), which a sidebar-only watcher
    /// would miss.
    private var watchers: [URL: FolderWatcher] = [:]

    /// Last desired set — the basis for churn guard #1.
    private var previousDesired: [URL: Int] = [:]

    // `weak`, not `unowned`: the tracker, tabCoordinator, and sidebar are
    // all stored properties of the same DocumentModel, so they share a
    // lifetime — but a debounced `$selectedURL` Combine closure or an
    // in-flight grace-sweep Task can fire DURING DocumentModel teardown,
    // after a sibling has already deallocated. `unowned` would crash on
    // that read (observed under the republish-invariant suite's many
    // short-lived models). `weak` + guards make teardown UAF-safe.
    private weak var tabCoordinator: TabCoordinator?
    private weak var sidebar: SidebarModel?
    private var cancellables: Set<AnyCancellable> = []

    /// Debounce for sidebar arrow-key navigation (churn guard #4):
    /// `$selectedURL` fires per keystroke; we don't want a recompute per
    /// row scrolled past.
    private static let sidebarDebounce: RunLoop.SchedulerTimeType.Stride = .milliseconds(200)

    public init(
        tabCoordinator: TabCoordinator,
        sidebar: SidebarModel,
        store: TrackedReposStore = TrackedReposStore()
    ) {
        self.tabCoordinator = tabCoordinator
        self.sidebar = sidebar
        self.store = store
        self.channel = TrackedReposChannel(store: store)
        wireObservers(tabCoordinator: tabCoordinator, sidebar: sidebar)
    }

    // MARK: - Demand-source observers

    private func wireObservers(tabCoordinator: TabCoordinator, sidebar: SidebarModel) {
        // Generic tab-set coverage: any tab mutation refreshes
        // openTabURLs. Debounced 0ms — it's already deduped.
        tabCoordinator.$openTabURLs
            .dropFirst()
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)

        tabCoordinator.$splitURL
            .dropFirst()
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)

        // Sidebar selection: arrow-key nav fires per keystroke →
        // debounce. Observed DIRECTLY (sibling), never forwarded into
        // DocumentModel — preserves PERF #1.
        sidebar.$selectedURL
            .dropFirst()
            .debounce(for: Self.sidebarDebounce, scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)

        sidebar.$rootURL
            .dropFirst()
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
    }

    // MARK: - Pins

    /// Toggle a repo pin and recompute. The "Pin Repo" / "Unpin Repo"
    /// sidebar context-menu items call this.
    public func togglePin(_ root: URL) {
        let r = TrackedReposReducer.normalize(root)
        if pinned.contains(r) { pinned.remove(r) } else { pinned.insert(r) }
        recompute()
    }

    public func setPinned(_ roots: Set<URL>) {
        pinned = Set(roots.map(TrackedReposReducer.normalize))
        recompute()
    }

    // MARK: - The single entry point

    /// Gather demand, diff, drive the store + watchers, recompute focus,
    /// and hand a fresh mirror to the channel. Idempotent and
    /// equality-guarded: unchanged demand is a zero-cost no-op (churn
    /// guard #1 — switching tabs within one repo makes no store calls,
    /// no watcher churn, no version bump).
    public func recompute() {
        let desired = gatherDesiredSet()

        // Churn guard #1: identical demand → skip the retain/release +
        // watcher-start churn. We still run a cheap grace sweep (so a
        // zero-ref root whose grace window has since elapsed actually
        // gets evicted on the next recompute, even without a demand
        // change) and recompute focus.
        if desired == previousDesired {
            Task { [weak self] in
                guard let self else { return }
                let result = await self.store.enforceCapAndGrace(now: Date())
                for root in result.dropped { self.stopWatcher(for: root) }
                for root in result.staleWatcherless { self.stopWatcher(for: root) }
                if !result.dropped.isEmpty || !result.staleWatcherless.isEmpty {
                    await self.handoffMirror()
                }
                self.updateFocusedRoot()
            }
            return
        }

        let previousRoots = Set(previousDesired.keys)
        let desiredRoots = Set(desired.keys)
        let newRoots = desiredRoots.subtracting(previousRoots)
        let goneRoots = previousRoots.subtracting(desiredRoots)
        previousDesired = desired

        Task { [weak self] in
            guard let self else { return }
            for root in newRoots {
                await self.store.retain(root)
                self.startWatcher(for: root)
            }
            for root in goneRoots {
                await self.store.release(root)
                // Watcher stays during grace; only stopped on full
                // eviction below.
            }
            await self.store.setPinned(self.pinned)
            let result = await self.store.enforceCapAndGrace(now: Date())
            for root in result.dropped {
                self.stopWatcher(for: root)
            }
            for root in result.staleWatcherless {
                // Bound FSEvents fan-out on referenced overflow roots —
                // stop the watcher but KEEP the snapshot (frozen).
                self.stopWatcher(for: root)
            }
            await self.handoffMirror()
            self.updateFocusedRoot()
        }
    }

    /// Pull the current store snapshots onto the main actor and hand
    /// them to the channel (which decides whether to tick its version).
    private func handoffMirror() async {
        let snaps = await store.snapshots()
        let roots = await store.trackedRoots
        channel.applyMirror(snaps, roots: roots)
    }

    /// Force a status refresh of the repo enclosing `url` (if tracked).
    /// Called on save so badges update deterministically rather than
    /// waiting on the FSEvents debounce. No-op if the file isn't in a
    /// tracked repo (the open path will have retained it already).
    public func refreshRepo(enclosing url: URL) {
        guard let root = TrackedReposReducer.resolveRoot(for: url, isDirectory: false)
        else { return }
        Task { [weak self] in
            guard let self else { return }
            // Only refresh if it's actually tracked — otherwise a save
            // in an untracked repo would spuriously spawn git.
            let snaps = await self.store.snapshots()
            guard snaps[root] != nil else { return }
            await self.store.refresh(root: root)
            await self.handoffMirror()
        }
    }

    // MARK: - Demand gathering

    private func gatherDesiredSet() -> [URL: Int] {
        guard let tabCoordinator else {
            // Coordinator gone (teardown): demand is just the pins.
            return TrackedReposReducer.desiredRepoSet(
                tabURLs: [], splitURL: nil, sidebarFolder: nil, pinned: pinned
            )
        }
        let tabURLs = Array(tabCoordinator.openTabURLs)
        let splitURL = tabCoordinator.splitURL
        let sidebarFolder = sidebar?.selectedURL ?? sidebar?.rootURL
        return TrackedReposReducer.desiredRepoSet(
            tabURLs: tabURLs,
            splitURL: splitURL,
            sidebarFolder: sidebarFolder,
            pinned: pinned
        )
    }

    private func updateFocusedRoot() {
        let resolved = resolveFocusedRoot()
        guard resolved != focusedRoot else { return }
        focusedRoot = resolved
        // `focusedRoot` is the Git panel's gate-#2 input (read by
        // `GitPanelSection.syncRepo` → `followFocus`), but it is NOT an
        // observed surface — the section only re-syncs on a
        // `channel.version` tick. A recompute can resolve focus (nil →
        // root) on the churn-guard-#1 path, where no mirror handoff
        // bumps the version; the panel would then stay empty with no
        // later tick to re-trigger (the occluded-launch repro). Bump the
        // version so the already-mounted section re-runs `syncRepo`.
        channel.notifyFocusChanged()
    }

    /// Pure resolution of which tracked root the Git panel should follow.
    /// Priority: repo enclosing the selected tab → sidebar folder's repo
    /// → single tracked root → most-recently-touched. nil iff nothing is
    /// tracked.
    private func resolveFocusedRoot() -> URL? {
        let tracked = channel.trackedRoots
        if let selected = tabCoordinator?.selected?.url,
           let root = TrackedReposReducer.resolveRoot(for: selected, isDirectory: false),
           tracked.contains(root) {
            return root
        }
        if let sidebarFolder = sidebar?.selectedURL ?? sidebar?.rootURL,
           let root = TrackedReposReducer.resolveRoot(for: sidebarFolder, isDirectory: true),
           tracked.contains(root) {
            return root
        }
        if tracked.count == 1 {
            return tracked.first
        }
        // Most-recently-touched = last in LRU order.
        return tracked.last
    }

    // MARK: - FSEvents handling

    /// Handle a debounced FSEvents burst for one tracked root. Filters
    /// `.git`-internal noise, invalidates the root-cache on `.git`
    /// create/delete, and refreshes the store iff any change is
    /// status-worthy.
    private func handleFSEvents(root: URL, changedDirs: [URL]) {
        var worthy = false
        for dir in changedDirs {
            // `.git` create/delete → a repo was init'd or removed under
            // this dir; invalidate the discoverRoot memo + icon cache.
            if TrackedReposReducer.touchesDotGitExistence(changedPath: dir.path) {
                let parent = dir.deletingLastPathComponent()
                rootCache[TrackedReposReducer.normalize(parent)] = nil
                channel.invalidateRootIconCache(for: parent)
            }
            channel.invalidateRootIconCache(for: dir)
            if TrackedReposReducer.isRefreshWorthy(changedPath: dir.path, repoRoot: root) {
                worthy = true
            }
        }
        guard worthy else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.store.refresh(root: root)
            await self.handoffMirror()
        }
    }

    // MARK: - Watcher lifecycle

    private func startWatcher(for root: URL) {
        let r = TrackedReposReducer.normalize(root)
        guard watchers[r] == nil else { return }
        // onChange hops to .main by default (FolderWatcher's default
        // queue), so we can mutate @MainActor state directly.
        let watcher = try? FolderWatcher(
            url: r,
            latency: 0.25,
            debounce: .milliseconds(200)
        ) { [weak self] dirs in
            MainActor.assumeIsolated {
                self?.handleFSEvents(root: r, changedDirs: dirs)
            }
        }
        if let watcher { watchers[r] = watcher }
    }

    private func stopWatcher(for root: URL) {
        let r = TrackedReposReducer.normalize(root)
        watchers[r]?.stop()
        watchers[r] = nil
    }

    // MARK: - Test seams

    /// Live watcher count (== live + grace tracked-root count after a
    /// settled recompute). Host-safe bookkeeping assertion seam.
    public var watcherCount: Int { watchers.count }

    public func _testHasWatcher(for root: URL) -> Bool {
        watchers[TrackedReposReducer.normalize(root)] != nil
    }

    /// Directly invoke the FSEvents handler for unit tests (no live
    /// stream). Exercises the storm filter + refresh wiring.
    public func _testHandleFSEvents(root: URL, changedDirs: [URL]) {
        handleFSEvents(root: root, changedDirs: changedDirs)
    }

    public func _testPreviousDesired() -> [URL: Int] { previousDesired }
}
