import XCTest

/// TSK-162 — the VM lane's JUnit converter (scripts/junit-convert.py),
/// pinned on the host.
///
/// The audited gap: the original converter parsed only passed|failed
/// lines, so XCTSkip self-skips were silently DROPPED from the artifact
/// and a case that crashed its worker (SIGABRT — no terminating line at
/// all) left the XML falsely green. The fixed contracts: skips become
/// `<skipped/>`, and a parsed-vs-"Executed N tests" count mismatch emits
/// a synthetic FAILING testcase so the artifact reads RED.
final class JUnitConverterTests: XCTestCase {

    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts/junit-convert.py")

    private func convert(_ fixture: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("junitconv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("out.txt")
        let output = dir.appendingPathComponent("out.xml")
        try fixture.write(to: input, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [Self.script.path, input.path, output.path]
        let err = Pipe()
        p.standardOutput = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0,
            String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        return try String(contentsOf: output, encoding: .utf8)
    }

    /// Skipped cases must appear as `<skipped/>` — not vanish (the
    /// heavy-tier / WebView-gate self-skips are the lane's honesty signal).
    func test_skippedCases_representedNotDropped() throws {
        let xml = try convert("""
            Test Case '-[ViewerUITests.SomeSuite test_a]' passed (0.100 seconds).
            Test Case '-[ViewerUITests.SomeSuite test_b]' skipped (0.001 seconds).
            Test Case '-[ViewerUITests.SomeSuite test_c]' failed (0.200 seconds).
            Executed 3 tests, with 1 failure (0 unexpected) in 0.301 (0.301) seconds
            """)
        XCTAssertTrue(xml.contains("<skipped/>"),
                      "skipped case dropped from the artifact: \(xml)")
        XCTAssertTrue(xml.contains(#"tests="3" failures="1" skipped="1""#),
                      "suite attributes must count all three outcomes: \(xml)")
        XCTAssertTrue(xml.contains(#"name="test_b""#))
        XCTAssertTrue(xml.contains("<failure type=\"failure\""))
    }

    /// A crashed worker emits no terminating line — the converter must
    /// cross-check against "Executed N tests" and emit a synthetic RED
    /// testcase instead of a silently green artifact.
    func test_crashedCase_turnsArtifactRed() throws {
        let xml = try convert("""
            Test Case '-[ViewerUITests.CrashSuite test_ok]' passed (0.100 seconds).
            Test Case '-[ViewerUITests.CrashSuite test_alsoOk]' passed (0.100 seconds).
            Executed 5 tests, with 0 failures (0 unexpected) in 1.000 (1.000) seconds
            """)
        XCTAssertTrue(xml.contains(#"name="JUnitConverter""#),
                      "missing synthetic count-mismatch suite: \(xml)")
        XCTAssertTrue(xml.contains("count-mismatch"),
                      "crash must surface as a count-mismatch failure: \(xml)")
        XCTAssertTrue(xml.contains("3 crashed/missing"),
                      "expected 5-2=3 missing cases named in the message: \(xml)")
    }

    /// Control: when every executed case has a terminating line, NO
    /// synthetic suite appears (the guard can't cry wolf).
    func test_matchingCounts_noSyntheticFailure() throws {
        let xml = try convert("""
            Test Case '-[ViewerCoreTests.CleanSuite test_one]' passed (0.010 seconds).
            Test Case '-[ViewerCoreTests.CleanSuite test_two]' passed (0.020 seconds).
            Executed 2 tests, with 0 failures (0 unexpected) in 0.030 (0.030) seconds
            """)
        XCTAssertFalse(xml.contains("JUnitConverter"),
                       "synthetic failure on a clean run: \(xml)")
        XCTAssertFalse(xml.contains("<failure"))
        XCTAssertTrue(xml.contains(#"tests="2" failures="0" skipped="0""#))
    }
}
