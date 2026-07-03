import Foundation
import Combine
import SwiftUI
import ViewerKit
import ViewerCore

// MARK: - Bookmark commands (file + line bookmarks)
//
// Carved out of DocumentModel.swift (TSK-1110 — DocumentModel SRP split). These
// are the command methods that drive bookmarking. The @Published `bookmarks` /
// `lastBookmarkOpenWarning` state, the publish helper `publishBookmarksChange()`
// (which touches the file-private `bookmarks` setter + the gutter line-cache),
// and the `bookmarkedLines(for:)` cache stay on the main class. Mutators here
// route every change through `publishBookmarksChange()` rather than touching the
// private(set) `bookmarks` storage directly — behaviour-identical, no
// observation change (the @Published lives on the same object), zero render risk.
extension DocumentModel {

    /// True if the currently-focused URL (a tab's file URL OR the open folder
    /// root when no file is in focus) is bookmarked.
    public var isCurrentTabBookmarked: Bool {
        guard let url = bookmarkTargetURL else { return false }
        return bookmarksStore.contains(url)
    }

    /// What Cmd+D operates on: prefer the current tab's file; fall back to the
    /// sidebar's open folder root. Lets users bookmark folders (previously
    /// file-only).
    public var bookmarkTargetURL: URL? {
        currentURL ?? sidebar.rootURL
    }

    /// Toggle the current tab's (or current folder's) bookmark.
    public func toggleCurrentTabBookmark() {
        guard let url = bookmarkTargetURL else { return }
        let name = url.lastPathComponent.isEmpty
            ? url.path
            : url.lastPathComponent
        _ = bookmarksStore.toggle(url: url, displayName: name)
        publishBookmarksChange()
    }

    /// Remove a bookmark by URL.
    public func removeBookmark(_ url: URL) {
        bookmarksStore.remove(url: url)
        publishBookmarksChange()
    }

    /// Remove a specific bookmark — file-level or line-level.
    public func removeBookmark(url: URL, line: Int?) {
        bookmarksStore.remove(url: url, line: line)
        publishBookmarksChange()
    }

    /// Clear all bookmarks.
    public func clearBookmarks() {
        bookmarksStore.clear()
        publishBookmarksChange()
    }

    /// TSK-330 — the app-level ⌘Z target outside the editor: whether the store
    /// has a removal that undo can restore.
    public var canUndoBookmarkRemoval: Bool { bookmarksStore.canUndoRemoval }

    /// Restore the most recently removed bookmark (the store has carried this
    /// stack since the Delete-to-remove ask; the Edit→Undo fallback is its first
    /// consumer). Republishes the bookmarks array so the panel + star indicators
    /// reflect the restoration immediately.
    @discardableResult
    public func undoLastBookmarkRemoval() -> Bool {
        guard bookmarksStore.undoLastRemoval() != nil else { return false }
        publishBookmarksChange()
        return true
    }

    /// Reload the `bookmarks` array from the store. Call this after a mutation
    /// that went directly through `bookmarksStore` (e.g. the sidebar
    /// context-menu's `toggle(url:)`) — those bypass the public DocumentModel
    /// API and won't otherwise propagate.
    public func refreshBookmarks() {
        publishBookmarksChange()
    }

    /// TSK-1464 — remove bookmarks whose targets no longer exist on disk.
    /// Each removal is undoable (⌘Z, same stack as a manual remove). Returns
    /// how many were pruned; outcome is surfaced as a toast either way so the
    /// menu action always visibly responds.
    @discardableResult
    public func pruneMissingBookmarks() -> Int {
        let removed = bookmarksStore.pruneMissing()
        if removed.isEmpty {
            ToastCenter.shared.post(.info, "No missing bookmarks",
                                    detail: "Every bookmark target still exists.")
            return 0
        }
        publishBookmarksChange()
        ToastCenter.shared.post(
            .success,
            "Removed \(removed.count) missing bookmark\(removed.count == 1 ? "" : "s")",
            detail: "Undo with \u{2318}Z")
        return removed.count
    }

    /// TSK-1464 — remove one entry from recents (the HistoryStore API existed
    /// with no UI caller; the sidebar row's context menu is the first).
    public func removeRecent(_ url: URL) {
        history.remove(url: url)
        recents = history.recent()
    }

    /// TSK-1464 — drop recents entries whose files/folders are gone. Returns
    /// how many were pruned; outcome toasted either way.
    @discardableResult
    public func pruneMissingRecents() -> Int {
        let removed = history.pruneMissing()
        if removed.isEmpty {
            ToastCenter.shared.post(.info, "No missing recent files",
                                    detail: "Every recent entry still exists.")
            return 0
        }
        recents = history.recent()
        ToastCenter.shared.post(
            .success,
            "Removed \(removed.count) missing recent\(removed.count == 1 ? "" : "s")")
        return removed.count
    }

    // MARK: - Line bookmarks

    /// Bookmark (or unbookmark) the line the caret is currently on in the source
    /// view. No-op when there's no current file or caret line is zero.
    public func toggleCurrentLineBookmark() {
        guard let url = currentURL else { return }
        let line = sourceSelection.line
        guard line > 0 else { return }
        let display = "\(url.lastPathComponent):\(line)"
        _ = bookmarksStore.toggle(url: url, displayName: display, line: line)
        publishBookmarksChange()
    }

    /// Open `entry` and — if it's a line bookmark — scroll to the stored line
    /// and select it.
    ///
    /// TOCTOU guard (TSK-309): a bookmark stores a path captured at add time,
    /// but the path can be re-pointed (symlink/dir swap, `mv`) before the user
    /// opens it. Re-validate the resolved target's identity against the snapshot
    /// taken at add time; on a mismatch (or deletion) REFUSE to follow the
    /// swapped target and surface `lastBookmarkOpenWarning` instead of silently
    /// opening whatever now sits at the path. Legacy entries with no captured
    /// identity (`.unverified`) open as before.
    public func openBookmark(_ entry: BookmarkEntry) {
        let verdict = bookmarksStore.validate(entry)
        guard verdict.isSafeToOpen else {
            setBookmarkOpenWarning(Self.bookmarkWarningMessage(for: entry, verdict: verdict))
            return
        }
        setBookmarkOpenWarning(nil)
        openPath(entry.url)
        if let line = entry.line {
            scrollSource(toLine: line)
        }
    }

    /// Dismiss the bookmark-open warning banner (the sidebar's X button).
    public func dismissBookmarkOpenWarning() {
        setBookmarkOpenWarning(nil)
    }

    /// User-facing message for a refused bookmark open. Pure — host-testable.
    static func bookmarkWarningMessage(for entry: BookmarkEntry,
                                       verdict: BookmarkValidation) -> String {
        let name = entry.displayName
        switch verdict {
        case .missing:
            return "Bookmark “\(name)” can no longer be found — its target was moved or deleted."
        case .identityChanged:
            return "Bookmark “\(name)” target changed — the path now points at a different file. Not opening it."
        case .ok, .unverified:
            // Not a refusal; included for exhaustiveness.
            return ""
        }
    }
}
