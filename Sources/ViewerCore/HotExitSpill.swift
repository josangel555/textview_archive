import Foundation

/// Sidecar spill for hot-exit unsaved buffers that exceed the inline cap
/// (`DocumentModel.hotExitMaxBytes`, 1 MiB) — TSK-1026.
///
/// `TabSnapshot.unsavedText` persists small unsaved buffers INLINE in the
/// per-session JSON, capped at 1 MiB so a big buffer can't bloat it (and trip
/// the 8 MiB snapshot read cap → silent data loss on restore). A dirty buffer
/// between 1 MiB and the editor's 32 MiB cap used to be DROPPED on hot-exit.
/// Instead we spill it to a sibling file and restore from there.
///
/// Keyed by the file PATH (a stable FNV-1a-64 hash), NOT the tab id — a tab's
/// UUID is regenerated on restore, so a tab-id key would never match after a
/// relaunch. Dedup guarantees one tab per path, so the path key is unique among
/// open files. Lives under the Sessions store so `File → Reset` sweeps it too.
///
/// Every entry point takes an injectable `directory` (defaulting to the real
/// per-user spill dir) so host tests can redirect to a scratch dir.
public enum HotExitSpill {

    /// Directory holding the spill files (created lazily on write).
    public static func directory() -> URL {
        SessionStore.defaultDirectory().appendingPathComponent("spill", isDirectory: true)
    }

    /// Stable, dependency-free FNV-1a-64 hash of the path → hex filename stem.
    static func pathKey(_ path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    static func url(forPath path: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(pathKey(path)).txt")
    }

    /// Spill `text` for `path`. Returns false on a write failure (caller keeps
    /// the inline path / treats it as not-spilled).
    @discardableResult
    public static func write(
        _ text: String, forPath path: String, in directory: URL = HotExitSpill.directory()
    ) -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try Data(text.utf8).write(to: url(forPath: path, in: directory), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The spilled unsaved text for `path`, or nil if none / unreadable.
    public static func read(
        forPath path: String, in directory: URL = HotExitSpill.directory()
    ) -> String? {
        guard let data = try? Data(contentsOf: url(forPath: path, in: directory)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Remove the spill for `path` (no-op if absent). Called when a tab's buffer
    /// drops back under the inline cap, is saved, or is closed.
    public static func remove(
        forPath path: String, in directory: URL = HotExitSpill.directory()
    ) {
        try? FileManager.default.removeItem(at: url(forPath: path, in: directory))
    }

    /// Disk-leak guard: drop spill files whose path-key isn't in `keepingPaths`
    /// (i.e. files no longer open in any session). Best-effort.
    public static func pruneOrphans(
        keepingPaths: Set<String>, in directory: URL = HotExitSpill.directory()
    ) {
        let keep = Set(keepingPaths.map(pathKey))
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".txt") {
            let stem = String(name.dropLast(4))
            if !keep.contains(stem) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }
}
