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
    /// O(1)-contains index over the URL set, maintained alongside
    /// `entries`. `contains(_:)` was called per tab in TabBar and per
    /// sidebar row — at O(N) per call, that's quadratic on the sidebar
    /// hot path. Rebuilt on load / add / remove / clear.
    private var urlIndex: Set<URL> = []

    /// Undo stack for removals (owner ask: Delete-to-remove + undo). Each
    /// entry remembers the removed bookmark and the index it sat at, so undo
    /// re-inserts it in place. Bounded; cleared by `clear()` (a deliberate
    /// wipe shouldn't be partially resurrectable).
    private var removalUndoStack: [(entry: BookmarkEntry, index: Int)] = []
    private let maxUndoDepth = 20

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
        return urlIndex.contains(n)
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
        rebuildIndex()
        save()
        return entry
    }

    /// Removes the matching `(url, line)` entry, or — when `line` is
    /// nil — only the file-level bookmark for that URL. Line bookmarks
    /// for the same URL are kept independent so removing the file
    /// bookmark doesn't sweep them away.
    public func remove(url: URL, line: Int? = nil) {
        let n = url.standardizedFileURL.resolvingSymlinksInPath()
        // `(url, line)` identity is unique (add dedups), so at most one match;
        // capture it + its index for undo before removing.
        guard let idx = entries.firstIndex(where: { $0.url == n && $0.line == line }) else {
            return
        }
        let removed = entries.remove(at: idx)
        removalUndoStack.append((removed, idx))
        if removalUndoStack.count > maxUndoDepth { removalUndoStack.removeFirst() }
        rebuildIndex()
        save()
    }

    /// True when there's a removal that `undoLastRemoval()` can restore.
    public var canUndoRemoval: Bool { !removalUndoStack.isEmpty }

    /// Restore the most recently removed bookmark at its original index
    /// (clamped). No-op if the stack is empty or the same `(url, line)` was
    /// re-added meanwhile (avoids a duplicate). Returns the restored entry.
    @discardableResult
    public func undoLastRemoval() -> BookmarkEntry? {
        guard let last = removalUndoStack.popLast() else { return nil }
        if entries.contains(where: { $0.url == last.entry.url && $0.line == last.entry.line }) {
            return nil
        }
        entries.insert(last.entry, at: max(0, min(last.index, entries.count)))
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        rebuildIndex()
        save()
        return last.entry
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
        urlIndex.removeAll(keepingCapacity: false)
        removalUndoStack.removeAll(keepingCapacity: false)
        save()
    }

    /// Repoint bookmarks after a file/folder rename so a renamed item's
    /// star (and any line bookmarks under it) follow the move instead of
    /// going stale. Matches BOTH the exact URL and — for a folder rename —
    /// any bookmark beneath `oldURL` (prefix), rebasing each onto `newURL`.
    /// Returns the number of entries moved. (TSK-283.)
    ///
    /// An exact-file rename also refreshes the entry's `displayName` to the
    /// new last path component; a folder rename leaves each child's own
    /// display name untouched (only an ancestor changed).
    @discardableResult
    public func relocate(from oldURL: URL, to newURL: URL) -> Int {
        let old = oldURL.standardizedFileURL.resolvingSymlinksInPath()
        let new = newURL.standardizedFileURL.resolvingSymlinksInPath()
        let oldPrefix = old.path.hasSuffix("/") ? old.path : old.path + "/"
        var moved = 0
        entries = entries.map { entry in
            if entry.url == old {
                moved += 1
                return BookmarkEntry(url: new, addedAt: entry.addedAt,
                                     displayName: new.lastPathComponent, line: entry.line)
            }
            // Folder rename: rebase a descendant's path onto the new folder.
            if entry.url.path.hasPrefix(oldPrefix) {
                let rel = String(entry.url.path.dropFirst(old.path.count))  // leading "/…"
                let rebased = URL(fileURLWithPath: new.path + rel)
                moved += 1
                return BookmarkEntry(url: rebased, addedAt: entry.addedAt,
                                     displayName: entry.displayName, line: entry.line)
            }
            return entry
        }
        if moved > 0 {
            rebuildIndex()
            save()
        }
        return moved
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
        rebuildIndex()
    }

    /// Refresh the O(1)-contains URL set from `entries`. Move/clear
    /// don't change membership, so they don't call this.
    private func rebuildIndex() {
        urlIndex = Set(entries.map { $0.url })
    }

    private func save() {
        // P2: off-main, coalesced, ordered (see JSONFileStore.enqueueWrite).
        // A bookmark add/toggle no longer stalls the main thread on a sync
        // atomic write.
        JSONFileStore.enqueueWrite(entries, to: storeURL)
    }

    /// Block until every pending JSON-store write has landed on disk
    /// (the save path is async/coalesced — P2). For terminate-drain and
    /// persistence-roundtrip tests.
    public func flush() {
        JSONFileStore.flushSync()
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
