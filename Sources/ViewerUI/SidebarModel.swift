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

    // Git status / repo-root / root-override moved OUT of SidebarModel
    // into the multi-repo git registry (`TrackedReposChannel` read side,
    // `TrackedReposStore` write side, `RepoFocusTracker` demand/pins).
    // SidebarModel is back to pure file-tree state. Views read git via
    // `model.trackedRepos.status(for:)` / `.repoRootKind(_:)` etc., and
    // pin via `model.repoFocus.togglePin(_:)`.

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
        clearCache()
        invalidateFlatCache()
        folderWatcher?.stop()
        folderWatcher = nil
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
        var touched = false
        var recencyDirty = false
        let norm = dirs.map(normalize)
        for d in norm {
            // Visible-children test (FW-6): expanded dirs render their
            // children; cached dirs we keep coherent regardless.
            guard expanded.contains(d) || childrenCache[d] != nil else { continue }
            // Re-read on the spot. Cheap (single readdir).
            let kids = (try? service.children(of: d, includeHidden: includeHidden)) ?? []
            if kids != childrenCache[d] {
                storeChildren(kids, for: d)
                sortedCache = sortedCache.filter { $0.key.url != d }
                touched = true
            }
            // A change under `d` can mean a child's mtime/ctime moved
            // (content edited) or the dir's own mtime moved (add/remove).
            // Drop the affected recency entries so the next read re-stats.
            FileTreeRecencyCache.invalidate(d)
            for kid in kids { FileTreeRecencyCache.invalidate(kid.url) }
            recencyDirty = true
        }
        if recencyDirty { recencyVersion &+= 1 }
        guard touched else { return }
        invalidateFlatCache()
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

    public func clearCache() {
        childrenCache.removeAll()
        childrenCacheOrder.removeAll()
        sortedCache.removeAll()
    }
}
