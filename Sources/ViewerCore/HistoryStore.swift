import Foundation

public struct HistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case file
        case folder
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
        // S8: check size on disk before decoding. A tampered file with
        // millions of entries shouldn't be able to inflate into memory.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: storeURL.path),
           let size = attrs[.size] as? Int,
           size > maxStoreFileBytes {
            // Treat oversize file the same as a corrupt one: start fresh.
            return
        }
        guard let data = try? Data(contentsOf: storeURL) else { return }
        guard let decoded = try? Self.decoder.decode([HistoryEntry].self, from: data) else {
            // Corrupt file — start fresh; we don't fail the app over a broken history.
            return
        }
        entries = decoded
            .sorted(by: { $0.lastOpenedAt > $1.lastOpenedAt })
            .prefix(maxEntries)
            .map { $0 }
    }

    private func save() {
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        guard let data = try? Self.encoder.encode(entries) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
