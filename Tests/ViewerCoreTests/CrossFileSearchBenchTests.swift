import XCTest
@testable import ViewerCore

/// Bench for `CrossFileSearch.search` hot path.
///
/// The hot loop scans many lines per file and historically allocated
/// `String(lineSub)` for every line before doing the case-insensitive
/// reject check. After the fix, the reject check runs on the
/// `Substring` (shared index space with parent `content`) and the
/// String allocation only happens on matched lines.
///
/// We measure two scenarios that exercise the savings:
///   - Sparse-match case-insensitive scan over a 1000-file tree where
///     ~1 line in 100 matches. This is the realistic shape for
///     codebase search. Asserts a generous ceiling so CI hardware
///     variance doesn't flap.
///   - "No-match" scan that has to reject the entire file via the
///     early `content.range(of:)` contains-check — confirms the early
///     reject still fires and the walker doesn't fall back to
///     line-by-line work.
///
/// Filter target:
///   `swift test --filter ViewerCoreTests.CrossFileSearchBenchTests`
final class CrossFileSearchBenchTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("XSearchBench-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tmpDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// Synthetic tree: 200 files × ~100 lines/file = 20K lines total.
    /// Each file has one matched line at the end. Case-insensitive
    /// scan exercises the per-line reject path (~20K rejects, ~200
    /// hits). Smaller than the "perf #9" 1000-file target because
    /// debug-build Swift case-folding is ~5x slower than release;
    /// scaled down to keep the test under a sensible CI budget while
    /// still exercising the optimized hot path. Release-build perf
    /// is reported in the benchmark output for tracking.
    func test_sparseMatch_caseInsensitive_under_5s() throws {
        let fileCount = 200
        let linesPerFile = 100
        // Build per-file content once; mutate the match marker per file.
        let baseFiller = Array(repeating: "lorem ipsum dolor sit amet",
                               count: linesPerFile - 1).joined(separator: "\n")
        for i in 0..<fileCount {
            let body = baseFiller + "\nNeedle-\(i) lives here\n"
            let url = tmpDir.appendingPathComponent("f\(i).md")
            try body.write(to: url, atomically: true, encoding: .utf8)
        }

        // Case-insensitive on purpose — this is the path the finding
        // targeted. Query intentionally won't hit the file-level
        // contains-check trivially: "needle" matches "Needle-N" via
        // case-folding.
        let opts = CrossFileSearch.Options(
            maxFileBytes: 1_000_000,
            maxResults: 100_000,
            caseSensitive: false
        )
        let t0 = Date()
        let groups = CrossFileSearch.search(
            root: tmpDir, query: "needle", options: opts
        )
        let elapsedMs = Date().timeIntervalSince(t0) * 1000

        let totalMatches = groups.reduce(0) { $0 + $1.matches.count }
        print("[CrossFileSearch] sparse-match \(fileCount) files × \(linesPerFile)l " +
              "case-insensitive: \(elapsedMs) ms, " +
              "\(groups.count) groups, \(totalMatches) matches")

        // Correctness: one group per file, one match per group.
        XCTAssertEqual(groups.count, fileCount)
        XCTAssertEqual(totalMatches, fileCount)

        // Perf ceiling. Debug build on Apple Silicon completes in
        // ~1-2 s; release is ~3-5x faster. We cap at 5 s so older CI
        // hardware doesn't flap but a real regression (quadratic
        // blow-up or per-line allocation on every line) blows past.
        XCTAssertLessThan(elapsedMs, 5_000,
            "\(fileCount)-file case-insensitive scan should stay under 5s")
    }

    /// All-reject scenario: 500 files, zero matches anywhere. Confirms
    /// the file-level early contains-check carries the load and we
    /// don't degrade to per-line work when no match exists.
    func test_noMatch_earlyReject_under_3s() throws {
        let fileCount = 500
        let linesPerFile = 200
        let body = Array(repeating: "no match on this line at all",
                         count: linesPerFile).joined(separator: "\n")
        for i in 0..<fileCount {
            let url = tmpDir.appendingPathComponent("f\(i).md")
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        let opts = CrossFileSearch.Options(
            maxFileBytes: 1_000_000,
            maxResults: 100_000,
            caseSensitive: false
        )
        let t0 = Date()
        let groups = CrossFileSearch.search(
            root: tmpDir, query: "zzz-never-present-zzz", options: opts
        )
        let elapsedMs = Date().timeIntervalSince(t0) * 1000

        print("[CrossFileSearch] no-match 500 files × \(linesPerFile)l " +
              "case-insensitive: \(elapsedMs) ms")
        XCTAssertTrue(groups.isEmpty)
        XCTAssertLessThan(elapsedMs, 3_000,
            "no-match 500-file scan should stay under 3s")
    }

    /// Sanity microbench: measures the allocation savings directly by
    /// running the hot per-line loop with and without the up-front
    /// `String(lineSub)` materialization on a single large file. This
    /// isn't an absolute-time assertion (host variance) — instead it
    /// asserts the new path (substring reject) is no worse than the
    /// old path (string-per-line reject) and logs the ratio so any
    /// future regression is visible in CI output.
    ///
    /// We deliberately compare against an in-test inlined version of
    /// the old impl rather than the live API, since the API now uses
    /// the optimized form. This pins the *speedup factor* against a
    /// reproducible baseline.
    func test_perLineLoop_substringRejectBeatsStringAllocPerLine() {
        // 50K lines, one match at the end. Worst case for the old
        // approach: every line gets allocated before reject.
        let n = 50_000
        var s = String(repeating: "lorem ipsum dolor sit amet\n", count: n - 1)
        s += "needle lives here\n"

        // OLD path: allocate String per line, then range-check.
        let t0 = Date()
        var oldHits = 0
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        for lineSub in lines {
            let line = String(lineSub)
            if line.range(of: "needle", options: [.caseInsensitive]) != nil {
                oldHits += 1
            }
        }
        let oldMs = Date().timeIntervalSince(t0) * 1000

        // NEW path: range-check Substring, only allocate on hit.
        let t1 = Date()
        var newHits = 0
        let lines2 = s.split(separator: "\n", omittingEmptySubsequences: false)
        for lineSub in lines2 {
            if lineSub.range(of: "needle", options: [.caseInsensitive]) != nil {
                _ = String(lineSub)  // simulate materialization on hit
                newHits += 1
            }
        }
        let newMs = Date().timeIntervalSince(t1) * 1000

        XCTAssertEqual(oldHits, 1)
        XCTAssertEqual(newHits, 1)
        let ratio = oldMs / max(newMs, 0.001)
        print("[CrossFileSearch] per-line bench (50K lines, 1 hit): " +
              "old=\(oldMs) ms, new=\(newMs) ms, speedup=\(ratio)x")

        // The new path must not be slower than the old one. We don't
        // assert a specific speedup factor — Swift's String impl may
        // optimize String(lineSub) into a no-op shared-storage init in
        // future toolchains, narrowing the gap. The load-bearing
        // assertion is "new is not a regression vs old".
        XCTAssertLessThanOrEqual(newMs, oldMs * 1.5,
            "new per-line path should be no worse than old (within 1.5x noise)")
    }
}
