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

    /// Keyboard-driven row selection (CRIT-6). Distinct from the currently-
    /// open file (`DocumentModel.currentURL`): you can navigate the sidebar
    /// with arrow keys without opening every file you scroll past.
    @Published public private(set) var selectedURL: URL?

    private let service: FileTreeService
    private let git: GitService
    private var childrenCache: [URL: [FileNode]] = [:]

    public init(
        service: FileTreeService = FileTreeService(),
        git: GitService = GitService()
    ) {
        self.service = service
        self.git = git
    }

    public func setRoot(_ url: URL?) {
        rootURL = url?.standardizedFileURL.resolvingSymlinksInPath()
        expanded.removeAll()
        clearCache()
        invalidateFlatCache()
        gitStatuses = [:]
        gitRepoRoot = nil
        if let url = rootURL {
            expanded.insert(url)
            ensureLoaded(url: url)
            refreshGitStatus()
            selectedURL = url
        } else {
            selectedURL = nil
        }
        isVisible = (rootURL != nil)
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
        gitStatuses[url.standardizedFileURL.resolvingSymlinksInPath()]
    }

    public func refreshGitStatus() {
        guard let root = rootURL else {
            gitStatuses = [:]
            gitRepoRoot = nil
            return
        }
        guard let repoRoot = git.repoRoot(for: root) else {
            gitStatuses = [:]
            gitRepoRoot = nil
            return
        }
        gitRepoRoot = repoRoot
        let service = git
        // CRIT-5: capture the repo root as a token so the main-actor hop
        // can refuse to write stale results if `setRoot(_:)` switched us
        // to a different folder while git was running. Weak-self so the
        // detached Task doesn't keep this model alive across shutdown.
        let token = repoRoot
        Task.detached(priority: .userInitiated) { [weak self] in
            let entries = (try? service.status(at: repoRoot)) ?? []
            var map: [URL: GitStatusEntry.Status] = [:]
            for entry in entries {
                let url = repoRoot.appendingPathComponent(entry.path)
                    .standardizedFileURL.resolvingSymlinksInPath()
                map[url] = entry.status
            }
            await MainActor.run {
                guard let self else { return }
                guard self.gitRepoRoot == token else { return }
                self.gitStatuses = map
            }
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
    public func children(of url: URL) -> [FileNode] {
        childrenCache[normalize(url)] ?? []
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
        return kids
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
    }
}
