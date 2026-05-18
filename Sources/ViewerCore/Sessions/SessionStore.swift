import Foundation

/// Filesystem wrapper around `Sessions/index.json` plus the
/// per-session `<uuid>.json` files. Mirrors `WorkspaceStore`'s shape:
/// best-effort atomic-write semantics, swallows IO errors.
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

    public static func defaultDirectory() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("MarkdownViewer/Sessions")
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

    public func loadIndex() -> SessionIndex? {
        let url = indexURL
        guard let idx = JSONFileStore.read(SessionIndex.self, from: url) else {
            return nil
        }
        // Same forward-compat guard as WorkspaceStore: refuse files
        // written by a newer schema so we don't truncate v3 fields on
        // the next re-encode. Mirrors ReviewStore's policy.
        if idx.version > SessionIndex.currentSchema { return nil }
        return idx
    }

    /// Synchronous write — for tests and the rare "I need this on
    /// disk RIGHT NOW" caller. Production paths should use
    /// `enqueueSaveIndex` so writes coalesce + don't block the
    /// MainActor.
    @discardableResult
    public func saveIndexSync(_ idx: SessionIndex) -> Bool {
        JSONFileStore.write(idx, to: indexURL)
    }

    /// Enqueue an index write on the serial write queue. If another
    /// index write is already pending, this value supersedes it
    /// (coalescing). Returns immediately.
    public func enqueueSaveIndex(_ idx: SessionIndex) {
        enqueue(idx, to: indexURL)
    }

    // MARK: Per-session snapshots ------------------------------------

    public func load(id: UUID) -> SessionSnapshot? {
        guard let snap = JSONFileStore.read(SessionSnapshot.self,
                                            from: fileURL(for: id)) else {
            return nil
        }
        if snap.schemaVersion > SessionSnapshot.currentSchema { return nil }
        return snap
    }

    @discardableResult
    public func saveSync(_ snap: SessionSnapshot) -> Bool {
        JSONFileStore.write(snap, to: fileURL(for: snap.id))
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
    /// Implementation: dispatches a no-op `sync` block onto the same
    /// serial queue that drains writes. By the time `sync` returns,
    /// every earlier-enqueued write block has run to completion.
    public func flushSync() {
        Self.writeQueue.sync { /* drain marker */ }
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

    // MARK: Legacy bridge --------------------------------------------

    /// Lift a legacy `WorkspaceSnapshot` into a new `SessionSnapshot`.
    /// Caller persists the result + writes a fresh index. Design §8.1.
    public func migrateLegacyWorkspace(from legacy: WorkspaceSnapshot)
        -> SessionSnapshot
    {
        SessionSnapshot.fromLegacy(legacy)
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
