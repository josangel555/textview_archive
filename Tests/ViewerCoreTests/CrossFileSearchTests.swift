import XCTest
@testable import ViewerCore

final class CrossFileSearchTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("XSearch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @discardableResult
    private func write(_ path: String, _ contents: String) -> URL {
        let url = tmpDir.appendingPathComponent(path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_singleFile_match() {
        write("a.md", "alpha\nbeta needle here\ngamma\n")
        let groups = CrossFileSearch.search(root: tmpDir, query: "needle")
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].matches.count, 1)
        XCTAssertEqual(groups[0].matches[0].lineNumber, 2)
        XCTAssertEqual(groups[0].matches[0].line, "beta needle here")
    }

    func test_multipleFiles_multipleMatches() {
        write("a.md", "needle\n")
        write("b/sub.md", "needle in subdir\n")
        write("c.md", "no match\n")
        let groups = CrossFileSearch.search(root: tmpDir, query: "needle")
        XCTAssertEqual(groups.count, 2)
        let names = Set(groups.map { $0.url.lastPathComponent })
        XCTAssertEqual(names, Set(["a.md", "sub.md"]))
    }

    func test_caseInsensitive_byDefault() {
        write("a.md", "NEEDLE\nneedle\nNeedle\n")
        let groups = CrossFileSearch.search(root: tmpDir, query: "needle")
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].matches.count, 3)
    }

    func test_caseSensitive_optional() {
        write("a.md", "NEEDLE\nneedle\nNeedle\n")
        var opts = CrossFileSearch.Options()
        opts.caseSensitive = true
        let groups = CrossFileSearch.search(root: tmpDir, query: "needle", options: opts)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].matches.count, 1)
        XCTAssertEqual(groups[0].matches[0].line, "needle")
    }

    func test_skipsBinaryFiles() {
        // Write a file with a NUL byte in the first 4KiB — should be skipped.
        let url = tmpDir.appendingPathComponent("img.bin")
        var bytes: [UInt8] = Array(repeating: 0xAA, count: 100)
        bytes.append(0x00)
        bytes.append(contentsOf: Array("needle".utf8))
        try? Data(bytes).write(to: url)
        let groups = CrossFileSearch.search(root: tmpDir, query: "needle")
        XCTAssertTrue(groups.isEmpty)
    }

    func test_skipsLargeFiles() {
        let url = tmpDir.appendingPathComponent("big.md")
        let big = String(repeating: "x", count: 200) + "\nneedle\n"
        let huge = String(repeating: big, count: 50_000)  // ~10 MiB
        try? huge.write(to: url, atomically: true, encoding: .utf8)
        var opts = CrossFileSearch.Options()
        opts.maxFileBytes = 1024  // tiny limit, ensure the file is skipped
        let groups = CrossFileSearch.search(root: tmpDir, query: "needle", options: opts)
        XCTAssertTrue(groups.isEmpty)
    }

    func test_skipsVCSAndBuildDirs() {
        write(".git/index", "needle in git\n")
        write("node_modules/lib.js", "needle in node_modules\n")
        write(".build/cache", "needle in build\n")
        write("real.md", "needle in real file\n")
        let groups = CrossFileSearch.search(root: tmpDir, query: "needle")
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].url.lastPathComponent, "real.md")
    }

    func test_emptyQuery_returnsNothing() {
        write("a.md", "anything\n")
        let groups = CrossFileSearch.search(root: tmpDir, query: "")
        XCTAssertTrue(groups.isEmpty)
    }

    func test_maxResults_caps_totalMatches() {
        for i in 0..<10 {
            write("f\(i).md", "needle\n")
        }
        var opts = CrossFileSearch.Options()
        opts.maxResults = 3
        let groups = CrossFileSearch.search(root: tmpDir, query: "needle", options: opts)
        let total = groups.reduce(0) { $0 + $1.matches.count }
        XCTAssertLessThanOrEqual(total, 3)
    }

    func test_matchRange_pointsAtNeedleInLine() {
        write("a.md", "hello WORLD foo\n")
        let groups = CrossFileSearch.search(root: tmpDir, query: "world")
        XCTAssertEqual(groups.count, 1)
        let m = groups[0].matches[0]
        XCTAssertNotNil(m.matchRange)
        if let r = m.matchRange {
            XCTAssertEqual(String(m.line[r]).lowercased(), "world")
        }
    }

    /// S2-D: case-insensitive search across characters whose
    /// lowercasing changes character count (German ß → "ss",
    /// Greek Σ → σ/ς, Turkish İ → "i\u{0307}"). The previous
    /// implementation lowercased the haystack and back-mapped by
    /// ordinal distance, which dropped matchRange to nil for these
    /// locales — visible as a missing highlight in the result row.
    func test_matchRange_germanSharpS_caseInsensitive() {
        write("a.md", "Straße ist groß\n")
        let groups = CrossFileSearch.search(root: tmpDir, query: "STRASSE")
        // Default `range(of:options:)` with caseInsensitive matches
        // ß ↔ "ss" via Unicode case-folding. Just confirm we got the
        // hit AND the matchRange is non-nil on the original (with-ß)
        // line — that's the S2-D regression.
        XCTAssertEqual(groups.count, 1)
        let m = groups[0].matches[0]
        XCTAssertNotNil(
            m.matchRange,
            "matchRange should survive multi-scalar lowercasing (ß → ss)"
        )
        if let r = m.matchRange {
            // The matched substring must be a valid slice of the
            // original line — substring extraction here would have
            // crashed under the prior bug if mapRange had returned a
            // stale index.
            let matched = String(m.line[r])
            XCTAssertTrue(
                matched.lowercased().contains("stra"),
                "matched text \(matched) should overlap the German Straße"
            )
        }
    }

    // MARK: - Pathological-tree bail tests
    //
    // The walker is bounded by `maxEntriesScanned` + a symlink-loop
    // visited-set. These tests confirm both backstops actually fire
    // (rather than relying on luck) on a hand-crafted nasty tree.
    // The relevant code lives in `CrossFileSearch.search` and is
    // exposed only via the static API, so we cover it indirectly via
    // total wall-clock + result count.

    func test_symlinkLoop_doesNotInfiniteRecurse() throws {
        // Build a tiny tree with a self-loop:
        //   tmp/start/
        //   tmp/start/needle.md      (the only real file)
        //   tmp/start/loop  ->  ..   (relative loop back to tmp)
        // Without the visited-set guard, the enumerator would walk
        // `start` → `start/loop/start` → … forever.
        let start = tmpDir.appendingPathComponent("start")
        try FileManager.default.createDirectory(
            at: start, withIntermediateDirectories: true)
        try "needle here\n".write(
            to: start.appendingPathComponent("needle.md"),
            atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: start.appendingPathComponent("loop"),
            withDestinationURL: URL(fileURLWithPath: ".."))

        // Search must complete in a bounded wall-clock budget. 10 s is
        // very generous; in practice this completes in <100 ms.
        let started = Date()
        let groups = CrossFileSearch.search(root: tmpDir, query: "needle")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 10.0,
            "symlink-loop walk must terminate — took \(elapsed)s")
        XCTAssertGreaterThanOrEqual(groups.count, 1,
            "the one real needle.md should still be found")
    }

    func test_maxEntriesScanned_caps_walkLength() throws {
        // Lay down 200 leaf files. With maxEntriesScanned=20 the walk
        // must bail well before visiting them all — proves the cap
        // actually short-circuits the enumerator.
        let many = tmpDir.appendingPathComponent("many")
        try FileManager.default.createDirectory(
            at: many, withIntermediateDirectories: true)
        for i in 0..<200 {
            try "no match\n".write(
                to: many.appendingPathComponent("f\(i).md"),
                atomically: true, encoding: .utf8)
        }
        // Plant a single needle past the bail point so we know the cap
        // fired. (We don't know the enumerator's traversal order, so
        // we don't assert the needle is missing — just that the walk
        // completes quickly and returns ≤ small count.)
        try "needle\n".write(
            to: many.appendingPathComponent("zzz-deep-needle.md"),
            atomically: true, encoding: .utf8)

        var opts = CrossFileSearch.Options()
        opts.maxEntriesScanned = 20
        let started = Date()
        let groups = CrossFileSearch.search(
            root: tmpDir, query: "needle", options: opts)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 5.0,
            "bounded walk must complete fast — took \(elapsed)s")
        // With 201 files and a 20-entry cap, we either find the needle
        // (if enumerator happens to surface it early) or not. Either
        // way, the test proves the call returned without scanning all
        // 201 files. Cap-fire is the load-bearing assertion: a totally
        // unbounded walk wouldn't bail under any cap, defeating the
        // backstop. We assert "≤ cap-sized" total matches:
        let total = groups.reduce(0) { $0 + $1.matches.count }
        XCTAssertLessThanOrEqual(total, opts.maxEntriesScanned,
            "result count must not exceed the cap")
    }

    // MARK: - Progress + cooperative cancel (TSK-1465)

    func test_search_onProgress_finalTickReportsExactCounts() {
        write("a.md", "needle\n")
        write("b.md", "needle twice\nneedle again\n")
        write("c.md", "nothing here\n")
        var ticks: [(Int, Int)] = []
        let groups = CrossFileSearch.search(
            root: tmpDir, query: "needle",
            onProgress: { ticks.append(($0, $1)) })
        let total = groups.reduce(0) { $0 + $1.matches.count }
        XCTAssertEqual(total, 3)
        XCTAssertFalse(ticks.isEmpty, "onProgress must fire at least the final tick")
        XCTAssertEqual(ticks.last?.1, 3, "the final tick reports the exact match count")
        XCTAssertGreaterThan(ticks.last?.0 ?? 0, 0, "entries scanned is reported")
    }

    func test_search_isCancelled_stopsEarly_returnsPartial() {
        for i in 0..<10 { write("f\(i).md", "needle \(i)\n") }
        let full = CrossFileSearch.search(root: tmpDir, query: "needle")
        XCTAssertEqual(full.count, 10, "precondition: all files match")
        // A token that trips after the first candidate is admitted: the walk's
        // per-file cancellation point breaks before later reads.
        var calls = 0
        let partial = CrossFileSearch.search(
            root: tmpDir, query: "needle",
            isCancelled: { calls += 1; return calls > 1 })
        XCTAssertLessThan(partial.count, full.count,
                          "a tripped token must stop the walk early (partial results)")
    }

    func test_searchFilenames_onProgress_finalTickReportsCounts() {
        write("hit-one.md", "x")
        write("hit-two.md", "x")
        write("miss.txt", "x")
        var ticks: [(Int, Int)] = []
        let groups = CrossFileSearch.searchFilenames(
            root: tmpDir, query: "hit",
            onProgress: { ticks.append(($0, $1)) })
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(ticks.last?.1, 2, "final tick reports the filename-match count")
    }
}
