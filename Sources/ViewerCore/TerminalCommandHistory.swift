import Foundation

/// TSK-1176 — in-app terminal command history: a persisted MRU list of commands
/// the user has run, with case-insensitive search. Complements
/// `TerminalFavoritesStore` (user-pinned commands); this is the auto-recorded
/// recency list a history-search palette filters. Pure model + persistence —
/// host-testable; the terminal feeds `record(_:)` and the search UI consumes it.
public final class TerminalCommandHistory {
    public static let maxEntries = 500
    public static let maxStoreFileBytes = 256 * 1024

    /// Process-wide shared history (TSK-1176): all terminal tabs record into ONE
    /// instance so the history is unified + a single writer to the persisted file
    /// (no per-tab instances racing on the same path). MainActor-isolated because
    /// the terminal records on the main actor — keeps access serialized without a lock.
    @MainActor public static let shared = TerminalCommandHistory()

    public let storeURL: URL
    private var items: [String] = []   // MRU, newest first

    public static func defaultURL() -> URL {
        // TSK-1288: markdownViewerDir() redirects to tmp under XCTest (real dir in prod).
        return TestStateRedirect.markdownViewerDir()
            .appendingPathComponent("terminal-history.json")
    }

    public init(storeURL: URL = TerminalCommandHistory.defaultURL()) {
        self.storeURL = storeURL
        load()
    }

    /// All recorded commands, newest first.
    public var all: [String] { items }

    /// Record a command run: move it to the front (deduped), trim to the cap.
    /// No-op on a blank command.
    @discardableResult
    public func record(_ command: String) -> Bool {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return false }
        items.removeAll { $0 == c }
        items.insert(c, at: 0)
        if items.count > Self.maxEntries { items = Array(items.prefix(Self.maxEntries)) }
        save()
        return true
    }

    /// Commands containing `query` (case-insensitive); the full list when blank.
    public func search(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { $0.lowercased().contains(q) }
    }

    public func clear() {
        guard !items.isEmpty else { return }
        items = []
        save()
    }

    public func reload() { load() }
    public func flush() { JSONFileStore.flushSync() }

    // MARK: - Persistence

    private func load() {
        guard let decoded = JSONFileStore.read(
            [String].self, from: storeURL, maxSize: Self.maxStoreFileBytes
        ) else { return }
        var seen = Set<String>()
        items = decoded.compactMap {
            let c = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !c.isEmpty, seen.insert(c).inserted else { return nil }
            return c
        }
        if items.count > Self.maxEntries { items = Array(items.prefix(Self.maxEntries)) }
    }

    private func save() { JSONFileStore.enqueueWrite(items, to: storeURL) }
}
