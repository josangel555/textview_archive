import Foundation
import Combine
import ViewerCore

/// Observable state for the file-browser sidebar. Lazily caches per-directory
/// children; UI calls `children(of:)` and trusts the result.
@MainActor
public final class SidebarModel: ObservableObject {
    @Published public private(set) var rootURL: URL?
    @Published public private(set) var expanded: Set<URL> = []
    @Published public var includeHidden: Bool = false {
        didSet {
            clearCache()
            invalidateFlatCache()
            for url in expanded { ensureLoaded(url: url) }
        }
    }
    @Published public var isVisible: Bool = false
    @Published public private(set) var gitStatuses: [URL: GitStatusEntry.Status] = [:]
    @Published public private(set) var gitRepoRoot: URL?

    /// User-set git-root override. When set, `refreshGitStatus()`
    /// uses this folder as the repo root instead of auto-discovering
    /// via `.git/` walk. Useful for nested worktrees, monorepo
    /// subdirs, or submodules.
    @Published public var gitRootOverride: URL? = nil

    /// Keyboard-driven row selection (CRIT-6). Distinct from the currently-
    /// open file (`DocumentModel.currentURL`): you can navigate the sidebar
    /// with arrow keys without opening every file you scroll past.
    @Published public private(set) var selectedURL: URL?

    private let service: FileTreeService
    private let git: GitService
    private var childrenCache: [URL: [FileNode]] = [:]

    /// FSEvents stream watching the current root recursively.
    /// Replaced on every `setRoot(_:)`. nil when no root open.
    private var folderWatcher: FolderWatcher?

    public init(
        service: FileTreeService = FileTreeService(),
        git: GitService = GitService()
    ) {
        self.service = service
        self.git = git
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
        clearCache()
        invalidateFlatCache()
        gitStatuses = [:]
        gitRepoRoot = nil
        folderWatcher?.stop()
        folderWatcher = nil
        if let url = rootURL {
            expanded.insert(url)
            ensureLoaded(url: url)
            refreshGitStatus()
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
    /// the watched tree have changed. Only invalidates dirs we
    /// actually have cached (so a `node_modules` burst doesn't fan
    /// out into a full reload). Re-publishes by mutating
    /// `childrenCache` indirectly via the flat-cache invalidation +
    /// a no-op assignment to a published prop.
    private func onFolderChange(_ dirs: [URL]) {
        var touched = false
        let norm = dirs.map(normalize)
        for d in norm {
            if childrenCache[d] != nil {
                // Re-read on the spot. Cheap (single readdir).
                let kids = (try? service.children(of: d, includeHidden: includeHidden)) ?? []
                if kids != childrenCache[d] {
                    childrenCache[d] = kids
                    sortedCache = sortedCache.filter { $0.key.url != d }
                    touched = true
                }
            }
        }
        guard touched else { return }
        invalidateFlatCache()
        // Force a publish so SwiftUI re-bodies. expanded is the
        // cheapest @Published prop to nudge — assigning the same
        // value is value-blind and refires (LESSONS).
        let snapshot = expanded
        expanded = snapshot
    }

    // MARK: Keyboard navigation (CRIT-6)

    public func setSelected(_ url: URL?) {
        let new = url.map(normalize)
        guard new != selectedURL else { return }   // avoid no-op republishes
        selectedURL = new
    }

    /// Flat list of nodes currently visible in the tree, in display order.
    /// Cached and invalidated whenever expansion / root / hidden-toggle /
    /// children-cache changes (`invalidateFlatCache()`).
    public func flatVisibleNodes() -> [FileNode] {
        if let cached = cachedFlat { return cached }
        guard let root = rootURL else {
            cachedFlat = []
            return []
        }
        var out: [FileNode] = [
            FileNode(url: root, name: root.lastPathComponent, isDirectory: true)
        ]
        appendVisibleChildren(of: root, into: &out)
        cachedFlat = out
        return out
    }

    /// Returns the FileNode for `url` if it's currently in the visible tree.
    private func node(for url: URL) -> FileNode? {
        flatVisibleNodes().first { $0.url == url }
    }

    private func appendVisibleChildren(of url: URL, into out: inout [FileNode]) {
        guard isExpanded(url) else { return }
        for child in children(of: url) {
            out.append(child)
            if child.isDirectory {
                appendVisibleChildren(of: child.url, into: &out)
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

    public func gitStatus(for url: URL) -> GitStatusEntry.Status? {
        gitStatuses[normalizedForGit(url)]
    }

    /// `resolvingSymlinksInPath()` is a `realpath` syscall. Called
    /// per visible sidebar row per body re-eval, on a 200-row tree
    /// this fired hundreds of stats per redraw. Cache the input→
    /// resolved mapping; entries are cleared whenever the sidebar
    /// root or git status map churns (callers set both at once).
    private var normalizationCache: [URL: URL] = [:]
    private func normalizedForGit(_ url: URL) -> URL {
        if let hit = normalizationCache[url] { return hit }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        // Cap the dict size; sidebar churns row URLs as it scrolls,
        // but the visible set + recently-scrolled-out is bounded.
        if normalizationCache.count > 2048 {
            normalizationCache.removeAll(keepingCapacity: true)
        }
        normalizationCache[url] = resolved
        return resolved
    }

    public func refreshGitStatus() {
        guard let root = rootURL else {
            gitStatuses = [:]
            gitRepoRoot = nil
            return
        }
        // User override wins over auto-discovery.
        let repoRoot: URL
        if let override = gitRootOverride {
            repoRoot = override
        } else if let discovered = git.repoRoot(for: root) {
            repoRoot = discovered
        } else {
            gitStatuses = [:]
            gitRepoRoot = nil
            return
        }
        gitRepoRoot = repoRoot
        let service = git
        // CRIT-5: capture the repo root as a token so the main-actor hop
        // can refuse to write stale results if `setRoot(_:)` switched us
        // to a different folder while git was running. The outer Task is
        // @MainActor so `self` can be captured safely; the blocking git
        // shell-out lives in a detached child whose return value is a
        // Sendable `[URL: Status]` map.
        let token = repoRoot
        Task { @MainActor [weak self] in
            let map = await Task.detached(priority: .userInitiated) {
                () -> [URL: GitStatusEntry.Status] in
                let entries = (try? service.status(at: repoRoot)) ?? []
                var result: [URL: GitStatusEntry.Status] = [:]
                for entry in entries {
                    let url = repoRoot.appendingPathComponent(entry.path)
                        .standardizedFileURL.resolvingSymlinksInPath()
                    result[url] = entry.status
                }
                return result
            }.value
            guard let self, self.gitRepoRoot == token else { return }
            // Equality guard: idle polls + tab-switch refreshes
            // commonly produce identical maps.
            if self.gitStatuses != map { self.gitStatuses = map }
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
        childrenCache[key] = kids
        invalidateFlatCache()
        pruneChildrenCacheIfNeeded()
        return kids
    }

    /// Cap on `childrenCache` size. Each entry is `[FileNode]` for one
    /// directory; on a wide monorepo, expanded directories can pile
    /// up to thousands of entries over a long session. Pruning is
    /// arbitrary (Dictionary key order has no semantic meaning); the
    /// dropped entries repopulate on next expand.
    private static let childrenCacheMax = 256
    private func pruneChildrenCacheIfNeeded() {
        guard childrenCache.count > Self.childrenCacheMax else { return }
        let dropCount = childrenCache.count - Self.childrenCacheMax * 2 / 3
        for key in childrenCache.keys.prefix(dropCount) {
            // Skip dirs we still actively need: the root and any
            // currently-expanded directory. Without this guard, the
            // sidebar tree would visibly collapse on prune.
            if key == rootURL || expanded.contains(key) { continue }
            childrenCache.removeValue(forKey: key)
        }
    }

    private func normalize(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    // MARK: Flat-visible cache

    /// Memoized flat list of visible nodes — recomputed lazily after any
    /// expand/collapse/setRoot/hidden-toggle/children-cache mutation.
    /// Avoids walking the tree on every arrow-key keystroke (which used to
    /// call flatVisibleNodes twice per press).
    private var cachedFlat: [FileNode]?

    private func invalidateFlatCache() {
        cachedFlat = nil
    }

    public func clearCache() {
        childrenCache.removeAll()
        sortedCache.removeAll()
    }
}
