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
        didSet { clearCache() }
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
            _ = children(of: url)
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
        Task.detached(priority: .userInitiated) {
            let entries = (try? service.status(at: repoRoot)) ?? []
            var map: [URL: GitStatusEntry.Status] = [:]
            for entry in entries {
                let url = repoRoot.appendingPathComponent(entry.path)
                    .standardizedFileURL.resolvingSymlinksInPath()
                map[url] = entry.status
            }
            await MainActor.run {
                self.gitStatuses = map
            }
        }
    }

    public func toggleVisibility() {
        isVisible.toggle()
    }

    public func toggleExpansion(_ url: URL) {
        if expanded.contains(url) {
            expanded.remove(url)
        } else {
            expanded.insert(url)
            _ = children(of: url)
        }
    }

    public func isExpanded(_ url: URL) -> Bool {
        expanded.contains(url)
    }

    public func children(of url: URL) -> [FileNode] {
        if let cached = childrenCache[url] { return cached }
        let children = (try? service.children(of: url, includeHidden: includeHidden)) ?? []
        childrenCache[url] = children
        return children
    }

    public func clearCache() {
        childrenCache.removeAll()
    }
}
