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
        case status, log, stash, trees, remotes
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .status:  return "Status"
            case .log:     return "Log"
            case .stash:   return "Stash"
            case .trees:   return "Trees"
            case .remotes: return "Remotes"
            }
        }
        public var keyChord: KeyEquivalent? {
            switch self {
            case .status:  return "s"
            case .log:     return "l"
            case .stash:   return "h"
            case .trees:   return "t"
            case .remotes: return "r"
            }
        }
    }

    @Published public var selectedTab: Tab = .status
    @Published public var repoRoot: URL?
    @Published public var head: GitClient.HeadInfo?

    @Published public var statusEntries: [GitClient.StatusEntry] = []
    @Published public var logEntries: [GitClient.GraphCommit] = []
    @Published public var stashEntries: [GitClient.StashEntry] = []
    @Published public var worktreeEntries: [GitClient.WorktreeEntry] = []
    @Published public var remoteEntries: [GitClient.RemoteEntry] = []

    @Published public var isRefreshing: Bool = false
    @Published public var lastRefreshed: [Tab: Date] = [:]

    /// Pagination cursor for log lazy-load.
    private(set) var logLoadedCount: Int = 0
    public let logPageSize: Int = 100
    public let logIncrementSize: Int = 200
    public let logHardCap: Int = 5000

    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
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
    }

    /// Hook from `NSWindow.didBecomeKeyNotification` (wired by the view).
    public func windowDidBecomeKey() {
        refreshCurrent()
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
        logLoadedCount = 0
        lastRefreshed = [:]
        refreshCurrent()
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
        Task { @MainActor [weak self] in
            let more = await Task.detached(priority: .utility) {
                GitClient(repoRoot: root).graphLog(maxEntries: take, skip: skip)
            }.value
            guard let self else { return }
            self.logEntries.append(contentsOf: more)
            self.logLoadedCount += more.count
        }
    }

    private func apply(_ p: Payload, tab: Tab, isInitialLogPage: Bool) {
        head = p.head
        if let s = p.status   { statusEntries   = s }
        if let l = p.log      {
            logEntries = l
            if isInitialLogPage { logLoadedCount = l.count }
        }
        if let s = p.stash    { stashEntries    = s }
        if let t = p.trees    { worktreeEntries = t }
        if let r = p.remotes  { remoteEntries   = r }
        lastRefreshed[tab] = Date()
        isRefreshing = false
    }

    // MARK: - Counts for tab-strip badges

    public func count(for tab: Tab) -> Int? {
        switch tab {
        case .status:  return statusEntries.isEmpty ? nil : statusEntries.count
        case .stash:   return stashEntries.isEmpty ? nil : stashEntries.count
        case .trees:   return worktreeEntries.isEmpty ? nil : worktreeEntries.count
        case .remotes: return remoteEntries.isEmpty ? nil : remoteEntries.count
        case .log:     return nil  // log count would be misleading (paginated)
        }
    }
}
