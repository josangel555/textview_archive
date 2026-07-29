import Foundation
import ViewerCore
import ViewerKit

// Recently-closed tabs: remember what a close destroyed, and put it back
// (File ▸ Recently Closed, ⇧⌘T / `reopen-closed-tab`).
extension DocumentModel {

    /// Remember the tab at `index` as recently closed. Called from EVERY
    /// user-initiated close path (`closeTabUnconditionally`,
    /// `closeOtherTabs`, `closeTabsToRight`) just BEFORE the tab is removed,
    /// while its URL and lens are still readable.
    ///
    /// Skips:
    /// - tabs with no URL (a blank New Tab — nothing to reopen);
    /// - EPHEMERAL preview tabs. A single-click sidebar preview or a git-diff
    ///   tab is transient by construction; listing it as "recently closed"
    ///   would bury the files the user actually worked in. Same rationale as
    ///   keeping transient opens out of Open Recent.
    func noteTabClosed(at index: Int) {
        guard tabs.tabs.indices.contains(index) else { return }
        let tab = tabs.tabs[index]
        guard let url = tab.url, !tab.isPreview else { return }
        recentlyClosed.record(url: url, viewMode: tab.viewMode)
    }

    /// A transient preview that became a REAL tab (edited, or reopened
    /// explicitly) is a genuine open, so it enters Open Recent now — the
    /// peek that created it was skipped on purpose. Idempotent:
    /// `HistoryStore.record` de-dupes by URL.
    func notePreviewPromoted(tabID: UUID) {
        guard let tab = tabs.tabs.first(where: { $0.id == tabID }),
              let url = tab.url else { return }
        history.record(url: url, kind: .file)
        recents = history.recent()
    }

    /// Reopen the most recently closed tab (⇧⌘T). Repeatable: each press
    /// walks one step further back through the close history. Returns false
    /// when there is nothing left to reopen (callers beep / disable the menu).
    @discardableResult
    public func reopenLastClosedTab() -> Bool {
        guard let entry = recentlyClosed.popMostRecent() else { return false }
        reopen(entry)
        return true
    }

    /// Reopen one specific entry picked from the Recently Closed menu.
    @discardableResult
    public func reopenClosedTab(url: URL) -> Bool {
        guard let entry = recentlyClosed.take(url: url) else { return false }
        reopen(entry)
        return true
    }

    private func reopen(_ entry: ClosedTab) {
        // A file deleted since it was closed can't be reopened — drop it and
        // report failure rather than opening an error tab for a ghost.
        guard FileManager.default.fileExists(atPath: entry.url.path) else { return }
        // `open(url:)` is the EXPLICIT-open path — a permanent tab, never the
        // ephemeral preview slot. The user asked for this file back; it
        // should not land in a slot the next sidebar click would recycle.
        open(url: entry.url)
        if let mode = entry.viewMode {
            setCurrentViewMode(mode)
        }
    }
}
