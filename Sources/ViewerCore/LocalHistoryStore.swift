import Foundation

/// On-disk local file-history (TSK-301) — content snapshots so a user can view
/// and restore earlier revisions of a file, independent of git or the in-buffer
/// undo stack. This is the STORE core: a deterministic, host-testable
/// snapshot/list/restore/prune engine. The *when* to snapshot (save-path
/// wiring), the history UI, and the retention/privacy policy are a separate
/// slice that needs an owner call — this layer just makes the mechanism work
/// and bounds it conservatively.
///
/// Layout: `<directory>/<pathKey>/<unixMillis>.snapshot` holds the raw content;
/// `<pathKey>/_path` records the original path for display/reverse-lookup.
/// `pathKey` is a stable FNV-1a-64 hash of the absolute path (deterministic
/// across runs — `Hasher` is not), so the same file always maps to the same
/// history dir without storing a fragile path→dir index.
///
/// Sendable: no mutable state, just the base directory URL (mirrors
/// `ReviewStore`). All IO is best-effort and never throws — a failed write or a
/// corrupt dir degrades to "no/older history", never a crash.
public final class LocalHistoryStore: Sendable {

    /// One stored revision of a file.
    public struct Version: Sendable, Equatable, Identifiable {
        /// The unix-millis token that names the snapshot file (stable id).
        public let id: String
        /// When the snapshot was taken (derived from `id`).
        public let savedAt: Date
        /// Byte size of the snapshot content (UTF-8).
        public let byteSize: Int
        public init(id: String, savedAt: Date, byteSize: Int) {
            self.id = id
            self.savedAt = savedAt
            self.byteSize = byteSize
        }
    }

    /// Per-file retention cap — older revisions beyond this are pruned oldest-
    /// first. Conservative default; the owner-facing policy slice can tune it.
    public static let maxVersionsPerFile = 50
    /// Skip snapshotting content larger than this (a huge file would bloat the
    /// history dir fast). Matches the per-file ceiling other stores use.
    public static let maxSnapshotBytes = 10 * 1024 * 1024  // 10 MiB

    public let directory: URL

    public static func defaultDirectory() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("MarkdownViewer/LocalHistory")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public init(directory: URL = LocalHistoryStore.defaultDirectory()) {
        self.directory = directory
    }

    /// Snapshot `content` for `path`, stamped `at`. Returns the new `Version`,
    /// or nil when skipped:
    ///   - content larger than `maxSnapshotBytes` (too big to retain), or
    ///   - identical to the most-recent version (dedup — no churn on re-saves
    ///     that didn't change the file), or
    ///   - the write failed.
    /// On success, prunes the file's history to `maxVersionsPerFile`
    /// (oldest-first). Best-effort; never throws.
    @discardableResult
    public func snapshot(path: String, content: String, at date: Date) -> Version? {
        guard content.utf8.count <= Self.maxSnapshotBytes else { return nil }

        // Dedup: skip if the newest existing version already holds this content.
        if let latest = versions(for: path).first,
           contentString(of: latest, for: path) == content {
            return nil
        }

        let dir = fileDirectory(for: path)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // TSK-1027: if this dir already belongs to a DIFFERENT path (FNV-1a-64
        // collision), don't pollute another file's history — bail.
        guard dirBelongsTo(path, dir: dir) else { return nil }

        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        var id = String(millis)
        var url = dir.appendingPathComponent("\(id).snapshot")
        // Same-millisecond collision (e.g. two saves in one tick): bump until free.
        var bump = 0
        while fm.fileExists(atPath: url.path) {
            bump += 1
            id = "\(millis)_\(bump)"
            url = dir.appendingPathComponent("\(id).snapshot")
        }

        guard (try? Data(content.utf8).write(to: url, options: .atomic)) != nil else {
            return nil
        }
        // Record the original path once (best-effort; for display/reverse-lookup).
        let pathFile = dir.appendingPathComponent("_path")
        if !fm.fileExists(atPath: pathFile.path) {
            try? Data(path.utf8).write(to: pathFile, options: .atomic)
        }

        pruneIfNeeded(in: dir)
        return Version(id: id, savedAt: date, byteSize: content.utf8.count)
    }

    /// All stored revisions of `path`, newest-first.
    public func versions(for path: String) -> [Version] {
        let dir = fileDirectory(for: path)
        guard dirBelongsTo(path, dir: dir) else { return [] }   // TSK-1027: hash-collision guard
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let versions = urls.compactMap { url -> Version? in
            guard url.pathExtension == "snapshot" else { return nil }
            let id = url.deletingPathExtension().lastPathComponent
            guard let millis = millis(fromID: id) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Version(
                id: id,
                savedAt: Date(timeIntervalSince1970: Double(millis) / 1000),
                byteSize: size
            )
        }
        // Newest first: sort by the numeric millis, not the raw string (so
        // "_N" bump suffixes and differing digit counts order correctly).
        return versions.sorted { (millis(fromID: $0.id) ?? 0) > (millis(fromID: $1.id) ?? 0) }
    }

    /// The stored content of `version` for `path`, or nil if the snapshot file
    /// is missing / unreadable / not valid UTF-8.
    public func contentString(of version: Version, for path: String) -> String? {
        let dir = fileDirectory(for: path)
        guard dirBelongsTo(path, dir: dir) else { return nil }   // TSK-1027: hash-collision guard
        let url = dir.appendingPathComponent("\(version.id).snapshot")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Drop all stored history for `path`. Best-effort.
    public func clear(for path: String) {
        try? FileManager.default.removeItem(at: fileDirectory(for: path))
    }

    // MARK: - Private

    /// Locate the per-path revision dir. Internal so tests can plant a
    /// mismatched `_path` sidecar (a real FNV-1a-64 collision is infeasible
    /// to construct).
    func fileDirectory(for path: String) -> URL {
        directory.appendingPathComponent(Self.pathKey(path))
    }

    /// True if `dir`'s `_path` sidecar is absent (legacy — can't disprove) or
    /// equals `path`. A PRESENT-but-different sidecar means an FNV hash
    /// collision: another file's history lives here, so we must neither serve
    /// it nor pollute it (TSK-1027).
    private func dirBelongsTo(_ path: String, dir: URL) -> Bool {
        let sidecar = dir.appendingPathComponent("_path")
        guard let data = try? Data(contentsOf: sidecar),
              let stored = String(data: data, encoding: .utf8) else {
            return true
        }
        return stored == path
    }

    /// Prune the directory's `.snapshot` files to `maxVersionsPerFile`,
    /// removing the oldest first. The `_path` sidecar is never counted/removed.
    private func pruneIfNeeded(in dir: URL) {
        let fm = FileManager.default
        let snaps = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "snapshot" }
            .sorted { (millis(fromID: $0.deletingPathExtension().lastPathComponent) ?? 0)
                    < (millis(fromID: $1.deletingPathExtension().lastPathComponent) ?? 0) }
        guard snaps.count > Self.maxVersionsPerFile else { return }
        for url in snaps.prefix(snaps.count - Self.maxVersionsPerFile) {
            try? fm.removeItem(at: url)
        }
    }

    /// Parse the numeric millis prefix from a snapshot id (`"1700000000000"`
    /// or `"1700000000000_2"` for a same-ms bump).
    private func millis(fromID id: String) -> Int64? {
        Int64(id.split(separator: "_").first.map(String.init) ?? id)
    }

    /// Stable, dependency-free FNV-1a-64 hash of the path → hex dir name.
    /// Deterministic across processes (Swift's `Hasher` is randomized per run).
    static func pathKey(_ path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
