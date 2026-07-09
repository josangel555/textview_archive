import Foundation
import ViewerCore

/// TSK-1500 — the "recover a DELETED file from Local History" flow's model glue.
/// The atomic create-from-version PRIMITIVE (`FileResurrection.recreate`) and its
/// safety rules are host-tested in ViewerCore; this reaches it: enumerate the
/// recoverable deleted files, and recreate+open one.
extension DocumentModel {

    /// Recently-opened FILES that are GONE from disk but still have Local History
    /// versions → recoverable. Reuses `recents` because it retains the real path
    /// (the history store keys paths by a one-way hash, so it can't enumerate
    /// them itself). Deduped, newest-recent first.
    public func recoverableDeletedFiles() -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for entry in recents where entry.kind == .file {
            let url = entry.url.standardizedFileURL
            let path = url.path
            if seen.contains(path) { continue }
            seen.insert(path)
            guard !FileManager.default.fileExists(atPath: path) else { continue }
            guard !localHistoryStore.versions(for: path).isEmpty else { continue }
            out.append(url)
        }
        return out
    }

    /// Recreate a deleted file from its LATEST Local History version, then open
    /// it. Posts a toast for the outcome; returns it for tests. Never overwrites
    /// (the primitive's O_EXCL guard) — if the file reappeared, opens the live
    /// one instead.
    @discardableResult
    public func resurrectFile(at url: URL) -> FileResurrection.Outcome {
        let path = url.standardizedFileURL.path
        // `versions(for:)` is newest-first, so the latest is `.first`.
        guard let latest = localHistoryStore.versions(for: path).first,
              let content = localHistoryStore.contentString(of: latest, for: path) else {
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
