import Foundation
import AppKit
import SwiftUI
import ViewerKit
import ViewerCore

// MARK: - Git log (legacy) — synthetic-markdown commit history
//
// Carved out of DocumentModel.swift (TSK-1110 — DocumentModel SRP split, slice 7).
// The legacy `git log` → synthetic-markdown-tab path (FileHistoryView is the
// modern replacement for the per-file case, but showGitLog is still live for the
// folder/repo scopes via SidebarView + WalkthroughPlayerImpl). `presentGitLogFailure`
// is private to this group (only showGitLog calls it) so it moves with them; the
// pure `gitLogMarkdown` / `writeGitLog` stay `static` on DocumentModel (SaveCopyTests
// + others reference them as DocumentModel.*). openInNewTab/GitClient are public.
// Behaviour-identical move; no @Published → zero render risk.
extension DocumentModel {

    public enum GitLogScope: Sendable { case file, folder, repo }

    /// Fetch `git log` for the given path (file or folder) and open it
    /// as a synthetic markdown tab. The rendered view picks up the
    /// markdown and shows commit metadata as a clickable list. Cached
    /// under `~/Library/Caches/MarkdownViewer/git-log/` so the
    /// rendered tab is a real file Launch Services can revisit.
    public func showGitLog(forPath url: URL, scope: GitLogScope) {
        guard let repoRoot = GitClient.discoverRoot(from: url) else { return }
        let relPath: String? = {
            let rootPath = repoRoot.standardizedFileURL.resolvingSymlinksInPath().path
            let filePath = url.standardizedFileURL.resolvingSymlinksInPath().path
            if scope == .repo { return nil }
            if filePath.hasPrefix(rootPath + "/") {
                return String(filePath.dropFirst(rootPath.count + 1))
            }
            return nil
        }()
        let client = GitClient(repoRoot: repoRoot)
        let entries = client.log(forPath: relPath, maxEntries: 200)
        let md = Self.gitLogMarkdown(
            entries: entries, url: url, repoRoot: repoRoot, scope: scope)
        // Write under caches so Launch Services treats it as a real file,
        // then open the FRESHLY-written file. Branch on the write result:
        // the old `try? createDirectory` + `try? write` swallowed both
        // failures AND still `openInNewTab(out)`'d the hashed path — so a
        // failed write (disk full, dir not writable) re-opened a STALE
        // prior git-log for the SAME (repo, relPath) hash, showing the
        // user yesterday's history as if it were current with zero signal.
        do {
            let out = try Self.writeGitLog(
                markdown: md, repoRoot: repoRoot, relPath: relPath)
            openInNewTab(out)
        } catch {
            presentGitLogFailure(error)
        }
    }

    /// Pure markdown body for a git-log tab — one commit per table row,
    /// SHA monospaced, subject pipe-escaped. Extracted so it is host-
    /// testable independent of the file write.
    static func gitLogMarkdown(
        entries: [GitClient.LogEntry], url: URL, repoRoot: URL, scope: GitLogScope
    ) -> String {
        var md = ""
        let title: String
        switch scope {
        case .file:   title = "History: \(url.lastPathComponent)"
        case .folder: title = "History: \(url.lastPathComponent)/"
        case .repo:   title = "History: \(repoRoot.lastPathComponent)"
        }
        md += "# \(title)\n\n"
        if entries.isEmpty {
            md += "_No commits._\n"
        } else {
            md += "| SHA | Subject | Author | Date |\n"
            md += "|---|---|---|---|\n"
            for e in entries {
                let safeSubject = e.subject
                    .replacingOccurrences(of: "|", with: "\\|")
                md += "| `\(e.sha)` | \(safeSubject) | \(e.author) | \(e.date) |\n"
            }
        }
        return md
    }

    /// Write the git-log markdown to a hashed cache file and return the
    /// written URL. THROWS on a create-directory or write failure so the
    /// caller never opens a stale hashed path. Hashed filename defeats
    /// collisions and keeps the dir browsable.
    /// `cacheRoot` defaults to the user caches dir; tests override it to a
    /// scratch (or deliberately-unwritable) location to exercise the
    /// branch-on-write-result contract host-side.
    static func writeGitLog(
        markdown: String, repoRoot: URL, relPath: String?, cacheRoot: URL? = nil
    ) throws -> URL {
        var hasher = Hasher()
        hasher.combine(repoRoot.path)
        hasher.combine(relPath ?? "")
        let hash = String(UInt(bitPattern: hasher.finalize()), radix: 16)
            .padding(toLength: 8, withPad: "0", startingAt: 0)
            .prefix(8)
        let cache = cacheRoot
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = cache.appendingPathComponent("MarkdownViewer/git-log", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let baseName = (relPath ?? repoRoot.lastPathComponent)
            .split(separator: "/").last.map(String.init) ?? "history"
        let out = dir.appendingPathComponent("\(baseName)-\(hash).md")
        try markdown.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    private func presentGitLogFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't open history"
        alert.informativeText =
            "The git history couldn't be written to a temporary file: \(error)"
        alert.runModal()
    }
}
