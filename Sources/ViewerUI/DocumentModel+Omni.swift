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
}
