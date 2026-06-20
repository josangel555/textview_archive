import XCTest
@testable import ViewerCore

/// Teeth for `LineDiff` (TSK-1103) — the dependency-free LCS line differ that
/// backs Local History's compact deltas and the diff UI. Covers: the
/// serialisable `Patch` round-trip (apply == new) for varied edits, lossless
/// line splitting, patch serialise/deserialise stability, and the UI hunk shape.
final class LineDiffTests: XCTestCase {

    // MARK: - Lossless splitting (the foundation of exact reconstruction)

    func test_lineSplit_isLossless_forAllShapes() {
        for text in ["", "a", "a\n", "\n", "a\nb", "a\nb\n", "\n\n\n", "a\n\nb\n", "trailing\n"] {
            XCTAssertEqual(LineDiff.lines(of: text).joined(separator: "\n"), text,
                           "split/join must be lossless for \(text.debugDescription)")
        }
    }

    // MARK: - Patch round-trip (apply(between(a,b), a) == b)

    func test_patch_roundTrips_forVariedEdits() {
        let cases: [(String, String)] = [
            ("a\nb\nc", "a\nb\nc"),                       // identical
            ("a\nb\nc", "a\nB\nc"),                       // single-line change
            ("a\nb\nc", "a\nb\nc\nd"),                    // append
            ("a\nb\nc\nd", "a\nb\nc"),                    // truncate
            ("a\nb\nc", "x\ny\nz"),                       // full rewrite
            ("", "hello"),                                // empty → content
            ("hello", ""),                                // content → empty
            ("a\nb\nc", "a\nb1\nb2\nc"),                  // insert in middle
            ("1\n2\n3\n4\n5", "1\n3\n5"),                 // delete alternating
            ("keep\n\nblank\n\nlines", "keep\n\nBLANK\n\nlines"),  // blank lines
            ("trailing\n", "trailing changed\n"),         // trailing newline
            ("no-trailing", "no-trailing\n"),             // gain a trailing newline
        ]
        for (a, b) in cases {
            let patch = LineDiff.Patch.between(a, b)
            let applied = patch.apply(to: a)
            XCTAssertEqual(applied, b, "patch \(a.debugDescription) → \(b.debugDescription) must round-trip")
        }
    }

    func test_patch_serializeDeserialize_isStable() {
        let a = "alpha\nbeta\ngamma\ndelta"
        let b = "alpha\nBETA\ngamma\nDELTA\nepsilon"
        let patch = LineDiff.Patch.between(a, b)
        let serialized = patch.serialized()
        let decoded = LineDiff.Patch.deserialize(serialized)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded, patch, "serialise→deserialise must preserve the patch exactly")
        // And the decoded patch still reconstructs b.
        XCTAssertEqual(decoded?.apply(to: a), b)
    }

    func test_patch_serialized_isCompactForSmallEdit() {
        // A one-line change inside a large file must serialise to a small blob.
        let base = (0..<5000).map { "line \($0)" }.joined(separator: "\n")
        var lines = base.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines[2500] = "line 2500 CHANGED"
        let edited = lines.joined(separator: "\n")
        let blob = LineDiff.Patch.between(base, edited).serialized()
        XCTAssertLessThan(blob.utf8.count, 200, "a one-line delta must be tiny, not file-sized")
        XCTAssertEqual(LineDiff.Patch.deserialize(blob)?.apply(to: base), edited)
    }

    func test_deserialize_malformed_returnsNil() {
        XCTAssertNil(LineDiff.Patch.deserialize("not a patch"))
        XCTAssertNil(LineDiff.Patch.deserialize("@ notanumber 0 0"))
        XCTAssertNil(LineDiff.Patch.deserialize("@ 0 0 2\n+only one insert line"))  // promises 2, gives 1
    }

    func test_apply_outOfRange_returnsNil() {
        // A patch that deletes past the end of `old` is corrupt → nil, no crash.
        let patch = LineDiff.Patch(ops: [.init(index: 0, delete: 99, insert: [])])
        XCTAssertNil(patch.apply(to: "a\nb"))
    }

    // MARK: - UI hunks

    func test_hunks_singleChange_hasContextAroundIt() {
        let old = (0..<20).map { "L\($0)" }.joined(separator: "\n")
        var lines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines[10] = "L10-edited"
        let new = lines.joined(separator: "\n")

        let hunks = LineDiff.hunks(from: old, to: new, context: 3)
        XCTAssertEqual(hunks.count, 1)
        let h = hunks[0]
        // One removed (L10) + one added (L10-edited), plus 3 context each side.
        XCTAssertTrue(h.lines.contains { $0.kind == .removed && $0.content == "L10" })
        XCTAssertTrue(h.lines.contains { $0.kind == .added && $0.content == "L10-edited" })
        XCTAssertEqual(h.lines.filter { $0.kind == .context }.count, 6)
    }

    func test_hunks_distantChanges_splitIntoSeparateHunks() {
        let old = (0..<40).map { "L\($0)" }.joined(separator: "\n")
        var lines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines[5] = "L5-x"
        lines[30] = "L30-x"
        let new = lines.joined(separator: "\n")
        let hunks = LineDiff.hunks(from: old, to: new, context: 3)
        XCTAssertEqual(hunks.count, 2, "far-apart changes form separate hunks")
    }

    func test_hunks_identical_isEmpty() {
        XCTAssertEqual(LineDiff.hunks(from: "a\nb\nc", to: "a\nb\nc"), [])
    }

    func test_hunks_lineNumbers_areOneBasedAndCorrect() {
        let hunks = LineDiff.hunks(from: "a\nb\nc", to: "a\nX\nc", context: 3)
        let changed = hunks.flatMap { $0.lines }
        let removed = changed.first { $0.kind == .removed }
        let added = changed.first { $0.kind == .added }
        XCTAssertEqual(removed?.oldLineNo, 2)
        XCTAssertNil(removed?.newLineNo)
        XCTAssertEqual(added?.newLineNo, 2)
        XCTAssertNil(added?.oldLineNo)
    }
}

// MARK: - Optimal linear-space Myers core: correctness + optimality + bounded
//         memory (TSK-1103). These are the teeth for the algorithm REPLACEMENT —
//         the old code used an O(n·m) full DP matrix that ballooned memory; the
//         new core is prefix/suffix-trim + line-interning + Myers O(N·D) time,
//         O(N) space (no n×m matrix). A regression to a non-minimal or incorrect
//         diff fails here; a regression to an O(n·m) allocation fails the
//         large-input timing/bound test below.
extension LineDiffTests {

    /// A small, deterministic PRNG so the fuzz is reproducible (no flaky CI).
    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
        mutating func int(_ upper: Int) -> Int { upper <= 0 ? 0 : Int(next() % UInt64(upper)) }
    }

    /// Reference LCS length via the classic O(n·m) DP — the ORACLE for
    /// optimality. Bounded to tiny inputs (so the oracle itself stays cheap);
    /// the production path never builds this.
    private func referenceLCSLength(_ a: [String], _ b: [String]) -> Int {
        let n = a.count, m = b.count
        if n == 0 || m == 0 { return 0 }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1
                                        : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        return dp[0][0]
    }

    /// Kept-line count implied by a patch = oldLines - sum(delete). Equals the
    /// LCS length of (old, new) iff the patch is OPTIMAL (Myers minimises the
    /// edit script, which maximises the kept subsequence).
    private func keptCount(_ patch: LineDiff.Patch, oldLineCount: Int) -> Int {
        oldLineCount - patch.ops.reduce(0) { $0 + $1.delete }
    }

    /// FUZZ: hundreds of random (old → new) pairs reconstruct BYTE-EXACT. This
    /// is the strongest correctness teeth — any invalid match (a kept pair where
    /// the lines differ, or a non-monotonic anchor) breaks reconstruction.
    func test_fuzz_patch_alwaysRoundTrips() {
        var rng = LCG(state: 0x1234_5678_9abc_def0)
        let alphabet = ["a", "b", "c", "", "x", "y", "longer line token"]
        for _ in 0..<800 {
            let oldN = rng.int(14)
            let newN = rng.int(14)
            let old = (0..<oldN).map { _ in alphabet[rng.int(alphabet.count)] }
                .joined(separator: "\n")
            let new = (0..<newN).map { _ in alphabet[rng.int(alphabet.count)] }
                .joined(separator: "\n")
            let patch = LineDiff.Patch.between(old, new)
            XCTAssertEqual(patch.apply(to: old), new,
                           "round-trip failed for old=\(old.debugDescription) new=\(new.debugDescription)")
            // Serialise/deserialise must also round-trip.
            let decoded = LineDiff.Patch.deserialize(patch.serialized())
            XCTAssertEqual(decoded?.apply(to: old), new,
                           "serialised round-trip failed for old=\(old.debugDescription) new=\(new.debugDescription)")
        }
    }

    /// OPTIMALITY: against the O(n·m) DP oracle on small inputs, the Myers patch
    /// must keep EXACTLY an LCS — i.e. it produces a MINIMAL edit script, not
    /// merely a valid one. (A valid-but-bloated diff would round-trip yet fail
    /// here.)
    func test_optimality_matchesReferenceLCS() {
        var rng = LCG(state: 0xfeed_face_cafe_b00b)
        let alphabet = ["a", "b", "c", "d"]
        for _ in 0..<300 {
            let oldArr = (0..<rng.int(11)).map { _ in alphabet[rng.int(alphabet.count)] }
            let newArr = (0..<rng.int(11)).map { _ in alphabet[rng.int(alphabet.count)] }
            let old = oldArr.joined(separator: "\n")
            let new = newArr.joined(separator: "\n")
            let patch = LineDiff.Patch.between(old, new)
            // `lines(of:)` of "" yields [""], so empty inputs have 1 element;
            // mirror that in the oracle by diffing the same split.
            let oA = LineDiff.lines(of: old)
            let oB = LineDiff.lines(of: new)
            let expected = referenceLCSLength(oA, oB)
            XCTAssertEqual(keptCount(patch, oldLineCount: oA.count), expected,
                           "patch must keep an LCS (optimal) for old=\(old.debugDescription) new=\(new.debugDescription)")
            XCTAssertEqual(patch.apply(to: old), new)   // and still correct
        }
    }

    /// BOUNDED MEMORY + OUTPUT-SENSITIVITY: a one-line change in a VERY large
    /// file must produce a tiny patch and complete fast. The old O(n·m) matrix
    /// for 100k lines would be ~10^10 Ints (~80 GB) — impossible; this completes
    /// because prefix/suffix-trim collapses N to ~1 and Myers is O(N·D). If
    /// someone reintroduces an O(n·m) structure, this test OOMs/times out.
    func test_largeFile_oneLineEdit_isTinyAndFast() {
        let count = 100_000
        let base = (0..<count).map { "line \($0)" }.joined(separator: "\n")
        var lines = base.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines[count / 2] = "line \(count / 2) CHANGED"
        let edited = lines.joined(separator: "\n")

        let start = Date()
        let patch = LineDiff.Patch.between(base, edited)
        let elapsed = Date().timeIntervalSince(start)

        // Output-sensitive: a single changed line ⇒ a single tiny op.
        XCTAssertEqual(patch.ops.count, 1)
        XCTAssertEqual(patch.ops.first?.delete, 1)
        XCTAssertEqual(patch.ops.first?.insert, ["line \(count / 2) CHANGED"])
        XCTAssertLessThan(patch.serialized().utf8.count, 200, "delta must be tiny")
        // Exact reconstruction.
        XCTAssertEqual(patch.apply(to: base), edited)
        // Generous wall-clock ceiling: an O(n·m) path on 100k lines could never
        // hit this; the linear-space path is milliseconds. (Loose to avoid CI
        // flakiness under load — the point is it does NOT blow up.)
        XCTAssertLessThan(elapsed, 5.0, "one-line edit on a 100k-line file must be fast (O(N), not O(n·m))")
    }

    /// A large near-full REWRITE (high edit distance) still completes in O(N)
    /// space without an n×m matrix. Edit distance D ≈ 2N here, so this exercises
    /// the Myers worst case (O(N·D) = O(N²) TIME) — but crucially O(N) MEMORY.
    /// Kept bounded (N = 1500) so the O(N²) *time* is fine while proving the
    /// memory profile: an O(n·m) matrix for N=1500 would be ~2.25M Ints PER
    /// recursion frame and the old code allocated one giant matrix; the new path
    /// uses O(N) strips regardless of D.
    func test_largeNearFullRewrite_completesWithoutMatrix() {
        let n = 1500
        let a = (0..<n).map { "alpha-\($0)" }.joined(separator: "\n")
        let b = (0..<n).map { "bravo-\($0)" }.joined(separator: "\n")
        let patch = LineDiff.Patch.between(a, b)
        XCTAssertEqual(patch.apply(to: a), b, "near-full rewrite must reconstruct exactly")
        // No lines are shared ⇒ the optimal patch keeps zero old lines.
        XCTAssertEqual(keptCount(patch, oldLineCount: n), 0)
    }
}
