import XCTest

/// TSK-795 — the coverage gate's threshold + target-attribution logic
/// (scripts/coverage_gate.py), pinned on the host.
///
/// The gate is the build's only enforcement of test coverage. The part that
/// can silently rot is the pure logic: the `Sources/<Target>/` attribution
/// regex (a renamed target stops matching → its files vanish from the gate),
/// the percent math (an off-by-one reads a 0%-covered file green), and the
/// exit-code contract the .sh relies on (0 pass / 2 threshold-miss / 3 no
/// data). These tests run the real script against synthetic `llvm-cov export`
/// JSON so a logic regression fails the HOST gate, not just an eyeballed CI
/// log. Mirrors JUnitConverterTests (the same shell-out-to-build-tool pattern).
final class CoverageGateTests: XCTestCase {

    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ViewerCoreTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("scripts/coverage_gate.py")

    private struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Run coverage_gate.py with `json` on stdin + the given args. Returns the
    /// exit status and captured streams (so a test can assert on BOTH the
    /// contract code and the human-readable output).
    @discardableResult
    private func run(_ json: String, _ args: [String]) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [Self.script.path] + args   // input defaults to '-' (stdin)
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        inPipe.fileHandleForWriting.write(Data(json.utf8))
        try inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      stdout: String(decoding: out, as: UTF8.self),
                      stderr: String(decoding: err, as: UTF8.self))
    }

    /// A small report: ViewerCore 80/100, a NESTED ViewerCore file 10/50
    /// (must fold into the same target → 90/150 = 60%), ViewerUI 40/40 = 100%,
    /// and an out-of-tree dependency (not under Sources/) that is NOT
    /// per-target gated but IS counted in the overall total.
    private let report = """
        {"data":[{"files":[
          {"filename":"/repo/Sources/ViewerCore/A.swift","summary":{"lines":{"count":100,"covered":80}}},
          {"filename":"/repo/Sources/ViewerCore/Highlight/B.swift","summary":{"lines":{"count":50,"covered":10}}},
          {"filename":"/repo/Sources/ViewerUI/C.swift","summary":{"lines":{"count":40,"covered":40}}},
          {"filename":"/repo/.build/checkouts/dep/D.swift","summary":{"lines":{"count":1000,"covered":0}}}
        ]}]}
        """

    /// Default (no thresholds) is REPORT-ONLY: it measures + prints but always
    /// exits 0, so the gate can be wired into the build without turning a merge
    /// red on day one. Nested source files must fold into the top target.
    func test_reportOnly_exitsZero_andFoldsNestedPaths() throws {
        let r = try run(report, [])
        XCTAssertEqual(r.status, 0, "report-only must exit 0. stderr=\(r.stderr)")
        // ViewerCore = (80+10)/(100+50) = 60.00% — nested Highlight/B folded in.
        XCTAssertTrue(r.stdout.contains("ViewerCore"))
        XCTAssertTrue(r.stdout.contains("60.00%"),
                      "nested path must fold into ViewerCore (90/150=60%): \(r.stdout)")
        XCTAssertTrue(r.stdout.contains("100.00%"), "ViewerUI 40/40: \(r.stdout)")
    }

    /// The overall TOTAL counts the out-of-tree dependency (130/1190 = 10.92%)
    /// even though that file is excluded from PER-TARGET gating.
    func test_total_countsAllFiles_includingNonTargetPaths() throws {
        let r = try run(report, [])
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.stdout.contains("TOTAL"))
        XCTAssertTrue(r.stdout.contains("10.92%"),
                      "total must include the .build dep file (130/1190): \(r.stdout)")
    }

    /// A per-target threshold miss must exit 2 (the .sh's fail contract) and
    /// name the offending target with actual<required.
    func test_perTargetThresholdMiss_exitsTwo() throws {
        let r = try run(report, ["--min-target", "70",
                                 "--include-target", "ViewerCore",
                                 "--include-target", "ViewerUI"])
        XCTAssertEqual(r.status, 2, "threshold miss must exit 2. stdout=\(r.stdout)")
        XCTAssertTrue(r.stdout.contains("COVERAGE GATE FAILED"))
        XCTAssertTrue(r.stdout.contains("ViewerCore: 60.00% < required 70%"),
                      "must name the failing target: \(r.stdout)")
        // ViewerUI is 100% — it must NOT appear as a failure.
        XCTAssertFalse(r.stdout.contains("ViewerUI: "),
                       "passing target must not be flagged: \(r.stdout)")
    }

    /// A passing per-target threshold exits 0. Control for the miss test above.
    func test_perTargetThresholdMet_exitsZero() throws {
        let r = try run(report, ["--min-target", "50",
                                 "--include-target", "ViewerCore"])
        XCTAssertEqual(r.status, 0, "60% >= 50% must pass. stdout=\(r.stdout)")
        XCTAssertFalse(r.stdout.contains("FAILED"))
    }

    /// `--target NAME=PCT` overrides the per-target default for one target.
    func test_perTargetOverride_appliesToNamedTargetOnly() throws {
        // Default min 90 (would fail ViewerCore@60); override ViewerCore=50 to
        // pass it. Only gate ViewerCore so ViewerUI's default doesn't interfere.
        let r = try run(report, ["--min-target", "90",
                                 "--target", "ViewerCore=50",
                                 "--include-target", "ViewerCore"])
        XCTAssertEqual(r.status, 0,
                       "override must lift ViewerCore's bar to 50. stdout=\(r.stdout)")
    }

    /// The overall (--min-total) gate is independent of the per-target gate.
    func test_minTotal_miss_exitsTwo() throws {
        let r = try run(report, ["--min-total", "50"])
        XCTAssertEqual(r.status, 2, "total 10.92% < 50% must fail. stdout=\(r.stdout)")
        XCTAssertTrue(r.stdout.contains("TOTAL: 10.92% < required 50%"),
                      "must name the TOTAL miss: \(r.stdout)")
    }

    /// Empty input → exit 3 (no coverage data), distinct from a threshold miss.
    func test_emptyInput_exitsThree() throws {
        let r = try run("", [])
        XCTAssertEqual(r.status, 3, "empty input must exit 3. stderr=\(r.stderr)")
    }

    /// Malformed JSON → exit 3, NOT a crash or a false-green 0.
    func test_malformedJSON_exitsThree() throws {
        let r = try run("not json at all", [])
        XCTAssertEqual(r.status, 3, "bad JSON must exit 3. stderr=\(r.stderr)")
        XCTAssertTrue(r.stderr.contains("not valid JSON"))
    }

    /// A well-formed report with zero files → exit 3 (empty coverage), so an
    /// empty/instrumentation-failed run can't read green.
    func test_noFiles_exitsThree() throws {
        let r = try run(#"{"data":[{"files":[]}]}"#, [])
        XCTAssertEqual(r.status, 3, "no files must exit 3. stderr=\(r.stderr)")
    }

    /// A target with zero instrumented lines is treated as 100% (vacuously
    /// covered) — it must not drag a threshold down or report NaN.
    func test_zeroLineTarget_isVacuouslyCovered() throws {
        let r = try run(#"""
            {"data":[{"files":[
              {"filename":"/repo/Sources/ViewerKit/Empty.swift","summary":{"lines":{"count":0,"covered":0}}}
            ]}]}
            """#, ["--min-target", "100", "--include-target", "ViewerKit"])
        XCTAssertEqual(r.status, 0, "0-line target must be vacuously 100%. stdout=\(r.stdout)")
        XCTAssertTrue(r.stdout.contains("100.00%"))
    }
}
