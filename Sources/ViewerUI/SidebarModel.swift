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
        gitStatuses = [:]
        gitRepoRoot = nil
        selectedURL = nil
        if let url = rootURL {
            expanded.insert(url)  // root always expanded
            ensureLoaded(url: url)
            refreshGitStatus()
            selectedURL = url
        }
        isVisible = (rootURL != nil)
    }

    // MARK: Keyboard navigation (CRIT-6)

    public func setSelected(_ url: URL?) {
        selectedURL = url.map(normalize)
    }

    /// Flat list of nodes currently visible in the tree, in display order.
    /// Used to compute next/previous for arrow-key navigation.
    public func flatVisibleNodes() -> [FileNode] {
        guard let root = rootURL else { return [] }
        var out: [FileNode] = [
            FileNode(url: root, name: root.lastPathComponent, isDirectory: true)
        ]
        appendVisibleChildren(of: root, into: &out)
        return out
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
            selectedURL = visible[min(i + 1, visible.count - 1)].url
        } else {
            selectedURL = visible.first?.url
        }
    }

    public func selectPrevious() {
        let visible = flatVisibleNodes()
        guard !visible.isEmpty else { return }
        if let cur = selectedURL,
           let i = visible.firstIndex(where: { $0.url == cur }) {
            selectedURL = visible[max(i - 1, 0)].url
        } else {
            selectedURL = visible.last?.url
        }
    }

    /// Left-arrow semantics: if a directory is expanded, collapse it.
    /// Otherwise, move selection to its parent directory.
    public func collapseOrFocusParent() {
        guard let cur = selectedURL else { return }
        if isExpanded(cur) {
            expanded.remove(cur)
            return
        }
        // Find the parent in the visible flat list and select it.
        let visible = flatVisibleNodes()
        guard let i = visible.firstIndex(where: { $0.url == cur }), i > 0 else { return }
        // The parent is the most recent earlier entry whose path is a prefix.
        let curPath = cur.path
        for j in stride(from: i - 1, through: 0, by: -1) {
            let pPath = visible[j].url.path + "/"
            if curPath.hasPrefix(pPath) {
                selectedURL = visible[j].url
                return
            }
        }
    }

    /// Right-arrow semantics: if a directory is collapsed, expand it.
    /// Otherwise, move to the first child (if any). Behaves like Finder —
    /// expanding an empty directory still toggles the chevron.
    public func expandOrFocusFirstChild() {
        guard let cur = selectedURL else { return }
        // Only meaningful on directories.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cur.path, isDirectory: &isDir),
              isDir.boolValue else { return }
        if !isExpanded(cur) {
            expanded.insert(normalize(cur))
            ensureLoaded(url: cur)
            return
        }
        if let first = children(of: cur).first {
            selectedURL = first.url
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
        return kids
    }

    private func normalize(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func clearCache() {
        childrenCache.removeAll()
    }
}
