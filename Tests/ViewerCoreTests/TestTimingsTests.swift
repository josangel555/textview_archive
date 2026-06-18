import XCTest

/// TSK-836 — the per-class swift-test timing aggregator (scripts/test-timings.py),
/// pinned on the host (same Process-invocation pattern as JUnitConverterTests).
///
/// The aggregator is the measure-first half of the build/test-speed work: it
/// sums `(N seconds)` per CLASS and prints a slowest-first table so TSK-849/850
/// know which classes to split / de-sleep. These tests guard the contract that
/// matters: correct per-class sums, slowest-first ordering, all outcomes
/// counted, and `top_n` limiting ROWS without distorting the TOTAL.
final class TestTimingsTests: XCTestCase {

    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts/test-timings.py")

    /// Run test-timings.py on `fixture`, returning its stdout report.
    private func report(_ fixture: String, topN: Int? = nil) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("testtimings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("out.txt")
        try fixture.write(to: input, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [Self.script.path, input.path] + (topN.map { [String($0)] } ?? [])
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0,
            String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        return String(decoding: data, as: UTF8.self)
    }

    private func index(of needle: String, in haystack: String) -> String.Index? {
        haystack.range(of: needle)?.lowerBound
    }

    /// Classes sort slowest-first by summed wall-clock, and each class's total
    /// is the sum of its cases.
    func test_sumsPerClass_andSortsSlowestFirst() throws {
        let out = try report("""
            Test Case '-[ViewerCoreTests.SlowSuite test_a]' passed (0.900 seconds).
            Test Case '-[ViewerCoreTests.FastSuite test_x]' passed (0.100 seconds).
            Test Case '-[ViewerCoreTests.SlowSuite test_b]' passed (0.600 seconds).
            Executed 3 tests, with 0 failures (0 unexpected) in 1.600 (1.600) seconds
            """)
        // SlowSuite = 0.900 + 0.600 = 1.500 (2 cases); FastSuite = 0.100 (1 case).
        XCTAssertTrue(out.contains("1.500"), "SlowSuite total wrong: \(out)")
        guard let slow = index(of: "SlowSuite", in: out),
              let fast = index(of: "FastSuite", in: out) else {
            return XCTFail("both classes must appear: \(out)")
        }
        XCTAssertLessThan(slow, fast, "slowest class must be listed first: \(out)")
        XCTAssertTrue(out.contains("TOTAL (2 classes)"), "grand total miscount: \(out)")
        XCTAssertTrue(out.contains("1.600"), "grand total seconds wrong: \(out)")
    }

    /// failed and skipped cases still carry `(N seconds)` and must be counted
    /// (the slow class might be slow *because* of a failing/skipped case).
    func test_countsAllOutcomes() throws {
        let out = try report("""
            Test Case '-[ViewerCoreTests.MultiSuite test_1]' passed (0.100 seconds).
            Test Case '-[ViewerCoreTests.MultiSuite test_2]' failed (0.200 seconds).
            Test Case '-[ViewerCoreTests.MultiSuite test_3]' skipped (0.050 seconds).
            Executed 3 tests, with 1 failure (0 unexpected) in 0.350 (0.350) seconds
            """)
        XCTAssertTrue(out.contains("0.350"), "must sum passed+failed+skipped: \(out)")
        XCTAssertTrue(out.contains("TOTAL (1 classes)"), "single class expected: \(out)")
    }

    /// `top_n` limits how many class ROWS print, but the TOTAL still reflects
    /// every class (a truncated view must not silently under-report).
    func test_topN_limitsRowsNotTotal() throws {
        let out = try report("""
            Test Case '-[ViewerCoreTests.SlowSuite test_a]' passed (0.900 seconds).
            Test Case '-[ViewerCoreTests.FastSuite test_x]' passed (0.100 seconds).
            Test Case '-[ViewerCoreTests.SlowSuite test_b]' passed (0.600 seconds).
            Executed 3 tests, with 0 failures (0 unexpected) in 1.600 (1.600) seconds
            """, topN: 1)
        XCTAssertTrue(out.contains("SlowSuite"), "slowest class must show: \(out)")
        XCTAssertFalse(out.contains("FastSuite"), "top_n=1 must hide the 2nd class row: \(out)")
        XCTAssertTrue(out.contains("TOTAL (2 classes)"), "TOTAL must still count all classes: \(out)")
    }
}
