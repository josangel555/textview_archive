import Foundation

/// Decides whether dropping a folder into the window should RE-ROOT the sidebar
/// (TSK-919). Dragging a folder that's already shown in the tree — the current
/// root itself, or a descendant under it — and dropping it back in the same
/// window must NOT re-root: that's the accidental self/sub-folder drag trap the
/// owner hit. An EXTERNAL folder (a parent, a sibling, or one from Finder)
/// still re-roots. Intentional "go into this subfolder" stays on the right-click
/// "Open Folder" command. Pure path logic — host-testable, no filesystem access.
public enum DropReRootPolicy {

    public static func shouldReRoot(folder: URL, currentRoot: URL?) -> Bool {
        guard let root = currentRoot else { return true }   // no root yet → open it
        let f = folder.standardizedFileURL
        let r = root.standardizedFileURL
        if f.path == r.path { return false }                // already the root
        // Descendant (component-wise so "/ab" isn't seen as under "/a").
        let fc = f.pathComponents, rc = r.pathComponents
        if fc.count > rc.count, Array(fc.prefix(rc.count)) == rc { return false }
        return true
    }
}
