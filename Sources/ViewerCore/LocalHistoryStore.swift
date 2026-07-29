import Foundation

/// On-disk local file-history (TSK-301, reworked TSK-1103) — content revisions
/// so a user can view, diff, and restore earlier versions of a file,
/// independent of git or the in-buffer undo stack. This is the STORE core: a
/// deterministic, host-testable snapshot/list/restore/diff/prune engine. The
/// *when* to snapshot (save-path wiring) and the history UI are SEPARATE slices
/// owned by sibling agents; this layer makes the mechanism work, applies the
/// owner's storage policy, and exposes a stable API those slices build on.
///
/// ## Owner storage policy (TSK-1103)
///
/// - **Adaptive representation.** The first version of a file, and any version
///   that is a near-full rewrite of the previous one, is stored as a FULL
///   snapshot. A small change is stored as a DIFF (a `LineDiff.Patch`) against
///   the nearest preceding full snapshot. For every non-first version we
///   compute BOTH a candidate full record and a candidate diff record and keep
///   whichever is smaller on disk — so we never pay more than a full snapshot
///   would have cost, and a tiny edit costs only its delta.
///   - *Anchor model (the tradeoff):* a diff is always against its nearest
///     preceding FULL snapshot — never a chain of diff-on-diff. Reconstructing
///     any version therefore reads at most TWO records (its anchor full + its
///     own delta), bounding reconstruction cost and blast radius (one corrupt
///     diff loses one version, not a whole chain). The cost is that a diff can
///     drift large as the file diverges from its anchor — which is exactly when
///     the "store whichever is smaller" rule promotes that version to a new full
///     snapshot, re-anchoring the chain. This keeps reconstruction O(1) records
///     while keeping storage near-minimal.
/// - **100 MB cap PER FILE, thinned — not truncated.** A file's total on-disk
///   history is reduced until under `maxFileHistoryBytes` by dropping the
///   least-valuable version each round: the interior version whose removal
///   leaves the smallest time gap (`thinningVictimIndex`). The FIRST and
///   NEWEST versions are never candidates, so a dense burst of saves is thinned
///   long before anything old, and the original draft survives. Nothing expires
///   by AGE. Pruning a FULL snapshot that later diffs depend on first
///   re-materialises (promotes) the oldest surviving dependent into a new full
///   snapshot, so the chain is never orphaned.
/// - **Text-only & secret-excluding.** `snapshot` refuses binary content and
///   content that looks like it carries a credential (`HistoryContentFilter`).
/// - **Configurable, default-ON.** Capture is gated by an injected `isEnabled`
///   closure (the app wires `PreferencesStore.localHistoryEnabled`, default
///   true). When off, `snapshot` is a no-op.
///
/// ## On-disk layout
///
/// `<directory>/<pathKey>/<unixMillis>.rev` — one record per version. Each
/// record is `<one-line JSON header>\n<payload>`:
///   - `kind:"full"`  → payload is the verbatim UTF-8 content.
///   - `kind:"diff"`  → payload is `LineDiff.Patch.serialized()` and the header
///     names its `anchor` (the id of the full snapshot it applies to).
/// The header also carries `size` (logical content byte length) and `hash`
/// (FNV-1a-64 of the content) so listing + dedup don't need to reconstruct.
/// `<pathKey>/_path` records the original path for display + the hash-collision
/// guard. `pathKey` is a stable FNV-1a-64 hash of the absolute path
/// (deterministic across runs — `Hasher` is randomized), so a file always maps
/// to the same dir without a fragile path→dir index.
///
/// Sendable: no mutable state, just the base directory URL and an `isEnabled`
/// gate. All IO is best-effort and never throws — a failed write or a corrupt
/// record degrades to "no/older history", never a crash.
public final class LocalHistoryStore: Sendable {

    /// One stored revision of a file.
    public struct Version: Sendable, Equatable, Identifiable {
        /// The unix-millis token that names the record file (stable id).
        public let id: String
        /// When the version was saved (derived from `id`).
        public let savedAt: Date
        /// LOGICAL content size (UTF-8 byte length of the full text), NOT the
        /// on-disk record size — so the UI shows the user a meaningful "this
        /// version was N bytes" regardless of how we stored it.
        public let byteSize: Int
        public init(id: String, savedAt: Date, byteSize: Int) {
            self.id = id
            self.savedAt = savedAt
            self.byteSize = byteSize
        }
    }

    /// A grouped, context-bearing diff hunk for the history UI. Aliased to the
    /// shared `LineDiff.DiffHunk` so callers have one hunk model.
    public typealias DiffHunk = LineDiff.DiffHunk

    /// Per-file byte cap: a file's total history is THINNED (see
    /// `thinningVictimIndex`) until its on-disk records sum under this.
    ///
    /// Raised 20 MiB → 100 MiB on owner instruction (2026-07-29): *"I don't
    /// want it to be cleared, unless say 100MB or so for that file. even then
    /// evict old, or do some compaction."* History is the safety net the
    /// conflict-resolution work now leans on, so it should be hard to lose.
    ///
    /// There is NO time-based expiry — age alone never deletes a version, only
    /// this byte budget does, and it thins the densest stretch rather than
    /// eating the timeline from the oldest end. Records are already compacted: each version is stored
    /// as a line-DIFF against the nearest full snapshot when that is smaller
    /// (see `capture`), and pruning a full snapshot that later diffs depend on
    /// first re-materialises the oldest surviving dependent so a chain is never
    /// orphaned.
    public static let maxFileHistoryBytes = 100 * 1024 * 1024  // 100 MiB

    /// Skip snapshotting a single version larger than this — a version bigger
    /// than the whole per-file budget could never be retained anyway, and it
    /// keeps one pathological save from dominating the dir.
    public static let maxSnapshotBytes = maxFileHistoryBytes

    /// Size-guard (owner policy TSK-1103): only attempt a DIFF candidate when
    /// BOTH the anchor and the new content are under this. A change above it (or
    /// against a large anchor) is stored as a FULL snapshot WITHOUT running the
    /// differ at all — so the line-diff only ever executes on small-to-moderate
    /// inputs, and even then it is O(N) memory (linear-space Myers).
    ///
    /// Rationale: the line-diff is now O(N·D) time / O(N) space (no O(n·m)
    /// matrix), but a near-full rewrite of a multi-MB file still does real
    /// (bounded) work to produce a delta that would be ~as big as a full
    /// snapshot anyway — the "store whichever is smaller" rule would then discard
    /// it. Routing large/near-full changes straight to a snapshot skips that
    /// wasted diff entirely. 1 MiB comfortably covers ordinary source/prose
    /// edits while capping per-save diff cost.
    public static let maxDiffInputBytes = 1 * 1024 * 1024  // 1 MiB

    public let directory: URL

    /// Capture gate. Default `{ true }` (policy default-ON). The app injects a
    /// closure reading `PreferencesStore.localHistoryEnabled` so the toggle is
    /// honoured live without ViewerCore importing the UI layer. Read on EVERY
    /// `snapshot` so flipping the pref takes effect immediately.
    private let isEnabled: @Sendable () -> Bool

    /// Per-file byte cap for THIS store instance (defaults to the static
    /// `maxFileHistoryBytes`). Injectable so tests can drive pruning at a small
    /// cap without writing megabytes (TSK-836: the byteCap tests were ~8-9s each
    /// writing ~24 MiB to hit the real 20 MiB cap; a small cap makes them ~0.1s).
    public let capBytes: Int
    /// Diff-input ceiling for THIS store instance (defaults to the static
    /// `maxDiffInputBytes`); scaled alongside `capBytes` so the snapshot↔diff
    /// ratios hold at a small test cap.
    public let diffInputCap: Int

    public static func defaultDirectory() -> URL {
        let fm = FileManager.default
        // TSK-1288: under XCTest, never touch the dev's real ~/Library state.
        if let base = TestStateRedirect.appSupportBase() {
            let dir = base.appendingPathComponent("MarkdownViewer/LocalHistory")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let support = (try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("MarkdownViewer/LocalHistory")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public init(
        directory: URL = LocalHistoryStore.defaultDirectory(),
        isEnabled: @escaping @Sendable () -> Bool = { true }
    ) {
        self.directory = directory
        self.isEnabled = isEnabled
        self.capBytes = Self.maxFileHistoryBytes
        self.diffInputCap = Self.maxDiffInputBytes
    }

    /// Init with an explicit byte budget (TSK-836). A SEPARATE label set from the
    /// 2-arg init (capBytes/diffInputCap are REQUIRED here, not defaulted) so the
    /// 2-arg init's ABI symbol stays stable — adding defaulted params to the
    /// EXISTING init instead would break existing call sites (the Swift
    /// defaulted-param link break: a stale caller .o references the old mangled
    /// `__allocating_init` and fails to link). Tests drive pruning at a small cap
    /// via this init; production keeps using the 2-arg form unchanged.
    public init(
        directory: URL,
        isEnabled: @escaping @Sendable () -> Bool = { true },
        capBytes: Int,
        diffInputCap: Int
    ) {
        self.directory = directory
        self.isEnabled = isEnabled
        self.capBytes = capBytes
        self.diffInputCap = diffInputCap
    }

    // MARK: - Public API (stable — sibling agents depend on these signatures)

    /// Snapshot `content` for `path`, stamped `at`. Returns the new `Version`,
    /// or nil when skipped:
    ///   - capture is disabled (`isEnabled()` is false), or
    ///   - content is empty, larger than `maxSnapshotBytes`, binary, or looks
    ///     like it carries a secret (`HistoryContentFilter`), or
    ///   - identical to the most-recent version (dedup — no churn on a re-save
    ///     that didn't change the file), or
    ///   - the write failed / the dir belongs to another path (hash collision).
    /// On success, stores the version adaptively (full vs diff, whichever is
    /// smaller) and prunes the file's history under `maxFileHistoryBytes`.
    /// Best-effort; never throws.
    @discardableResult
    /// TSK-1608 (owner 2026-07-26: "saves are choking … beach ball when I
    /// save") — the OFF-MAIN snapshot entry point.
    ///
    /// `snapshot(path:content:at:)` is genuinely expensive: it reads every
    /// existing `.rev` record for the file, may reconstruct the newest version
    /// to dedup, runs a line-diff, writes the record, then prunes under the
    /// byte cap. Measured at ~220 ms per call on an 80 KB file
    /// (`LocalHistorySnapshotCostTests`) — and it was being called
    /// SYNCHRONOUSLY on the main actor from `EditorCoordinator.saveEditor`,
    /// so every ⌘S blocked the UI for about a quarter second.
    ///
    /// Snapshotting is best-effort by contract (a failure must never fail a
    /// save that already landed on disk), so it does not belong on the save's
    /// critical path at all. This runs it on a private SERIAL queue: the main
    /// thread returns immediately, and serialization keeps concurrent saves of
    /// the same file from interleaving their read-modify-write of the history
    /// directory.
    ///
    /// Ordering note: snapshots land slightly after the save. A snapshot still
    /// in flight when the app quits is dropped — acceptable for a best-effort
    /// recovery aid, and the on-disk file itself is already saved.
    public func snapshotInBackground(path: String, content: String, at date: Date) {
        Self.snapshotQueue.async { [self] in
            _ = snapshot(path: path, content: content, at: date)
        }
    }

    /// Serial queue for background snapshots. `utility` QoS: recovery history
    /// is useful but never urgent, and this must not compete with the UI.
    private static let snapshotQueue = DispatchQueue(
        label: "com.markdownviewer.localhistory.snapshot", qos: .utility)

    /// Test seam: block until every queued background snapshot has finished,
    /// so a test can assert on the resulting history deterministically.
    public static func drainBackgroundSnapshots(timeout: TimeInterval = 10) {
        let sem = DispatchSemaphore(value: 0)
        snapshotQueue.async { sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
    }

    public func snapshot(path: String, content: String, at date: Date) -> Version? {
        capture(path: path, content: content, at: date).version
    }

    /// Why a capture did not store a new revision. Callers that are about to
    /// DESTROY the content being captured (conflict resolution discarding one
    /// side) must distinguish these: `.alreadyPresent` is as safe as `.stored`,
    /// every other case means the content would be **gone**.
    public enum CaptureRefusal: String, Sendable, Equatable {
        case historyDisabled
        case empty
        case tooLarge
        case looksBinary
        case looksLikeSecret
        case secretLikePath
        case storageCollision
        case writeFailed

        /// User-facing reason, for a prompt that has to admit the copy can't
        /// be kept.
        public var explanation: String {
            switch self {
            case .historyDisabled: return "Local History is turned off"
            case .empty:           return "the content is empty"
            case .tooLarge:        return "the file is larger than the Local History size cap"
            case .looksBinary:     return "the content looks binary"
            case .looksLikeSecret: return "the content looks like it contains a secret"
            case .secretLikePath:  return "this file name is excluded from Local History"
            case .storageCollision: return "its history folder is in use by another file"
            case .writeFailed:     return "writing the history record failed"
            }
        }
    }

    /// Outcome of an attempted capture.
    public enum CaptureOutcome: Sendable, Equatable {
        /// A new revision was written.
        case stored(Version)
        /// The newest existing revision already holds exactly this content, so
        /// nothing needed writing — the content IS recoverable.
        case alreadyPresent
        /// Nothing was stored; this content is NOT recoverable from history.
        case refused(CaptureRefusal)

        public var version: Version? {
            if case .stored(let v) = self { return v }
            return nil
        }

        /// True when the content is retrievable from Local History afterwards.
        /// The precondition for any caller that is about to discard it.
        public var isPreserved: Bool {
            switch self {
            case .stored, .alreadyPresent: return true
            case .refused:                 return false
            }
        }

        public var refusal: CaptureRefusal? {
            if case .refused(let r) = self { return r }
            return nil
        }
    }

    /// `snapshot` with a REASON when nothing was stored.
    ///
    /// Added for conflict resolution (2026-07-28): discarding one side of a
    /// disk conflict is only non-destructive if the discarded bytes actually
    /// landed in history, and this store legitimately declines several classes
    /// of content (secrets, oversize, binary, disabled). A caller that assumed
    /// success would silently destroy exactly the content the user was told was
    /// being kept. Single code path — `snapshot` delegates here.
    public func capture(path: String, content: String, at date: Date) -> CaptureOutcome {
        guard isEnabled() else { return .refused(.historyDisabled) }
        guard !content.isEmpty else { return .refused(.empty) }
        guard content.utf8.count <= capBytes else { return .refused(.tooLarge) }
        guard !HistoryContentFilter.isProbablyBinary(content) else { return .refused(.looksBinary) }
        guard !HistoryContentFilter.looksLikeSecret(content) else { return .refused(.looksLikeSecret) }
        // Filename-based secret exclusion (TSK-1103 merge): the viewer's
        // LocalHistoryPolicy excludes by NAME (.env / *.pem / credentials…),
        // which catches secret files whose CONTENT alone wouldn't trip the
        // content filter. Unified here so EVERY save path is gated at the store.
        guard !LocalHistoryPolicy.isSecretLike(path: path) else { return .refused(.secretLikePath) }

        let dir = fileDirectory(for: path)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // TSK-1027: if this dir already belongs to a DIFFERENT path (FNV-1a-64
        // collision), don't pollute another file's history — bail.
        guard dirBelongsTo(path, dir: dir) else { return .refused(.storageCollision) }

        let existing = records(in: dir)              // ascending by millis
        let contentHash = LineDiff.fnv1a(content)

        // Dedup: skip if the newest existing version already holds this content.
        if let newest = existing.last, newest.header.hash == contentHash,
           reconstruct(newest, allRecords: existing) == content {
            return .alreadyPresent
        }

        let id = freshID(for: date, in: dir)
        let contentSize = content.utf8.count

        // Decide representation. Always have a FULL candidate; if there's a
        // current anchor we can reconstruct, also build a DIFF candidate and
        // keep the smaller record (a near-full rewrite naturally lands on full).
        var chosenHeader = Header.full(size: contentSize, hash: contentHash)
        var chosenPayload = content
        let fullRecordBytes = chosenHeader.recordByteSize(payload: content)

        // SIZE-GUARD (TSK-1103): only run the differ when this change is small
        // enough — both the new content AND the anchor must be under
        // `maxDiffInputBytes`. A large/near-full change is stored as a FULL
        // snapshot WITHOUT computing a diff, so the line-diff never runs on huge
        // inputs (and even on allowed inputs it is O(N) memory). This is the
        // product-layer bound that, with the linear-space algorithm, makes the
        // 77 GB matrix runaway impossible.
        if contentSize <= diffInputCap,
           let anchor = existing.last(where: { $0.header.kind == .full }),
           anchor.header.size <= diffInputCap,
           let anchorContent = reconstruct(anchor, allRecords: existing) {
            let diffPayload = LineDiff.Patch.between(anchorContent, content).serialized()
            let diffHeader = Header.diff(size: contentSize, hash: contentHash, anchor: anchor.id)
            if diffHeader.recordByteSize(payload: diffPayload) < fullRecordBytes {
                chosenHeader = diffHeader
                chosenPayload = diffPayload
            }
        }

        let url = dir.appendingPathComponent("\(id).rev")
        guard writeRecord(header: chosenHeader, payload: chosenPayload, to: url) else {
            return .refused(.writeFailed)
        }

        // Record the original path once (best-effort; display + collision guard).
        let pathFile = dir.appendingPathComponent("_path")
        if !fm.fileExists(atPath: pathFile.path) {
            try? Data(path.utf8).write(to: pathFile, options: .atomic)
        }

        pruneUnderByteCap(in: dir)
        return .stored(Version(id: id, savedAt: date, byteSize: contentSize))
    }

    /// All stored revisions of `path`, newest-first.
    public func versions(for path: String) -> [Version] {
        let dir = fileDirectory(for: path)
        guard dirBelongsTo(path, dir: dir) else { return [] }   // TSK-1027 guard
        return records(in: dir)
            .sorted { $0.millis > $1.millis }                   // newest first
            .map { Version(id: $0.id,
                           savedAt: Date(timeIntervalSince1970: Double($0.millis) / 1000),
                           byteSize: $0.header.size) }
    }

    /// The stored content of `version` for `path`, transparently reconstructed
    /// from its full snapshot (or its anchor full + delta). Nil if the record is
    /// missing / unreadable / its anchor is gone.
    public func contentString(of version: Version, for path: String) -> String? {
        let dir = fileDirectory(for: path)
        guard dirBelongsTo(path, dir: dir) else { return nil }  // TSK-1027 guard
        let all = records(in: dir)
        guard let rec = all.first(where: { $0.id == version.id }) else { return nil }
        return reconstruct(rec, allRecords: all)
    }

    /// Drop all stored history for `path`. Best-effort.
    public func clear(for path: String) {
        try? FileManager.default.removeItem(at: fileDirectory(for: path))
    }

    /// TSK-1573 — every absolute path Local History has EVER tracked, read from
    /// the per-directory `_path` sidecars (NOT the recents list). This lets the
    /// recover-deleted flow surface a file deleted long ago / dropped from
    /// recents — the store keys dirs by a one-way hash, but each dir records its
    /// origin path in `_path`, so the set is fully enumerable. Deduped; a dir with
    /// no readable sidecar (legacy/corrupt) is skipped; a listing failure ⇒ [].
    public func allTrackedPaths() -> [String] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for dir in dirs {
            let sidecar = dir.appendingPathComponent("_path")
            guard let data = try? Data(contentsOf: sidecar),
                  let path = String(data: data, encoding: .utf8),
                  !path.isEmpty, seen.insert(path).inserted else { continue }
            out.append(path)
        }
        return out
    }

    // MARK: - Diff API (added for the history UI — TSK-1103)

    /// Diff between two stored versions of `path` (`from` → `to`), as grouped
    /// context-bearing hunks. Nil if either version can't be reconstructed.
    /// `context` is the unchanged-line padding around each change run.
    public func diff(from: Version, to: Version, for path: String, context: Int = 3) -> [DiffHunk]? {
        guard let a = contentString(of: from, for: path),
              let b = contentString(of: to, for: path) else { return nil }
        return LineDiff.hunks(from: a, to: b, context: context)
    }

    /// Diff a stored version against arbitrary current text (e.g. the live
    /// editor buffer) — `version` → `current`. Nil if the version can't be
    /// reconstructed.
    public func diff(version: Version, againstCurrent current: String, for path: String, context: Int = 3) -> [DiffHunk]? {
        guard let base = contentString(of: version, for: path) else { return nil }
        return LineDiff.hunks(from: base, to: current, context: context)
    }

    // MARK: - Record model

    /// Parsed header of a `.rev` record.
    struct Header: Equatable {
        enum Kind: String { case full, diff }
        let kind: Kind
        let size: Int          // logical content byte length
        let hash: UInt64       // FNV-1a-64 of the content
        let anchor: String?    // diff only: id of the full snapshot it applies to

        static func full(size: Int, hash: UInt64) -> Header {
            Header(kind: .full, size: size, hash: hash, anchor: nil)
        }
        static func diff(size: Int, hash: UInt64, anchor: String) -> Header {
            Header(kind: .diff, size: size, hash: hash, anchor: anchor)
        }

        /// Serialise as a single JSON line (no embedded newline, so the first
        /// `\n` of the record cleanly separates header from payload).
        func serializedLine() -> String {
            // Hand-rolled JSON (primitives only) to avoid an encoder allocation
            // per write and to GUARANTEE single-line output.
            var s = "{\"kind\":\"\(kind.rawValue)\",\"size\":\(size),\"hash\":\(hash)"
            if let anchor { s += ",\"anchor\":\"\(anchor)\"" }
            s += "}"
            return s
        }

        /// Total on-disk byte size of a record with this header + `payload`
        /// (header line + `\n` + payload, all UTF-8). Used to compare full vs
        /// diff candidates and to sum the per-file cap.
        func recordByteSize(payload: String) -> Int {
            serializedLine().utf8.count + 1 + payload.utf8.count
        }

        static func parse(_ line: Substring) -> Header? {
            // Minimal tolerant parse of our own single-line JSON.
            func string(_ key: String) -> String? {
                guard let r = line.range(of: "\"\(key)\":\"") else { return nil }
                let tail = line[r.upperBound...]
                guard let end = tail.firstIndex(of: "\"") else { return nil }
                return String(tail[..<end])
            }
            func number(_ key: String) -> String? {
                guard let r = line.range(of: "\"\(key)\":") else { return nil }
                let run = line[r.upperBound...].prefix(while: { $0.isNumber })
                return run.isEmpty ? nil : String(run)
            }
            guard let kindRaw = string("kind"), let kind = Kind(rawValue: kindRaw),
                  let sizeRaw = number("size"), let size = Int(sizeRaw),
                  let hashRaw = number("hash"), let hash = UInt64(hashRaw) else { return nil }
            return Header(kind: kind, size: size, hash: hash, anchor: string("anchor"))
        }
    }

    /// An on-disk record located in a file's history dir.
    struct Record {
        let id: String
        let millis: Int64
        let url: URL
        let header: Header
        let onDiskBytes: Int
    }

    // MARK: - Private — record IO

    /// Load + parse every `.rev` record in `dir`, ascending by millis. Records
    /// with an unparseable header are skipped (best-effort, never crash).
    private func records(in dir: URL) -> [Record] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let recs = urls.compactMap { url -> Record? in
            guard url.pathExtension == "rev" else { return nil }
            let id = url.deletingPathExtension().lastPathComponent
            guard let millis = millis(fromID: id),
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8),
                  let nl = text.firstIndex(of: "\n"),
                  let header = Header.parse(text[..<nl]) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? data.count
            return Record(id: id, millis: millis, url: url, header: header, onDiskBytes: size)
        }
        return recs.sorted { $0.millis < $1.millis }
    }

    /// Reconstruct the full content of `rec`. A `full` record returns its
    /// payload verbatim; a `diff` record loads its anchor's full content and
    /// applies the stored line patch. Deterministic; nil if anything is
    /// missing/corrupt.
    private func reconstruct(_ rec: Record, allRecords: [Record]) -> String? {
        guard let (_, payload) = readRecord(rec.url) else { return nil }
        switch rec.header.kind {
        case .full:
            return payload
        case .diff:
            guard let anchorId = rec.header.anchor,
                  let anchor = allRecords.first(where: { $0.id == anchorId }),
                  anchor.header.kind == .full,
                  let anchorContent = reconstruct(anchor, allRecords: allRecords),
                  let patch = LineDiff.Patch.deserialize(payload) else { return nil }
            return patch.apply(to: anchorContent)
        }
    }

    /// Read + split a record file into (header, payload). Payload is everything
    /// after the first `\n`.
    private func readRecord(_ url: URL) -> (Header, String)? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              let nl = text.firstIndex(of: "\n"),
              let header = Header.parse(text[..<nl]) else { return nil }
        return (header, String(text[text.index(after: nl)...]))
    }

    private func writeRecord(header: Header, payload: String, to url: URL) -> Bool {
        let blob = header.serializedLine() + "\n" + payload
        return (try? Data(blob.utf8).write(to: url, options: .atomic)) != nil
    }

    // MARK: - Private — pruning under the byte cap

    /// Prune `dir`'s records oldest-first until their on-disk total is under
    /// `maxFileHistoryBytes`. The NEWEST record is never removed. Before
    /// deleting a FULL snapshot that surviving diffs anchor to, the oldest
    /// surviving dependent is PROMOTED to a full snapshot (re-materialised) so no
    /// chain is orphaned.
    /// Which version to drop when a file is over budget.
    ///
    /// NOT simply the oldest (owner, 2026-07-29: *"We don't want to lose the
    /// oldest ones. We have to be smart about it."*). Dropping oldest-first
    /// eats a file's history from the beginning, so the original draft — often
    /// the single most valuable version — is the first casualty, while fifty
    /// near-identical saves from this afternoon all survive.
    ///
    /// Instead this THINS the densest stretch: for each interior version it
    /// measures the time gap its removal would leave (`next - previous`) and
    /// drops the smallest one. A burst of rapid saves is thinned long before
    /// anything from last month, and the timeline keeps an even spread as it
    /// shrinks — the backup-rotation idea, applied per file.
    ///
    /// The FIRST and LAST versions are never candidates: the original state and
    /// the newest state both survive until nothing else is left.
    ///
    /// Returns nil when there is no interior version to thin (fewer than 3), so
    /// the caller can fall back. Pure → host-tested.
    static func thinningVictimIndex(millis: [Int64]) -> Int? {
        guard millis.count > 2 else { return nil }
        var best: (index: Int, span: Int64)?
        for i in 1..<(millis.count - 1) {
            let span = millis[i + 1] - millis[i - 1]
            // `<=` keeps the LAST minimum on ties, biasing removal toward the
            // newer side of an evenly-spaced run — older versions are the ones
            // we are trying hardest to keep.
            if best == nil || span <= best!.span { best = (i, span) }
        }
        return best?.index
    }

    private func pruneUnderByteCap(in dir: URL) {
        let fm = FileManager.default
        var recs = records(in: dir)                          // ascending
        func total() -> Int { recs.reduce(0) { $0 + $1.onDiskBytes } }

        while total() > capBytes, recs.count > 1 {
            // Thin the densest stretch; with fewer than 3 versions there is no
            // interior to thin, so the oldest goes and the NEWEST is kept (it
            // is the one a recovery actually reaches for).
            let victimIndex = Self.thinningVictimIndex(millis: recs.map(\.millis)) ?? 0
            let victim = recs[victimIndex]

            if victim.header.kind == .full {
                // Deleting this full would orphan EVERY surviving diff anchored
                // to it. Promote the oldest such dependent to a full snapshot,
                // then RE-BASE the remaining dependents onto it — each re-based
                // diff's patch is recomputed against the new full's content (NOT
                // merely re-pointed: a patch built against the victim's content
                // does not apply to a different version's content).
                promoteAndRebaseDependents(of: victim, in: recs)
            }

            try? fm.removeItem(at: victim.url)
            recs = records(in: dir)                          // re-read after mutation
        }
    }

    /// Promote the oldest diff anchored on `victim` to a full snapshot, then
    /// re-base every other diff anchored on `victim` onto that new full
    /// (recomputing each patch against the new full's reconstructed content) so
    /// the chain survives `victim`'s deletion intact. Best-effort: a dependent
    /// that can't be reconstructed/rewritten is left as-is (it would already be
    /// unreadable), never crashes.
    private func promoteAndRebaseDependents(of victim: Record, in recs: [Record]) {
        let dependents = recs
            .filter { $0.header.kind == .diff && $0.header.anchor == victim.id }
            .sorted { $0.millis < $1.millis }
        guard let promotee = dependents.first,
              let promoteeContent = reconstruct(promotee, allRecords: recs) else { return }

        // Materialise the oldest dependent as a new FULL snapshot in place.
        let fullHeader = Header.full(size: promotee.header.size, hash: promotee.header.hash)
        guard writeRecord(header: fullHeader, payload: promoteeContent, to: promotee.url) else { return }

        // Re-base each remaining dependent: recompute its patch against the
        // newly-materialised full's content (it now anchors on `promotee`).
        // SIZE-GUARD (TSK-1103): only re-diff when both sides are under
        // `maxDiffInputBytes`; otherwise re-base the dependent as its OWN full
        // snapshot (still anchor-free, never orphaned) — so the differ never
        // runs on large inputs even on the prune/re-anchor path.
        let promoteeFitsDiff = promotee.header.size <= diffInputCap
        for dep in dependents.dropFirst() {
            guard let depContent = reconstruct(dep, allRecords: recs) else { continue }
            if promoteeFitsDiff, dep.header.size <= diffInputCap {
                let newPatch = LineDiff.Patch.between(promoteeContent, depContent).serialized()
                let newHeader = Header.diff(size: dep.header.size, hash: dep.header.hash, anchor: promotee.id)
                _ = writeRecord(header: newHeader, payload: newPatch, to: dep.url)
            } else {
                let newHeader = Header.full(size: dep.header.size, hash: dep.header.hash)
                _ = writeRecord(header: newHeader, payload: depContent, to: dep.url)
            }
        }
    }

    // MARK: - Private — ids, dirs, hashing

    /// Allocate a free `<millis>` (or `<millis>_N`) id for `date` in `dir`.
    private func freshID(for date: Date, in dir: URL) -> String {
        let fm = FileManager.default
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        var id = String(millis)
        var bump = 0
        while fm.fileExists(atPath: dir.appendingPathComponent("\(id).rev").path) {
            bump += 1
            id = "\(millis)_\(bump)"
        }
        return id
    }

    /// Locate the per-path revision dir. Internal so tests can plant a
    /// mismatched `_path` sidecar (a real FNV-1a-64 collision is infeasible
    /// to construct).
    func fileDirectory(for path: String) -> URL {
        directory.appendingPathComponent(Self.pathKey(path))
    }

    /// True if `dir`'s `_path` sidecar is absent (legacy — can't disprove) or
    /// equals `path`. A PRESENT-but-different sidecar means an FNV hash
    /// collision: another file's history lives here, so we must neither serve it
    /// nor pollute it (TSK-1027).
    private func dirBelongsTo(_ path: String, dir: URL) -> Bool {
        let sidecar = dir.appendingPathComponent("_path")
        guard let data = try? Data(contentsOf: sidecar),
              let stored = String(data: data, encoding: .utf8) else {
            return true
        }
        return stored == path
    }

    /// Parse the numeric millis prefix from a record id (`"1700000000000"`
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
