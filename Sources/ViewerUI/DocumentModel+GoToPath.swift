import Foundation
import Combine
import SwiftUI
import ViewerKit
import ViewerCore

// MARK: - Go-to-path prompt (show / dismiss / record / commit)
//
// Carved out of DocumentModel.swift (TSK-1110 — DocumentModel SRP split). The
// Go-to-path prompt's show/dismiss + the headless expand→validate→open commit
// path + the open-panel recents merge. The prompt-intent stored state
// (goToPathNewSessionIntent / goToPathPrefill) stays on the class (an extension
// can't declare stored props), widened private(set)→internal(set) so these
// methods write it; isGoToPathPresented + lastGoToError are @Published public on
// the class; openPath / openFolderInNewSession / goToPathHistory / history are
// already accessible. (This is the GoToPath half of the old "Command registry"
// MARK; the keybindings half stays.)
extension DocumentModel {
    public func showGoToPath(newSessionIntent: Bool = false) {
        goToPathNewSessionIntent = newSessionIntent
        goToPathPrefill = newSessionIntent ? "~" : nil
        isGoToPathPresented = true
        // Clear stale error state from a previous attempt so the dump
        // reflects only the current invocation.
        lastGoToError = ""
    }
    public func dismissGoToPath() {
        isGoToPathPresented = false
        goToPathNewSessionIntent = false
        goToPathPrefill = nil
        lastGoToError = ""
    }

    /// Record a successfully-opened path in the Go-to-path history.
    /// Called by `GoToPathPrompt` after `openPath`. Stored as the raw
    /// expanded path string (not URL) so the UI can re-display it
    /// verbatim — including tilde-form if we ever start preserving it.
    public func recordGoToPath(_ absolutePath: String) {
        goToPathHistory.record(absolutePath)
    }

    /// Recents to surface alongside the native Open dialog (TSK-746).
    /// Merges the two persisted sources — typed Go-to paths
    /// (`goToPathHistory`, newest-first) ahead of opened files/folders
    /// (`history`, newest-first) — then de-dups, drops paths that no
    /// longer exist, and caps. The Go-to paths lead because they're the
    /// user's most deliberate "open this" intents. Pure derivation lives
    /// in `OpenPanelRecents` (host-tested); this just supplies the merged
    /// source list.
    public func openPanelRecents(
        limit: Int = OpenPanelRecents.defaultLimit
    ) -> [OpenPanelRecentEntry] {
        let merged = goToPathHistory.recent()
            + history.recent().map { $0.url.path }
        return OpenPanelRecents.derive(from: merged, limit: limit)
    }

    /// Headless equivalent of `GoToPathPrompt.submit(newSession:)`. The
    /// script runner can't drive the prompt's local TextField, so this
    /// method exposes the same expand → validate → open path so VM UI
    /// tests can exercise both happy-path and error-path behaviour.
    ///
    /// On success: records history, calls `openPath` (or
    /// `openFolderInNewSession` when `newSession` is true and the path
    /// is a directory), dismisses the prompt, clears `lastGoToError`.
    ///
    /// On failure: populates `lastGoToError` with the user-facing
    /// message and leaves the prompt visible so the next interaction
    /// can correct it.
    public func commitGoToPath(_ rawPath: String, newSession: Bool = false) {
        switch GoToPathExpansion.resolveExisting(rawPath) {
        case .failure(let err):
            lastGoToError = Self.userMessage(for: err)
        case .success(let url):
            recordGoToPath(url.path)
            if newSession || goToPathNewSessionIntent,
               GoToPathExpansion.isDirectory(url.path),
               let openInNew = openFolderInNewSession {
                openInNew(url)
            } else {
                openPath(url)
            }
            lastGoToError = ""
            dismissGoToPath()
        }
    }

    private static func userMessage(for err: GoToPathExpansion.Error) -> String {
        switch err {
        case .empty:    return "Enter an absolute path."
        case .relative: return "Path must be absolute (start with / or ~)."
        case .notFound: return "No file or folder at that path."
        }
    }
}
