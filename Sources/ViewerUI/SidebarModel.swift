import Foundation
import Combine
import ViewerCore
import os

/// Observable state for the file-browser sidebar. Lazily caches per-directory
/// children; UI calls `children(of:)` and trusts the result.
@MainActor
public final class SidebarModel: ObservableObject {
    @Published public private(set) var rootURL: URL?
    @Published public private(set) var expanded: Set<URL> = []
    @Published public var includeHidden: Bool = true {
        didSet {
            clearCache()   // also drops the flat-row memo
            invalidateDescendantsCache()   // global-find set changes too (TSK-666)
            for url in expanded { ensureLoaded(url: url) }
        }
    }
    @Published public var isVisible: Bool = false

    // MARK: - Global-find descendant cache (TSK-666, fuzzy filter mode B)

    /// One global-find candidate: a descendant of the root regardless of
    /// expansion state, with its root-relative display path.
    public struct DescendantEntry: Equatable, Sendable {
        public let url: URL
        /// Root-relative path (`/`-joined) — mode B ranks on this so deep
        /// matches benefit from path-segment word boundaries.
        public let relPath: String
        public let isDirectory: Bool
    }

    /// Bump published when a cache build COMPLETES, so the filter view can
    /// upgrade mode-A results to global results mid-typing. Deliberately
    /// the only published surface of the cache (one bump per build — not
    /// per-keystroke observation widening; the #215 rule).
    @Published public private(set) var descendantsVersion = 0

    /// nil = not built (or invalidated). Built OFF-MAIN by
    /// `ensureDescendantsCache()`; never touched from `body` (design rule 1).
    private var descendantsCache: [DescendantEntry]?
    private var descendantsBuildTask: Task<Void, Never>?
    /// Generation token: a build started before an invalidation must not
    /// land its (stale) result after it.
    private var descendantsGeneration = 0

    /// Skip-set for the global walk: heavyweight machine-managed trees
    /// that would dominate the candidate list without ever being what the
    /// user is fuzzy-finding. (The VISIBLE tree still shows them when
    /// expanded — this only scopes the global FIND set.)
    nonisolated static let descendantSkipNames: Set<String> =
        [".git", "node_modules", ".build", ".swiftpm", "dist"]

    /// Hard ceiling on the candidate list — a runaway tree (mounted volume,
    /// home dir as root) must not balloon memory. Logged on truncation.
    nonisolated static let descendantCap = 50_000

    /// The global-find candidates, or nil while unbuilt/building (callers
    /// fall back to the visible rows — typing never blocks on the walk).
    public func globalFindCandidates() -> [DescendantEntry]? { descendantsCache }

    /// Kick the off-main walk if no cache exists and none is building.
    /// Idempotent; completion bumps `descendantsVersion` on the main actor.
    public func ensureDescendantsCache() {
        guard descendantsCache == nil, descendantsBuildTask == nil,
              let root = rootURL else { return }
        let gen = descendantsGeneration
        let includeHidden = self.includeHidden
        descendantsBuildTask = Task { [weak self] in
            let entries = await Task.detached(priority: .utility) {
                Self.walkDescendants(root: root, includeHidden: includeHidden)
            }.value
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.descendantsBuildTask = nil
                // A root/hidden change invalidated this build mid-flight —
                // drop the stale result; the next ensure starts fresh.
                guard self.descendantsGeneration == gen else { return }
                self.descendantsCache = entries
                self.descendantsVersion &+= 1
            }
        }
    }

    /// Drop the cache and outdate any in-flight build. Hooked to the same
    /// signals that change the candidate set: root change (`setRoot` via
    /// `clearCache`... root path), hidden-toggle, and FSEvents mutations.
    private func invalidateDescendantsCache() {
        descendantsGeneration &+= 1
        descendantsCache = nil
        descendantsBuildTask?.cancel()
        descendantsBuildTask = nil
    }

    /// The off-main walk. `FileManager.enumerator` honors the hidden flag;
    /// the skip-set prunes whole subtrees via `skipDescendants`. Capped.
    nonisolated static func walkDescendants(
        root: URL, includeHidden: Bool
    ) -> [DescendantEntry] {
        let opts: FileManager.DirectoryEnumerationOptions =
            includeHidden ? [] : [.skipsHiddenFiles]
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: opts
        ) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var out: [DescendantEntry] = []
        for case let url as URL in walker {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            if isDir, descendantSkipNames.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            out.append(DescendantEntry(
                url: url,
                relPath: String(path.dropFirst(rootPath.count + 1)),
                isDirectory: isDir
            ))
            if out.count >= descendantCap {
                Logger(subsystem: "com.markdownviewer", category: "sidebar")
                    .warning("global-find walk hit the \(Self.descendantCap) cap — list truncated")
                break
            }
        }
        return out
    }

    /// Expand every ancestor directory of `url` (mode-B auto-reveal): a
    /// filtered hit inside a collapsed branch stays visible when the
    /// filter clears. Loads each newly-expanded level's children so the
    /// flat tree can actually render the chain.
    public func revealAncestors(of url: URL) {
        guard let root = rootURL else { return }
        let rootPath = root.standardizedFileURL.path
        var chain: [URL] = []
        var dir = url.standardizedFileURL.deletingLastPathComponent()
        while dir.path.hasPrefix(rootPath + "/") || dir.path == rootPath {
            chain.append(dir)
            if dir.path == rootPath { break }
            dir = dir.deletingLastPathComponent()
        }
        for d in chain.reversed() {
            expanded.insert(d)
            ensureLoaded(url: d)
        }
        invalidateFlatCache()
    }

    // Git status / repo-root / root-override moved OUT of SidebarModel
    // into the multi-repo git registry (`TrackedReposChannel` read side,
    // `TrackedReposStore` write side, `RepoFocusTracker` demand/pins).
    // SidebarModel is back to pure file-tree state. Views read git via
    // `model.trackedRepos.status(for:)` / `.repoRootKind(_:)` etc., and
    // pin via `model.repoFocus.togglePin(_:)`.

    /// "Does the current project have Claude transcripts?" — single
    /// source of truth for both the accordion (Claude timeline section)
    /// and the shoulder rail's Claude button filled-state.
    ///
    /// Previously cached in `SidebarView`'s `@State` and refreshed via
    /// an `.onChange(of: rootURL)`; moved here so the rail (which lives
    /// OUTSIDE `SidebarView`) reads the same flag — otherwise the
    /// button's filled-state and the accordion's presence diverge.
    ///
    /// Refreshed in `setRoot(_:)` via a shallow `FileManager` existence
    /// check (`ClaudeLogParser.hasTranscripts`). It already ran on the
    /// main actor (indirectly via the view's `.onChange`); keep it a
    /// shallow check — a deep scan would have to move off-main.
    @Published public private(set) var claudeHasTranscripts: Bool = false

    /// Memoized git working-tree root for the current `rootURL` (the
    /// nearest ancestor containing `.git`), or nil when the root isn't
    /// inside a repo.
    ///
    /// PERF: `GitClient.discoverRoot(from:)` walks up to 32 ancestors
    /// doing a `fileExists` syscall per step. SidebarView called it from
    /// TWO body getters (`folderStatsAvailable`, `filesPanel`) on EVERY
    /// body pass — and the sidebar re-bodies constantly. That was ~64
    /// syscalls per pass for a value that only changes when the root
    /// changes (or a `.git` appears/disappears at the root). Cache it
    /// here: computed once in `setRoot(_:)`, re-discovered in
    /// `onFolderChange` only when the root directory itself is among the
    /// changed dirs (covers `git init` / `git clone` / repo removal at the
    /// root). Views read this published value instead of FS-walking.
    @Published public private(set) var gitRepoRoot: URL?

    /// Keyboard-driven row selection (CRIT-6). Distinct from the currently-
    /// open file (`DocumentModel.currentURL`): you can navigate the sidebar
    /// with arrow keys without opening every file you scroll past.
    @Published public private(set) var selectedURL: URL?

    /// Monotonic counter bumped whenever the recency-stripe inputs for
    /// one or more visible files may have changed (RWC-3). `FileRowView`
    /// observes this to re-load its cached `FileTreeRecencyAttributes`
    /// after `FileTreeRecencyCache.invalidate(_:)` has been called for
    /// the affected URLs — closing the gap where the stripe was frozen
    /// "as of first render" because the per-URL `invalidate` was never
    /// wired to the FolderWatcher / save path. Incremented on the main
    /// actor only.
    @Published public private(set) var recencyVersion: Int = 0

    private let service: FileTreeService
    private var childrenCache: [URL: [FileNode]] = [:]
    /// Insertion / touch order for `childrenCache`, oldest first
    /// (RWC-5). Plain `Dictionary` iteration order is unspecified, so
    /// the old prune evicted arbitrary entries — easily the ones we'd
    /// re-read next. This list gives the prune a real LRU axis: a key
    /// is appended (and any prior occurrence removed) every time its
    /// cache entry is written, so the tail is the most-recently-touched
    /// and the head is the coldest. Kept in lockstep with the dict:
    /// writes go through `storeChildren(_:for:)`, removals through the
    /// prune loop / `clearCache()`.
    private var childrenCacheOrder: [URL] = []

    /// FSEvents stream watching the current root recursively.
    /// Replaced on every `setRoot(_:)`. nil when no root open.
    private var folderWatcher: FolderWatcher?

    public init(
        service: FileTreeService = FileTreeService()
    ) {
        self.service = service
    }

    public func setRoot(_ url: URL?) {
        let normalized = url?.standardizedFileURL.resolvingSymlinksInPath()
        // If we're being asked to set the same root we already have,
        // preserve the existing expansion state and selection. Otherwise
        // opening the same folder via Open Recent collapses every
        // expansion the user has made.
        if normalized == rootURL {
            isVisible = (rootURL != nil)
            return
        }
        rootURL = normalized
        expanded.removeAll()
        clearCache()   // also drops the flat-row memo
        invalidateDescendantsCache()   // new root = new global-find set (TSK-666)
        folderWatcher?.stop()
        folderWatcher = nil
        // Refresh the Claude-transcript flag on every root change. Cheap
        // shallow FS existence check; runs on the main actor (this whole
        // method is @MainActor) — same place it ran before via the
        // view's `.onChange(of: rootURL)`.
        claudeHasTranscripts = ClaudeLogParser.hasTranscripts(for: rootURL)
        // Memoize the git-root discovery once per root change (see
        // `gitRepoRoot`). Same place / cadence as the transcript flag.
        gitRepoRoot = rootURL.flatMap { GitClient.discoverRoot(from: $0) }
        if let url = rootURL {
            expanded.insert(url)
            ensureLoaded(url: url)
            // Git status is now driven by RepoFocusTracker's $rootURL
            // Combine sink → recompute() (which retains the repo + starts
            // its per-root watcher). SidebarModel no longer spawns git.
            selectedURL = url
            // Start the FSEvents stream. Any external change in the
            // tree (new file via Terminal, branch switch, etc.)
            // invalidates the affected directory's cache and refires
            // the dependent SwiftUI views.
            folderWatcher = try? FolderWatcher(url: url) { [weak self] dirs in
                // Callback hops to .main by default — safe to mutate.
                MainActor.assumeIsolated {
                    self?.onFolderChange(dirs)
                }
            }
        } else {
            selectedURL = nil
        }
        isVisible = (rootURL != nil)
    }

    /// Called by the FSEvents stream when one or more directories in
    /// the watched tree have changed. Re-reads a changed dir if its
    /// children are (or should be) on screen, then re-publishes.
    ///
    /// FW-6: the visibility test is now explicit. A directory's children
    /// are rendered iff the directory is `expanded`. We refresh a changed
    /// dir when it's `expanded` OR already cached — so a creation inside a
    /// visible-but-pruned directory (cache evicted, still expanded) is no
    /// longer silently dropped. We deliberately still skip changed dirs
    /// that are neither (a `node_modules` write burst under a collapsed
    /// node doesn't fan out into a reload).
    ///
    /// RWC-3: for every refreshed dir we invalidate the recency-attribute
    /// cache for the dir and its children, then bump `recencyVersion` so
    /// `FileRowView` re-loads its stripe color (previously frozen because
    /// `FileTreeRecencyCache.invalidate` was never wired to anything).
    private func onFolderChange(_ dirs: [URL]) {
        // P2 #1: the FSEvents tick fires on any fs change under the watched
        // tree; a build / `git checkout` is a write STORM. Re-listing each
        // touched dir (`contentsOfDirectory` + a `realpath` syscall per
        // child + a sort) ran SYNCHRONOUSLY on the main actor here — a
        // main-thread stall proportional to (dirs × children) on every
        // burst. (FolderWatcher already debounces the stream, so this is
        // one re-list per coalesced tick, but a wide dir still stalls.)
        //
        // Fix: do the directory I/O OFF the main actor (`Task.detached`),
        // then hop back to compare/store/publish. Recency-cache invalidation
        // is NSLock-guarded (thread-safe) so it can run on the detached side.
        //
        // Filtering to visible/cached dirs is a cheap main-actor set/dict
        // lookup — do it here so we only pay the I/O for dirs that matter.
        let toRead: [URL] = dirs.map(normalize).filter {
            expanded.contains($0) || childrenCache[$0] != nil
        }
        guard !toRead.isEmpty else { return }

        let service = self.service
        let includeHidden = self.includeHidden
        Task.detached(priority: .utility) {
            // OFF-MAIN: the readdir + per-child stat/realpath + sort, plus
            // the (thread-safe) recency-cache invalidation.
            var results: [(dir: URL, kids: [FileNode])] = []
            for d in toRead {
                let kids = (try? service.children(of: d, includeHidden: includeHidden)) ?? []
                FileTreeRecencyCache.invalidate(d)
                for kid in kids { FileTreeRecencyCache.invalidate(kid.url) }
                results.append((d, kids))
            }
            await self.applyFolderChange(results)
        }
    }

    /// Main-actor tail of `onFolderChange`: compare the freshly-listed
    /// children (read off-main) against the cache, store the changed ones,
    /// and publish. Kept tiny + main-isolated so the publish path is
    /// unchanged — only the I/O moved off-main.
    private func applyFolderChange(_ results: [(dir: URL, kids: [FileNode])]) {
        var touched = false
        for (d, kids) in results {
            // The dir may have been collapsed / evicted while the I/O ran;
            // only apply if it's still visible or cached (re-check on main).
            guard expanded.contains(d) || childrenCache[d] != nil else { continue }
            if kids != childrenCache[d] {
                storeChildren(kids, for: d)
                sortedCache = sortedCache.filter { $0.key.url != d }
                touched = true
            }
        }
        // If the ROOT directory itself was among the changed dirs, a `.git`
        // may have appeared / disappeared (e.g. `git init`, `git clone`,
        // `rm -rf .git`). Re-discover the memoized git root so the
        // folder-stats toggle's availability tracks reality. Cheap walk,
        // gated to the rare root-dir-change case — not every FSEvents tick.
        if let root = rootURL, results.contains(where: { $0.dir == root }) {
            let rediscovered = GitClient.discoverRoot(from: root)
            if rediscovered != gitRepoRoot { gitRepoRoot = rediscovered }
        }
        // Recency stripes may have shifted regardless of whether the child
        // LIST changed (a child's mtime moved on a content edit), and the
        // off-main invalidation already dropped the affected entries — so
        // bump the version unconditionally for the dirs we re-read.
        if !results.isEmpty { recencyVersion &+= 1 }
        guard touched else { return }
        invalidateFlatCache()
        // An external mutation changed the candidate set — the global-find
        // cache rebuilds lazily on the next filter use (TSK-666).
        invalidateDescendantsCache()
        // Force a publish so SwiftUI re-bodies. expanded is the
        // cheapest @Published prop to nudge — assigning the same
        // value is value-blind and refires (LESSONS).
        let snapshot = expanded
        expanded = snapshot
    }

    /// SidebarModel-side hook for in-app file mutations (Save, Git apply,
    /// formatter rewrite, etc.) — RWC-3's "save-observer". FSEvents
    /// *will* eventually fire `onFolderChange` for the parent directory,
    /// but with latency; calling this immediately after a write refreshes
    /// the row's recency stripe on the next body pass without waiting for
    /// the FSEvents coalesce window. Invalidates the URL's recency entry
    /// (and its parent dir's, whose mtime moves on add/remove) and bumps
    /// `recencyVersion`. Cheap + idempotent; safe to over-call.
    public func fileDidChange(_ url: URL) {
        let resolved = normalize(url)
        FileTreeRecencyCache.invalidate(resolved)
        FileTreeRecencyCache.invalidate(resolved.deletingLastPathComponent())
        recencyVersion &+= 1
    }

    /// TSK-329: force a synchronous re-list of `directory`'s children after
    /// an IN-APP file creation, so the new file appears in the tree
    /// immediately instead of waiting for the FSEvents coalesce window.
    /// (`fileDidChange` only touches recency, not the child LIST.) Cheap —
    /// one `contentsOfDirectory` — and idempotent. Also expands the dir so
    /// the freshly-listed child is actually visible.
    public func reloadChildren(of directory: URL) {
        let dir = normalize(directory)
        let kids = (try? service.children(of: dir, includeHidden: includeHidden)) ?? []
        storeChildren(kids, for: dir)
        expanded.insert(dir)
        invalidateFlatCache()
        descendantsCache = nil   // the global-find set changed (TSK-666)
        // Nudge a publish (assigning the same Set value refires — LESSONS).
        let snapshot = expanded
        expanded = snapshot
    }

    // MARK: Keyboard navigation (CRIT-6)

    public func setSelected(_ url: URL?) {
        let new = url.map(normalize)
        guard new != selectedURL else { return }   // avoid no-op republishes
        selectedURL = new
    }

    /// A single visible row in the flattened file tree, with the depth
    /// it should be indented at. Depth 0 == root.
    public struct VisibleRow: Equatable, Sendable, Identifiable {
        public let node: FileNode
        public let depth: Int
        public var id: URL { node.url }
    }

    /// Flat list of (node, depth) pairs currently visible in the tree, in
    /// display order. Cached and invalidated whenever expansion / root /
    /// hidden-toggle / children-cache changes (`invalidateFlatCache()`).
    ///
    /// This is the source of truth for the SwiftUI `LazyVStack`-backed
    /// `FileRowView` rendering: by flattening server-side we let
    /// `LazyVStack` virtualize the entire visible window, which it can't
    /// do when each row's body recursively materializes its own
    /// children via a non-lazy `ForEach` (perf #6).
    public func flatVisibleRows() -> [VisibleRow] {
        if let cached = cachedFlatRows { return cached }
        guard let root = rootURL else {
            cachedFlatRows = []
            return []
        }
        var out: [VisibleRow] = [
            VisibleRow(
                node: FileNode(url: root, name: root.lastPathComponent, isDirectory: true),
                depth: 0
            )
        ]
        appendVisibleChildren(of: root, depth: 1, into: &out)
        cachedFlatRows = out
        return out
    }

    /// Backward-compat wrapper around `flatVisibleRows()` that drops the
    /// depth column. Kept so existing callers (keyboard nav,
    /// `node(for:)`, tests) don't have to care about depth.
    public func flatVisibleNodes() -> [FileNode] {
        flatVisibleRows().map { $0.node }
    }

    /// Returns the FileNode for `url` if it's currently in the visible tree.
    private func node(for url: URL) -> FileNode? {
        flatVisibleRows().first { $0.node.url == url }?.node
    }

    private func appendVisibleChildren(
        of url: URL, depth: Int, into out: inout [VisibleRow]
    ) {
        guard isExpanded(url) else { return }
        for child in children(of: url) {
            out.append(VisibleRow(node: child, depth: depth))
            if child.isDirectory {
                appendVisibleChildren(of: child.url, depth: depth + 1, into: &out)
            }
        }
    }

    public func selectNext() {
        let visible = flatVisibleNodes()
        guard !visible.isEmpty else { return }
        if let cur = selectedURL,
           let i = visible.firstIndex(where: { $0.url == cur }) {
            setSelected(visible[min(i + 1, visible.count - 1)].url)
        } else {
            setSelected(visible.first?.url)
        }
    }

    public func selectPrevious() {
        let visible = flatVisibleNodes()
        guard !visible.isEmpty else { return }
        if let cur = selectedURL,
           let i = visible.firstIndex(where: { $0.url == cur }) {
            setSelected(visible[max(i - 1, 0)].url)
        } else {
            setSelected(visible.last?.url)
        }
    }

    /// Left-arrow semantics: if a directory is expanded, collapse it.
    /// Otherwise, move selection to its parent directory (unless we're at
    /// or above the root).
    public func collapseOrFocusParent() {
        guard let cur = selectedURL else { return }
        if isExpanded(cur) {
            expanded.remove(cur)
            invalidateFlatCache()
            return
        }
        // The parent is simply deletingLastPathComponent. Only move if the
        // parent is still inside the user's rooted view.
        guard let root = rootURL, cur != root else { return }
        let parent = normalize(cur.deletingLastPathComponent())
        guard parent.path.hasPrefix(root.path) else { return }
        setSelected(parent)
    }

    /// Right-arrow semantics: if a directory is collapsed, expand it.
    /// Otherwise, move to the first child (if any). The "is directory" check
    /// reads the cached `FileNode.isDirectory` instead of hitting the
    /// filesystem on every keystroke.
    public func expandOrFocusFirstChild() {
        guard let cur = selectedURL else { return }
        let isDir = (cur == rootURL) || (node(for: cur)?.isDirectory ?? false)
        guard isDir else { return }
        if !isExpanded(cur) {
            expanded.insert(normalize(cur))
            ensureLoaded(url: cur)
            invalidateFlatCache()
            return
        }
        if let first = children(of: cur).first {
            setSelected(first.url)
        }
    }

    public func toggleVisibility() {
        isVisible.toggle()
    }

    public func toggleExpansion(_ url: URL) {
        let key = normalize(url)
        if expanded.contains(key) {
            expanded.remove(key)
        } else {
            expanded.insert(key)
            ensureLoaded(url: key)
        }
        invalidateFlatCache()
    }

    public func isExpanded(_ url: URL) -> Bool {
        expanded.contains(normalize(url))
    }

    /// Cache-only read. Safe to call from SwiftUI bodies; never does IO.
    /// Result is cached per `(url, sortMode, includeHidden, raw-count)`.
    /// Without this, the FILES tree re-sorted every expanded directory
    /// per body re-eval — at ~30 visible rows + 5–10 expanded dirs ×
    /// 200 entries that's 10K compares per redraw on a wide repo.
    public func children(of url: URL) -> [FileNode] {
        let key = normalize(url)
        let raw = childrenCache[key] ?? []
        let cacheKey = SortedKey(
            url: key, sortMode: sortMode,
            includeHidden: includeHidden, rawCount: raw.count
        )
        if let hit = sortedCache[cacheKey] { return hit }
        let result = sortChildren(raw)
        // Bound the sorted cache. Real working set is the open tree.
        if sortedCache.count > 512 {
            sortedCache.removeAll(keepingCapacity: true)
        }
        sortedCache[cacheKey] = result
        return result
    }

    private struct SortedKey: Hashable {
        let url: URL
        let sortMode: FolderSortMode
        let includeHidden: Bool
        let rawCount: Int
    }
    private var sortedCache: [SortedKey: [FileNode]] = [:]

    @Published public var sortMode: FolderSortMode = .name {
        didSet {
            sortedCache.removeAll(keepingCapacity: true)
            invalidateFlatCache()
        }
    }

    public enum FolderSortMode: String, CaseIterable, Identifiable, Sendable {
        case name = "Name"
        case sizeDescending = "Size"
        case modifiedDescending = "Recent"
        case modifiedAscending = "Added"
        public var id: String { rawValue }
    }

    /// Apply the current sort mode. Directories always sort before
    /// files (Finder-like), then within each group the chosen mode
    /// applies. Falls back to name for fields a node doesn't have
    /// (e.g. size is nil for directories).
    private func sortChildren(_ nodes: [FileNode]) -> [FileNode] {
        switch sortMode {
        case .name:
            return nodes  // service already returns in name order
        case .sizeDescending:
            return nodes.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                if lhs.isDirectory { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
                return (lhs.byteCount ?? 0) > (rhs.byteCount ?? 0)
            }
        case .modifiedDescending:
            return nodes.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                let lm = lhs.modifiedAt ?? .distantPast
                let rm = rhs.modifiedAt ?? .distantPast
                if lm != rm { return lm > rm }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        case .modifiedAscending:
            return nodes.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                let lm = lhs.modifiedAt ?? .distantFuture
                let rm = rhs.modifiedAt ?? .distantFuture
                if lm != rm { return lm < rm }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    /// Loads (synchronously) and caches the directory's children if not yet
    /// cached. Call from event handlers (setRoot, toggleExpansion), never
    /// from a SwiftUI body.
    @discardableResult
    public func ensureLoaded(url: URL) -> [FileNode] {
        let key = normalize(url)
        if let cached = childrenCache[key] { return cached }
        let kids = (try? service.children(of: key, includeHidden: includeHidden)) ?? []
        storeChildren(kids, for: key)
        invalidateFlatCache()
        pruneChildrenCacheIfNeeded()
        return kids
    }

    /// Write a `childrenCache` entry and record it as most-recently-used
    /// in `childrenCacheOrder`. Centralised so the dict and the LRU list
    /// never drift (RWC-5).
    private func storeChildren(_ kids: [FileNode], for key: URL) {
        childrenCache[key] = kids
        if let i = childrenCacheOrder.firstIndex(of: key) {
            childrenCacheOrder.remove(at: i)
        }
        childrenCacheOrder.append(key)
    }

    /// Cap on `childrenCache` size. Each entry is `[FileNode]` for one
    /// directory; on a wide monorepo, expanded directories can pile
    /// up to thousands of entries over a long session.
    ///
    /// RWC-5: prune the genuinely-coldest entries (head of the LRU
    /// `childrenCacheOrder` list), skipping the root and any expanded
    /// dir (evicting those would visibly collapse the tree), and **loop
    /// until we're actually under target**. The previous version sliced
    /// `prefix(dropCount)` off an unordered `Dictionary.keys`, so (a)
    /// eviction was arbitrary rather than LRU, and (b) every skipped
    /// root/expanded key still consumed a slot in that fixed-size slice,
    /// so a working set dominated by expanded dirs under-evicted and the
    /// cache could sit permanently over cap.
    private static let childrenCacheMax = 256
    private func pruneChildrenCacheIfNeeded() {
        let target = Self.childrenCacheMax * 2 / 3
        guard childrenCache.count > Self.childrenCacheMax else { return }
        var idx = 0
        // Walk oldest → newest. `childrenCacheOrder` head is coldest.
        while childrenCache.count > target, idx < childrenCacheOrder.count {
            let key = childrenCacheOrder[idx]
            // Keep dirs we still actively need on screen.
            if key == rootURL || expanded.contains(key) {
                idx += 1
                continue
            }
            childrenCache.removeValue(forKey: key)
            childrenCacheOrder.remove(at: idx)
            // Don't advance idx: remove(at:) shifted the next element
            // into this slot.
        }
        // Order list can accumulate stale keys only via the paths above,
        // which keep it in sync; nothing else to reconcile here.
    }

    private func normalize(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    // MARK: Flat-visible cache

    /// Memoized flat list of visible (node, depth) rows — recomputed
    /// lazily after any expand/collapse/setRoot/hidden-toggle/children-
    /// cache mutation. Avoids walking the tree on every arrow-key
    /// keystroke (which used to call flatVisibleNodes twice per press)
    /// and serves the LazyVStack-based render path in `SidebarView`.
    private var cachedFlatRows: [VisibleRow]?

    private func invalidateFlatCache() {
        cachedFlatRows = nil
    }

    /// Drops every derived cache in one shot. The flat-row memo
    /// (`cachedFlatRows`) is invalidated HERE rather than left to each
    /// caller: it is derived from `childrenCache`, so clearing the
    /// children cache without dropping the memo leaves a stale flattened
    /// tree (the exact desync hit by `DocumentModel`'s git-checkout
    /// `clearCache()` call, which has no access to the private
    /// `invalidateFlatCache()`). Folding it in makes the two impossible
    /// to drift.
    public func clearCache() {
        childrenCache.removeAll()
        childrenCacheOrder.removeAll()
        sortedCache.removeAll()
        cachedFlatRows = nil
    }
}
