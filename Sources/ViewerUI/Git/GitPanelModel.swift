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
    /// TSK-1443: the commit-message field the Status-tab commit bar binds to.
    /// Cleared after a successful commit.
    @Published public var commitMessage: String = ""
    /// TSK-1443: a path awaiting discard confirmation (drives the Status-tab
    /// confirm dialog). `nil` = no dialog. A destructive op NEVER runs without
    /// passing through here (`GitStageOp.discard.requiresConfirm`).
    @Published public var pendingDiscard: String?
    /// TSK-1443: true while an index mutation (stage/unstage/commit/discard) is
    /// shelling out, so the commit bar can disable + show progress.
    @Published public private(set) var isMutating: Bool = false
    @Published public var logEntries: [GitClient.GraphCommit] = []
    /// SHA of the log commit whose diff is currently shown (TSK-595).
    /// Drives the Log tab's selected-row highlight; reset on repo switch
    /// so a stale SHA never matches a row in an unrelated repository.
    @Published public private(set) var selectedLogSHA: String?
    /// TSK-522: the multi-selected log commits (Cmd/Shift-click) feeding
    /// the cumulative diff. A plain click (`selectLogCommit`) resets this
    /// to the single clicked commit, so row highlight = membership here.
    @Published public private(set) var selectedLogSHAs: Set<String> = []
    /// Shift-range anchor — the most recently plain- or Cmd-selected
    /// commit. Not published: it only matters at the next shift-click.
    private var logSelectionAnchor: String?
    /// TSK-596: full-message log search. `nil` = no search active (the
    /// Log tab shows the normal paged `logEntries`); non-nil = the
    /// `git log --grep` match set currently displayed. Bodies are
    /// searched too — that's why this is git-backed rather than a
    /// client-side filter over the (subject-only, paged) loaded list.
    @Published public private(set) var logSearchResults: [GitClient.GraphCommit]?
    /// The live search-field text. The Log tab binds its TextField here
    /// and calls `runLogSearch` on change.
    @Published public var logSearchQuery: String = ""
    /// TSK-1600 — the search is TWO-PHASE: instant local hits (sha / ref /
    /// worktree prefixes + subject over the loaded rows) publish immediately,
    /// then the debounced `git log --grep` body pass merges in. `false` while
    /// that second pass is in flight, so callers (and tests) can tell "showing
    /// early hits" from "final match set".
    @Published public private(set) var logSearchIsSettled: Bool = true
    @Published public var stashEntries: [GitClient.StashEntry] = []
    @Published public var worktreeEntries: [GitClient.WorktreeEntry] = []
    /// TSK-1604 — last-commit metadata for each worktree head, keyed by sha
    /// (both abbreviated and full). Loaded with the Trees tab in one batched
    /// `git show`, so the tab can show "sha · 2h ago · subject".
    @Published public var worktreeHeadMetas: [String: GitClient.CommitMeta] = [:]
    @Published public var remoteEntries: [GitClient.RemoteEntry] = []

    /// TSK-1602 — when true the Log tab loads the ALL-REFS graph (`--all`),
    /// so every worktree's branch tip and their divergence points render in
    /// ONE graph instead of only the current worktree's history. Persisted
    /// app-wide; flipping it reloads the log.
    @Published public var showAllRefs: Bool =
        GitLogPrefs.resolveShowAllRefs(UserDefaults.standard) {
        didSet {
            guard showAllRefs != oldValue else { return }
            UserDefaults.standard.set(showAllRefs, forKey: GitLogPrefs.showAllRefsKey)
            refreshCurrent()
        }
    }

    /// TSK-1601/1602 — local branch → the OTHER worktree's directory name
    /// that has it checked out. Feeds `GitRefKind.classify` so a branch held
    /// by a sibling worktree gets its own chip color + worktree subtitle.
    public var worktreeBranchMap: [String: String] {
        var map: [String: String] = [:]
        for wt in worktreeEntries where wt.state != .current {
            if let b = wt.branch { map[b] = wt.path.lastPathComponent }
        }
        return map
    }

    /// The worktree list in the shape the pure search matcher wants.
    public var searchWorktrees: [GitLogSearchQuery.Worktree] {
        worktreeEntries.map {
            GitLogSearchQuery.Worktree(
                name: $0.path.lastPathComponent, branch: $0.branch, head: $0.head)
        }
    }

    /// Remote names for ref classification (falls back to the conventional
    /// set before the Remotes tab has loaded).
    public var remoteNamesForRefs: Set<String> {
        let names = Set(remoteEntries.map(\.name))
        return names.isEmpty ? ["origin", "upstream"] : names
    }

    /// Unresolved-comment count for the active review, surfaced as the
    /// Review tab's badge (§6.4). `nil` = no active review / nothing to badge.
    /// Set by the review UI when it loads/mutates a review; the panel's own
    /// git-driven refresh leaves it untouched (reviews live in `.textview/`,
    /// not a git command).
    @Published public var reviewCount: Int?

    /// TSK-523: the review currently open in the Review tab. Non-nil makes
    /// `ReviewIndexTab` present the review-aware `ReviewTabView` (inline
    /// structured diff + add-comment) instead of the index list. Cleared on
    /// repo switch — a session's store/git are bound to the old root.
    @Published public private(set) var activeReviewSession: ReviewSession?

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

    /// In-flight grep-log search (TSK-596). Generation-guarded like
    /// `loadMoreLog` so a stale result can't land after a newer query /
    /// a clear / a repo switch.
    /// `nonisolated(unsafe)` so the nonisolated `deinit` (M15, TSK-989) can
    /// cancel it. The class is `@MainActor`; every non-deinit access is on main.
    private nonisolated(unsafe) var logSearchTask: Task<Void, Never>?
    private var logSearchGen: Int = 0
    /// Debounce before shelling out per keystroke. Internal so tests
    /// can zero it.
    var logSearchDebounceNanos: UInt64 = 250_000_000

    /// `nonisolated(unsafe)` (with `refreshTask`/`loadMoreTask`/`logSearchTask`)
    /// so the nonisolated `deinit` (M15, TSK-989) can invalidate/cancel them.
    /// The class is `@MainActor`; every non-deinit access is on main.
    private nonisolated(unsafe) var timer: Timer?
    private nonisolated(unsafe) var refreshTask: Task<Void, Never>?
    /// In-flight `loadMoreLog` pagination task — tracked so it can be cancelled
    /// when the log is reset/refreshed under it (the generation guard is the
    /// correctness backstop; cancellation just avoids the wasted shell-out).
    /// Internal (not private) as the TSK-150 test seam: the stale-page
    /// guard test captures this task before invalidating the list
    /// identity, then awaits it to assert the page was dropped.
    private(set) nonisolated(unsafe) var loadMoreTask: Task<Void, Never>?
    /// Cache freshness threshold — anything older than this on tab-switch
    /// triggers an immediate refresh. Matches the user-stated 60 s cadence.
    private let cacheTTL: TimeInterval = 60

    public init() {
        // TSK-620: the panel is a view-local @StateObject, so the
        // `--script` harness verbs (`git-log-click` family) and the
        // diagnostic dump cannot be handed the instance — they resolve it
        // through this weak registry instead. Weak: a dismounted panel
        // must not linger; the newest mounted panel wins (the app shows one).
        Self.live = self
    }

    /// The live (most recently constructed) panel instance — the
    /// exact-closure bridge for script verbs and the dump projection.
    public private(set) static weak var live: GitPanelModel?

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
        logSearchTask?.cancel()
        logSearchTask = nil
    }

    /// L-mem backstop (M15, TSK-989): `start()` schedules a 60 s repeating
    /// `Timer` on `RunLoop.main(.common)` whose block captures `[weak self]`,
    /// so the run loop — not the model — retains the timer. That means this
    /// `deinit` CAN run while the timer is still live, and without invalidating
    /// it here the timer keeps firing `self?.refreshCurrent()` (a no-op once
    /// self is gone) every 60 s forever — a leaked run-loop source. `stop()`
    /// is the normal teardown but it is wired solely to `GitPanelView`'s
    /// `onDisappear`; any teardown that skips it would otherwise leak the timer
    /// AND leave the three in-flight tasks running. This mirrors `stop()` as
    /// the unconditional backstop. The `Task`s are cooperatively cancelled
    /// (cancellation is thread-safe); the timer invalidation is the load-
    /// bearing bit.
    deinit {
        timer?.invalidate()
        refreshTask?.cancel()
        loadMoreTask?.cancel()
        logSearchTask?.cancel()
    }

    /// Test seam (M15, TSK-989): the scheduled refresh timer, so a host test
    /// can take a reference, drop the model WITHOUT calling `stop()`, and
    /// assert the deinit invalidated it (`timer.isValid == false`). Not for
    /// production use.
    var timerForTesting: Timer? { timer }

    /// Hook from `NSWindow.didBecomeKeyNotification` (wired by the view).
    public func windowDidBecomeKey() {
        refreshCurrent()
    }

    /// Record which log commit's diff is being shown (TSK-595). The Log
    /// tab calls this from its row action; rows compare their SHA against
    /// `selectedLogSHA` for the selected-row highlight.
    public func selectLogCommit(sha: String) {
        selectedLogSHA = sha
        selectedLogSHAs = [sha]
        logSelectionAnchor = sha
    }

    /// TSK-522: modified-click multi-select. Cmd toggles membership;
    /// Shift extends a contiguous run from the anchor in log order. Only
    /// the normal paged log participates — the grep match set (search
    /// mode) is a filtered view whose row adjacency is NOT commit
    /// adjacency, so range/contiguity math over it would lie.
    public func logRowClicked(sha: String, command: Bool = false, shift: Bool = false) {
        guard !isLogSearchActive else { return }
        if command {
            if selectedLogSHAs.contains(sha) {
                selectedLogSHAs.remove(sha)
                if logSelectionAnchor == sha { logSelectionAnchor = selectedLogSHAs.first }
            } else {
                selectedLogSHAs.insert(sha)
                logSelectionAnchor = sha
            }
        } else if shift,
                  let anchor = logSelectionAnchor,
                  let aIdx = logEntries.firstIndex(where: { $0.sha == anchor }),
                  let tIdx = logEntries.firstIndex(where: { $0.sha == sha }) {
            selectedLogSHAs = Set(logEntries[min(aIdx, tIdx)...max(aIdx, tIdx)].map(\.sha))
        } else {
            selectLogCommit(sha: sha)
        }
    }

    /// Drop the whole log selection (the selection bar's ✕, repo switch).
    public func clearLogSelection() {
        if !selectedLogSHAs.isEmpty { selectedLogSHAs = [] }
        logSelectionAnchor = nil
        if selectedLogSHA != nil { selectedLogSHA = nil }
    }

    // MARK: - Commit review (TSK-523)

    /// "Review Commit…" from the Log tab: find-or-create the `.commit(sha)`
    /// review in the repo's project-local store, activate its session, and
    /// switch to the Review tab. Idempotent per (repo, sha) — re-invoking
    /// reopens the SAME review (comments accumulate; no duplicates).
    public func openCommitReview(sha: String) {
        guard let root = repoRoot else { return }
        let store = ReviewStore.projectLocal(repoRoot: root)
        let git = GitClient(repoRoot: root)
        let review: Review
        if let existing = store.list()
            .compactMap({ store.load(id: $0.id) })
            .first(where: { $0.scope == .commit(sha: sha) }) {
            review = existing
        } else {
            let author = git.configuredAuthor() ?? ("Unknown", "")
            let now = Date()
            review = Review(
                id: ReviewID.generate(now: now),
                createdAt: now,
                updatedAt: now,
                title: "Review of \(sha)",
                scope: .commit(sha: sha),
                repoRoot: root.path,
                // base = the commit's (first) parent so `.old`-side anchors
                // resolve; a root commit's "sha^" fails rev-parse → blobSha
                // nil → staleness degrades to .unknown (documented).
                baseSha: "\(sha)^",
                headSha: sha,
                author: ReviewAuthor(name: author.name, email: author.email)
            )
            _ = store.save(review)
        }
        let session = ReviewSession(review: review, store: store, git: git)
        session.reload()
        activeReviewSession = session
        selectTab(.review)
    }

    /// TSK-909: reviews scoped to `sha` for the Git-log right-click "Reviews"
    /// submenu (lazy — called only when the submenu opens). Empty when no repo.
    public func reviewsForCommit(_ sha: String) -> [Review] {
        guard let root = repoRoot else { return [] }
        return ReviewStore.projectLocal(repoRoot: root).reviews(forCommit: sha)
    }

    /// Open an existing review from the index list (Stage 3 row click).
    public func openReview(id: String) {
        guard let root = repoRoot else { return }
        let store = ReviewStore.projectLocal(repoRoot: root)
        guard let review = store.load(id: id) else { return }
        let session = ReviewSession(review: review, store: store,
                                    git: GitClient(repoRoot: root))
        session.reload()
        activeReviewSession = session
        selectTab(.review)
    }

    /// Back from the open review to the index list. Flushes the debounced
    /// save so a just-typed comment isn't lost with the session.
    public func closeActiveReview() {
        activeReviewSession?.flush()
        activeReviewSession = nil
    }

    /// TSK-522: the `git diff base tip` range for the current
    /// multi-selection, or nil when fewer than two commits are selected.
    /// `topoIndex` = position in the loaded log, which IS topo order
    /// (`graphLog` passes `--topo-order`). A selected SHA that fell out
    /// of the list (wholesale log refresh) just drops out of the math.
    public var cumulativeLogSelectionRange: CumulativeDiffSelection.Range? {
        guard selectedLogSHAs.count > 1 else { return nil }
        let commits = logEntries.enumerated().compactMap { idx, c in
            selectedLogSHAs.contains(c.sha)
                ? CumulativeDiffSelection.Commit(sha: c.sha, topoIndex: idx, parents: c.parents)
                : nil
        }
        return CumulativeDiffSelection.resolve(commits)
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
        clearLogSelection()
        clearLogSearch()
        closeActiveReview()
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
        var treeMetas: [String: GitClient.CommitMeta]?
        var remotes: [GitClient.RemoteEntry]?
    }

    public func refreshCurrent() {
        guard let root = repoRoot else { return }
        let tab = selectedTab
        let page = logPageSize
        // TSK-1602: snapshot the all-refs flag on the main actor (like `page`)
        // so the detached loader never touches @Published state.
        let allRefs = showAllRefs
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
                case .log:     p.log     = client.graphLog(
                                            maxEntries: page, skip: 0, allRefs: allRefs)
                case .stash:   p.stash   = client.stashList()
                case .trees:
                    let trees = client.worktreeList()
                    p.trees = trees
                    // TSK-1604: one batched lookup for every worktree head.
                    p.treeMetas = client.commitMetas(shas: trees.map(\.head))
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
              logSearchResults == nil,  // TSK-596: search view isn't paged
              logLoadedCount > 0,
              logLoadedCount < logHardCap else { return }
        let skip = logLoadedCount
        let take = min(logIncrementSize, logHardCap - logLoadedCount)
        // Snapshot the list's identity. If a refresh / repo switch resets or
        // wholesale-replaces the log across the suspension below, `logGen`
        // (and `repoRoot` / `logLoadedCount`) move out from under us, and we
        // must discard `more` rather than append a stale or cross-repo page.
        let gen = logGen
        // TSK-1602: page with the SAME ref set the initial page used, or the
        // topo order shifts under the skip and rows duplicate/vanish.
        let allRefs = showAllRefs
        loadMoreTask?.cancel()
        loadMoreTask = Task { @MainActor [weak self] in
            let more = await Task.detached(priority: .utility) {
                GitClient(repoRoot: root).graphLog(
                    maxEntries: take, skip: skip, allRefs: allRefs)
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
        if let m = p.treeMetas, worktreeHeadMetas != m { worktreeHeadMetas = m }
        if let r = p.remotes, remoteEntries != r { remoteEntries = r }
        lastRefreshed[tab] = Date()
        if isRefreshing { isRefreshing = false }
    }

    // MARK: - Index actions (stage / unstage / commit / discard) — TSK-1443

    /// Stage a file (`git add`). Reversible; runs immediately.
    public func stage(path: String) { runIndexOp(.stage, path: path) }
    /// Unstage a file (`git reset HEAD` / `rm --cached` on unborn HEAD).
    public func unstage(path: String) { runIndexOp(.unstage, path: path) }

    /// Request a discard — opens the confirm dialog; NEVER runs the destructive
    /// op directly. `confirmDiscard()` (from the dialog) is the only path that
    /// actually reverts the file, so a discard can't happen without an explicit
    /// confirmation (`GitStageOp.discard.requiresConfirm`).
    public func requestDiscard(path: String) { pendingDiscard = path }
    public func cancelDiscard() { pendingDiscard = nil }
    public func confirmDiscard() {
        guard let path = pendingDiscard else { return }
        pendingDiscard = nil
        runIndexOp(.discard, path: path)
    }

    /// Commit the staged index with `commitMessage`. Refuses an empty message
    /// (toast feedback, no commit); on success clears the field + refreshes.
    public func commit() {
        let msg = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else {
            ToastCenter.shared.post(.error, "Enter a commit message to commit.")
            return
        }
        guard repoRoot != nil else { return }
        Task { @MainActor [weak self] in await self?.performCommit(message: msg) }
    }

    private func runIndexOp(_ op: GitStageOp, path: String) {
        guard repoRoot != nil else { return }
        Task { @MainActor [weak self] in await self?.performIndexOp(op, path: path) }
    }

    /// Awaitable core (also the host-test seam): run the mutation OFF-MAIN, then
    /// toast the outcome and refresh the Status tab. Returns whether it applied.
    @discardableResult
    func performIndexOp(_ op: GitStageOp, path: String) async -> Bool {
        guard let root = repoRoot else { return false }
        isMutating = true
        let result = await Task.detached(priority: .userInitiated) { () -> (ok: Bool, message: String) in
            let git = GitClient(repoRoot: root)
            switch op {
            case .stage:   return git.stage(path: path)
            case .unstage: return git.unstage(path: path)
            case .discard: return git.discardChanges(path: path)
            case .commit:  return (false, "commit is handled by performCommit")
            }
        }.value
        isMutating = false
        if result.ok {
            refreshCurrent()
        } else {
            ToastCenter.shared.post(.error, "Git \(op.verb) failed", detail: result.message)
        }
        return result.ok
    }

    /// Awaitable commit core (host-test seam). Empty-message guard lives in the
    /// public `commit()`; callers here pass a pre-trimmed non-empty message.
    @discardableResult
    func performCommit(message: String) async -> Bool {
        guard let root = repoRoot else { return false }
        isMutating = true
        let result = await Task.detached(priority: .userInitiated) {
            GitClient(repoRoot: root).commit(message: message)
        }.value
        isMutating = false
        if result.ok {
            commitMessage = ""
            refreshCurrent()
            ToastCenter.shared.post(.success, "Committed.")
        } else {
            ToastCenter.shared.post(.error, "Commit failed", detail: result.message)
        }
        return result.ok
    }

    // MARK: - Log search (TSK-596)

    /// The list the Log tab renders: the search match set while a
    /// search is active, the normal paged log otherwise.
    public var displayedLogEntries: [GitClient.GraphCommit] {
        logSearchResults ?? logEntries
    }

    public var isLogSearchActive: Bool { logSearchResults != nil }

    /// Debounced full-message search over the repo's history. Empty /
    /// whitespace query clears the search and restores the paged log.
    public func runLogSearch(_ rawQuery: String) {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        logSearchTask?.cancel()
        logSearchGen &+= 1
        guard let root = repoRoot, !q.isEmpty else {
            clearLogSearch()
            return
        }
        let gen = logSearchGen
        let debounce = logSearchDebounceNanos
        // TSK-1600: INSTANT local pass over the already-loaded rows — commit-id
        // prefix, branch/tag/remote-ref prefix, worktree prefix, and subject
        // substring resolve with no subprocess, so the list narrows as the user
        // types. The debounced `--grep` pass below adds BODY/description hits
        // (the loaded rows carry only the subject) and the union is published.
        let localHits = GitLogSearchQuery.filter(
            commits: logEntries, worktrees: searchWorktrees,
            refsFor: { $0.refs }, rawQuery: q)
        // Publish early hits ONLY when there are some: an empty local pass
        // would flash "0 results" before the authoritative grep lands.
        if !localHits.isEmpty { logSearchResults = localHits }
        logSearchIsSettled = false
        logSearchTask = Task { @MainActor [weak self] in
            if debounce > 0 {
                try? await Task.sleep(nanoseconds: debounce)
            }
            guard let self, !Task.isCancelled, self.logSearchGen == gen else { return }
            let hits = await Task.detached(priority: .utility) {
                GitClient(repoRoot: root).grepLog(query: q)
            }.value
            // Same staleness contract as loadMoreLog: the query, repo,
            // and generation must all still be the ones we searched for.
            guard !Task.isCancelled,
                  self.logSearchGen == gen,
                  self.repoRoot == root else { return }
            self.logSearchResults = GitLogSearchQuery.merge(local: localHits, body: hits)
            self.logSearchIsSettled = true
        }
    }

    public func clearLogSearch() {
        logSearchTask?.cancel()
        logSearchTask = nil
        logSearchGen &+= 1
        logSearchIsSettled = true
        if logSearchResults != nil { logSearchResults = nil }
        if !logSearchQuery.isEmpty { logSearchQuery = "" }
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
