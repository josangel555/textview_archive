import XCTest
@testable import ViewerCore

/// TSK-926/927 — CLI argv parsing (extracted from the AppDelegate so it's
/// host-testable). The `mdv` shim + `open -a` sit on top; this pins the
/// flag/path parsing the app launch relies on.
final class LaunchArgsTests: XCTestCase {

    func test_empty_isAllDefaults() {
        let a = LaunchArgs.parse([])
        XCTAssertEqual(a, LaunchArgs())
        XCTAssertFalse(a.diagnose)
        XCTAssertEqual(a.autoSnapshotDelay, -1)
        XCTAssertTrue(a.paths.isEmpty)
    }

    func test_singleFile_isAPath() {
        XCTAssertEqual(LaunchArgs.parse(["README.md"]).paths, ["README.md"])
    }

    func test_multipleFiles_allPaths_inOrder() {
        // CORR-10: every positional path opens, in order.
        XCTAssertEqual(
            LaunchArgs.parse(["a.md", "b.json", "c.csv"]).paths,
            ["a.md", "b.json", "c.csv"])
    }

    func test_folderPath_isAPath() {
        XCTAssertEqual(LaunchArgs.parse(["/Users/me/projects"]).paths,
                       ["/Users/me/projects"])
    }

    func test_diagnoseAndSource_flags() {
        let a = LaunchArgs.parse(["--diagnose", "--source", "f.txt"])
        XCTAssertTrue(a.diagnose)
        XCTAssertTrue(a.forceSource)
        XCTAssertEqual(a.paths, ["f.txt"], "flags must not be collected as paths")
    }

    func test_autoSnapshot_consumesValue_andNotAPath() {
        let a = LaunchArgs.parse(["--auto-snapshot", "2.5", "doc.md"])
        XCTAssertEqual(a.autoSnapshotDelay, 2.5)
        XCTAssertEqual(a.paths, ["doc.md"],
            "the snapshot delay value must not be mistaken for a path")
    }

    func test_autoSnapshot_missingOrBadValue_isIgnored() {
        XCTAssertEqual(LaunchArgs.parse(["--auto-snapshot"]).autoSnapshotDelay, -1)
        // A non-numeric next token is NOT consumed → it stays a path.
        let a = LaunchArgs.parse(["--auto-snapshot", "notanumber"])
        XCTAssertEqual(a.autoSnapshotDelay, -1)
        XCTAssertEqual(a.paths, ["notanumber"])
    }

    func test_script_and_walkthrough_consumeValues() {
        let a = LaunchArgs.parse(["--script", "/tmp/s.json", "--walkthrough", "/tmp/w.md", "x.md"])
        XCTAssertEqual(a.scriptPath, "/tmp/s.json")
        XCTAssertEqual(a.walkthroughPath, "/tmp/w.md")
        XCTAssertEqual(a.paths, ["x.md"])
    }

    func test_unknownDoubleDashFlags_areIgnored_notPaths() {
        // --mcp-stdio / --claude-monitor are handled at the top level; here they
        // must be dropped, not collected as files to open.
        let a = LaunchArgs.parse(["--mcp-stdio", "--claude-monitor", "real.md"])
        XCTAssertEqual(a.paths, ["real.md"])
    }
}
