import XCTest
@testable import ViewerCore

/// Teeth for `LocalHistoryStore` (TSK-301, reworked TSK-1103) — adaptive
/// snapshot/diff file-version storage. End-to-end against a temp dir (the store
/// does real IO, like ReviewStore): snapshot/list/restore round-trip, the
/// adaptive full-vs-diff choice + exact reconstruction, the 20 MB/file byte cap
/// (with anchor promotion), text-only + secret exclusion, the default-ON gate,
/// dedup, per-file isolation, clear, the diff API, and the stable path-hash.
/// Time is injected (`at:`) so ordering/pruning are deterministic.
final class LocalHistoryStoreTests: XCTestCase {

    private var dir: URL!
    private var store: LocalHistoryStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-localhist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = LocalHistoryStore(directory: dir)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let path = "/Users/me/notes.md"
    private func date(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }

    /// On-disk byte total for a path's history dir (sum of `.rev` records).
    private func onDiskBytes(for p: String) -> Int {
        let d = store.fileDirectory(for: p)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: d, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.filter { $0.pathExtension == "rev" }.reduce(0) {
            $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    // MARK: - Round-trip

    func test_snapshotThenListAndRestore_roundTrip() {
        let v1 = store.snapshot(path: path, content: "alpha", at: date(1_700_000_000))
        XCTAssertNotNil(v1)
        XCTAssertEqual(v1?.byteSize, 5)

        let versions = store.versions(for: path)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(store.contentString(of: versions[0], for: path), "alpha")
        XCTAssertEqual(versions[0].savedAt, date(1_700_000_000))
    }

    func test_versions_areNewestFirst() {
        store.snapshot(path: path, content: "v1\nbody", at: date(1_700_000_000))
        store.snapshot(path: path, content: "v2\nbody", at: date(1_700_000_100))
        store.snapshot(path: path, content: "v3\nbody", at: date(1_700_000_200))
        let versions = store.versions(for: path)
        XCTAssertEqual(versions.count, 3)
        XCTAssertEqual(store.contentString(of: versions[0], for: path), "v3\nbody")
        XCTAssertEqual(store.contentString(of: versions[2], for: path), "v1\nbody")
        XCTAssertGreaterThan(versions[0].savedAt, versions[1].savedAt)
    }

    // MARK: - Adaptive full-vs-diff + reconstruction (owner policy)

    func test_smallEdit_storedAsDiff_andReconstructsExactly() {
        // A large base, then a one-line change. The delta must be MUCH smaller
        // on disk than a second full snapshot, AND reconstruct exactly.
        let base = (0..<2000).map { "line \($0)" }.joined(separator: "\n")
        var edited = base.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        edited[1000] = "line 1000 EDITED"
        let editedStr = edited.joined(separator: "\n")

        let v1 = store.snapshot(path: path, content: base, at: date(1_700_000_000))
        let bytesAfterBase = onDiskBytes(for: path)
        let v2 = store.snapshot(path: path, content: editedStr, at: date(1_700_000_100))
        let bytesAfterEdit = onDiskBytes(for: path)
        XCTAssertNotNil(v1); XCTAssertNotNil(v2)

        // The second version's record must be far smaller than the base record
        // (i.e. it was stored as a diff, not a 2nd full snapshot).
        let secondRecordBytes = bytesAfterEdit - bytesAfterBase
        XCTAssertLessThan(secondRecordBytes, bytesAfterBase / 4,
                          "a one-line edit must store a compact diff, not a full snapshot")

        // Both versions reconstruct EXACTLY.
        let vs = store.versions(for: path)            // newest first
        XCTAssertEqual(store.contentString(of: vs[0], for: path), editedStr)
        XCTAssertEqual(store.contentString(of: vs[1], for: path), base)
    }

    func test_nearFullRewrite_storedAsFull_andReconstructsExactly() {
        // A base, then a TOTAL rewrite sharing no lines. A diff would be ~as big
        // as (bigger than) the full, so the store must keep a full snapshot.
        let base = (0..<800).map { "alpha \($0)" }.joined(separator: "\n")
        let rewrite = (0..<800).map { "bravo \($0)" }.joined(separator: "\n")

        store.snapshot(path: path, content: base, at: date(1_700_000_000))
        let v2 = store.snapshot(path: path, content: rewrite, at: date(1_700_000_100))
        XCTAssertNotNil(v2)

        // Inspect the newest record's header: it must be a FULL snapshot.
        let recs = loadRecords()
        let newest = recs.max { $0.millis < $1.millis }!
        XCTAssertEqual(newest.header.kind, .full,
                       "a near-full rewrite must be stored as a full snapshot, not a giant diff")

        // Reconstructs exactly.
        let vs = store.versions(for: path)
        XCTAssertEqual(store.contentString(of: vs[0], for: path), rewrite)
        XCTAssertEqual(store.contentString(of: vs[1], for: path), base)
    }

    func test_reconstruct_acrossManyDiffVersions_isExact() {
        // Many incremental edits → many diffs against one anchor. EVERY version
        // round-trips to its exact original.
        var expected: [String: String] = [:]
        var content = (0..<500).map { "row \($0)" }.joined(separator: "\n")
        var t: TimeInterval = 1_700_000_000
        var lastVersionId: String?
        for edit in 0..<30 {
            var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            lines[edit * 10] = "row \(edit * 10) -- rev \(edit)"
            content = lines.joined(separator: "\n")
            let v = store.snapshot(path: path, content: content, at: date(t))
            t += 100
            XCTAssertNotNil(v)
            expected[v!.id] = content
            lastVersionId = v!.id
        }
        XCTAssertNotNil(lastVersionId)
        for v in store.versions(for: path) {
            XCTAssertEqual(store.contentString(of: v, for: path), expected[v.id],
                           "version \(v.id) must reconstruct exactly")
        }
    }

    func test_reconstruct_preservesTrailingNewline() {
        // Lossless line split: trailing-newline content must round-trip.
        let withNL = "a\nb\nc\n"
        let v = store.snapshot(path: path, content: withNL, at: date(1_700_000_000))
        XCTAssertNotNil(v)
        XCTAssertEqual(store.contentString(of: v!, for: path), withNL)
        // Then an edit (stored as a diff) also preserves the trailing newline.
        let edited = "a\nB\nc\n"
        let v2 = store.snapshot(path: path, content: edited, at: date(1_700_000_100))
        XCTAssertEqual(store.contentString(of: v2!, for: path), edited)
    }

    // MARK: - 20 MB/file byte cap

    func test_byteCap_prunesOldest_keepsNewest_underCap() {
        // Use a tiny store so the test is fast: 200 KiB cap. Each version is a
        // distinct ~50 KiB near-rewrite (so each is a full snapshot), forcing
        // the cap to bite and prune oldest-first.
        let smallCapStore = LocalHistoryStore(directory: dir)   // same dir
        _ = smallCapStore
        // We can't change the static cap; instead write enough genuine data to
        // exceed the real 20 MiB cap would be huge. So drive the cap via the
        // helper that lets us assert pruning behaviour at the real cap with
        // big-but-bounded content: 12 versions × ~2 MiB unique each = ~24 MiB.
        let blockSize = 2 * 1024 * 1024 / 8     // ~2 MiB of 8-char lines
        var ids: [String] = []
        for i in 0..<14 {
            // Unique content each time (no dedup, near-rewrite → mostly full).
            let body = (0..<blockSize).map { String(format: "%07d%c", $0, Character(UnicodeScalar(65 + (i % 26))!).asciiValue!) }
                .joined(separator: "\n")
            if let v = store.snapshot(path: path, content: body, at: date(1_700_000_000 + TimeInterval(i))) {
                ids.append(v.id)
            }
        }
        XCTAssertGreaterThan(ids.count, 0)

        // Under the cap after all writes.
        XCTAssertLessThanOrEqual(onDiskBytes(for: path), LocalHistoryStore.maxFileHistoryBytes,
                                 "total history must be pruned under the per-file byte cap")
        // The NEWEST version is always retained and reconstructs.
        let vs = store.versions(for: path)
        XCTAssertFalse(vs.isEmpty)
        let newest = vs[0]
        XCTAssertEqual(newest.id, ids.last)
        XCTAssertNotNil(store.contentString(of: newest, for: path))
        // The OLDEST written id was pruned (cap forced it out).
        XCTAssertFalse(vs.map(\.id).contains(ids.first!), "oldest version pruned by the byte cap")
    }

    func test_byteCap_promotesAnchor_soSurvivingDiffsStillReconstruct() {
        // Build an anchor full + several diffs, then push enough new big fulls to
        // force the original anchor out. Surviving diffs that anchored on it must
        // still reconstruct (the store promotes a dependent diff to a full).
        let base = (0..<4000).map { "base line number \($0)" }.joined(separator: "\n")
        store.snapshot(path: path, content: base, at: date(1_700_000_000))   // anchor full
        var content = base
        var expected: [String: String] = [:]
        var t: TimeInterval = 1_700_000_100
        for e in 0..<5 {                                  // small edits → diffs
            var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            lines[e] = "base line number \(e) edited rev \(e)"
            content = lines.joined(separator: "\n")
            let v = store.snapshot(path: path, content: content, at: date(t)); t += 100
            expected[v!.id] = content
        }
        // Now flood with big unique fulls to evict the original anchor.
        let blockSize = 2 * 1024 * 1024 / 8
        for i in 0..<14 {
            let body = (0..<blockSize).map { String(format: "Z%07d%d", $0, i) }.joined(separator: "\n")
            store.snapshot(path: path, content: body, at: date(t)); t += 100
        }
        // Every SURVIVING version that we recorded an expectation for must still
        // reconstruct exactly (anchor promotion kept the chain intact).
        let surviving = store.versions(for: path)
        for v in surviving where expected[v.id] != nil {
            XCTAssertEqual(store.contentString(of: v, for: path), expected[v.id],
                           "a surviving diff must reconstruct after its anchor was pruned+promoted")
        }
        XCTAssertLessThanOrEqual(onDiskBytes(for: path), LocalHistoryStore.maxFileHistoryBytes)
    }

    // MARK: - Size-guard: large changes route to SNAPSHOT, never run a big diff
    //         (TSK-1103 memory-runaway fix). The old store always called
    //         LineDiff.between(anchor, content) — whose O(n·m) LCS matrix
    //         ballooned phys_footprint to ~77 GB on big inputs. These pin the
    //         product-layer guard that keeps the differ off large inputs.

    func test_sizeGuard_largeChange_isStoredAsSnapshot_notDiff() {
        // A base just under the diff-input cap, then a change with a large body
        // ABOVE the cap. The large version must be a FULL snapshot — the differ
        // is never invoked against it (so no big-matrix risk), yet it is still
        // captured and reconstructs exactly.
        let smallBase = (0..<100).map { "base line \($0)" }.joined(separator: "\n")
        let v1 = store.snapshot(path: path, content: smallBase, at: date(1_700_000_000))
        XCTAssertNotNil(v1)

        // ~1.2 MiB > maxDiffInputBytes (1 MiB) but < maxSnapshotBytes (20 MiB).
        let bigLineCount = (LocalHistoryStore.maxDiffInputBytes + 200 * 1024) / 16
        let bigBody = (0..<bigLineCount).map { String(format: "row %010d", $0) }
            .joined(separator: "\n")
        XCTAssertGreaterThan(bigBody.utf8.count, LocalHistoryStore.maxDiffInputBytes)
        XCTAssertLessThanOrEqual(bigBody.utf8.count, LocalHistoryStore.maxSnapshotBytes)

        let v2 = store.snapshot(path: path, content: bigBody, at: date(1_700_000_100))
        XCTAssertNotNil(v2)

        // The newest record (the big change) MUST be a full snapshot — the
        // size-guard skipped the diff path entirely.
        let recs = loadRecords()
        let newest = recs.max { $0.millis < $1.millis }!
        XCTAssertEqual(newest.header.kind, .full,
                       "a change over maxDiffInputBytes must be a snapshot, never a (potentially huge) diff")

        // And it reconstructs exactly (the snapshot is verbatim).
        let vs = store.versions(for: path)
        XCTAssertEqual(store.contentString(of: vs[0], for: path), bigBody)
        XCTAssertEqual(store.contentString(of: vs[1], for: path), smallBase)
    }

    func test_sizeGuard_changeAgainstLargeAnchor_isStoredAsSnapshot() {
        // When the ANCHOR itself is over the diff-input cap, even a small new
        // version must NOT diff against it (that diff would run the differ on a
        // huge anchor). It is stored as a full snapshot instead.
        // Each line is "L%010d" (11 chars) + '\n' = 12 bytes; size for ~1.2 MiB.
        let bigLineCount = (LocalHistoryStore.maxDiffInputBytes + 200 * 1024) / 12
        let bigBase = (0..<bigLineCount).map { String(format: "L%010d", $0) }
            .joined(separator: "\n")
        XCTAssertGreaterThan(bigBase.utf8.count, LocalHistoryStore.maxDiffInputBytes)
        XCTAssertNotNil(store.snapshot(path: path, content: bigBase, at: date(1_700_000_000)))

        // A tiny edit of the big base: would normally be a diff, but the anchor
        // is too big, so the guard forces a full snapshot.
        var edited = bigBase.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        edited[0] = "L0000000000 CHANGED"
        let editedStr = edited.joined(separator: "\n")
        let v2 = store.snapshot(path: path, content: editedStr, at: date(1_700_000_100))
        XCTAssertNotNil(v2)

        let recs = loadRecords()
        let newest = recs.max { $0.millis < $1.millis }!
        XCTAssertEqual(newest.header.kind, .full,
                       "a change against an over-cap anchor must be a snapshot, not a diff against the big anchor")
        XCTAssertEqual(store.contentString(of: store.versions(for: path)[0], for: path), editedStr)
    }

    func test_sizeGuard_moderateAllowedChange_stillUsesCompactDiff() {
        // A change UNDER the cap still takes the (now O(N)-memory) diff path and
        // stores a compact delta — proving the guard only diverts LARGE changes,
        // and that the linear-space differ handles a sizeable-but-allowed input
        // without a giant matrix (this completes in milliseconds; an O(n·m)
        // matrix for ~30k lines would be ~10^9 Ints).
        let lineCount = 30_000                          // ~ under 1 MiB at this width
        let base = (0..<lineCount).map { "ln \($0)" }.joined(separator: "\n")
        XCTAssertLessThanOrEqual(base.utf8.count, LocalHistoryStore.maxDiffInputBytes)
        XCTAssertNotNil(store.snapshot(path: path, content: base, at: date(1_700_000_000)))
        let bytesAfterBase = onDiskBytes(for: path)

        var edited = base.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        edited[lineCount / 2] = "ln \(lineCount / 2) EDITED"
        let editedStr = edited.joined(separator: "\n")

        let start = Date()
        let v2 = store.snapshot(path: path, content: editedStr, at: date(1_700_000_100))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNotNil(v2)

        // Stored as a compact diff (record far smaller than a 2nd full).
        let recs = loadRecords()
        let newest = recs.max { $0.millis < $1.millis }!
        XCTAssertEqual(newest.header.kind, .diff, "an under-cap one-line edit must be a compact diff")
        let secondRecordBytes = onDiskBytes(for: path) - bytesAfterBase
        XCTAssertLessThan(secondRecordBytes, bytesAfterBase / 10,
                          "the delta must be a small fraction of a full snapshot")
        // Exact reconstruction + bounded time (O(N), not O(n·m)).
        XCTAssertEqual(store.contentString(of: store.versions(for: path)[0], for: path), editedStr)
        XCTAssertLessThan(elapsed, 5.0, "diff of a ~30k-line under-cap change must be fast (linear-space)")
    }

    // MARK: - Text-only + secret exclusion

    func test_binaryContent_isNotStored() {
        let binary = "PNG\u{0}\u{0}\u{1}\u{2}garbage\u{0}data"
        XCTAssertNil(store.snapshot(path: path, content: binary, at: date(1_700_000_000)))
        XCTAssertTrue(store.versions(for: path).isEmpty)
    }

    func test_secretContent_isNotStoredVerbatim() {
        let secret = """
        # config
        AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIKK7MDENGbPxRfiCYEXAMPLEKEY
        normal line
        """
        XCTAssertNil(store.snapshot(path: path, content: secret, at: date(1_700_000_000)),
                     "secret-bearing content must be skipped")
        XCTAssertTrue(store.versions(for: path).isEmpty)
        // And the secret string must NOT appear anywhere on disk for this path.
        let d = store.fileDirectory(for: path)
        let onDisk = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
        for url in onDisk {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            XCTAssertFalse(text.contains("wJalrXUtnFEMIKK7MDENGbPxRfiCYEXAMPLEKEY"),
                           "a credential must never be persisted verbatim")
        }
    }

    func test_privateKeyBlock_isNotStored() {
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEpAIBAAKCAQEA1234567890abcdef
        -----END RSA PRIVATE KEY-----
        """
        XCTAssertNil(store.snapshot(path: path, content: pem, at: date(1_700_000_000)))
        XCTAssertTrue(store.versions(for: path).isEmpty)
    }

    func test_ordinaryProse_withTheWordPassword_isStored() {
        // Conservative-but-not-overzealous: prose mentioning "password" without
        // an actual secret value is NOT suppressed.
        let prose = "Please remember to change your password regularly.\nIt keeps you safe."
        XCTAssertNotNil(store.snapshot(path: path, content: prose, at: date(1_700_000_000)))
        XCTAssertEqual(store.versions(for: path).count, 1)
    }

    // MARK: - Default-on + toggle

    func test_default_isOn_capturesByDefault() {
        // Default init → enabled.
        XCTAssertNotNil(store.snapshot(path: path, content: "hello", at: date(1_700_000_000)))
        XCTAssertEqual(store.versions(for: path).count, 1)
    }

    func test_toggleOff_suppressesCapture() {
        let offStore = LocalHistoryStore(directory: dir, isEnabled: { false })
        XCTAssertNil(offStore.snapshot(path: path, content: "hello", at: date(1_700_000_000)))
        XCTAssertTrue(offStore.versions(for: path).isEmpty)
    }

    func test_toggle_isReadLive_perSnapshot() {
        // A flag that flips between snapshots is honoured per-call.
        final class Box: @unchecked Sendable { var on = true }
        let box = Box()
        let s = LocalHistoryStore(directory: dir, isEnabled: { box.on })
        XCTAssertNotNil(s.snapshot(path: path, content: "one", at: date(1_700_000_000)))
        box.on = false
        XCTAssertNil(s.snapshot(path: path, content: "two", at: date(1_700_000_100)))
        box.on = true
        XCTAssertNotNil(s.snapshot(path: path, content: "three", at: date(1_700_000_200)))
        XCTAssertEqual(s.versions(for: path).count, 2)     // "two" was suppressed
    }

    // MARK: - Dedup, isolation, clear, ids

    func test_dedup_identicalToLatest_isNoOp() {
        XCTAssertNotNil(store.snapshot(path: path, content: "same\nx", at: date(1_700_000_000)))
        XCTAssertNil(store.snapshot(path: path, content: "same\nx", at: date(1_700_000_050)))
        XCTAssertEqual(store.versions(for: path).count, 1)
        XCTAssertNotNil(store.snapshot(path: path, content: "diff\nx", at: date(1_700_000_100)))
        XCTAssertNotNil(store.snapshot(path: path, content: "same\nx", at: date(1_700_000_200)))
        XCTAssertEqual(store.versions(for: path).count, 3)
    }

    func test_oversizeContent_isSkipped() {
        let big = String(repeating: "x", count: LocalHistoryStore.maxSnapshotBytes + 1)
        XCTAssertNil(store.snapshot(path: path, content: big, at: date(1_700_000_000)))
        XCTAssertTrue(store.versions(for: path).isEmpty)
    }

    func test_emptyContent_isSkipped() {
        XCTAssertNil(store.snapshot(path: path, content: "", at: date(1_700_000_000)))
        XCTAssertTrue(store.versions(for: path).isEmpty)
    }

    func test_perFileIsolation() {
        let other = "/Users/me/other.md"
        store.snapshot(path: path, content: "mine", at: date(1_700_000_000))
        store.snapshot(path: other, content: "theirs", at: date(1_700_000_000))
        XCTAssertEqual(store.versions(for: path).count, 1)
        XCTAssertEqual(store.versions(for: other).count, 1)
        XCTAssertEqual(store.contentString(of: store.versions(for: path)[0], for: path), "mine")
        XCTAssertEqual(store.contentString(of: store.versions(for: other)[0], for: other), "theirs")
    }

    func test_clear_dropsHistory() {
        store.snapshot(path: path, content: "a", at: date(1_700_000_000))
        store.snapshot(path: path, content: "b", at: date(1_700_000_100))
        XCTAssertEqual(store.versions(for: path).count, 2)
        store.clear(for: path)
        XCTAssertTrue(store.versions(for: path).isEmpty)
    }

    func test_sameMillisecond_doesNotCollide() {
        XCTAssertNotNil(store.snapshot(path: path, content: "first", at: date(1_700_000_000)))
        XCTAssertNotNil(store.snapshot(path: path, content: "second", at: date(1_700_000_000)))
        XCTAssertEqual(store.versions(for: path).count, 2)
    }

    func test_versionsForUnknownPath_isEmpty() {
        XCTAssertTrue(store.versions(for: "/nope/missing.txt").isEmpty)
    }

    func test_pathKey_isStableAndPathSpecific() {
        XCTAssertEqual(LocalHistoryStore.pathKey(path), LocalHistoryStore.pathKey(path))
        XCTAssertNotEqual(LocalHistoryStore.pathKey("/a"), LocalHistoryStore.pathKey("/b"))
    }

    func test_collisionGuard_dirBelongingToAnotherPath_servesNoHistory() throws {
        let v = store.snapshot(path: path, content: "alpha", at: date(1_700_000_000))
        XCTAssertNotNil(v)
        XCTAssertEqual(store.versions(for: path).count, 1)

        let sidecar = store.fileDirectory(for: path).appendingPathComponent("_path")
        try Data("/some/other/file.md".utf8).write(to: sidecar)

        XCTAssertEqual(store.versions(for: path), [], "must not serve a colliding dir's history")
        XCTAssertNil(store.contentString(of: v!, for: path))
        XCTAssertNil(store.snapshot(path: path, content: "beta", at: date(1_700_000_200)))
    }

    // MARK: - Diff API (for the UI)

    func test_diff_betweenTwoVersions_reportsTheChangedLine() {
        let v1 = store.snapshot(path: path, content: "a\nb\nc", at: date(1_700_000_000))!
        let v2 = store.snapshot(path: path, content: "a\nB\nc", at: date(1_700_000_100))!
        let hunks = store.diff(from: v1, to: v2, for: path)
        XCTAssertNotNil(hunks)
        let kinds = hunks!.flatMap { $0.lines }.filter { $0.kind != .context }
        XCTAssertTrue(kinds.contains { $0.kind == .removed && $0.content == "b" })
        XCTAssertTrue(kinds.contains { $0.kind == .added && $0.content == "B" })
    }

    func test_diff_versionAgainstCurrent_text() {
        let v1 = store.snapshot(path: path, content: "x\ny\nz", at: date(1_700_000_000))!
        let hunks = store.diff(version: v1, againstCurrent: "x\ny\nz\nNEW", for: path)
        XCTAssertNotNil(hunks)
        let added = hunks!.flatMap { $0.lines }.filter { $0.kind == .added }
        XCTAssertEqual(added.map(\.content), ["NEW"])
    }

    func test_diff_identical_isEmpty() {
        let v1 = store.snapshot(path: path, content: "same\nlines", at: date(1_700_000_000))!
        XCTAssertEqual(store.diff(version: v1, againstCurrent: "same\nlines", for: path), [])
    }

    // MARK: - Helpers

    /// Internal helper: load the typed records for `path` (mirrors the store's
    /// own loader, used to assert header.kind in adaptive-choice tests).
    private struct LoadedRecord { let millis: Int64; let header: LocalHistoryStore.Header }
    private func loadRecords() -> [LoadedRecord] {
        let d = store.fileDirectory(for: path)
        let urls = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url -> LoadedRecord? in
            guard url.pathExtension == "rev" else { return nil }
            let id = url.deletingPathExtension().lastPathComponent
            guard let millis = Int64(id.split(separator: "_").first.map(String.init) ?? id),
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  let nl = text.firstIndex(of: "\n"),
                  let header = LocalHistoryStore.Header.parse(text[..<nl]) else { return nil }
            return LoadedRecord(millis: millis, header: header)
        }
    }
}
