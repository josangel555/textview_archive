import XCTest
@testable import ViewerCore

/// TSK-829: cross-file search parallelization — the cap/order parity guards
/// (gate-run, deterministic) + a manual measurement (env-gated, not in the
/// gate — it writes a large corpus and times wall-clock).
final class CrossFileSearchParallelTests: XCTestCase {

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-xfs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Cap behaviour must match serial EXACTLY: matches are taken in
    /// (walk-order, line-order) and the global `maxResults` stops mid-file. A
    /// single file with many matching lines pins the mid-file break without
    /// depending on cross-file enumeration order (which the FS, not us, sets).
    func testSingleFileStopsAtMaxResultsMidFile() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var s = ""
        for i in 0..<20 { s += "needle \(i)\n" }   // 20 matching lines
        try s.write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let r = CrossFileSearch.search(
            root: root, query: "needle",
            options: .init(maxResults: 5))
        let matches = r.flatMap { $0.matches }
        XCTAssertEqual(matches.count, 5, "global maxResults must stop mid-file")
        // First 5 lines, in line order.
        XCTAssertEqual(matches.map { $0.lineNumber }, [1, 2, 3, 4, 5])
    }

    /// Within a file, matches are returned in ascending line order.
    func testMatchesInLineOrder() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = "alpha\nneedle one\nbeta\nneedle two\ngamma\nneedle three\n"
        try s.write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let r = CrossFileSearch.search(root: root, query: "needle")
        let matches = r.flatMap { $0.matches }
        XCTAssertEqual(matches.map { $0.lineNumber }, [2, 4, 6])
        XCTAssertEqual(matches.map { $0.line }, ["needle one", "needle two", "needle three"])
    }

    /// All matching files are found (no file dropped by the parallel fold).
    func testAllMatchingFilesFound() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for f in 0..<50 {
            try "x\nneedle here\ny\n".write(
                to: root.appendingPathComponent("f\(f).txt"),
                atomically: true, encoding: .utf8)
        }
        // One non-matching file.
        try "nothing relevant\n".write(
            to: root.appendingPathComponent("z.txt"), atomically: true, encoding: .utf8)

        let r = CrossFileSearch.search(
            root: root, query: "needle",
            options: .init(maxResults: 10_000))
        XCTAssertEqual(r.count, 50, "every matching file must appear exactly once")
        XCTAssertEqual(r.flatMap { $0.matches }.count, 50)
    }

    /// Manual measurement (env-gated; NOT in the headless gate — it writes a
    /// large corpus and is wall-clock-flaky under load). Run:
    ///   MDV_RUN_BENCH=1 swift test --filter CrossFileSearchParallelTests/testMeasure
    func testMeasure() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MDV_RUN_BENCH"] == "1",
            "bench: set MDV_RUN_BENCH=1")
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = 3000, linesPerFile = 40
        for f in 0..<files {
            var s = ""
            for l in 0..<linesPerFile {
                s += (l % 6 == 0)
                    ? "needle token line \(f)-\(l)\n"
                    : "ordinary filler content line \(f)-\(l)\n"
            }
            try s.write(to: root.appendingPathComponent("f\(f).txt"),
                        atomically: true, encoding: .utf8)
        }
        let opts = CrossFileSearch.Options(maxResults: 1_000_000, maxEntriesScanned: 1_000_000)
        _ = CrossFileSearch.search(root: root, query: "needle", options: opts) // warm caches
        let t0 = Date()
        let r = CrossFileSearch.search(root: root, query: "needle", options: opts)
        let ms = Date().timeIntervalSince(t0) * 1000
        let total = r.reduce(0) { $0 + $1.matches.count }
        print("[XFS-bench] \(files) files × \(linesPerFile) lines: \(ms) ms, \(total) matches")
    }
}
