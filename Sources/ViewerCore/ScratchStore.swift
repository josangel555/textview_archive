import Foundation

/// Centralized DISK-backed scratch/cache storage for the app's transient
/// artifacts (rendered-HTML browser previews, `git diff`/`git show` tabs, jq
/// output, etc.), plus a pruning policy so these never accumulate unbounded.
///
/// ## DECISION (TSK-752): disk-backed, NOT an in-memory FS
///
/// The temp artifacts split into two consumer shapes, and the consumer dictates
/// the backing store:
///
/// 1. **md-render-HTML "Open in Browser"** (`DocumentModel`
///    `writeActiveMarkdownPreviewHTML` → `NSWorkspace.open`). The consumer is the
///    user's DEFAULT BROWSER — a *separate process*. A cross-process handoff can
///    only carry a real `file://` URL the other process can `open(2)`; there is no
///    shared in-memory filesystem between two unrelated macOS processes without a
///    new dependency (a FUSE/`memfs` mount or a RAM disk image), which the owner
///    gates and which buys nothing here. So this path is **disk-mandatory**.
///
/// 2. **git-diff tabs** (`GitLogDiffActions`/`GitStatusTab`/`GitStashTab`/
///    `RecentChangesSection` → `DocumentModel.open(url:)`). The consumer is
///    in-process, so an in-memory buffer is *technically* possible — but it would
///    mean either a custom `URLProtocol`/scheme handler feeding the editor +
///    WebView, or a RAM disk, for files that are small (a few KB–MB of patch text)
///    and short-lived. macOS's `/var/folders` temp and `~/Library/Caches` are
///    already memory-resident while hot (unified buffer cache) and spill to disk
///    only under pressure — i.e. the OS gives us the in-memory fast path for free,
///    with disk durability as the fallback. Re-implementing that ourselves is pure
///    cost (complexity, a dependency, two code paths) for no measurable win.
///
/// Conclusion: **keep disk.** The real, actionable gap was not the medium but the
/// *hygiene* — five copy-pasted call sites each resolved
/// `~/Library/Caches/MarkdownViewer/<sub>` by hand and NONE ever pruned, so the
/// preview/diff caches grew one file per document-stem / per commit forever. This
/// type centralizes the resolution and adds a bounded eviction policy.
public enum ScratchStore {

    /// Resolve `~/Library/Caches/MarkdownViewer/<name>` (creating it), falling
    /// back to the temp dir when Caches is unavailable. This is the single source
    /// of truth the diff/preview/jq sites should use instead of re-deriving it.
    ///
    /// `create: false` skips the `createDirectory` side effect (handy for pure
    /// path resolution / tests that don't want the dir to materialize).
    @discardableResult
    public static func cacheSubdir(_ name: String, create: Bool = true) -> URL {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base
            .appendingPathComponent("MarkdownViewer", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        if create {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Bounds on how much a scratch directory may hold before older entries are
    /// evicted. A nil bound means "no limit on that axis". Eviction is OLDEST
    /// (by modification date) first, and applies all three caps jointly.
    public struct PrunePolicy: Sendable, Equatable {
        /// Evict entries older than this (seconds). nil ⇒ no age cap.
        public var maxAge: TimeInterval?
        /// Keep at most this many entries. nil ⇒ no count cap.
        public var maxCount: Int?
        /// Keep the total on-disk size at or under this many bytes. nil ⇒ no size cap.
        public var maxTotalBytes: Int?

        public init(maxAge: TimeInterval? = nil,
                    maxCount: Int? = nil,
                    maxTotalBytes: Int? = nil) {
            self.maxAge = maxAge
            self.maxCount = maxCount
            self.maxTotalBytes = maxTotalBytes
        }

        /// Default for the diff/preview scratch caches: drop anything older than
        /// 7 days, then cap to the 200 most-recent files and 64 MiB total. Tuned
        /// to be generous (a heavy git-browsing session won't lose its open tabs)
        /// while still bounding unbounded growth.
        public static let scratchDefault = PrunePolicy(
            maxAge: 7 * 24 * 60 * 60,
            maxCount: 200,
            maxTotalBytes: 64 * 1024 * 1024)
    }

    /// One directory entry's prune-relevant facts. Pure input to `entriesToEvict`
    /// so the eviction MATH is host-testable without touching the filesystem.
    public struct Entry: Sendable, Equatable {
        public let url: URL
        /// Last-modified instant (used for age + recency ordering).
        public let modified: Date
        /// Size in bytes (used for the total-size cap).
        public let size: Int

        public init(url: URL, modified: Date, size: Int) {
            self.url = url
            self.modified = modified
            self.size = size
        }
    }

    /// PURE eviction planner: given the current entries and a policy, return the
    /// subset to delete, oldest-first. `now` is injectable for deterministic age
    /// tests. The three caps are applied in order — age, then count, then size —
    /// and the survivors are always the MOST-RECENT entries.
    ///
    /// Deterministic ordering: ties on `modified` break by `url.path` so the
    /// result is stable regardless of input order.
    public static func entriesToEvict(_ entries: [Entry],
                                      policy: PrunePolicy,
                                      now: Date = Date()) -> [Entry] {
        // Newest first; stable tiebreak so the plan is reproducible.
        let sorted = entries.sorted {
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            return $0.url.path < $1.url.path
        }

        var keep: [Entry] = []
        var evict: [Entry] = []
        var runningBytes = 0

        for entry in sorted {
            var drop = false

            if let maxAge = policy.maxAge,
               now.timeIntervalSince(entry.modified) > maxAge {
                drop = true
            }
            if !drop, let maxCount = policy.maxCount, keep.count >= maxCount {
                drop = true
            }
            if !drop, let maxBytes = policy.maxTotalBytes,
               runningBytes + entry.size > maxBytes {
                drop = true
            }

            if drop {
                evict.append(entry)
            } else {
                keep.append(entry)
                runningBytes += entry.size
            }
        }
        return evict
    }

    /// Read a scratch directory's entries, plan eviction via `entriesToEvict`, and
    /// delete the losers. Returns the URLs actually removed (best-effort: a delete
    /// failure is swallowed and the URL omitted). Safe to call before every write
    /// to a scratch dir; it never throws and never touches files outside `dir`.
    @discardableResult
    public static func prune(directory dir: URL,
                             policy: PrunePolicy = .scratchDefault,
                             now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey,
                                      .fileSizeKey,
                                      .isRegularFileKey]
        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return [] }

        let entries: [Entry] = contents.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            // Only prune regular files — never recurse into / delete subdirs.
            guard values?.isRegularFile == true else { return nil }
            let modified = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? 0
            return Entry(url: url, modified: modified, size: size)
        }

        let toEvict = entriesToEvict(entries, policy: policy, now: now)
        var removed: [URL] = []
        for entry in toEvict where (try? fm.removeItem(at: entry.url)) != nil {
            removed.append(entry.url)
        }
        return removed
    }
}
