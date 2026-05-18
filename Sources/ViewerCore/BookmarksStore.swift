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

    /// True if **any** bookmark entry (file-level or line-level) is set
    /// for this URL. Kept for the existing "is current file/folder
    /// bookmarked?" check that drives the star indicator.
    public func contains(_ url: URL) -> Bool {
        let n = url.standardizedFileURL.resolvingSymlinksInPath()
        return entries.contains { $0.url == n }
    }

    /// Line-aware lookup. Pass `line: nil` to check the file-level
    /// bookmark; pass a 1-based line number to check a line bookmark.
    public func contains(url: URL, line: Int?) -> Bool {
        let n = url.standardizedFileURL.resolvingSymlinksInPath()
        return entries.contains { $0.url == n && $0.line == line }
    }

    /// Adds `url` (or `(url, line)` for a line bookmark) if not
    /// present. Returns the new or existing entry.
    @discardableResult
    public func add(url: URL, displayName: String? = nil, line: Int? = nil) -> BookmarkEntry {
        let n = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = entries.first(where: { $0.url == n && $0.line == line }) {
            return existing
        }
        let entry = BookmarkEntry(
            url: n,
            addedAt: clock(),
            displayName: displayName ?? n.lastPathComponent,
            line: line
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
        return entry
    }

    /// Removes the matching `(url, line)` entry, or — when `line` is
    /// nil — only the file-level bookmark for that URL. Line bookmarks
    /// for the same URL are kept independent so removing the file
    /// bookmark doesn't sweep them away.
    public func remove(url: URL, line: Int? = nil) {
        let n = url.standardizedFileURL.resolvingSymlinksInPath()
        let before = entries.count
        entries.removeAll { $0.url == n && $0.line == line }
        if entries.count != before { save() }
    }

    @discardableResult
    public func toggle(url: URL, displayName: String? = nil, line: Int? = nil) -> Bool {
        let n = url.standardizedFileURL.resolvingSymlinksInPath()
        if entries.contains(where: { $0.url == n && $0.line == line }) {
            remove(url: n, line: line)
            return false
        } else {
            add(url: n, displayName: displayName, line: line)
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
        guard let decoded = JSONFileStore.read(
            [BookmarkEntry].self, from: storeURL, maxSize: maxStoreFileBytes
        ) else { return }
        entries = Array(decoded.prefix(maxEntries))
    }

    private func save() {
        JSONFileStore.write(entries, to: storeURL)
    }
}

public struct BookmarkEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Identity composes URL with optional line, so the same file can
    /// have both a file-level bookmark and one or more line bookmarks
    /// without colliding.
    public var id: String {
        if let line = line { return "\(url.path)#L\(line)" }
        return url.path
    }
    public let url: URL
    public let addedAt: Date
    public let displayName: String
    /// 1-based line number for line bookmarks; nil for whole-file
    /// bookmarks. Older on-disk entries decode with nil here.
    public let line: Int?

    public init(url: URL, addedAt: Date, displayName: String? = nil, line: Int? = nil) {
        self.url = url
        self.addedAt = addedAt
        self.displayName = displayName ?? url.lastPathComponent
        self.line = line
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
                  let d = BookmarkEntry.iso8601.date(from: s) {
            self.addedAt = d
        } else {
            self.addedAt = Date()
        }
        self.displayName = (try? c.decode(String.self, forKey: .displayName))
            ?? url.lastPathComponent
        // Optional — old entries don't have it; new entries may set it.
        self.line = try? c.decodeIfPresent(Int.self, forKey: .line)
    }

    public enum CodingKeys: String, CodingKey {
        case url, addedAt, displayName, line
    }

    /// Shared formatter — was allocated per-entry-decoded, which on a
    /// 200-bookmark store meant 200 fresh formatters on every launch.
    /// `nonisolated(unsafe)`: `ISO8601DateFormatter.date(from:)` is
    /// documented thread-safe; Swift 6's checker can't see that.
    nonisolated(unsafe) private static let iso8601 = ISO8601DateFormatter()
}
