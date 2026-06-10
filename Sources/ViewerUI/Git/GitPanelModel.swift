import Foundation
import SwiftUI
import ViewerCore

/// State container for the multi-tab Git panel. Independent of where the
/// panel is hosted (sidebar accordion today, dock pane / detached window
/// later) — owns selected tab, per-tab cached data, refresh policy.
///
/// Refresh policy:
/// - On `start()`, kicks off a 60 s repeating timer that refreshes the
///   currently-visible tab.
/// - On window-key (regain focus), refreshes the current tab.
/// - When `repoRoot` changes, drops all cached data and refreshes the
///   current tab.
/// - `selectTab(_:)` refreshes the new tab if its cache is older than
///   60 s (cheap; equivalent to switching to it for the first time).
///
/// Per-tab cache + refresh state — refreshing only the visible tab keeps
/// the background `git` workload proportional to what's on screen.
@MainActor
public final class GitPanelModel: ObservableObject {

    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case status, log, stash, trees, remotes, review
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .status:  return "Status"
            case .log:     return "Log"
            case .stash:   return "Stash"
            case .trees:   return "Trees"
            case .remotes: return "Remotes"
            case .review:  return "Review"
            }
        }
        public var keyChord: KeyEquivalent? {
            switch self {
            case .status:  return "s"
            case .log:     return "l"
            case .stash:   return "h"
            case .trees:   return "t"
            case .remotes: return "r"
            case .review:  return "v"
            }
        }
    }

    @Published public var selectedTab: Tab = .status
    @Published public var repoRoot: URL?
    @Published public var head: GitClient.HeadInfo?

    /// Explicit user repo pick from the header picker. When set, the
    /// panel stays pinned to this root even as focus follows tabs —
    /// until focus moves to a DIFFERENT tracked repo, at which point
    /// follow resumes (see `followFocus(_:tracked:)`). nil = follow
    /// the focused root.
    @Published public private(set) var userPinnedPanelRoot: URL?

    @Published public var statusEntries: [GitClient.StatusEntry] = []
    @Published public var logEntries: [GitClient.GraphCommit] = []
    /// SHA of the log commit whose diff is currently shown (TSK-595).
    /// Drives the Log tab's selected-row highlight; reset on repo switch
    /// so a stale SHA never matches a row in an unrelated repository.
    @Published public private(set) var selectedLogSHA: String?
    @Published public var stashEntries: [GitClient.StashEntry] = []
    @Published public var worktreeEntries: [GitClient.WorktreeEntry] = []
    @Published public var remoteEntries: [GitClient.RemoteEntry] = []

    /// Unresolved-comment count for the active review, surfaced as the
    /// Review tab's badge (§6.4). `nil` = no active review / nothing to badge.
    /// Set by the review UI when it loads/mutates a review; the panel's own
    /// git-driven refresh leaves it untouched (reviews live in `.textview/`,
    /// not a git command).
    @Published public var reviewCount: Int?

    @Published public var isRefreshing: Bool = false
    @Published public var lastRefreshed: [Tab: Date] = [:]

    /// Pagination cursor for log lazy-load.
    private(set) var logLoadedCount: Int = 0
    public let logPageSize: Int = 100
    public let logIncrementSize: Int = 200
    public let logHardCap: Int = 5000

    /// Monotonic generation for the log list. Bumped every time the log is
    /// reset or wholesale-replaced (repo switch, initial-page refresh) so an
    /// in-flight `loadMoreLog` page that lost a race against a reset/refresh
    /// can detect it and discard its (now stale / cross-repo) result instead
    /// of appending it onto a different list.
    private var logGen: Int = 0

    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    /// In-flight `loadMoreLog` pagination task — tracked so it can be cancelled
    /// when the log is reset/refreshed under it (the generation guard is the
    /// correctness backstop; cancellation just avoids the wasted shell-out).
    private var loadMoreTask: Task<Void, Never>?
    /// Cache freshness threshold — anything older than this on tab-switch
    /// triggers an immediate refresh. Matches the user-stated 60 s cadence.
    private let cacheTTL: TimeInterval = 60

    public init() {}

    // MARK: - Lifecycle

    public func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCurrent() }
        }
        // RunLoop.common so it fires while menus / drags are active.
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
        loadMoreTask?.cancel()
        loadMoreTask = nil
    }

    /// Hook from `NSWindow.didBecomeKeyNotification` (wired by the view).
    public func windowDidBecomeKey() {
        refreshCurrent()
    }

    /// Record which log commit's diff is being shown (TSK-595). The Log
    /// tab calls this from its row action; rows compare their SHA against
    /// `selectedLogSHA` for the selected-row highlight.
    public func selectLogCommit(sha: String) {
        selectedLogSHA = sha
    }

    public func setRepoRoot(_ url: URL?) {
        guard url != repoRoot else { return }
        repoRoot = url
        // Clear all caches; the new repo state is unrelated.
        statusEntries = []
        logEntries = []
        stashEntries = []
        worktreeEntries = []
        remoteEntries = []
        head = nil
        selectedLogSHA = nil
        logLoadedCount = 0
        logGen &+= 1
        loadMoreTask?.cancel()
        loadMoreTask = nil
        lastRefreshed = [:]
        refreshCurrent()
    }

    /// Explicit user repo pick from the header picker. The panel pins to
    /// `root` (overriding focus-follow) until focus moves to a DIFFERENT
    /// tracked repo. A no-op `setRepoRoot` guard means re-picking the
    /// current root just (re)asserts the pin without churning caches.
    public func pickRepoRoot(_ root: URL) {
        userPinnedPanelRoot = root
        setRepoRoot(root)
    }

    /// Reconcile the panel's repo with the registry's focused root.
    /// Called by the host on focus / version changes.
    ///
    /// - If the user has pinned a panel root via the picker, stay on it
    ///   AS LONG AS it's still tracked. Once `focusedRoot` moves to a
    ///   different tracked repo (the user navigated to a tab in another
    ///   repo), the explicit pick is released and follow resumes.
    /// - Otherwise follow `focusedRoot` directly.
    public func followFocus(_ focusedRoot: URL?, tracked: [URL]) {
        if let pinned = userPinnedPanelRoot {
            // Released when focus has moved to a *different* tracked repo,
            // or when the pinned root is no longer tracked at all.
            let focusMovedAway = (focusedRoot != nil && focusedRoot != pinned)
            let pinDropped = !tracked.contains(pinned)
            if focusMovedAway || pinDropped {
                userPinnedPanelRoot = nil
                setRepoRoot(focusedRoot)
            } else {
                setRepoRoot(pinned)
            }
            return
        }
        setRepoRoot(focusedRoot)
    }

    // MARK: - Tab selection

    public func selectTab(_ tab: Tab) {
        let was = selectedTab
        selectedTab = tab
        // If the new tab's cache is stale or empty, refresh it. (Don't
        // refresh on no-op selection.)
        if tab != was {
            let last = lastRefreshed[tab]
            if last == nil || Date().timeIntervalSince(last!) > cacheTTL {
                refreshCurrent()
            }
        }
    }

    // MARK: - Refresh

    /// Sendable bag of everything a tab refresh can produce. Lets the
    /// detached work hand back a single value, and the MainActor side
    /// fan it out to the right @Published properties.
    private struct Payload: Sendable {
        var head: GitClient.HeadInfo?
        var status: [GitClient.StatusEntry]?
        var log: [GitClient.GraphCommit]?
        var stash: [GitClient.StashEntry]?
        var trees: [GitClient.WorktreeEntry]?
        var remotes: [GitClient.RemoteEntry]?
    }

    public func refreshCurrent() {
        guard let root = repoRoot else { return }
        let tab = selectedTab
        let page = logPageSize
        refreshTask?.cancel()
        // A refresh that re-fetches the initial log page wholesale-replaces the
        // list; cancel any in-flight pagination so it can't append onto it. The
        // generation guard (`apply` bumps `logGen` on the initial page) is the
        // correctness backstop if the page already passed its suspension point.
        loadMoreTask?.cancel()
        loadMoreTask = nil
        isRefreshing = true
        // Outer Task is @MainActor so capturing self is fine. The
        // blocking shell-out work lives on a detached task whose return
        // value is a Sendable Payload — no @MainActor capture crosses
        // the actor boundary.
        refreshTask = Task { @MainActor [weak self] in
            let payload = await Task.detached(priority: .utility) {
                let client = GitClient(repoRoot: root)
                var p = Payload(head: client.headInfo())
                switch tab {
                case .status:  p.status  = client.status()
                case .log:     p.log     = client.graphLog(maxEntries: page, skip: 0)
                case .stash:   p.stash   = client.stashList()
                case .trees:   p.trees   = client.worktreeList()
                case .remotes: p.remotes = client.remoteList()
                case .review:  break  // reviews load from .textview/ (ReviewStore), not a git command
                }
                return p
            }.value
            guard let self, !Task.isCancelled else { return }
            self.apply(payload, tab: tab, isInitialLogPage: true)
        }
    }

    /// Lazy-load the next page of log entries (called by LogTab when the
    /// user scrolls to the bottom).
    public func loadMoreLog() {
        guard let root = repoRoot,
              logLoadedCount > 0,
              logLoadedCount < logHardCap else { return }
        let skip = logLoadedCount
        let take = min(logIncrementSize, logHardCap - logLoadedCount)
        // Snapshot the list's identity. If a refresh / repo switch resets or
        // wholesale-replaces the log across the suspension below, `logGen`
        // (and `repoRoot` / `logLoadedCount`) move out from under us, and we
        // must discard `more` rather than append a stale or cross-repo page.
        let gen = logGen
        loadMoreTask?.cancel()
        loadMoreTask = Task { @MainActor [weak self] in
            let more = await Task.detached(priority: .utility) {
                GitClient(repoRoot: root).graphLog(maxEntries: take, skip: skip)
            }.value
            guard let self, !Task.isCancelled else { return }
            // The list must still be the exact one we paged off of: same repo,
            // same generation, and `skip` still the tail (no refresh inserted a
            // fresh initial page underneath). Otherwise drop the result.
            guard self.repoRoot == root,
                  gen == self.logGen,
                  self.logLoadedCount == skip else { return }
            self.logEntries.append(contentsOf: more)
            self.logLoadedCount += more.count
        }
    }

    private func apply(_ p: Payload, tab: Tab, isInitialLogPage: Bool) {
        // Equality-guarded so a refresh that produces identical results
        // (very common: idle polls, focus-regain refreshes, no filesystem
        // change) doesn't trigger a full sidebar+panel republish.
        if head != p.head { head = p.head }
        if let s = p.status, statusEntries != s { statusEntries = s }
        if let l = p.log {
            if logEntries != l { logEntries = l }
            if isInitialLogPage {
                // The initial page replaces the list wholesale; bump the
                // generation so any in-flight `loadMoreLog` page that raced
                // this refresh discards its result instead of appending it.
                logGen &+= 1
                if logLoadedCount != l.count { logLoadedCount = l.count }
            }
        }
        if let s = p.stash, stashEntries != s { stashEntries = s }
        if let t = p.trees, worktreeEntries != t { worktreeEntries = t }
        if let r = p.remotes, remoteEntries != r { remoteEntries = r }
        lastRefreshed[tab] = Date()
        if isRefreshing { isRefreshing = false }
    }

    // MARK: - Counts for tab-strip badges

    public func count(for tab: Tab) -> Int? {
        switch tab {
        case .status:  return statusEntries.isEmpty ? nil : statusEntries.count
        case .stash:   return stashEntries.isEmpty ? nil : stashEntries.count
        case .trees:   return worktreeEntries.isEmpty ? nil : worktreeEntries.count
        case .remotes: return remoteEntries.isEmpty ? nil : remoteEntries.count
        case .log:     return nil  // log count would be misleading (paginated)
        case .review:  return reviewCount  // unresolved-comment count for the active review, or nil
        }
    }
}
