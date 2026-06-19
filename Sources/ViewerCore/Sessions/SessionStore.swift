import Foundation

/// Filesystem wrapper around `Sessions/index.json` plus the
/// per-session `<uuid>.json` files. Best-effort atomic-write semantics,
/// swallows IO errors. Supersedes the retired `WorkspaceStore` (G).
///
/// **Concurrency model (design-doc gap #1, fixed):** all disk writes
/// are funneled through a single private serial `DispatchQueue`
/// (`Self.writeQueue`). That makes writes:
///
///   1. Strictly ordered — a save() issued after an earlier save() to
///      the same file *always* lands on disk after it. No file-level
///      locking needed; the queue serializes.
///   2. Coalescible at the call site — `enqueueSave` debounces by URL
///      (newer pending value wins) so a burst of mutations during a
///      drag / typing storm collapses into one disk write.
///   3. Drainable on terminate — `flushSync()` waits for every
///      already-queued write to complete (via a barrier-style sync
///      block), so `applicationWillTerminate` can guarantee the user's
///      state is on disk before the process exits.
///
/// Reads remain synchronous on the caller's queue — they're called
/// from launch on the main thread, infrequent, and a stale-vs-fresh
/// concurrent read/write can't lose data because writes are atomic
/// (POSIX rename).
public final class SessionStore: @unchecked Sendable {
    public let directory: URL

    /// Single serial queue for *all* SessionStore writes across all
    /// instances. Using a class-static queue means a test SessionStore
    /// and a production SessionStore share ordering — fine, because
    /// the queue dispatches by file URL and tests use a fresh tmpdir
    /// each run. Label is QoS-tagged `.utility`: persistence isn't
    /// latency-critical but it's also not deferred-background.
    private static let writeQueue = DispatchQueue(
        label: "com.markdownviewer.SessionStore.writes",
        qos: .utility
    )

    /// Coalescing map: URL → latest pending value. Replaces an
    /// already-enqueued write so a 500 ms burst collapses to one disk
    /// hit. Guarded by `coalesceLock` because mutations can arrive
    /// from any thread (the publishing side dispatches off MainActor
    /// when appropriate). `Any` is escape-hatch for the heterogeneous
    /// value types we coalesce (SessionIndex + SessionSnapshot).
    /// `nonisolated(unsafe)` is correct here: the lock is the
    /// invariant, not Swift's actor isolation — every read/write is
    /// gated by `coalesceLock`. Swift 6 strict-concurrency can't see
    /// across the lock so we annotate.
    nonisolated(unsafe) private static var pending: [URL: Any] = [:]
    nonisolated(unsafe) private static let coalesceLock = NSLock()

    /// Hard ceilings on the on-disk JSON we'll inflate into memory.
    /// `JSONFileStore.read` no-ops its size guard when `maxSize == .max`
    /// (the default), so a tampered / runaway file could otherwise be
    /// read whole into RAM before the decode even runs. Passing an
    /// explicit cap routes an oversized file down the existing
    /// nil/`.corrupt`/start-empty path instead. Sized generously so a
    /// legitimate file is never rejected: the index scales with the
    /// open-session count, a snapshot holds one workspace's reconstructible
    /// state (path list, scroll/selection positions). Mirrors the
    /// `maxSize:` discipline in `BookmarksStore` / `PluginGrantStore`.
    public static let maxIndexFileSize = 4 * 1024 * 1024
    public static let maxSnapshotFileSize = 8 * 1024 * 1024

    public static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let fm = FileManager.default
        // Clean-room override (host live-smoke / T4 session smokes): redirect the
        // store to per-run scratch so a scripted launch never appends scratch
        // pills to the user's real `~/Library/Application Support/MarkdownViewer/
        // Sessions`. `MDV_SKIP_WORKSPACE_RESTORE=1` only suppresses RESTORE —
        // persist() still fires — so the harness must also point the store
        // somewhere disposable. Two knobs, checked in order:
        //   - `MDV_SESSIONS_DIR`: the Sessions dir itself (most direct).
        //   - `MDV_APP_SUPPORT`:  the Application Support root; we append
        //     `MarkdownViewer/Sessions` so one var redirects sibling stores too.
        // (Salvaged from superseded scratch branch worktree-wf_7f6adec6-3ab-64;
        // the rest of that branch — wireLifecycle on the skip-restore path — had
        // already landed on main.)
        let env = environment
        let dir: URL
        if let override = env["MDV_SESSIONS_DIR"], !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else if let appSupport = env["MDV_APP_SUPPORT"], !appSupport.isEmpty {
            dir = URL(fileURLWithPath: appSupport, isDirectory: true)
                .appendingPathComponent("MarkdownViewer/Sessions")
        } else {
            let support = (try? fm.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )) ?? fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
            dir = support.appendingPathComponent("MarkdownViewer/Sessions")
        }
        // createDirectory is idempotent under withIntermediateDirectories:
        // true; failure here surfaces later as a missing-file on read.
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.createDirectory(
            at: dir.appendingPathComponent("trash"),
            withIntermediateDirectories: true
        )
        return dir
    }

    public init(directory: URL = SessionStore.defaultDirectory()) {
        self.directory = directory
    }

    // MARK: Index ----------------------------------------------------

    /// Outcome of attempting to load `index.json`. Distinguishes the
    /// three cases the coordinator must treat differently (PERSIST-03):
    ///
    ///   - `.loaded`: a valid, schema-compatible index was read. The
    ///     coordinator may persist freely.
    ///   - `.absent`: there is no index file (fresh install, or the
    ///     file was deleted). Persisting a fresh index is safe.
    ///   - `.corrupt`: a file exists but doesn't parse (truncated /
    ///     wrong-shape JSON). The coordinator starts empty but may
    ///     overwrite — the bytes are already unusable, so re-persisting
    ///     can only improve matters.
    ///   - `.newerSchema`: a file exists and parses far enough to read
    ///     a `version` greater than `currentSchema`. This is a *running
    ///     an older build against a newer on-disk index* (downgrade)
    ///     situation. The coordinator MUST NOT overwrite it — doing so
    ///     would truncate the newer build's fields (PERSIST-04). We
    ///     surface a banner instead.
    public enum IndexLoadResult: Equatable {
        case loaded(SessionIndex)
        case absent
        case corrupt
        case newerSchema(foundVersion: Int)
    }

    /// Probe just the `version` field of a JSON object on disk. Used to
    /// classify a file that `JSONFileStore.read(SessionIndex.self, …)`
    /// can't fully decode — so we can tell "newer schema" apart from
    /// "corrupt". Returns nil when the file is missing, oversized,
    /// non-JSON, or has no integer `version`.
    private struct SchemaProbe: Decodable { let version: Int }

    /// Rich load that classifies the outcome. Existing callers can keep
    /// using `loadIndex()`; the coordinator uses this to gate writes.
    public func loadIndexResult() -> IndexLoadResult {
        let url = indexURL
        // Fast path: a clean, compatible decode.
        if let idx = JSONFileStore.read(SessionIndex.self, from: url,
                                        maxSize: Self.maxIndexFileSize) {
            if idx.version > SessionIndex.currentSchema {
                return .newerSchema(foundVersion: idx.version)
            }
            return .loaded(idx)
        }
        // The full decode failed (or the file is absent). Disambiguate.
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .absent
        }
        // A file exists but didn't decode as SessionIndex. It might be a
        // newer schema whose *required* fields drifted (so the full
        // decode failed) yet still carries a readable `version`. Probe
        // for that before declaring it corrupt.
        if let probe = JSONFileStore.read(SchemaProbe.self, from: url,
                                          maxSize: Self.maxIndexFileSize),
           probe.version > SessionIndex.currentSchema {
            return .newerSchema(foundVersion: probe.version)
        }
        return .corrupt
    }

    public func loadIndex() -> SessionIndex? {
        if case let .loaded(idx) = loadIndexResult() { return idx }
        return nil
    }

    /// Synchronous write — for tests and the rare "I need this on
    /// disk RIGHT NOW" caller. Production paths should use
    /// `enqueueSaveIndex` so writes coalesce + don't block the
    /// MainActor.
    @discardableResult
    public func saveIndexSync(_ idx: SessionIndex) -> Bool {
        if wouldClobberLiveSnapshots(idx) {
            noteRefusedClobber(liveSnapshotIDs().count)
            return false
        }
        return Self.syncWrite(idx, to: indexURL)
    }

    /// Enqueue an index write on the serial write queue. If another
    /// index write is already pending, this value supersedes it
    /// (coalescing). Returns immediately.
    public func enqueueSaveIndex(_ idx: SessionIndex) {
        if wouldClobberLiveSnapshots(idx) {
            noteRefusedClobber(liveSnapshotIDs().count)
            return
        }
        enqueue(idx, to: indexURL)
    }

    /// IDs of live (non-trashed) per-session snapshot files in `directory`.
    /// `index.json` and the `trash/` subdir are excluded. A genuinely-closed
    /// session has its snapshot `moveToTrash`'d first, so a live snapshot whose
    /// id is missing from an about-to-be-written index signals the race that
    /// emptied `index.json` while the user's sessions still existed on disk.
    public func liveSnapshotIDs() -> [UUID] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { url -> UUID? in
            guard url.pathExtension == "json",
                  url.lastPathComponent != "index.json" else { return nil }
            return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
        }
    }

    /// Substantial orphaned snapshots eligible for index recovery (TSK-438
    /// self-heal): live (non-trash) snapshot files whose sidebar root still
    /// exists AND that have ≥1 open tab — i.e. a real working session lost to an
    /// index clobber, NOT an intentionally-closed one (`close()` trashes its
    /// snapshot first) and NOT an empty stub. Deduped by root (newest wins),
    /// newest-first, capped. Empty when there's nothing worth recovering, so the
    /// caller falls back to a clean empty state.
    public func recoverableSnapshots(maxCount: Int = 24) -> [SessionSnapshot] {
        let fm = FileManager.default
        var byRoot: [String: SessionSnapshot] = [:]
        for id in liveSnapshotIDs() {
            guard let snap = load(id: id),
                  let root = snap.sidebarRootPath, !root.isEmpty,
                  fm.fileExists(atPath: root),
                  !snap.openTabs.isEmpty else { continue }
            if let existing = byRoot[root], existing.lastActiveAt >= snap.lastActiveAt {
                continue
            }
            byRoot[root] = snap
        }
        return byRoot.values
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
            .prefix(maxCount)
            .map { $0 }
    }

    /// The exact session-tab-clobber signature (TSK-438): persisting an EMPTY
    /// session list while snapshot files still live on disk. Refusing such a
    /// write — keeping the prior, non-empty index — is what stops the whole
    /// session-tab strip from vanishing on next launch even though the user's
    /// sessions still exist. A legitimate "closed the last session" write has
    /// already trashed that snapshot, so `liveSnapshotIDs()` is empty and the
    /// write proceeds normally.
    private func wouldClobberLiveSnapshots(_ idx: SessionIndex) -> Bool {
        guard idx.sessions.isEmpty else { return false }
        return !liveSnapshotIDs().isEmpty
    }

    private func noteRefusedClobber(_ count: Int) {
        FileHandle.standardError.write(Data(
            ("[SessionStore] refused to persist an empty session index while "
             + "\(count) snapshot file(s) still exist on disk (clobber guard, "
             + "TSK-438) — keeping the prior index.\n").utf8))
    }

    // MARK: Per-session snapshots ------------------------------------

    public func load(id: UUID) -> SessionSnapshot? {
        guard let snap = JSONFileStore.read(SessionSnapshot.self,
                                            from: fileURL(for: id),
                                            maxSize: Self.maxSnapshotFileSize) else {
            return nil
        }
        if snap.schemaVersion > SessionSnapshot.currentSchema { return nil }
        return snap
    }

    @discardableResult
    public func saveSync(_ snap: SessionSnapshot) -> Bool {
        Self.syncWrite(snap, to: fileURL(for: snap.id))
    }

    /// Enqueue a snapshot write on the serial write queue. Coalesces
    /// with any pending write for the same session UUID.
    public func enqueueSave(_ snap: SessionSnapshot) {
        enqueue(snap, to: fileURL(for: snap.id))
    }

    /// Block until every queued write has been flushed to disk. Call
    /// from `applicationWillTerminate`. Safe to call from any thread
    /// — but typically the main thread on quit.
    ///
    /// Implementation (PERSIST-07): a single `sync` barrier only waits
    /// for blocks *already dispatched*. To be robust against any timing
    /// window where a coalesced value is still pending but its draining
    /// block races the barrier, we drain to a fixpoint: run a barrier
    /// block that writes any straggler pending value inline, and repeat
    /// until the queue observes an empty `pending` map. Because the
    /// write queue is serial, no new block can sneak between iterations
    /// without us seeing its pending value first.
    public func flushSync() {
        while true {
            var drainedSomething = false
            Self.writeQueue.sync {
                // Inside the serial queue: snapshot + clear every
                // currently-pending write and flush it synchronously.
                // Any enqueue that lands after this block is, by FIFO,
                // ordered after the next iteration's barrier too.
                Self.coalesceLock.lock()
                let pending = Self.pending
                Self.pending.removeAll(keepingCapacity: true)
                Self.coalesceLock.unlock()
                for (url, value) in pending {
                    drainedSomething = true
                    Self._encodeAndWrite(value, to: url)
                }
            }
            if !drainedSomething { break }
        }
    }

    /// Move a session's snapshot to `trash/`, preserving filename. No-op
    /// if the file is missing. The 30-day retention sweep is the next
    /// layer up; this just stages the file. Runs synchronously: trash
    /// moves are user-driven (close button) and happen one-at-a-time.
    public func moveToTrash(id: UUID) {
        let src = fileURL(for: id)
        let dst = trashURL(for: id)
        let fm = FileManager.default
        try? fm.createDirectory(at: dst.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        // If a previous trashed-then-restored cycle left a file at the
        // destination, overwrite — the latest closure is the truth.
        try? fm.removeItem(at: dst)
        try? fm.moveItem(at: src, to: dst)
    }

    /// Delete trashed snapshots older than `days` days. Cheap to run
    /// on launch; design §5.6 specifies 30-day TTL.
    public func emptyTrashOlderThan(_ days: Int, now: Date = Date()) {
        let fm = FileManager.default
        let trash = directory.appendingPathComponent("trash")
        guard let urls = try? fm.contentsOfDirectory(
            at: trash, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        for url in urls {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date.distantPast
            if mtime < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - private

    /// Enqueue any value-to-URL pair onto the serial write queue, with
    /// coalescing: if a write to `url` is already pending, replace its
    /// value. Only the latest value is written when the queued block
    /// runs.
    private func enqueue<T: Encodable>(_ value: T, to url: URL) {
        Self.coalesceLock.lock()
        let wasAlreadyPending = Self.pending[url] != nil
        Self.pending[url] = value
        Self.coalesceLock.unlock()
        guard !wasAlreadyPending else {
            // Existing queued block will pick up the newer value when
            // it runs. Save the GCD dispatch cost.
            return
        }
        Self.writeQueue.async {
            Self.coalesceLock.lock()
            let snapshot = Self.pending.removeValue(forKey: url)
            Self.coalesceLock.unlock()
            guard let snapshot else { return }
            // Encode + atomic-write through JSONFileStore. We can't
            // assume the heterogeneous `Any` here is `T` anymore
            // (a newer enqueue may have replaced the value with the
            // same type), so encode by dispatching on the concrete
            // value via `_encodeAndWrite`.
            Self._encodeAndWrite(snapshot, to: url)
        }
    }

    /// Synchronous write that stays coherent with the coalescing queue
    /// (PERSIST race fix). A naive `JSONFileStore.write` here would bypass
    /// the serial `writeQueue` entirely, so it could (a) land *before* an
    /// already-dispatched async block for the same URL — letting a stale
    /// coalesced value overwrite this fresh one — or (b) race a concurrent
    /// enqueue's drain. Mirroring `flushSync`'s drain discipline, we run
    /// the write *inside* `writeQueue.sync`: the serial queue guarantees
    /// every earlier async block for any URL has completed first, and we
    /// evict any pending coalesced value for this URL inside the same block
    /// so no straggler can resurrect after we write. Returns the write's
    /// success bool.
    @discardableResult
    private static func syncWrite<T: Encodable>(_ value: T, to url: URL) -> Bool {
        Self.writeQueue.sync {
            Self.coalesceLock.lock()
            Self.pending.removeValue(forKey: url)
            Self.coalesceLock.unlock()
            return JSONFileStore.write(value, to: url)
        }
    }

    /// Type-erased encode helper. We need this because `pending` holds
    /// `Any` (the dictionary value type can't be `Encodable` —
    /// existentials of protocols-with-Self-or-associated-type aren't
    /// usable as concrete dict values pre-Swift-5.7-existentials, and
    /// we want this code to remain portable across Swift 6.1/6.3).
    /// Dispatch handles both types we actually enqueue.
    private static func _encodeAndWrite(_ value: Any, to url: URL) {
        if let snap = value as? SessionSnapshot {
            JSONFileStore.write(snap, to: url)
        } else if let idx = value as? SessionIndex {
            JSONFileStore.write(idx, to: url)
        }
        // Other types: silently dropped. By construction the only
        // callers are this file's enqueueSave / enqueueSaveIndex.
    }

    private var indexURL: URL {
        directory.appendingPathComponent("index.json")
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func trashURL(for id: UUID) -> URL {
        directory.appendingPathComponent("trash")
            .appendingPathComponent("\(id.uuidString).json")
    }
}
