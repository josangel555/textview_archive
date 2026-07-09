import AppKit
import Foundation
import ViewerCore

/// TSK-1489 — the new-tab omnibox dispatch: classify a typed/pasted string via
/// the host-tested `OmniResolver` and route it to the matching action. The
/// classification table is pure + host-tested; this is the thin AppKit/model
/// glue that acts on each `Action`.
extension DocumentModel {

    /// Resolve + act on new-tab omnibox input. Returns the classified action so
    /// callers/tests can assert the routing decision without re-classifying.
    @discardableResult
    public func resolveOmniInput(_ raw: String) -> OmniResolver.Action {
        let action = OmniResolver.classify(raw) { path in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
            return isDir.boolValue
        }
        switch action {
        case .openPath(let path, _):
            openPath(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        case .openURL(let s), .gitRemote(let s):
            // No in-app clone flow yet — hand web URLs + git remotes to the
            // default browser (the repo page for a remote). The clone/subscribe
            // policy is a follow-on; opening the page is the useful default.
            if let url = URL(string: s) { NSWorkspace.shared.open(url) }
        case .search(let q):
            // Route to the SAME cross-file engine the search panel uses.
            openGlobalSearch(query: q)
        case .empty:
            break
        }
        return action
    }

    /// TSK-1572 — the launchpad's sections (Recent Files / Recent Folders /
    /// Bookmarks) built from the model's recents + bookmarks. Host-testable bridge
    /// the EmptyStateView renders; `LaunchpadSelection` flattens it for arrow-nav.
    public func launchpadSections(limit: Int = 8) -> [LaunchpadSections.Section] {
        let recentItems = recents.map {
            LaunchpadSections.Item(
                title: $0.url.lastPathComponent, path: $0.url.path,
                isDirectory: $0.kind == .folder)
        }
        let bookmarkItems = bookmarks.map { bm in
            LaunchpadSections.Item(
                title: bm.displayName.isEmpty ? bm.url.lastPathComponent : bm.displayName,
                path: bm.url.path, isDirectory: false)   // sectioning ignores this for bookmarks
        }
        return LaunchpadSections.build(recents: recentItems, bookmarks: bookmarkItems, limit: limit)
    }

    /// TSK-1572 — the clone plan for a git remote (as `OmniResolver` classifies a
    /// `.gitRemote`), targeting the current workspace root's PARENT (so the clone
    /// lands beside the open project) or home. Host-testable; the `git clone`
    /// execution + opening the checkout are the render/IO tail (TSK-1582).
    public func gitClonePlan(forRemote remote: String) -> GitClonePlan? {
        let parent = sidebar.rootURL?.deletingLastPathComponent().path ?? NSHomeDirectory()
        return GitClonePlan.make(fromRemote: remote, into: parent)
    }
}
