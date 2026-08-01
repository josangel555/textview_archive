import Foundation
import ViewerKit

/// One closed tab, remembered so it can be reopened (File ▸ Recently Closed,
/// and ⇧⌘T for the most recent).
public struct ClosedTab: Equatable, Identifiable, Sendable, Codable {
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
/// PERSISTED since 2026-08-01 (⇧⌘T survives a relaunch — the browser
/// idiom): `recently-closed.json` beside `history.json`, written through
/// the coalescing `JSONFileStore` queue, wiped by `AppCacheReset`'s
/// `.recents` domain. The old resurrect-deleted-files objection is
/// handled at LOAD: entries whose file no longer exists are dropped. A
/// nil `storeURL` keeps the store purely in-memory (tests, preview
/// hosts). Held as a plain (non-`@Published`) store so recording a close
/// does NOT republish `DocumentModel` — the menu is built on demand in
/// `menuNeedsUpdate`, so nothing needs to observe it (chrome re-body
/// budget, PERF #1).
public final class RecentlyClosedStore {

    /// Newest first.
    public private(set) var entries: [ClosedTab] = []

    /// Bounded so a long session can't grow it without limit; 40 matches the
    /// Open Recent menu's cap (both doubled 2026-08-01, owner intake I-17).
    public let limit: Int

    /// nil = in-memory only.
    private let storeURL: URL?

    /// Generous for 40 small records; the read cap just bounds a corrupt file.
    private let maxStoreFileBytes = 256 * 1024

    public init(limit: Int = 40, storeURL: URL? = nil) {
        self.limit = max(1, limit)
        self.storeURL = storeURL
        load()
    }

    /// `recently-closed.json` beside `history.json` — same
    /// test-redirect-aware resolution as `HistoryStore.defaultStoreURL`.
    public static func defaultStoreURL() -> URL {
        HistoryStore.defaultStoreURL()
            .deletingLastPathComponent()
            .appendingPathComponent("recently-closed.json", isDirectory: false)
    }

    private func load() {
        guard let url = storeURL,
              let decoded = JSONFileStore.read(
                [ClosedTab].self, from: url, maxSize: maxStoreFileBytes)
        else { return }
        // Files deleted since the last run must not resurrect in the menu
        // (the objection that kept this store in-memory) — filter at load,
        // the one place it's cheap and always current.
        entries = Array(
            decoded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
                .prefix(limit))
    }

    private func persist() {
        guard let url = storeURL else { return }
        JSONFileStore.enqueueWrite(entries, to: url)
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Remember a closed tab. Re-closing the same file moves it to the front
    /// rather than adding a duplicate, so the list stays a set of distinct
    /// files instead of filling with one path.
    public func record(url: URL, viewMode: ViewMode? = nil, at date: Date = Date()) {
        entries.removeAll { $0.url == url }
        entries.insert(ClosedTab(url: url, viewMode: viewMode, closedAt: date), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        persist()
    }

    /// Pop the most recently closed tab (⇧⌘T). Removing it means repeated
    /// presses walk BACK through the close history instead of reopening the
    /// same file forever.
    public func popMostRecent() -> ClosedTab? {
        guard !entries.isEmpty else { return nil }
        let popped = entries.removeFirst()
        persist()
        return popped
    }

    /// Take a specific entry (picked from the menu), removing it — reopening
    /// it means it is no longer closed.
    public func take(url: URL) -> ClosedTab? {
        guard let i = entries.firstIndex(where: { $0.url == url }) else { return nil }
        let taken = entries.remove(at: i)
        persist()
        return taken
    }

    /// Drop an entry without reopening it — used when a file is reopened by
    /// some other route, so the list never offers to "reopen" an open file.
    public func forget(url: URL) {
        let before = entries.count
        entries.removeAll { $0.url == url }
        if entries.count != before { persist() }
    }

    public func clear() {
        entries.removeAll()
        persist()
    }
}
