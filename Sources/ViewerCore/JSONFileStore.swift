import Foundation

/// Tiny shared helper for the read/write-JSON-to-disk pattern used by
/// `HistoryStore`, `BookmarksStore`, `SessionStore`. Same encoder
/// config (ISO-8601 dates, pretty-printed + sorted-keys), same
/// max-size check before decoding (so a tampered file can't inflate
/// into memory), same atomic write + parent-dir creation.
///
/// Callers use the static `read` / `write` entrypoints; nothing here
/// holds state.
public enum JSONFileStore {

    /// Read a single Codable value from `url`. Returns nil on:
    /// - file missing
    /// - file larger than `maxSize` (treated like a corrupt file —
    ///   refuse to inflate it)
    /// - decode failure (corrupt JSON / schema drift)
    ///
    /// Never throws — callers historically swallow errors here and
    /// start fresh. Preserving that surface keeps the refactor a
    /// pure extract.
    public static func read<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        maxSize: Int = .max
    ) -> T? {
        if maxSize != .max,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int,
           size > maxSize {
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              maxSize == .max || data.count <= maxSize else { return nil }
        return try? Self.decoder.decode(T.self, from: data)
    }

    /// Read an *array* of Codable values from `url`, dropping any
    /// element that fails to decode instead of discarding the whole
    /// file (PERSIST-02). One malformed entry — a path the encoder
    /// couldn't represent, a future `kind` an old build doesn't know —
    /// would otherwise nuke the user's entire history / bookmarks list.
    ///
    /// Returns nil on the same hard-failure cases as `read` (missing
    /// file, oversize, non-array JSON). An empty-but-valid array decodes
    /// to `[]`, not nil. Per-element failures are silently skipped — the
    /// caller's contract is "best-effort, start with what survived."
    public static func readLenientArray<T: Decodable>(
        _ element: T.Type,
        from url: URL,
        maxSize: Int = .max
    ) -> [T]? {
        guard let wrappers = read([FailableDecodable<T>].self,
                                  from: url, maxSize: maxSize) else {
            return nil
        }
        return wrappers.compactMap(\.value)
    }

    /// Decodes a `T` if possible; otherwise captures the failure and
    /// yields `nil` for `value`, so a surrounding array decode doesn't
    /// abort on one bad element. The thrown decode error is swallowed by
    /// design — these stores are best-effort and never surface decode
    /// errors to the user.
    public struct FailableDecodable<T: Decodable>: Decodable {
        public let value: T?
        public init(from decoder: Decoder) {
            value = try? T(from: decoder)
        }
    }

    /// Central failure hook (audit THEME 1, "silent persistence failures").
    ///
    /// Every store in the app writes through this type, and every caller
    /// discards the returned Bool — so a full disk at quit lost sessions,
    /// bookmarks and hot-exit edits with NO signal anywhere. Rather than
    /// teaching ~a dozen call sites to handle the Bool (best-effort is the
    /// right CONTRACT for them), the failure is reported once, here, at the
    /// choke point every path funnels through (sync `write`, the coalesced
    /// queue, `flushSync`, and SessionStore's direct calls).
    ///
    /// The app installs a handler that surfaces a rate-limited toast (see
    /// `PersistenceFailureReporter`); invoked on whatever thread the write ran
    /// on, so handlers must hop themselves. Nil (tests, CLI tools) keeps the
    /// old silent behaviour.
    nonisolated(unsafe) public static var onWriteFailure: (@Sendable (URL) -> Void)?

    /// Write `value` to `url`, creating parent dirs as needed. Atomic
    /// write; on disk failure the existing file is preserved.
    ///
    /// Returns true on success. Callers historically ignored the
    /// return value (best-effort persistence); failures are surfaced
    /// centrally via `onWriteFailure` instead.
    @discardableResult
    public static func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        guard let data = try? Self.encoder.encode(value) else {
            onWriteFailure?(url)
            return false
        }
        let ok = writeDurably(data, to: url)
        if !ok { onWriteFailure?(url) }
        return ok
    }

    /// Atomic + DURABLE write (TSK-1011). `Data.write(.atomic)` does a temp +
    /// rename but does NOT fsync, so a crash/power-loss right after the rename
    /// can leave a zero-length or truncated file (silent data loss — the very
    /// thing the prior comment claimed was handled). Here we fsync the temp
    /// file's data BEFORE the rename and fsync the directory AFTER, so the
    /// rename entry itself is durable. Internal so host tests can exercise it.
    static func writeDurably(_ data: Data, to url: URL) -> Bool {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp)
            let fh = try FileHandle(forWritingTo: tmp)
            try fh.synchronize()   // fsync(2): flush data to disk before the rename
            try fh.close()
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        // rename(2) is atomic and overwrites the destination in place.
        guard rename(tmp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        // fsync the directory so the rename entry survives a crash too.
        let dfd = open(dir.path, O_RDONLY)
        if dfd >= 0 {
            fsync(dfd)
            close(dfd)
        }
        return true
    }

    // MARK: - Off-main coalescing write (P2 — main-thread I/O)
    //
    // `write` above is synchronous: encode (pretty + sorted, the slow
    // config) + a stat-ed `createDirectory` + an atomic temp-write + fsync
    // + rename. Run from a @MainActor store's `save()` on every file open /
    // bookmark toggle / go-to-path use, that stalls the main thread on disk
    // I/O for a routine action (P2).
    //
    // `enqueueWrite` moves the encode + disk hit OFF the main thread, with
    // the same guarantees SessionStore established:
    //   1. Strictly ordered per URL — a serial queue; a later enqueue to the
    //      same URL always lands after an earlier one.
    //   2. Coalesced per URL — a burst (e.g. clearing history = N removes)
    //      collapses to one disk write; only the latest snapshot is written.
    //   3. Drainable — `flushSync()` blocks until the queue is empty so
    //      `applicationWillTerminate` can guarantee the last write landed.
    //
    // The caller mutates its in-memory model on the main actor (cheap) and
    // hands a SNAPSHOT to `enqueueWrite`; nothing mutable crosses the queue.

    private static let writeQueue = DispatchQueue(
        label: "com.markdownviewer.JSONFileStore.writes",
        qos: .utility
    )

    /// URL → latest pending write closure. The closure captures the
    /// already-snapshotted value + its concrete type, so no type erasure is
    /// needed and the encode happens on the write queue (off-main). Guarded
    /// by `coalesceLock` — enqueues arrive on the main actor, the queue
    /// drains on `.utility`.
    nonisolated(unsafe) private static var pending: [URL: () -> Bool] = [:]
    nonisolated(unsafe) private static let coalesceLock = NSLock()

    /// Enqueue an off-main, coalesced, ordered write of `value` to `url`.
    ///
    /// `value` must be a value-type snapshot (the stores pass their
    /// `[Entry]` arrays, which are `Sendable` value types) so the captured
    /// copy can't be mutated out from under the write. The encode runs on
    /// the write queue, not the caller's thread.
    public static func enqueueWrite<T: Encodable & Sendable>(_ value: T, to url: URL) {
        coalesceLock.lock()
        let alreadyPending = pending[url] != nil
        // Latest-wins: replace any queued closure for this URL.
        pending[url] = { Self.write(value, to: url) }
        coalesceLock.unlock()
        guard !alreadyPending else {
            // An enqueued drain block will pick up the newer closure.
            return
        }
        writeQueue.async {
            coalesceLock.lock()
            let job = pending.removeValue(forKey: url)
            coalesceLock.unlock()
            _ = job?()
        }
    }

    /// Block until every queued write has drained. Call from
    /// `applicationWillTerminate` so the user's last history / bookmark /
    /// go-to-path mutation is on disk before the process exits.
    public static func flushSync() {
        // Snapshot the queued URLs and run their writes synchronously on the
        // calling thread (drain), THEN sync a barrier to catch any block the
        // queue is mid-flight on. Draining inline avoids a deadlock if a
        // write block is itself waiting on the queue.
        writeQueue.sync {
            coalesceLock.lock()
            let jobs = Array(pending.values)
            pending.removeAll()
            coalesceLock.unlock()
            for job in jobs { _ = job() }
        }
    }

    // MARK: - Shared encoder / decoder

    /// ISO-8601 dates + pretty + sorted keys. Matches the surface the
    /// three call sites all converged on; pretty-print so the JSON
    /// files are human-debuggable in TextView itself.
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
