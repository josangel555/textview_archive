import Foundation
import ViewerCore

/// TSK-1500 — the "recover a DELETED file from Local History" flow's model glue.
/// The atomic create-from-version PRIMITIVE (`FileResurrection.recreate`) and its
/// safety rules are host-tested in ViewerCore; this reaches it: enumerate the
/// recoverable deleted files, and recreate+open one.
extension DocumentModel {

    /// FILES that are GONE from disk but still have Local History versions →
    /// recoverable. TSK-1573: enumerates the FULL set of history-tracked paths
    /// (`localHistoryStore.allTrackedPaths()`, read from the `_path` sidecars) so a
    /// file deleted LONG AGO / dropped from recents is still recoverable — not just
    /// recently-opened ones. Recents are unioned in first so the most-relevant
    /// (recently-touched) deletions sort ahead of the long-tail. Deduped.
    public func recoverableDeletedFiles() -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        // Recents first (they retain ordering relevance), then the store's full set.
        let recentPaths = recents
            .filter { $0.kind == .file }
            .map { $0.url.standardizedFileURL.path }
        for path in recentPaths + localHistoryStore.allTrackedPaths() {
            let std = URL(fileURLWithPath: path).standardizedFileURL
            let key = std.path
            guard seen.insert(key).inserted else { continue }
            guard !FileManager.default.fileExists(atPath: key) else { continue }
            guard !localHistoryStore.versions(for: key).isEmpty else { continue }
            out.append(std)
        }
        return out
    }

    /// The recoverable versions of a deleted file (newest-first) — drives the
    /// version PICKER in the recover sheet (TSK-1573). Empty when the file exists
    /// or has no history.
    public func recoverableVersions(for url: URL) -> [LocalHistoryStore.Version] {
        localHistoryStore.versions(for: url.standardizedFileURL.path)
    }

    /// Recreate a deleted file from its LATEST Local History version, then open
    /// it. Convenience over `resurrectFile(at:version:)` — passes `nil` to pick
    /// the newest version.
    @discardableResult
    public func resurrectFile(at url: URL) -> FileResurrection.Outcome {
        resurrectFile(at: url, version: nil)
    }

    /// Recreate a deleted file from a CHOSEN Local History version (TSK-1573
    /// picker), or the latest when `version` is nil, then open it. Posts a toast
    /// for the outcome; returns it for tests. Never overwrites (the primitive's
    /// O_EXCL guard) — if the file reappeared, opens the live one instead.
    @discardableResult
    public func resurrectFile(
        at url: URL, version: LocalHistoryStore.Version?
    ) -> FileResurrection.Outcome {
        let path = url.standardizedFileURL.path
        // `versions(for:)` is newest-first, so nil ⇒ the latest is `.first`.
        let chosen = version ?? localHistoryStore.versions(for: path).first
        guard let chosen,
              let content = localHistoryStore.contentString(of: chosen, for: path) else {
            _ = toasts.post(.error, "No history to recover “\(url.lastPathComponent)”.")
            return .failed("no history")
        }
        guard let root = sidebar.rootURL?.standardizedFileURL.path else {
            _ = toasts.post(.error, "Open the file's workspace folder first to recover it.")
            return .refusedOutsideWorkspace
        }
        let outcome = FileResurrection.recreate(content: content, atPath: path, workspaceRoot: root)
        switch outcome {
        case .created:
            _ = toasts.post(.success, "Recovered “\(url.lastPathComponent)”.")
            openPath(url)
        case .refusedExists:
            // It reappeared (a sync tool / the user re-created it) — the existing
            // bytes are untouched; open the live file instead of clobbering.
            _ = toasts.post(.info, "“\(url.lastPathComponent)” already exists — opening it.")
            openPath(url)
        case .refusedOutsideWorkspace:
            _ = toasts.post(.error, "Can't recover “\(url.lastPathComponent)” — outside the workspace.")
        case .failed(let message):
            _ = toasts.post(.error, "Couldn't recover “\(url.lastPathComponent)”.", detail: message)
        }
        return outcome
    }
}
