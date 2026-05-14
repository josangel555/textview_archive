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

    private let service: FileTreeService
    private var childrenCache: [URL: [FileNode]] = [:]

    public init(service: FileTreeService = FileTreeService()) {
        self.service = service
    }

    public func setRoot(_ url: URL?) {
        rootURL = url?.standardizedFileURL.resolvingSymlinksInPath()
        expanded.removeAll()
        clearCache()
        if let url = rootURL {
            expanded.insert(url)  // root always expanded
            _ = children(of: url)
        }
        isVisible = (rootURL != nil)
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
