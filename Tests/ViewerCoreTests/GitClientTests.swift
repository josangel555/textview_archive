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
