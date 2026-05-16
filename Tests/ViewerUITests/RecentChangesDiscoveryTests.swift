import XCTest
@testable import ViewerCore
@testable import ViewerUI

/// Regression coverage for the "Git is not showing anything" fix
/// (commit d175548): the CHANGED sidebar section used to refresh only
/// when `sidebar.rootURL` changed, leaving the section dark when the
/// user opened a file inside a repo without opening the folder.
///
/// `discoverRepo` is the pure helper that encodes the fallback rule.
/// Test it directly with a temp git repo so the wiring stays honest.
final class RecentChangesDiscoveryTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("/usr/bin/git not available")
        }
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RecentChangesDiscoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try git(["init", "-q"])
        _ = try git(["config", "user.email", "t@example.com"])
        _ = try git(["config", "user.name", "t"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func sameRepo(_ a: URL?, _ b: URL?) -> Bool {
        a?.standardizedFileURL.resolvingSymlinksInPath().path
            == b?.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: -

    /// Sidebar root is the repo → returns the repo.
    func test_uses_sidebarRoot_when_set() {
        let repo = RecentChangesSection.discoverRepo(
            sidebarRoot: tmp, currentURL: nil
        )
        XCTAssertTrue(sameRepo(repo, tmp))
    }

    /// Sidebar root is set but is outside any repo → nil.
    func test_returns_nil_when_sidebarRoot_outside_repo() {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentChanges-outside-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let repo = RecentChangesSection.discoverRepo(
            sidebarRoot: outside, currentURL: nil
        )
        XCTAssertNil(repo)
    }

    /// Sidebar root nil but currentURL is inside a repo → falls back
    /// to the file's parent. This is the bug fix we're regression-
    /// testing.
    func test_falls_back_to_currentURL_parent_when_sidebarRoot_nil() throws {
        let file = tmp.appendingPathComponent("sub/a.md")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let repo = RecentChangesSection.discoverRepo(
            sidebarRoot: nil, currentURL: file
        )
        XCTAssertTrue(sameRepo(repo, tmp),
                      "expected discovery from currentURL.parent when sidebarRoot=nil")
    }

    /// Both nil → nil. Edge case but documents the contract.
    func test_returns_nil_when_both_signals_missing() {
        let repo = RecentChangesSection.discoverRepo(
            sidebarRoot: nil, currentURL: nil
        )
        XCTAssertNil(repo)
    }

    /// SidebarRoot wins when both are set, even if currentURL points
    /// to a different repo. Documented "current folder" precedence.
    func test_sidebarRoot_wins_when_both_set() throws {
        // Make a second repo so currentURL is in a different one.
        let otherRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentChanges-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: otherRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: otherRepo) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = otherRepo
        p.arguments = ["init", "-q"]
        try p.run(); p.waitUntilExit()

        let otherFile = otherRepo.appendingPathComponent("a.md")
        try "x".write(to: otherFile, atomically: true, encoding: .utf8)

        let repo = RecentChangesSection.discoverRepo(
            sidebarRoot: tmp,
            currentURL: otherFile
        )
        XCTAssertTrue(sameRepo(repo, tmp),
                      "sidebarRoot must take precedence over currentURL")
    }

    // MARK: -

    private func git(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = tmp
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(),
                      encoding: .utf8) ?? ""
    }
}
