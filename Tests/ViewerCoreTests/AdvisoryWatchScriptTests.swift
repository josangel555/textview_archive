import XCTest

/// TSK-628: hermetic pins for `scripts/swiftpm-advisory-watch.sh` — the
/// matcher's HONESTY properties, kept gate-runnable via the
/// `MDV_ADVISORY_FIXTURE` seam (canned advisories, zero network).
///
/// History this guards: the original matcher fed pins via a herestring
/// ALONGSIDE its heredoc — the herestring won, python executed the PIN LIST
/// as a script, and the empty result read as PASSED. A watch that cannot
/// match must fail, and a real match must fail loudly; both are pinned here.
final class AdvisoryWatchScriptTests: XCTestCase {

    private var scriptURL: URL {
        // Tests run from the package directory; resolve relative to #filePath
        // so the suite works regardless of cwd.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ViewerCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("scripts/swiftpm-advisory-watch.sh")
    }

    private func tempFile(_ contents: String, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("advisory-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Run the script with a pins file + advisory fixture; return (exit, output).
    private func run(resolved: URL, fixture: URL) throws -> (code: Int32, out: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        env["MDV_PACKAGE_RESOLVED"] = resolved.path
        env["MDV_ADVISORY_FIXTURE"] = fixture.path
        env["MDV_ADVISORY_STRICT"] = "1"
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private let resolvedJSON = """
    { "version": 2, "pins": [
        { "identity": "tree-sitter-swift",
          "location": "https://github.com/alex-pinkus/tree-sitter-swift",
          "state": { "revision": "abc123" } },
        { "identity": "swift-markdown",
          "location": "https://github.com/apple/swift-markdown.git",
          "state": { "revision": "def456" } }
    ] }
    """

    func test_cleanFixture_passes_andMatcherActuallyRan() throws {
        let resolved = try tempFile(resolvedJSON, name: "Package.resolved")
        let fixture = try tempFile("""
        [ { "ghsa_id": "GHSA-xxxx-yyyy-zzzz", "summary": "unrelated package",
            "vulnerabilities": [ { "package": { "name": "github.com/vapor/vapor" } } ] } ]
        """, name: "advisories.json")
        let r = try run(resolved: resolved, fixture: fixture)
        XCTAssertEqual(r.code, 0, r.out)
        // The honesty tell: the matcher's scan line MUST be present — its
        // absence is exactly the herestring false green this test guards.
        XCTAssertTrue(r.out.contains("1 advisories scanned"),
                      "matcher did not run: \(r.out)")
        XCTAssertTrue(r.out.contains("PASSED (2 pins)"), r.out)
    }

    func test_matchingAdvisory_hits_andFails() throws {
        let resolved = try tempFile(resolvedJSON, name: "Package.resolved")
        let fixture = try tempFile("""
        [ { "ghsa_id": "GHSA-test-0001", "summary": "grammar parser overflow",
            "vulnerabilities": [ { "package": { "name": "github.com/alex-pinkus/tree-sitter-swift" } } ] } ]
        """, name: "advisories.json")
        let r = try run(resolved: resolved, fixture: fixture)
        XCTAssertEqual(r.code, 1, "a pinned-package advisory must FAIL the watch: \(r.out)")
        XCTAssertTrue(r.out.contains("HIT GHSA-test-0001"), r.out)
        XCTAssertTrue(r.out.contains("tree-sitter-swift"), r.out)
    }

    func test_gitSuffixAndCaseDrift_stillMatch() throws {
        // The .git-suffixed pin and a case-drifted advisory name must match
        // (the matcher normalizes both sides).
        let resolved = try tempFile(resolvedJSON, name: "Package.resolved")
        let fixture = try tempFile("""
        [ { "ghsa_id": "GHSA-test-0002", "summary": "markdown parse",
            "vulnerabilities": [ { "package": { "name": "github.com/Apple/Swift-Markdown" } } ] } ]
        """, name: "advisories.json")
        let r = try run(resolved: resolved, fixture: fixture)
        XCTAssertEqual(r.code, 1, r.out)
        XCTAssertTrue(r.out.contains("HIT GHSA-test-0002"), r.out)
    }

    func test_emptyFixture_passes() throws {
        let resolved = try tempFile(resolvedJSON, name: "Package.resolved")
        let fixture = try tempFile("[]", name: "advisories.json")
        let r = try run(resolved: resolved, fixture: fixture)
        XCTAssertEqual(r.code, 0, r.out)
        XCTAssertTrue(r.out.contains("0 advisories scanned"), r.out)
    }
}
