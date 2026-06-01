import Foundation

/// Persists the user's most-recent paths entered via the "Go to file /
/// folder" prompt (⇧⌘G). Separate store from `HistoryStore` because:
///   - much smaller cap (10 vs 100) — these are typed paths, not the
///     full app-wide recents stream
///   - distinct UX — Up/Down arrow in an empty prompt cycles these,
///     not the file palette's recents
///   - decouples the prompt's eviction policy from the global history
///     (rapid typing into the prompt shouldn't push real files out of
///     `recents`)
///
/// Thread-safety: callers touch this from the main actor; the wrapping
/// publisher in `DocumentModel` keeps the access serialized. Disk
/// writes happen on the actor thread (single-file JSON, atomic write,
/// tiny payload — no need for a background queue).
public final class GoToPathHistoryStore {
    public let storeURL: URL
    public let maxEntries: Int

    /// 64 KiB ceiling on the persisted file. Ten path strings of even
    /// 1 KiB each is 10 KiB; 64 KiB is room to spare without giving a
    /// tampered file a runway to balloon memory.
    public let maxStoreFileBytes: Int

    private var entries: [String] = []

    public init(
        storeURL: URL,
        maxEntries: Int = 10,
        maxStoreFileBytes: Int = 64 * 1024
    ) {
        self.storeURL = storeURL
        self.maxEntries = maxEntries
        self.maxStoreFileBytes = maxStoreFileBytes
        load()
    }

    public static func defaultStoreURL() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("MarkdownViewer", isDirectory: true)
            .appendingPathComponent("recent-paths.json", isDirectory: false)
    }

    /// Newest-first list of absolute paths previously opened via the
    /// Go-to prompt. Caller treats this as read-only.
    public func recent() -> [String] { entries }

    public var count: Int { entries.count }

    /// Record an open. Path should already be expanded + absolute.
    /// Deduplicates (re-add moves to front). Caps at `maxEntries`.
    public func record(_ path: String) {
        guard !path.isEmpty else { return }
        entries.removeAll { $0 == path }
        entries.insert(path, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    public func clear() {
        entries.removeAll()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let decoded = JSONFileStore.read(
            [String].self, from: storeURL, maxSize: maxStoreFileBytes
        ) else { return }
        // Defensive: cap on load too (a tampered file with maxStoreFileBytes
        // of short strings could still exceed maxEntries).
        entries = Array(decoded.prefix(maxEntries))
    }

    private func save() {
        // P2: off-main, coalesced, ordered (see JSONFileStore.enqueueWrite).
        // Every Go-To-Path use no longer stalls the main thread on a sync
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

/// Pure helpers for the "Go to file / folder" prompt. Kept here (no
/// SwiftUI imports) so they're unit-testable on the host without
/// pulling in AppKit.
public enum GoToPathExpansion {
    public enum Error: Swift.Error, Equatable, Sendable {
        case empty
        case relative
        case notFound
    }

    /// Expand `~` / `~user` and validate that the result is an
    /// absolute path. Does NOT touch the filesystem — use
    /// `resolveExisting` for the existence check.
    ///
    /// Returns the expanded absolute path on success.
    public static func expand(_ raw: String) -> Result<String, Error> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.empty) }
        let expanded = (trimmed as NSString).expandingTildeInPath
        // After tilde expansion the path must be absolute. A leftover
        // leading "~" means the user typed a malformed tilde (e.g.
        // "~nonexistent") that NSString couldn't expand; treat as
        // relative.
        guard expanded.hasPrefix("/") else {
            return .failure(.relative)
        }
        return .success(expanded)
    }

    /// Full pipeline: expand + existence check. Returns a URL ready
    /// to hand to `DocumentModel.openPath`.
    public static func resolveExisting(
        _ raw: String,
        fileManager: FileManager = .default
    ) -> Result<URL, Error> {
        switch expand(raw) {
        case .failure(let err): return .failure(err)
        case .success(let path):
            if fileManager.fileExists(atPath: path) {
                return .success(URL(fileURLWithPath: path))
            } else {
                return .failure(.notFound)
            }
        }
    }

    /// True iff the expanded path resolves to a directory. Caller is
    /// expected to have already validated existence.
    public static func isDirectory(
        _ path: String,
        fileManager: FileManager = .default
    ) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }
}
