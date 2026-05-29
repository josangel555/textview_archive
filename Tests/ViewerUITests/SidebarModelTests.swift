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

    private func runGit(_ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = dir
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "git", code: Int(p.terminationStatus))
        }
    }

    func test_refreshGitStatus_populatesFromRepo() async throws {
        // Set up a tiny git repo with one untracked file.
        try runGit(["-c", "init.defaultBranch=main", "init"], in: tmpDir)
        try runGit(["config", "user.email", "test@example.com"], in: tmpDir)
        try runGit(["config", "user.name", "Test"], in: tmpDir)
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
        // Build state: populate `gitStatuses` and `gitRepoRoot` via a
        // repo tmpdir first, then re-`setRoot` to a non-repo dir and
        // assert both fields actually got cleared. The old version
        // started with an empty model and asserted the (already-empty)
        // map was empty after 100 ms — meaningless.
        let repoDir = tmpDir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(
            at: repoDir, withIntermediateDirectories: true)
        // Initialise a tiny git repo so refreshGitStatus has something
        // to populate. `git init -q` is fast and offline.
        let init1 = Process()
        init1.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        init1.arguments = ["git", "init", "-q", repoDir.path]
        try init1.run(); init1.waitUntilExit()
        let aURL = repoDir.appendingPathComponent("a.md")
        try "x".write(to: aURL, atomically: true, encoding: .utf8)

        let model = SidebarModel()
        model.setRoot(repoDir)
        // Wait until git status has populated AND gitRepoRoot is set.
        let populated = await {
            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline {
                if model.gitRepoRoot != nil && !model.gitStatuses.isEmpty {
                    return true
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return false
        }()
        XCTAssertTrue(populated, "git status should have populated in the repo dir")

        // Now switch to a non-repo dir. Both the map and the repo root
        // must clear.
        let nonRepoDir = tmpDir.appendingPathComponent("not-a-repo")
        try FileManager.default.createDirectory(
            at: nonRepoDir, withIntermediateDirectories: true)
        model.setRoot(nonRepoDir)
        let cleared = await {
            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline {
                if model.gitRepoRoot == nil && model.gitStatuses.isEmpty {
                    return true
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return false
        }()
        XCTAssertTrue(cleared, "switching to a non-repo dir should clear git state")
    }

    // MARK: CRIT-6 — keyboard navigation

    func test_setRoot_initiallySelectsRoot() async throws {
        let model = SidebarModel()
        try touch("a.md")
        model.setRoot(tmpDir)
        XCTAssertEqual(model.selectedURL?.resolvingSymlinksInPath(),
                       tmpDir.resolvingSymlinksInPath())
    }

    func test_flatVisibleNodes_respectsExpansion() async throws {
        let model = SidebarModel()
        try mkdir("docs")
        try touch("docs/inside.md")
        try touch("a.md")
        model.setRoot(tmpDir)
        // Root is auto-expanded → root + docs + a.md (docs not expanded so
        // inside.md hidden).
        let names = model.flatVisibleNodes().map { $0.name }
        XCTAssertEqual(names, [tmpDir.lastPathComponent, "docs", "a.md"])

        // Expand docs → its child appears.
        model.toggleExpansion(tmpDir.appendingPathComponent("docs"))
        XCTAssertEqual(model.flatVisibleNodes().map { $0.name },
                       [tmpDir.lastPathComponent, "docs", "inside.md", "a.md"])
    }

    func test_selectNext_walksFlatVisible() async throws {
        let model = SidebarModel()
        try touch("a.md")
        try touch("b.md")
        model.setRoot(tmpDir)
        // Start at root.
        XCTAssertEqual(model.selectedURL, model.rootURL)
        model.selectNext()
        XCTAssertEqual(model.selectedURL?.lastPathComponent, "a.md")
        model.selectNext()
        XCTAssertEqual(model.selectedURL?.lastPathComponent, "b.md")
        // At the end — selectNext is a no-op.
        model.selectNext()
        XCTAssertEqual(model.selectedURL?.lastPathComponent, "b.md")
    }

    func test_selectPrevious_walksUp() async throws {
        let model = SidebarModel()
        try touch("a.md")
        try touch("b.md")
        model.setRoot(tmpDir)
        model.selectNext()
        model.selectNext()
        XCTAssertEqual(model.selectedURL?.lastPathComponent, "b.md")
        model.selectPrevious()
        XCTAssertEqual(model.selectedURL?.lastPathComponent, "a.md")
        model.selectPrevious()
        XCTAssertEqual(model.selectedURL, model.rootURL)
    }

    func test_collapseOrFocusParent_collapsesExpandedDir() async throws {
        let model = SidebarModel()
        try mkdir("docs")
        model.setRoot(tmpDir)
        let root = model.rootURL!
        XCTAssertTrue(model.isExpanded(root))
        model.collapseOrFocusParent()
        XCTAssertFalse(model.isExpanded(root))
    }

    func test_collapseOrFocusParent_movesToParentForFile() async throws {
        let model = SidebarModel()
        try mkdir("docs")
        try touch("docs/inside.md")
        model.setRoot(tmpDir)
        model.toggleExpansion(tmpDir.appendingPathComponent("docs"))
        // Move selection down to inside.md
        model.selectNext()  // → docs
        model.selectNext()  // → inside.md
        XCTAssertEqual(model.selectedURL?.lastPathComponent, "inside.md")
        model.collapseOrFocusParent()
        XCTAssertEqual(model.selectedURL?.lastPathComponent, "docs")
    }

    func test_expandOrFocusFirstChild_expandsCollapsed() async throws {
        let model = SidebarModel()
        try mkdir("docs")
        try touch("docs/inside.md")
        model.setRoot(tmpDir)
        let docs = tmpDir.appendingPathComponent("docs")
        // Select docs but don't expand it.
        model.selectNext()
        XCTAssertEqual(model.selectedURL?.lastPathComponent, "docs")
        XCTAssertFalse(model.isExpanded(docs))
        model.expandOrFocusFirstChild()
        XCTAssertTrue(model.isExpanded(docs))
    }

    func test_expandOrFocusFirstChild_movesIntoFirstChild() async throws {
        let model = SidebarModel()
        try mkdir("docs")
        try touch("docs/inside.md")
        model.setRoot(tmpDir)
        let docs = tmpDir.appendingPathComponent("docs")
        model.toggleExpansion(docs)  // expand
        model.setSelected(docs)
        model.expandOrFocusFirstChild()  // already expanded → move into child
        XCTAssertEqual(model.selectedURL?.lastPathComponent, "inside.md")
    }

    // MARK: - PERF #6 — flatVisibleRows pins virtualization shape

    /// Pin: a deep tree with no expanded children must report only the
    /// rows that are actually on-screen — the root plus its immediate
    /// (collapsed) children. The previous SidebarView shape recursed
    /// `FileRowView` -> non-lazy `ForEach`, so any expand of the root
    /// materialized every descendant in one body pass and defeated the
    /// outer `LazyVStack`. After flattening, the visible row set is
    /// exactly what the `LazyVStack` will consider candidates.
    func test_flatVisibleRows_deepCollapsedTree_onlyTopLevelMaterialized() async throws {
        let model = SidebarModel()
        // Build: root/                       (depth 0, auto-expanded)
        //          d0/                       (depth 1, collapsed)
        //            d1/d2/.../d29/leaf.md   (depth 2..31, all COLLAPSED)
        //          file_000.md ... file_049.md (depth 1, files)
        //
        // The depth (30) is deliberately moderate to stay well under
        // darwin PATH_MAX; the perf claim is about the relationship
        // between *materialized row count* and *expansion state*, not
        // about absolute depth. A 30-level collapsed subtree + 50
        // sibling files is plenty to falsify the pre-fix recursive
        // shape, which would have unconditionally walked every level.
        try mkdir("d0")
        var path = "d0"
        for i in 0..<30 {
            path += "/d\(i + 1)"
            try mkdir(path)
        }
        try touch(path + "/leaf.md")  // 30 + 1 levels deep
        for i in 0..<50 {
            try touch(String(format: "file_%03d.md", i))
        }
        model.setRoot(tmpDir)

        // Only the root is expanded by default. Visible rows = root +
        // its direct children = 1 + (1 dir + 50 files) = 52.
        let rows = model.flatVisibleRows()
        XCTAssertEqual(
            rows.count, 52,
            "Deep collapsed tree must only materialize top-level rows " +
            "(1 root + 1 directory + 50 files = 52); got \(rows.count)"
        )
        XCTAssertEqual(rows.first?.depth, 0)
        XCTAssertTrue(rows.dropFirst().allSatisfy { $0.depth == 1 })

        // Negative-control: expanding one level adds exactly 1 row
        // (the next directory), proving the flat list grows by the
        // visible delta, not by the whole subtree.
        let before = model.flatVisibleRows().count
        model.toggleExpansion(tmpDir.appendingPathComponent("d0"))
        let after = model.flatVisibleRows().count
        XCTAssertEqual(
            after - before, 1,
            "Expanding one directory must add only its immediate visible " +
            "children (1 here); got delta \(after - before)"
        )
    }

    /// Depths must equal the number of slashes between root and node —
    /// i.e. the indentation the sidebar applies (`depth * 14 + 8`)
    /// remains visually correct after the flatten refactor.
    func test_flatVisibleRows_depthsMatchTreeStructure() async throws {
        let model = SidebarModel()
        try mkdir("a/b/c")
        try touch("a/b/c/leaf.md")
        try touch("a/sibling.md")
        try touch("root.md")
        model.setRoot(tmpDir)
        let a = tmpDir.appendingPathComponent("a")
        let b = a.appendingPathComponent("b")
        let c = b.appendingPathComponent("c")
        model.toggleExpansion(a)
        model.toggleExpansion(b)
        model.toggleExpansion(c)

        let byName = Dictionary(
            uniqueKeysWithValues:
                model.flatVisibleRows().map { ($0.node.name, $0.depth) }
        )
        XCTAssertEqual(byName[tmpDir.lastPathComponent], 0)
        XCTAssertEqual(byName["a"], 1)
        XCTAssertEqual(byName["b"], 2)
        XCTAssertEqual(byName["c"], 3)
        XCTAssertEqual(byName["leaf.md"], 4)
        XCTAssertEqual(byName["sibling.md"], 2)
        XCTAssertEqual(byName["root.md"], 1)
    }

    /// flatVisibleNodes (existing API) must keep returning the same
    /// node list, in the same order, as the new rows-with-depth API —
    /// keyboard navigation relies on it.
    func test_flatVisibleNodes_matchesFlatVisibleRowsOrder() async throws {
        let model = SidebarModel()
        try mkdir("x")
        try touch("x/y.md")
        try touch("z.md")
        model.setRoot(tmpDir)
        model.toggleExpansion(tmpDir.appendingPathComponent("x"))

        XCTAssertEqual(
            model.flatVisibleNodes().map { $0.url },
            model.flatVisibleRows().map { $0.node.url }
        )
    }

    /// flatVisibleRows must be memoized — repeated reads return the
    /// same array contents without re-walking. Toggling expansion
    /// invalidates the cache. We can't directly observe the cache, but
    /// we can pin the contract on a wider tree: identical results
    /// before and after a no-op read; correct results after a
    /// mutation.
    func test_flatVisibleRows_invalidatesOnMutation() async throws {
        let model = SidebarModel()
        try mkdir("dir")
        try touch("dir/child.md")
        model.setRoot(tmpDir)
        let first = model.flatVisibleRows()
        let second = model.flatVisibleRows()
        XCTAssertEqual(first, second)
        model.toggleExpansion(tmpDir.appendingPathComponent("dir"))
        let third = model.flatVisibleRows()
        XCTAssertNotEqual(first.count, third.count)
        XCTAssertEqual(third.map { $0.node.name }.last, "child.md")
    }
}
