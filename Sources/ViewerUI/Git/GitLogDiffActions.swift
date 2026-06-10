import Foundation
import ViewerCore

/// The Git Log row/toolbar ACTION CLOSURES, hoisted out of `GitLogTab`
/// so the view's buttons and the `--script` harness verbs invoke the
/// IDENTICAL code path (exact-closure rule, TSK-620/522/523): a verb
/// exercising these proves the same behavior a user's click produces,
/// minus only the pixel hit-area routing (in-process SwiftUI event
/// synthesis is impossible — LESSONS "in-process event synthesis").
///
/// v1 diff presentation: `git show` / `git diff base..tip` output written
/// to a cache .diff file and opened as a tab (the Status-tab trick);
/// #131 tracks the proper in-app DiffView replacement.
@MainActor
public enum GitLogDiffActions {

    /// What a click on a log row does, modifier-dispatched: cmd toggles
    /// the SHA in the multi-selection, shift extends the range
    /// (TSK-522), a plain click opens the commit's diff (TSK-523).
    public static func rowClicked(sha: String,
                                  command: Bool,
                                  shift: Bool,
                                  panel: GitPanelModel,
                                  doc: DocumentModel) {
        if command {
            panel.logRowClicked(sha: sha, command: true)
        } else if shift {
            panel.logRowClicked(sha: sha, shift: true)
        } else {
            showCommit(sha: sha, panel: panel, doc: doc)
        }
    }

    /// Plain click: select the row and open the commit's diff tab.
    public static func showCommit(sha: String,
                                  panel: GitPanelModel,
                                  doc: DocumentModel) {
        guard let root = panel.repoRoot else { return }
        panel.selectLogCommit(sha: sha)
        let client = GitClient(repoRoot: root)
        let body = client.commitDiff(sha: sha)
        guard let out = writeDiffFile(body, name: "\(sha).diff") else { return }
        doc.openInNewTab(out)
    }

    /// TSK-522: open the cumulative (net) diff for the multi-selection —
    /// `git diff base tip` via `GitClient.cumulativeDiff`.
    public static func showCumulativeDiff(panel: GitPanelModel,
                                          doc: DocumentModel) {
        guard let root = panel.repoRoot,
              let range = panel.cumulativeLogSelectionRange else { return }
        let client = GitClient(repoRoot: root)
        let body = client.cumulativeDiff(baseRef: range.baseRef, tipRef: range.tipRef)
        guard let out = writeDiffFile(
            body, name: "\(range.baseRef)..\(range.tipRef).diff") else { return }
        doc.openInNewTab(out)
    }

    private static func writeDiffFile(_ body: String, name: String) -> URL? {
        let cache = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = cache.appendingPathComponent("MarkdownViewer/diffs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(name)
        do {
            try body.write(to: out, atomically: true, encoding: .utf8)
            return out
        } catch {
            return nil
        }
    }
}
