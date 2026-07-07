import Foundation

/// TSK-1447 — persisted request-builder state for the in-app HTTP client: a
/// bounded HISTORY of sent requests (auto-recorded, newest-first, deduped on
/// content) and a set of user-SAVED named requests. Follows the
/// `FeedSubscriptionStore` / `HistoryStore` pattern: two single-file JSON stores
/// via `JSONFileStore` (max-size guard, off-main coalesced writes), Application-
/// Support layout with NO bundle-id prefix, main-actor call contract.
///
/// TWO files under `~/Library/Application Support/MarkdownViewer/`:
///   - `http-history.json` — `[HTTPHistoryEntry]`, newest-first (capped).
///   - `http-saved.json`   — `[HTTPSavedRequest]`, newest-saved-first.
///
/// Pure value logic — no AppKit/SwiftUI — so the whole lifecycle is host-testable.

// MARK: - Saved request

/// A user-named request the builder can recall. Identity is `id`; `name` is the
/// display label and the dedup key on save (re-saving a name UPDATES it).
public struct HTTPSavedRequest: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var request: HTTPRequestModel
    public var savedAt: Date

    public init(id: UUID = UUID(), name: String, request: HTTPRequestModel, savedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.request = request
        self.savedAt = savedAt
    }
}

// MARK: - History entry

/// One auto-recorded sent request, with its outcome status (nil when the send
/// failed before a response). Newest-first in the store.
public struct HTTPHistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var request: HTTPRequestModel
    public var sentAt: Date
    /// Response status code, or nil if the request never got one (transport error).
    public var status: Int?

    public init(id: UUID = UUID(), request: HTTPRequestModel, sentAt: Date = Date(), status: Int? = nil) {
        self.id = id
        self.request = request
        self.sentAt = sentAt
        self.status = status
    }

    /// A compact one-line label for a Load menu / history row:
    /// "`200 · GET example.com/api`" (status omitted when absent).
    public var displayLabel: String {
        let verbURL = "\(request.method.rawValue) \(Self.shortURL(request.urlString))"
        if let status { return "\(status) · \(verbURL)" }
        return verbURL
    }

    /// The URL reduced to host+path for a menu label (falls back to the raw string).
    static func shortURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else { return urlString }
        let path = url.path
        return path.isEmpty || path == "/" ? host : host + path
    }
}

// MARK: - Store

public final class HTTPRequestStore {
    public let historyURL: URL
    public let savedURL: URL
    /// Cap on recorded history entries (newest kept, oldest evicted).
    public let maxHistory: Int
    /// Cap on saved requests.
    public let maxSaved: Int
    public let maxStoreFileBytes: Int

    private var historyEntries: [HTTPHistoryEntry] = []
    private var savedEntries: [HTTPSavedRequest] = []
    private let clock: @Sendable () -> Date

    public init(
        historyURL: URL,
        savedURL: URL,
        maxHistory: Int = 100,
        maxSaved: Int = 200,
        maxStoreFileBytes: Int = 4 * 1024 * 1024,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.historyURL = historyURL
        self.savedURL = savedURL
        self.maxHistory = maxHistory
        self.maxSaved = maxSaved
        self.maxStoreFileBytes = maxStoreFileBytes
        self.clock = clock
        load()
    }

    /// Convenience: the app's default on-disk locations (redirected to a tmp dir
    /// under XCTest via `TestStateRedirect`).
    public convenience init() {
        self.init(
            historyURL: Self.defaultHistoryURL(),
            savedURL: Self.defaultSavedURL())
    }

    public static func defaultHistoryURL() -> URL {
        supportDir().appendingPathComponent("http-history.json", isDirectory: false)
    }

    public static func defaultSavedURL() -> URL {
        supportDir().appendingPathComponent("http-saved.json", isDirectory: false)
    }

    private static func supportDir() -> URL {
        // TSK-1288: markdownViewerDir() redirects to tmp under XCTest (real dir in prod).
        TestStateRedirect.markdownViewerDir()
    }

    // MARK: - Reads

    /// Newest-first history (caller treats as read-only).
    public var history: [HTTPHistoryEntry] { historyEntries }
    /// Saved requests, newest-saved-first.
    public var saved: [HTTPSavedRequest] { savedEntries }

    // MARK: - History

    /// Record a just-sent request at the front of history. Dedupes on request
    /// CONTENT (method/url/headers/body — not the ephemeral row ids): an identical
    /// re-send moves the existing entry to the front (with the fresh time+status)
    /// rather than piling duplicates. Trims to `maxHistory`.
    @discardableResult
    public func recordHistory(_ request: HTTPRequestModel, status: Int? = nil) -> HTTPHistoryEntry {
        let sig = Self.signature(request)
        historyEntries.removeAll { Self.signature($0.request) == sig }
        let entry = HTTPHistoryEntry(request: request, sentAt: clock(), status: status)
        historyEntries.insert(entry, at: 0)
        if historyEntries.count > maxHistory {
            historyEntries = Array(historyEntries.prefix(maxHistory))
        }
        saveHistory()
        return entry
    }

    public func deleteHistory(id: UUID) {
        let before = historyEntries.count
        historyEntries.removeAll { $0.id == id }
        if historyEntries.count != before { saveHistory() }
    }

    public func clearHistory() {
        guard !historyEntries.isEmpty else { return }
        historyEntries.removeAll()
        saveHistory()
    }

    // MARK: - Saved

    /// Save `request` under `name`. Idempotent on the (trimmed) name: re-saving an
    /// existing name UPDATES that entry's request + time in place rather than
    /// duplicating (mirrors `FeedSubscriptionStore.subscribe`). An empty name is
    /// rejected (returns nil). Trims to `maxSaved`, dropping the oldest.
    @discardableResult
    public func save(name: String, request: HTTPRequestModel) -> HTTPSavedRequest? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let idx = savedEntries.firstIndex(where: { $0.name == trimmed }) {
            let updated = HTTPSavedRequest(
                id: savedEntries[idx].id, name: trimmed, request: request, savedAt: clock())
            savedEntries[idx] = updated
            saveSaved()
            return updated
        }
        let entry = HTTPSavedRequest(name: trimmed, request: request, savedAt: clock())
        savedEntries.insert(entry, at: 0)
        if savedEntries.count > maxSaved {
            savedEntries = Array(savedEntries.prefix(maxSaved))
        }
        saveSaved()
        return entry
    }

    public func deleteSaved(id: UUID) {
        let before = savedEntries.count
        savedEntries.removeAll { $0.id == id }
        if savedEntries.count != before { saveSaved() }
    }

    // MARK: - Signature (content-dedup key for history)

    /// Content fingerprint of a request, ignoring the ephemeral header-row UUIDs
    /// and timeout — so two logically-identical requests dedupe in history.
    static func signature(_ m: HTTPRequestModel) -> String {
        let headers = m.headers
            .map { "\($0.isEnabled ? "1" : "0"):\($0.name):\($0.value)" }
            .joined(separator: "\u{1f}")
        return [m.method.rawValue, m.urlString, m.body, headers].joined(separator: "\u{1e}")
    }

    // MARK: - Persistence

    private func load() {
        if let entries = JSONFileStore.readLenientArray(
            HTTPHistoryEntry.self, from: historyURL, maxSize: maxStoreFileBytes
        ) {
            historyEntries = Array(
                entries.sorted { $0.sentAt > $1.sentAt }.prefix(maxHistory))
        }
        if let entries = JSONFileStore.readLenientArray(
            HTTPSavedRequest.self, from: savedURL, maxSize: maxStoreFileBytes
        ) {
            savedEntries = Array(
                entries.sorted { $0.savedAt > $1.savedAt }.prefix(maxSaved))
        }
    }

    private func saveHistory() {
        JSONFileStore.enqueueWrite(historyEntries, to: historyURL)
    }

    private func saveSaved() {
        JSONFileStore.enqueueWrite(savedEntries, to: savedURL)
    }

    /// Block until every pending JSON-store write has landed (writes are
    /// async/coalesced). For persistence-roundtrip tests.
    public func flush() {
        JSONFileStore.flushSync()
    }
}
