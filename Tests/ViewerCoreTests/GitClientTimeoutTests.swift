import XCTest
@testable import ViewerCore

/// Host-safe tests for the wall-clock timeout threaded through
/// `GitClient.init(statusTimeout:)` → `run` → `ProcessRunner.run(timeout:)`.
///
/// To force a deterministic timeout we install a `clean` filter that
/// `sleep`s for far longer than the test's `statusTimeout`. `git status`
/// runs the clean filter to decide whether a tracked file is modified,
/// so a tiny timeout SIGTERMs git mid-filter — surfacing `timedOut`
/// without depending on a giant repo or flaky timing.
///
/// All scratch lives under `FileManager.temporaryDirectory`; never
/// `~/Documents`.
final class GitClientTimeoutTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("/usr/bin/git not available")
        }
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-git-timeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try git(["init", "-q"])
        _ = try git(["config", "user.email", "t@e.com"])
        _ = try git(["config", "user.name", "T"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = tmp
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// Commit a file, then install a sleeping `clean` filter assigned to
    /// it, then modify it — so the next `git status` invokes the slow
    /// filter.
    private func installSleepingCleanFilter() throws {
        let file = tmp.appendingPathComponent("slow.txt")
        // Commit with the molasses filter ALREADY assigned, then modify
        // the worktree copy to the SAME byte length. git status detects
        // mtime changed but size unchanged → it must run the `clean`
        // filter to recompute the blob hash and decide modification,
        // which is where the 30s sleep traps it.
        try "slow.txt filter=molasses\n".write(
            to: tmp.appendingPathComponent(".gitattributes"),
            atomically: true, encoding: .utf8
        )
        // `cat` is an identity clean filter for the initial commit so the
        // blob is stored verbatim; we swap to `sleep` afterwards.
        _ = try git(["config", "filter.molasses.clean", "cat"])
        try "aaaa\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try git(["add", ".gitattributes", "slow.txt"])
        _ = try git(["commit", "-q", "-m", "init"])
        // Now the slow filter, and a same-length worktree edit so git
        // can't short-circuit on size and is forced to run the filter.
        _ = try git(["config", "filter.molasses.clean", "sleep 30"])
        try "bbbb\n".write(to: file, atomically: true, encoding: .utf8)
        // Force a different mtime so the stat cache is invalidated.
        let future = Date().addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: file.path)
    }

    func test_statusEntriesResult_surfacesTimedOut() throws {
        try installSleepingCleanFilter()
        let client = GitClient(repoRoot: tmp, statusTimeout: 0.5)
        let start = Date()
        let result = client.statusEntriesResult()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(result.timedOut, "the sleeping clean filter must trip the wall-clock timeout")
        XCTAssertLessThan(elapsed, 10, "watchdog should fire well under the 30s sleep")
    }

    func test_statusEntriesResult_noTimeout_onFastRepo() throws {
        // Plain modified file, generous timeout → completes, timedOut false.
        let file = tmp.appendingPathComponent("a.txt")
        try "v1\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try git(["add", "a.txt"])
        _ = try git(["commit", "-q", "-m", "init"])
        try "v2\n".write(to: file, atomically: true, encoding: .utf8)

        let client = GitClient(repoRoot: tmp, statusTimeout: 10)
        let result = client.statusEntriesResult()
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.entries.contains { $0.path == "a.txt" && $0.status == .modified })
    }

    func test_headInfoResult_noTimeout_onFastRepo() throws {
        let file = tmp.appendingPathComponent("a.txt")
        try "x\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try git(["add", "a.txt"])
        _ = try git(["commit", "-q", "-m", "init"])

        let client = GitClient(repoRoot: tmp, statusTimeout: 10)
        let result = client.headInfoResult()
        XCTAssertFalse(result.timedOut)
        XCTAssertNotNil(result.head, "HEAD info present on a committed repo")
    }

    func test_defaultNilTimeout_preservesBehavior() throws {
        // No statusTimeout → no wall-clock cap; status still works.
        let file = tmp.appendingPathComponent("a.txt")
        try "x\n".write(to: file, atomically: true, encoding: .utf8)
        let client = GitClient(repoRoot: tmp)  // statusTimeout defaults nil
        let entries = client.statusEntries()
        XCTAssertTrue(entries.contains { $0.path == "a.txt" && $0.status == .untracked })
        let result = client.statusEntriesResult()
        XCTAssertFalse(result.timedOut, "no timeout configured → never reports timedOut")
    }
}
