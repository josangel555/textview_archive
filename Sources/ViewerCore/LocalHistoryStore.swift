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
/// - **20 MB cap PER FILE.** A file's total on-disk history is pruned
///   oldest-first until under `maxFileHistoryBytes`. The newest version is
///   always retained. Pruning a FULL snapshot that later diffs depend on first
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

    /// Per-file byte cap (owner policy TSK-1103): a file's total history is
    /// pruned oldest-first until its on-disk records sum under this.
    public static let maxFileHistoryBytes = 20 * 1024 * 1024  // 20 MiB

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

    public init(
        directory: URL = LocalHistoryStore.defaultDirectory(),
        isEnabled: @escaping @Sendable () -> Bool = { true }
    ) {
        self.directory = directory
        self.isEnabled = isEnabled
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
    public func snapshot(path: String, content: String, at date: Date) -> Version? {
        guard isEnabled() else { return nil }
        guard !content.isEmpty else { return nil }
        guard content.utf8.count <= Self.maxSnapshotBytes else { return nil }
        guard !HistoryContentFilter.isProbablyBinary(content) else { return nil }
        guard !HistoryContentFilter.looksLikeSecret(content) else { return nil }
        // Filename-based secret exclusion (TSK-1103 merge): the viewer's
        // LocalHistoryPolicy excludes by NAME (.env / *.pem / credentials…),
        // which catches secret files whose CONTENT alone wouldn't trip the
        // content filter. Unified here so EVERY save path is gated at the store.
        guard !LocalHistoryPolicy.isSecretLike(path: path) else { return nil }

        let dir = fileDirectory(for: path)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // TSK-1027: if this dir already belongs to a DIFFERENT path (FNV-1a-64
        // collision), don't pollute another file's history — bail.
        guard dirBelongsTo(path, dir: dir) else { return nil }

        let existing = records(in: dir)              // ascending by millis
        let contentHash = LineDiff.fnv1a(content)

        // Dedup: skip if the newest existing version already holds this content.
        if let newest = existing.last, newest.header.hash == contentHash,
           reconstruct(newest, allRecords: existing) == content {
            return nil
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
        if contentSize <= Self.maxDiffInputBytes,
           let anchor = existing.last(where: { $0.header.kind == .full }),
           anchor.header.size <= Self.maxDiffInputBytes,
           let anchorContent = reconstruct(anchor, allRecords: existing) {
            let diffPayload = LineDiff.Patch.between(anchorContent, content).serialized()
            let diffHeader = Header.diff(size: contentSize, hash: contentHash, anchor: anchor.id)
            if diffHeader.recordByteSize(payload: diffPayload) < fullRecordBytes {
                chosenHeader = diffHeader
                chosenPayload = diffPayload
            }
        }

        let url = dir.appendingPathComponent("\(id).rev")
        guard writeRecord(header: chosenHeader, payload: chosenPayload, to: url) else { return nil }

        // Record the original path once (best-effort; display + collision guard).
        let pathFile = dir.appendingPathComponent("_path")
        if !fm.fileExists(atPath: pathFile.path) {
            try? Data(path.utf8).write(to: pathFile, options: .atomic)
        }

        pruneUnderByteCap(in: dir)
        return Version(id: id, savedAt: date, byteSize: contentSize)
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
    private func pruneUnderByteCap(in dir: URL) {
        let fm = FileManager.default
        var recs = records(in: dir)                          // ascending
        func total() -> Int { recs.reduce(0) { $0 + $1.onDiskBytes } }

        while total() > Self.maxFileHistoryBytes, recs.count > 1 {
            let victim = recs[0]                             // oldest

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
        let promoteeFitsDiff = promotee.header.size <= Self.maxDiffInputBytes
        for dep in dependents.dropFirst() {
            guard let depContent = reconstruct(dep, allRecords: recs) else { continue }
            if promoteeFitsDiff, dep.header.size <= Self.maxDiffInputBytes {
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
