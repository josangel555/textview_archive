import XCTest
@testable import ViewerCore

/// Tests against a freshly created temp git repo. Skipped if
/// /usr/bin/git isn't available.
final class GitClientTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        // Skip cleanly if no git.
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("/usr/bin/git not available")
        }
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-git-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // git init + identity for clean commits
        _ = try git(["init", "-q"])
        _ = try git(["config", "user.email", "test@example.com"])
        _ = try git(["config", "user.name", "Test"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testDiscoverRootInsideRepo() {
        let nested = tmp.appendingPathComponent("a/b/c")
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let root = GitClient.discoverRoot(from: nested)
        // Path comparison via standardized — temp dirs go through /var/folders or /private/var/folders.
        // Compare paths, not URLs — URLs differ in trailing-slash even
        // after standardization.
        XCTAssertEqual(root?.standardizedFileURL.resolvingSymlinksInPath().path,
                       tmp.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    func testDiscoverRootOutsideRepo() {
        let outside = URL(fileURLWithPath: "/")
        XCTAssertNil(GitClient.discoverRoot(from: outside))
    }

    func testStatusReflectsNewFile() throws {
        try "hello".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let client = GitClient(repoRoot: tmp)
        let entries = client.status()
        XCTAssertTrue(entries.contains(where: { $0.path == "a.txt" && $0.isUntracked }))
    }

    func testStatusReflectsModifiedFile() throws {
        let f = tmp.appendingPathComponent("a.txt")
        try "v1".write(to: f, atomically: true, encoding: .utf8)
        _ = try git(["add", "a.txt"])
        _ = try git(["commit", "-q", "-m", "init"])
        try "v2".write(to: f, atomically: true, encoding: .utf8)
        let entries = GitClient(repoRoot: tmp).status()
        let mod = entries.first(where: { $0.path == "a.txt" })
        XCTAssertEqual(mod?.workingStatus, "M")
    }

    func testStatusEmptyOnCleanRepo() throws {
        let f = tmp.appendingPathComponent("a.txt")
        try "v1".write(to: f, atomically: true, encoding: .utf8)
        _ = try git(["add", "a.txt"])
        _ = try git(["commit", "-q", "-m", "init"])
        XCTAssertTrue(GitClient(repoRoot: tmp).status().isEmpty)
    }

    func testLogReturnsEntries() throws {
        try "x".write(to: tmp.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."])
        _ = try git(["commit", "-q", "-m", "first commit"])
        try "y".write(to: tmp.appendingPathComponent("y.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."])
        _ = try git(["commit", "-q", "-m", "second commit"])
        let log = GitClient(repoRoot: tmp).log()
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(log[0].subject, "second commit")
        XCTAssertEqual(log[1].subject, "first commit")
    }

    func testStatusEmptyOutsideRepo() {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-not-a-repo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        // GitClient.status() catches the error and returns [].
        XCTAssertTrue(GitClient(repoRoot: outside).status().isEmpty)
    }

    // MARK: - diff (Batch C, commit db57c6a)

    func test_diff_returns_unified_diff_for_modified_file() throws {
        // Stage a tracked file at HEAD, modify it, ask for diff.
        let file = tmp.appendingPathComponent("notes.md")
        try "v1\nline two\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try git(["add", "notes.md"])
        _ = try git(["commit", "-q", "-m", "init"])
        try "v1\nline two CHANGED\nline three\n".write(to: file, atomically: true, encoding: .utf8)

        let diff = GitClient(repoRoot: tmp).diff(forPath: "notes.md")
        XCTAssertTrue(diff.contains("--- a/notes.md"),
                      "expected unified-diff header, got:\n\(diff)")
        XCTAssertTrue(diff.contains("+++ b/notes.md"),
                      "expected unified-diff header (b), got:\n\(diff)")
        XCTAssertTrue(diff.contains("+line two CHANGED"),
                      "expected the new line in the patch, got:\n\(diff)")
        XCTAssertTrue(diff.contains("-line two"),
                      "expected the deleted line in the patch, got:\n\(diff)")
        XCTAssertFalse(diff.contains("\u{1B}["),
                       "diff should be color-stripped (--no-color); ANSI escapes leaked")
    }

    func test_diff_is_empty_for_unmodified_file() throws {
        let file = tmp.appendingPathComponent("clean.txt")
        try "static\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try git(["add", "clean.txt"])
        _ = try git(["commit", "-q", "-m", "init"])

        let diff = GitClient(repoRoot: tmp).diff(forPath: "clean.txt")
        XCTAssertTrue(diff.isEmpty || diff.allSatisfy(\.isWhitespace),
                      "expected empty diff for unmodified file, got:\n\(diff)")
    }

    func test_diff_returns_empty_when_path_missing() {
        // Path that doesn't exist in the tree → git returns nothing
        // (no warning since the file isn't tracked); we surface "".
        let diff = GitClient(repoRoot: tmp).diff(forPath: "no/such/file.md")
        XCTAssertEqual(diff, "")
    }

    func test_diff_handles_path_with_spaces() throws {
        let file = tmp.appendingPathComponent("a file.txt")
        try "before\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try git(["add", "a file.txt"])
        _ = try git(["commit", "-q", "-m", "init"])
        try "before\nafter\n".write(to: file, atomically: true, encoding: .utf8)
        let diff = GitClient(repoRoot: tmp).diff(forPath: "a file.txt")
        XCTAssertTrue(diff.contains("+after"),
                      "diff must work with spaces in path, got:\n\(diff)")
    }

    private func git(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = tmp
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
