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
        if let url = rootURL {
            expanded.insert(url)  // root always expanded
            ensureLoaded(url: url)
            refreshGitStatus()
        }
        isVisible = (rootURL != nil)
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
