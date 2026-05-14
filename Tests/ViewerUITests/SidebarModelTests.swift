import XCTest
import ViewerCore
@testable import ViewerUI

@MainActor
final class SidebarModelTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @discardableResult
    private func touch(_ relativePath: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    private func mkdir(_ relativePath: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Cache contract — the regression test for the "side effect in body" bug

    func test_children_returnsEmptyBeforeEnsureLoaded() async throws {
        let model = SidebarModel()
        let dir = try mkdir("docs")
        try touch("docs/a.md")
        // Before any ensureLoaded call, the cache is cold and children() must
        // not do IO (SwiftUI body code calls this).
        XCTAssertEqual(model.children(of: dir), [])
    }

    func test_ensureLoaded_populatesCache() async throws {
        let model = SidebarModel()
        let dir = try mkdir("docs")
        try touch("docs/a.md")
        try touch("docs/b.md")
        model.ensureLoaded(url: dir)
        XCTAssertEqual(model.children(of: dir).map { $0.name }, ["a.md", "b.md"])
    }

    func test_setRoot_loadsRootChildrenSynchronously() async throws {
        let model = SidebarModel()
        try touch("a.md")
        try mkdir("sub")
        model.setRoot(tmpDir)
        XCTAssertEqual(model.rootURL?.resolvingSymlinksInPath(),
                       tmpDir.resolvingSymlinksInPath())
        XCTAssertTrue(model.isExpanded(model.rootURL!))
        let kids = model.children(of: model.rootURL!)
        XCTAssertEqual(kids.map { $0.name }, ["sub", "a.md"])
        XCTAssertTrue(model.isVisible)
    }

    func test_toggleExpansion_loadsChildrenOnExpand() async throws {
        let model = SidebarModel()
        let dir = try mkdir("docs")
        try touch("docs/a.md")
        XCTAssertEqual(model.children(of: dir), [])
        model.toggleExpansion(dir)
        XCTAssertTrue(model.isExpanded(dir))
        XCTAssertEqual(model.children(of: dir).count, 1)
    }

    func test_toggleExpansion_unloadKeepsCacheButDropsExpanded() async throws {
        let model = SidebarModel()
        let dir = try mkdir("docs")
        try touch("docs/a.md")
        model.toggleExpansion(dir)  // expand: loads
        model.toggleExpansion(dir)  // collapse
        XCTAssertFalse(model.isExpanded(dir))
        // Cache is still warm — children() should still return content for
        // a folder we've previously expanded (cheap).
        XCTAssertEqual(model.children(of: dir).count, 1)
    }

    // MARK: includeHidden

    func test_includeHidden_didSet_repopulatesExpandedNodes() async throws {
        let model = SidebarModel()
        try touch("a.md")
        try touch(".hidden")
        model.setRoot(tmpDir)
        let root = model.rootURL!
        XCTAssertEqual(model.children(of: root).map { $0.name }, ["a.md"])

        model.includeHidden = true
        // After toggling, the previously-expanded root is reloaded with
        // hidden entries included (no manual refresh needed).
        let names = Set(model.children(of: root).map { $0.name })
        XCTAssertEqual(names, [".hidden", "a.md"])
    }

    // MARK: Root rotation

    func test_changingRoot_clearsExpandedAndCache() async throws {
        let model = SidebarModel()
        let r1 = try mkdir("r1")
        try touch("r1/a.md")
        let r2 = try mkdir("r2")
        try touch("r2/b.md")

        model.setRoot(r1)
        XCTAssertFalse(model.children(of: r1).isEmpty)

        model.setRoot(r2)
        XCTAssertFalse(model.children(of: r2).isEmpty)
        XCTAssertFalse(model.isExpanded(r1), "expansion from previous root should be cleared")
        XCTAssertEqual(model.children(of: r1), [],
                       "cache from previous root should be cleared")
    }

    func test_setRoot_nil_clearsEverything() async throws {
        let model = SidebarModel()
        try touch("a.md")
        model.setRoot(tmpDir)
        XCTAssertTrue(model.isVisible)

        model.setRoot(nil)
        XCTAssertNil(model.rootURL)
        XCTAssertFalse(model.isVisible)
        XCTAssertTrue(model.expanded.isEmpty)
    }

    // MARK: T6 — refreshGitStatus integration (no test existed previously)

    func test_refreshGitStatus_populatesFromRepo() async throws {
        // Set up a tiny git repo with one untracked file.
        let git = GitService()
        try git.run(["-c", "init.defaultBranch=main", "init"], in: tmpDir)
        try git.run(["config", "user.email", "test@example.com"], in: tmpDir)
        try git.run(["config", "user.name", "Test"], in: tmpDir)
        try touch("a.md")

        let model = SidebarModel()
        model.setRoot(tmpDir)

        // refreshGitStatus dispatches a detached task; poll up to ~1 s.
        var statuses: [URL: GitStatusEntry.Status] = [:]
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            statuses = model.gitStatuses
            if !statuses.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)  // 50 ms
        }
        XCTAssertFalse(statuses.isEmpty, "git status should have populated the map")
        let aURL = tmpDir.appendingPathComponent("a.md")
            .standardizedFileURL.resolvingSymlinksInPath()
        XCTAssertEqual(statuses[aURL], .untracked)
    }

    func test_refreshGitStatus_outsideRepo_clearsMap() async throws {
        let model = SidebarModel()
        try touch("a.md")
        model.setRoot(tmpDir)
        // tmpDir is not a git repo → gitRepoRoot stays nil and statuses are empty.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(model.gitStatuses.isEmpty)
        XCTAssertNil(model.gitRepoRoot)
    }
}
