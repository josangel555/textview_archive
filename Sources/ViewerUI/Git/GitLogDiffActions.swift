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

    /// Trace of the most recent action — embedded in the step dump
    /// (`gitLogTrace`) so a failing VM scenario shows WHICH link of the
    /// chain (root → range → git body → cache write → tab open) broke,
    /// instead of a silent no-op. Same pattern as `UIEventSynth.lastTrace`.
    public private(set) static var lastTrace: String = ""

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

    /// Plain click: select the row and open the commit's diff in the ONE
    /// ephemeral PREVIEW slot (TSK-1594) — VSCode-style, matching the sidebar
    /// file browser. A single click previews (italic, reused slot: clicking
    /// another commit replaces it in place, so browsing commits never stacks
    /// tabs); clicking the SAME commit again (i.e. a double-click) finds it
    /// already open and promotes it to a permanent tab via `openOrReveal`. The
    /// `<sha>.diff` cache path is deterministic per commit (TSK-907), so the
    /// dedup + promote works off the URL.
    public static func showCommit(sha: String,
                                  panel: GitPanelModel,
                                  doc: DocumentModel) {
        guard let root = panel.repoRoot else {
            lastTrace = "showCommit(\(sha)): NO repoRoot"
            return
        }
        panel.selectLogCommit(sha: sha)
        let client = GitClient(repoRoot: root)
        // I-02 (owner 2026-08-01): an UNBOUNDED docs-corpora commit (tens of MB)
        // choked the diff WebView ("no diff shown", panel wedged). Bound the
        // body — whole-line cut + an explicit truncation notice in the preamble
        // — before it reaches the .diff file / renderer.
        let bounded = GitDiffBounds.bound(
            client.commitDiff(sha: sha),
            maxBytes: maxDiffBytes,
            commandHint: "git show \(sha)")
        guard let out = writeDiffFile(bounded.text, name: "\(sha).diff") else {
            lastTrace = "showCommit(\(sha)): cache WRITE FAILED (body=\(bounded.text.count)B)"
            return
        }
        doc.openPreview(url: out)
        if bounded.truncated {
            ToastCenter.shared.post(.info,
                "Large commit — diff truncated (full: git show \(String(sha.prefix(10))))")
        }
        lastTrace = "showCommit(\(sha)): root=\(root.lastPathComponent) "
            + "body=\(bounded.text.count)B/\(bounded.originalBytes)B out=\(out.path) "
            + "tabs=\(doc.tabs.tabs.count)"
    }

    /// I-02 test seam: the byte cap applied to commit/cumulative diff bodies.
    /// Production always uses the GitDiffBounds default; tests shrink it to
    /// drive truncation with a tiny fixture.
    static var maxDiffBytes = GitDiffBounds.defaultMaxBytes

    /// TSK-522: open the cumulative (net) diff for the multi-selection —
    /// `git diff base tip` via `GitClient.cumulativeDiff`.
    public static func showCumulativeDiff(panel: GitPanelModel,
                                          doc: DocumentModel) {
        guard let root = panel.repoRoot else {
            lastTrace = "cumulativeDiff: NO repoRoot"
            return
        }
        guard let range = panel.cumulativeLogSelectionRange else {
            lastTrace = "cumulativeDiff: NO range (selected=\(panel.selectedLogSHAs.count) "
                + "logEntries=\(panel.logEntries.count))"
            return
        }
        let client = GitClient(repoRoot: root)
        // I-02: bounded like showCommit — a multi-commit net diff is the
        // easiest way to produce a renderer-choking body.
        let bounded = GitDiffBounds.bound(
            client.cumulativeDiff(baseRef: range.baseRef, tipRef: range.tipRef),
            maxBytes: maxDiffBytes,
            commandHint: "git diff \(range.baseRef) \(range.tipRef)")
        guard let out = writeDiffFile(
            bounded.text, name: "\(range.baseRef)..\(range.tipRef).diff") else {
            lastTrace = "cumulativeDiff: cache WRITE FAILED (body=\(bounded.text.count)B)"
            return
        }
        doc.openPreview(url: out)   // TSK-1594: ephemeral preview slot
        if bounded.truncated {
            ToastCenter.shared.post(.info,
                "Large range — diff truncated (full: git diff \(range.baseRef) \(range.tipRef))")
        }
        lastTrace = "cumulativeDiff(\(range.baseRef)..\(range.tipRef)): "
            + "body=\(bounded.text.count)B/\(bounded.originalBytes)B out=\(out.path) "
            + "tabs=\(doc.tabs.tabs.count)"
    }

    private static func writeDiffFile(_ body: String, name: String) -> URL? {
        // TSK-752: disk-backed scratch (the diff opens in-process as a tab, but
        // disk keeps it cheap + lets the OS page-cache do the in-memory fast
        // path). Centralized resolution + bounded pruning so the cache doesn't
        // grow one file per commit forever.
        let dir = ScratchStore.cacheSubdir("diffs")
        ScratchStore.prune(directory: dir)
        let out = dir.appendingPathComponent(name)
        do {
            try body.write(to: out, atomically: true, encoding: .utf8)
            return out
        } catch {
            return nil
        }
    }
}
