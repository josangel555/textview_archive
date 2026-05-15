import Foundation

/// User-pinned files/folders. Distinct from HistoryStore (which tracks
/// EVERY open) — bookmarks are an explicit "I'll keep this around"
/// gesture. Order is insertion-order (most recently pinned first), but
/// the user can reorder via `move(from:to:)`.
///
/// Persistence: JSON on disk. Thread safety is not a goal — callers
/// touch this from the main actor via DocumentModel.
public final class BookmarksStore {
    public let storeURL: URL
    public let maxEntries: Int
    public let maxStoreFileBytes: Int

    private var entries: [BookmarkEntry] = []
    private let clock: @Sendable () -> Date

    public init(
        storeURL: URL,
        maxEntries: Int = 200,
        maxStoreFileBytes: Int = 1 * 1024 * 1024,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storeURL = storeURL
        self.maxEntries = maxEntries
        self.maxStoreFileBytes = maxStoreFileBytes
        self.clock = clock
        load()
    }

    public static func defaultStoreURL() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("MarkdownViewer", isDirectory: true)
            .appendingPathComponent("bookmarks.json", isDirectory: false)
    }

    public func all() -> [BookmarkEntry] { entries }

    public func contains(_ url: URL) -> Bool {
        let n = url.standardizedFileURL.resolvingSymlinksInPath()
        return entries.contains { $0.url == n }
    }

    /// Adds `url` if not present. Returns the new (or existing) entry.
    @discardableResult
    public func add(url: URL, displayName: String? = nil) -> BookmarkEntry {
        let n = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = entries.first(where: { $0.url == n }) {
            return existing
        }
        let entry = BookmarkEntry(
            url: n,
            addedAt: clock(),
            displayName: displayName ?? n.lastPathComponent
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
        return entry
    }

    public func remove(url: URL) {
        let n = url.standardizedFileURL.resolvingSymlinksInPath()
        let before = entries.count
        entries.removeAll { $0.url == n }
        if entries.count != before { save() }
    }

    @discardableResult
    public func toggle(url: URL, displayName: String? = nil) -> Bool {
        let n = url.standardizedFileURL.resolvingSymlinksInPath()
        if entries.contains(where: { $0.url == n }) {
            remove(url: n)
            return false
        } else {
            add(url: n, displayName: displayName)
            return true
        }
    }

    public func clear() {
        entries = []
        save()
    }

    /// Move bookmark from index `from` to index `to`. Indices outside
    /// the current range are clamped.
    public func move(from: Int, to: Int) {
        guard !entries.isEmpty else { return }
        let src = max(0, min(from, entries.count - 1))
        let dst = max(0, min(to, entries.count - 1))
        if src == dst { return }
        let item = entries.remove(at: src)
        entries.insert(item, at: dst)
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        guard data.count <= maxStoreFileBytes else { return }
        guard let decoded = try? JSONDecoder().decode([BookmarkEntry].self, from: data) else {
            return
        }
        entries = Array(decoded.prefix(maxEntries))
    }

    private func save() {
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(entries) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

public struct BookmarkEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let addedAt: Date
    public let displayName: String

    public init(url: URL, addedAt: Date, displayName: String? = nil) {
        self.url = url
        self.addedAt = addedAt
        self.displayName = displayName ?? url.lastPathComponent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try c.decode(URL.self, forKey: .url)
        // Tolerate older entries written without ISO8601 / with custom
        // format — fall back to "now" so a malformed entry doesn't
        // poison the whole load.
        if let d = try? c.decode(Date.self, forKey: .addedAt) {
            self.addedAt = d
        } else if let s = try? c.decode(String.self, forKey: .addedAt),
                  let d = ISO8601DateFormatter().date(from: s) {
            self.addedAt = d
        } else {
            self.addedAt = Date()
        }
        self.displayName = (try? c.decode(String.self, forKey: .displayName))
            ?? url.lastPathComponent
    }

    public enum CodingKeys: String, CodingKey {
        case url, addedAt, displayName
    }
}
