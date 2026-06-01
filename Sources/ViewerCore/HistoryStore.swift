import Foundation

public struct HistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case file
        case folder

        /// Forward-compat: a future build may persist a `kind` this
        /// build doesn't know (PERSIST-02). Decode the unknown value to
        /// `.file` rather than throwing — a single unrecognized kind
        /// must not drop the whole entry (and, with the lenient array
        /// decode, must not drop the rest of the history either).
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .file
        }
    }

    public var id: String { url.path }
    public let url: URL
    public let kind: Kind
    public var lastOpenedAt: Date
    public let displayName: String

    public init(url: URL, kind: Kind, lastOpenedAt: Date, displayName: String? = nil) {
        self.url = url
        self.kind = kind
        self.lastOpenedAt = lastOpenedAt
        self.displayName = displayName ?? url.lastPathComponent
    }
}

/// Persists a list of recently opened files / folders to JSON on disk.
/// Pure logic, no UI imports. Thread-safe is *not* a goal — callers should
/// touch it from the main actor (it'll be wrapped in DocumentModel).
public final class HistoryStore {
    public let storeURL: URL
    public let maxEntries: Int

    /// Maximum bytes the persisted JSON may be before we refuse to decode
    /// it. Caps the worst case where a tampered file with 10M entries
    /// otherwise decodes into memory *before* the `prefix(maxEntries)`
    /// trim. Default 1 MiB easily fits 100 entries with paths up to a few
    /// hundred chars each (S8).
    public let maxStoreFileBytes: Int

    private var entries: [HistoryEntry] = []
    private let clock: @Sendable () -> Date

    public init(
        storeURL: URL,
        maxEntries: Int = 100,
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
            .appendingPathComponent("history.json", isDirectory: false)
    }

    /// Records an open. If the URL is already present, its timestamp is bumped
    /// and the entry moves to the front. List capped at `maxEntries`.
    @discardableResult
    public func record(url: URL, kind: HistoryEntry.Kind = .file) -> HistoryEntry {
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        entries.removeAll { $0.url == normalized }
        let entry = HistoryEntry(url: normalized, kind: kind, lastOpenedAt: clock())
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
        return entry
    }

    public func remove(url: URL) {
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        let before = entries.count
        entries.removeAll { $0.url == normalized }
        if entries.count != before {
            save()
        }
    }

    public func clear() {
        entries.removeAll()
        save()
    }

    /// Returns entries ordered newest-first.
    public func recent(limit: Int = .max) -> [HistoryEntry] {
        Array(entries.prefix(limit))
    }

    public var count: Int { entries.count }

    // MARK: - Persistence

    private func load() {
        // S8: max-size guard inside JSONFileStore.read prevents a
        // tampered file from inflating into memory.
        // PERSIST-02: lenient array decode — one malformed entry is
        // dropped rather than discarding the whole history.
        guard let decoded = JSONFileStore.readLenientArray(
            HistoryEntry.self, from: storeURL, maxSize: maxStoreFileBytes
        ) else { return }
        entries = decoded
            .sorted(by: { $0.lastOpenedAt > $1.lastOpenedAt })
            .prefix(maxEntries)
            .map { $0 }
    }

    private func save() {
        // P2: off-main, coalesced, ordered. The in-memory `entries`
        // mutation already happened on the caller's (main) actor; we hand a
        // value-type snapshot to the write queue so the encode + atomic disk
        // write never stalls the main thread on a routine file open.
        JSONFileStore.enqueueWrite(entries, to: storeURL)
    }

    /// Block until every pending write across all JSON stores has landed on
    /// disk. The save path is now async/coalesced (P2), so a caller that
    /// needs the bytes on disk RIGHT NOW (process terminate, or a test
    /// reopening the store to assert persistence) must drain first.
    public func flush() {
        JSONFileStore.flushSync()
    }
}
