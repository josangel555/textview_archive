import Foundation

/// TSK-1017: durable per-file scroll + zoom memory that survives a session
/// switch AND app relaunch.
///
/// The IN-SESSION scroll memory in `DocumentModel` (UX-K #231) lives on the
/// `Tab` and dies with the session/tab. This store is the DURABLE backing
/// layer: keyed by FILE IDENTITY, it remembers where in a file you were and
/// at what zoom, so reopening the file later (even after a quit) returns you
/// to the same spot.
///
/// ## Identity keying
/// The primary key is the resolved absolute path. For rename robustness we
/// also stamp `(dev, inode)` when available, and a lookup falls back to that
/// fileID when the path misses — so a renamed file still finds its remembered
/// position. A missing/unidentifiable file simply returns `nil`.
///
/// ## Eviction
/// Two independent caps, both LRU-by-`savedAt` (oldest evicted first):
///   - `maxEntries` (default 500): a hard count ceiling.
///   - `maxStoreFileBytes` (default 1 MiB): a byte budget on the encoded
///     payload, so a pathologically long path set can't balloon the file.
/// Eviction runs on every mutation and again on load (a tampered file is
/// trimmed back into budget).
///
/// ## Write amplification
/// Callers gate writes behind `shouldPersist(...)` — we only stamp an entry
/// when the user actually scrolled or zoomed AWAY from the position we last
/// restored. An untouched file (opened, glanced at, closed) writes nothing.
/// Persistence itself rides `JSONFileStore.enqueueWrite` (off-main, coalesced
/// per URL), so a burst of `remember` calls collapses to one disk write.
///
/// Thread-safety: mirrors the sibling stores — callers touch this from the
/// main actor; disk writes are dispatched off-main by `JSONFileStore`.
public final class ScrollMemoryStore {

    /// One file's remembered viewport + zoom. `Codable` so the whole map
    /// round-trips through `JSONFileStore`. `path` is the resolved absolute
    /// path (primary key); `dev`/`inode` are the rename-robust fallback id.
    public struct Entry: Codable, Equatable, Sendable {
        /// Resolved absolute path — the primary identity key.
        public var path: String
        /// POSIX device id, when stat succeeded (rename-robust fallback key).
        public var dev: UInt64?
        /// POSIX inode, when stat succeeded (rename-robust fallback key).
        public var inode: UInt64?
        /// 1-based top-of-viewport line for the source/editor channel. `nil`
        /// ⇒ no remembered text-scroll (top of file).
        public var scrollTopLine: Int?
        /// Rendered-markdown WebView vertical offset (`window.scrollY`).
        /// `nil` ⇒ no remembered rendered-scroll.
        public var renderedScrollY: Double?
        /// Per-file zoom multiplier at capture time. `nil` ⇒ inherit the
        /// global zoom (don't override).
        public var zoomLevel: Double?
        /// Last-touched timestamp; the LRU eviction key.
        public var savedAt: Date

        public init(
            path: String,
            dev: UInt64? = nil,
            inode: UInt64? = nil,
            scrollTopLine: Int? = nil,
            renderedScrollY: Double? = nil,
            zoomLevel: Double? = nil,
            savedAt: Date
        ) {
            self.path = path
            self.dev = dev
            self.inode = inode
            self.scrollTopLine = scrollTopLine
            self.renderedScrollY = renderedScrollY
            self.zoomLevel = zoomLevel
            self.savedAt = savedAt
        }

        /// True iff this entry carries nothing worth remembering (top of file,
        /// no rendered offset, default/absent zoom). Such an entry is never
        /// persisted — and an update that lands here removes the entry.
        var isEmpty: Bool {
            (scrollTopLine ?? 0) <= 0
                && (renderedScrollY ?? 0) <= 0
                && zoomLevel == nil
        }
    }

    public let storeURL: URL
    public let maxEntries: Int
    public let maxStoreFileBytes: Int

    /// Injectable clock so eviction/LRU tests are deterministic.
    private let now: () -> Date

    /// path → entry. The fileID fallback index is derived on demand (lookups
    /// are rare relative to mutations, and the map is small).
    private var entries: [String: Entry] = [:]

    public init(
        storeURL: URL,
        maxEntries: Int = 500,
        maxStoreFileBytes: Int = 1 << 20,   // 1 MiB
        now: @escaping () -> Date = Date.init
    ) {
        self.storeURL = storeURL
        self.maxEntries = maxEntries
        self.maxStoreFileBytes = maxStoreFileBytes
        self.now = now
        load()
    }

    /// Default location: `~/Library/Application Support/MarkdownViewer/`
    /// (the NO-bundle-id support dir, per CLAUDE.md), alongside
    /// `bookmarks.json` / `recent-paths.json` / `history.json`.
    public static func defaultStoreURL() -> URL {
        // TSK-1288: markdownViewerDir() redirects to tmp under XCTest (real dir in prod).
        return TestStateRedirect.markdownViewerDir()
            .appendingPathComponent("scroll-memory.json", isDirectory: false)
    }

    // MARK: - Identity

    /// Resolve a URL to its primary key: the standardized, symlink-resolved
    /// absolute path. Matches `appendLazyTab`'s normalization so a tab and
    /// this store agree on identity.
    public static func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Best-effort `(dev, inode)` for `path`. `nil` when the file is gone or
    /// stat fails (we then key on path alone).
    static func fileID(forPath path: String,
                       fileManager: FileManager = .default) -> (dev: UInt64, inode: UInt64)? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let dev = attrs[.systemNumber] as? NSNumber,
              let inode = attrs[.systemFileNumber] as? NSNumber else { return nil }
        return (dev.uint64Value, inode.uint64Value)
    }

    // MARK: - Lookup

    /// The remembered entry for `url`, or `nil`. Tries the resolved-path key
    /// first; on a path miss, falls back to matching `(dev, inode)` so a
    /// renamed-on-disk file still recovers its position. A path that no longer
    /// exists (so no fileID) and isn't in the map by path ⇒ `nil`.
    public func entry(for url: URL,
                      fileManager: FileManager = .default) -> Entry? {
        let path = Self.key(for: url)
        if let hit = entries[path] { return hit }
        guard let fid = Self.fileID(forPath: path, fileManager: fileManager) else {
            return nil
        }
        return entries.values.first { $0.dev == fid.dev && $0.inode == fid.inode }
    }

    /// Convenience used by tests / non-URL callers: look up by a raw resolved
    /// path with an explicit (optional) fileID for the rename fallback.
    func entry(forPath path: String, fileID fid: (dev: UInt64, inode: UInt64)?) -> Entry? {
        if let hit = entries[path] { return hit }
        guard let fid else { return nil }
        return entries.values.first { $0.dev == fid.dev && $0.inode == fid.inode }
    }

    public var count: Int { entries.count }

    // MARK: - Save-decision predicate

    /// Whether a `remember` is worth a disk write. We persist ONLY when the
    /// candidate differs from what we last restored/stored for this file —
    /// i.e. the user actually scrolled or zoomed since restore. An untouched
    /// file (candidate == restored baseline) returns `false`, killing the
    /// write-amplification an open/glance/close cycle would otherwise cause.
    ///
    /// `restored` is the entry the open path fed back (or `nil` if the file
    /// opened at the top with default zoom). `candidate` is the live position.
    public static func shouldPersist(restored: Entry?, candidate: Entry) -> Bool {
        // Nothing to remember (top of file, default zoom) ⇒ skip, and let a
        // mutation that lands here CLEAR an existing entry (handled in remember).
        if candidate.isEmpty && restored == nil { return false }
        guard let restored else { return true }
        return restored.scrollTopLine != candidate.scrollTopLine
            || restored.renderedScrollY != candidate.renderedScrollY
            || restored.zoomLevel != candidate.zoomLevel
    }

    // MARK: - Mutation

    /// Record (or update) the remembered position for `url`. Stamps `savedAt`
    /// from the clock so this entry becomes the freshest (last-evicted) one.
    /// An empty candidate (top of file, no zoom) REMOVES any existing entry
    /// rather than persisting a no-op. Caller is expected to have gated on
    /// `shouldPersist` already, but this is also safe to call unconditionally.
    public func remember(
        url: URL,
        scrollTopLine: Int? = nil,
        renderedScrollY: Double? = nil,
        zoomLevel: Double? = nil,
        fileManager: FileManager = .default
    ) {
        let path = Self.key(for: url)
        let fid = Self.fileID(forPath: path, fileManager: fileManager)
        var entry = Entry(
            path: path,
            dev: fid?.dev,
            inode: fid?.inode,
            scrollTopLine: scrollTopLine,
            renderedScrollY: renderedScrollY,
            zoomLevel: zoomLevel,
            savedAt: now()
        )
        if entry.isEmpty {
            // A reset-to-top / reset-zoom should forget, not store a husk.
            if entries.removeValue(forKey: path) != nil { save() }
            return
        }
        entry.savedAt = now()
        entries[path] = entry
        evict()
        save()
    }

    /// Forget everything (wired into `File → Reset`).
    public func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        save()
    }

    // MARK: - Eviction

    /// Enforce both caps, LRU-by-`savedAt` (oldest first). Count first (cheap),
    /// then the byte budget on the encoded payload.
    private func evict() {
        if entries.count > maxEntries {
            // Drop the oldest until back at the cap.
            let ordered = entries.values.sorted { $0.savedAt < $1.savedAt }
            let overflow = entries.count - maxEntries
            for victim in ordered.prefix(overflow) {
                entries.removeValue(forKey: victim.path)
            }
        }
        // Byte budget: drop oldest while the encoded snapshot exceeds budget,
        // but NEVER below a single entry — a lone entry that alone exceeds the
        // budget (e.g. a pathologically long path) is still kept (the count cap
        // bounds the worst case), so a too-small budget can't nuke everything.
        while entries.count > 1, encodedByteCount() > maxStoreFileBytes {
            guard let oldest = entries.values.min(by: { $0.savedAt < $1.savedAt }) else { break }
            entries.removeValue(forKey: oldest.path)
        }
    }

    /// Byte size of the snapshot as it WOULD be written (same encoder config
    /// the disk write uses), so the budget tracks the real on-disk size.
    private func encodedByteCount() -> Int {
        (try? JSONFileStore.encoder.encode(entries))?.count ?? 0
    }

    // MARK: - Persistence

    private func load() {
        guard let decoded = JSONFileStore.read(
            [String: Entry].self, from: storeURL, maxSize: maxStoreFileBytes
        ) else { return }
        entries = decoded
        // Defensive: a hand-edited file could exceed the count cap even under
        // the byte ceiling. Trim on load so the in-memory invariant holds.
        if entries.count > maxEntries || encodedByteCount() > maxStoreFileBytes {
            evict()
            save()
        }
    }

    private func save() {
        JSONFileStore.enqueueWrite(entries, to: storeURL)
    }

    /// Drain pending writes (terminate path / round-trip tests).
    public func flush() {
        JSONFileStore.flushSync()
    }
}
