import Foundation
import ViewerCore

// MARK: - TSK-1599 — web-diff per-file navigation (Current | Old | New)
//
// The diff page's file-header buttons post `{action:"open", version, path,
// blob}` over the `mdvDiff` bridge; `WebDiffPane` routes them here.
//
// Repo resolution is BEST-EFFORT: a `.diff` tab holds only text, so the repo
// context comes from the live git panel (the surface that produced every git
// diff tab), falling back to the sidebar root. A miss degrades to a toast —
// never a silent no-op.
extension DocumentModel {

    /// The repo root the diff most plausibly came from.
    var diffNavigationRepoRoot: URL? {
        GitPanelModel.live?.repoRoot ?? sidebar.rootURL
    }

    /// "Current": open the WORKING-TREE file at `path` (repo-relative). The
    /// working copy may match neither diff side — that's the point of the
    /// label. Ephemerality: a real file open is a normal preview-open (same
    /// as a sidebar single-click).
    public func diffOpenCurrentFile(path: String) {
        guard let root = diffNavigationRepoRoot else {
            ToastCenter.shared.post(.info, "No repository context for \(path)")
            return
        }
        let url = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            ToastCenter.shared.post(.info, "\(path) is not in the working tree")
            return
        }
        openPreview(url: url)
    }

    /// "Old" / "New": materialize the blob (`git cat-file -p <sha>`) into a
    /// scratch file named after the version + original filename, and open it
    /// in the ephemeral preview slot. `sha` comes from the patch's own
    /// `index` line, so it resolves in the diff's repo.
    public func diffOpenBlob(sha: String, path: String, versionLabel: String) {
        guard let root = diffNavigationRepoRoot else {
            ToastCenter.shared.post(.info, "No repository context for \(path)")
            return
        }
        guard let contents = GitClient(repoRoot: root).blobContents(sha: sha) else {
            ToastCenter.shared.post(.info, "Couldn't load the \(versionLabel) version of \(path)")
            return
        }
        let dir = ScratchStore.cacheSubdir("diffs")
        ScratchStore.prune(directory: dir)
        let name = (path as NSString).lastPathComponent
        let out = dir.appendingPathComponent("\(versionLabel)-\(sha.prefix(7))-\(name)")
        do {
            try contents.write(to: out, atomically: true, encoding: .utf8)
        } catch {
            ToastCenter.shared.post(.info, "Couldn't write the \(versionLabel) version of \(path)")
            return
        }
        openPreview(url: out)
    }
}
