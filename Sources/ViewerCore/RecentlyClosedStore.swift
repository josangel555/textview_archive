import Foundation
import ViewerKit

/// One closed tab, remembered so it can be reopened (File ▸ Recently Closed,
/// and ⇧⌘T for the most recent).
public struct ClosedTab: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let url: URL
    /// Lens the tab was showing, so reopening lands back in the same view
    /// rather than the category default.
    public let viewMode: ViewMode?
    public let closedAt: Date

    public init(id: UUID = UUID(), url: URL, viewMode: ViewMode?, closedAt: Date) {
        self.id = id
        self.url = url
        self.viewMode = viewMode
        self.closedAt = closedAt
    }

    public var displayName: String { url.lastPathComponent }
}

/// Newest-first stack of recently closed tabs.
///
/// Deliberately NOT persisted to disk (yet) — it lives for the run of the app,
/// which is where "I closed that by accident" happens. Persisting it would add
/// a new Application Support file plus `AppCacheReset` / `SettingsRelocation`
/// wiring, and would resurrect entries pointing at files deleted since; see
/// BACKLOG. Held as a plain (non-`@Published`) store so recording a close does
/// NOT republish `DocumentModel` — the menu is built on demand in
/// `menuNeedsUpdate`, so nothing needs to observe it (chrome re-body budget,
/// PERF #1).
public final class RecentlyClosedStore {

    /// Newest first.
    public private(set) var entries: [ClosedTab] = []

    /// Bounded so a long session can't grow it without limit; 20 matches the
    /// Open Recent menu's cap.
    public let limit: Int

    public init(limit: Int = 20) {
        self.limit = max(1, limit)
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Remember a closed tab. Re-closing the same file moves it to the front
    /// rather than adding a duplicate, so the list stays a set of distinct
    /// files instead of filling with one path.
    public func record(url: URL, viewMode: ViewMode? = nil, at date: Date = Date()) {
        entries.removeAll { $0.url == url }
        entries.insert(ClosedTab(url: url, viewMode: viewMode, closedAt: date), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    /// Pop the most recently closed tab (⇧⌘T). Removing it means repeated
    /// presses walk BACK through the close history instead of reopening the
    /// same file forever.
    public func popMostRecent() -> ClosedTab? {
        entries.isEmpty ? nil : entries.removeFirst()
    }

    /// Take a specific entry (picked from the menu), removing it — reopening
    /// it means it is no longer closed.
    public func take(url: URL) -> ClosedTab? {
        guard let i = entries.firstIndex(where: { $0.url == url }) else { return nil }
        return entries.remove(at: i)
    }

    /// Drop an entry without reopening it — used when a file is reopened by
    /// some other route, so the list never offers to "reopen" an open file.
    public func forget(url: URL) {
        entries.removeAll { $0.url == url }
    }

    public func clear() {
        entries.removeAll()
    }
}
