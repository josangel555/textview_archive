import XCTest
@testable import ViewerUI
@testable import ViewerCore
@testable import ViewerKit

/// Tests for `DocumentModel.revealInSidebar(_:)` + isSidebarLocked.
/// Pure model-state asserts; no SwiftUI rendering needed.
@MainActor
final class SidebarRevealTests: XCTestCase {

    private var tmpRoot: URL!
    private var nested: URL!
    private var leafFile: URL!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tmpRoot = fm.temporaryDirectory
            .appendingPathComponent("SidebarRevealTests-\(UUID().uuidString)")
        nested = tmpRoot.appendingPathComponent("a/b/c", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        leafFile = nested.appendingPathComponent("leaf.txt")
        try "hello".write(to: leafFile, atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        if let tmpRoot { try? FileManager.default.removeItem(at: tmpRoot) }
        try await super.tearDown()
    }

    private func makeModel() -> DocumentModel {
        DocumentModel()
    }

    func test_reveal_sets_root_when_none_open() {
        let m = makeModel()
        XCTAssertNil(m.sidebar.rootURL)
        m.revealInSidebar(leafFile)
        XCTAssertNotNil(m.sidebar.rootURL)
        // Root should be the leaf's containing folder.
        XCTAssertEqual(
            m.sidebar.rootURL?.standardizedFileURL.resolvingSymlinksInPath().path,
            nested.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    func test_reveal_expands_ancestors_within_existing_root() {
        let m = makeModel()
        m.sidebar.setRoot(tmpRoot)
        m.revealInSidebar(leafFile)
        // a, a/b, a/b/c should all be expanded.
        XCTAssertTrue(m.sidebar.isExpanded(tmpRoot))
        XCTAssertTrue(m.sidebar.isExpanded(tmpRoot.appendingPathComponent("a")))
        XCTAssertTrue(m.sidebar.isExpanded(tmpRoot.appendingPathComponent("a/b")))
        // The leaf itself isn't a directory so we expand its parent only.
        XCTAssertEqual(
            m.sidebar.selectedURL?.standardizedFileURL.resolvingSymlinksInPath().path,
            leafFile.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    func test_reveal_respects_lock() {
        let m = makeModel()
        let differentRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtherRoot-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: differentRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: differentRoot) }
        m.sidebar.setRoot(differentRoot)
        m.toggleSidebarLock()
        XCTAssertTrue(m.isSidebarLocked)

        // leafFile is OUTSIDE the current root. With lock on, reveal
        // must be a silent no-op — root unchanged, selection unchanged.
        let rootBefore = m.sidebar.rootURL
        m.revealInSidebar(leafFile)
        XCTAssertEqual(m.sidebar.rootURL, rootBefore)
    }

    func test_toggle_sidebar_lock_flips_state() {
        let m = makeModel()
        XCTAssertFalse(m.isSidebarLocked)
        m.toggleSidebarLock()
        XCTAssertTrue(m.isSidebarLocked)
        m.toggleSidebarLock()
        XCTAssertFalse(m.isSidebarLocked)
    }
}
