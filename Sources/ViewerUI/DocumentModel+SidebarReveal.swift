import Foundation

// Sidebar reveal / follow-active-tab (TSK-1110 SRP slice) — reveal a URL in the
// sidebar tree (re-root if needed unless locked, expand every ancestor, select),
// and the follow-mode "reveal within the current root, never re-root" variant.
// The isSidebarLocked / sidebarFollowsActiveTab @Published state + their toggles
// stay on DocumentModel (stored props). Behavior-preserving move out of
// DocumentModel.swift.
extension DocumentModel {

    /// Reveal `url` in the sidebar: switch the root if needed, expand
    /// every parent directory between the root and the URL, select the
    /// URL. Used by tab right-click → "Reveal in Sidebar" and by the
    /// implicit-reveal-on-click hook in the file tree.
    public func revealInSidebar(_ url: URL) {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        // If sidebar has no root, OR the URL isn't inside the current
        // root, set the root to the URL's containing folder (unless
        // the sidebar is locked — then bail with selection only).
        let needsRoot: Bool = {
            guard let root = sidebar.rootURL else { return true }
            let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
            return !target.path.hasPrefix(rootPath + "/") && target.path != rootPath
        }()
        if needsRoot {
            if isSidebarLocked {
                // Locked — keep the existing root; we can only select
                // inside it, not navigate elsewhere. Silently no-op.
                return
            }
            let folder = target.hasDirectoryPath ? target : target.deletingLastPathComponent()
            sidebar.setRoot(folder)
        }
        // Expand every ancestor from the root down to (but not
        // including) the URL itself. This walks string components
        // rather than file-system traversal so it doesn't do IO.
        if let root = sidebar.rootURL {
            let rootStd = root.standardizedFileURL.resolvingSymlinksInPath()
            var cur = rootStd
            let rel = target.path
                .replacingOccurrences(of: rootStd.path + "/", with: "")
                .split(separator: "/")
                .map(String.init)
            // Always expand the root itself so the tree is visible.
            if !sidebar.isExpanded(cur) { sidebar.toggleExpansion(cur) }
            for segment in rel.dropLast() {
                cur = cur.appendingPathComponent(segment, isDirectory: true)
                if !sidebar.isExpanded(cur) { sidebar.toggleExpansion(cur) }
            }
        }
        sidebar.setSelected(target)
    }

    /// If follow-mode is on, reveal the active tab's file in the sidebar
    /// without re-rooting. Called on tab-selection change.
    /// (internal: `selectTab` stays on DocumentModel and calls this cross-file.)
    func followActiveTabIfNeeded() {
        guard sidebarFollowsActiveTab, let url = currentURL else { return }
        revealInSidebarWithinRoot(url)
    }

    /// Select + expand `url` in the sidebar IFF it's inside the current root.
    /// Never changes the root (unlike `revealInSidebar`, which can re-root).
    /// No-op when there's no root or the URL is outside it.
    private func revealInSidebarWithinRoot(_ url: URL) {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let root = sidebar.rootURL else { return }
        let rootStd = root.standardizedFileURL.resolvingSymlinksInPath()
        let inRoot = target.path == rootStd.path
            || target.path.hasPrefix(rootStd.path + "/")
        guard inRoot else { return }   // outside root → don't re-root
        var cur = rootStd
        let rel = target.path
            .replacingOccurrences(of: rootStd.path + "/", with: "")
            .split(separator: "/")
            .map(String.init)
        if !sidebar.isExpanded(cur) { sidebar.toggleExpansion(cur) }
        for segment in rel.dropLast() {
            cur = cur.appendingPathComponent(segment, isDirectory: true)
            if !sidebar.isExpanded(cur) { sidebar.toggleExpansion(cur) }
        }
        sidebar.setSelected(target)
    }
}
