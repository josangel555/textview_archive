import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-916 — manual "Refresh" on a folder force re-lists it + its expanded
/// descendants from disk, ignoring the children cache. (The FSEvents
/// auto-refresh — TSK-915 — only fires on a *detected* change; this is the
/// manual escape hatch for network/iCloud mounts or a dropped watcher.)
@MainActor
final class SidebarRefreshFromDiskTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarRefreshFromDisk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @discardableResult
    private func touch(_ relativePath: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    private func mkdir(_ relativePath: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A file added on disk to the refreshed folder appears after refresh,
    /// proving the cache was re-read (not served stale).
    func test_refreshFromDisk_picksUpExternallyAddedFile() throws {
        let model = SidebarModel()
        try touch("a.md")
        model.setRoot(tmpDir)
        XCTAssertEqual(Set(model.children(of: tmpDir).map(\.name)), ["a.md"])

        // Add a file directly on disk (the watcher is not involved here).
        try touch("b.md")
        // Stale cache still shows only a.md until we force a re-list.
        XCTAssertEqual(Set(model.children(of: tmpDir).map(\.name)), ["a.md"],
            "precondition: cache is stale until a refresh")

        model.refreshFromDisk(tmpDir)
        XCTAssertEqual(Set(model.children(of: tmpDir).map(\.name)), ["a.md", "b.md"],
            "refresh must re-read the directory from disk")
    }

    /// A removal on disk is reflected after refresh.
    func test_refreshFromDisk_dropsExternallyRemovedFile() throws {
        let model = SidebarModel()
        let gone = try touch("gone.md")
        try touch("keep.md")
        model.setRoot(tmpDir)
        XCTAssertEqual(Set(model.children(of: tmpDir).map(\.name)), ["gone.md", "keep.md"])

        try FileManager.default.removeItem(at: gone)
        model.refreshFromDisk(tmpDir)
        XCTAssertEqual(Set(model.children(of: tmpDir).map(\.name)), ["keep.md"],
            "refresh must drop a file removed on disk")
    }

    /// Refresh re-lists an EXPANDED descendant, not just the clicked folder —
    /// the whole visible subtree refreshes in one action.
    func test_refreshFromDisk_reListsExpandedDescendant() throws {
        let model = SidebarModel()
        let sub = try mkdir("sub")
        try touch("sub/old.md")
        model.setRoot(tmpDir)
        model.toggleExpansion(sub)            // expand sub so it's visible
        _ = model.children(of: sub)           // prime sub's cache
        XCTAssertEqual(Set(model.children(of: sub).map(\.name)), ["old.md"])

        try touch("sub/new.md")               // add a file inside the expanded sub
        model.refreshFromDisk(tmpDir)         // refresh the ROOT
        XCTAssertEqual(Set(model.children(of: sub).map(\.name)), ["old.md", "new.md"],
            "refreshing the root must also re-list its expanded descendants")
    }

    /// A COLLAPSED descendant is not force-listed (we don't pay I/O for
    /// subtrees the user can't see) — bounds the refresh cost.
    func test_refreshFromDisk_skipsCollapsedDescendant() throws {
        let model = SidebarModel()
        let sub = try mkdir("sub")
        try touch("sub/seed.md")
        model.setRoot(tmpDir)
        // sub is NOT expanded and never primed → children(of:) is cache-only.
        XCTAssertTrue(model.children(of: sub).isEmpty,
            "precondition: a never-loaded collapsed dir has no cached children")

        model.refreshFromDisk(tmpDir)
        XCTAssertTrue(model.children(of: sub).isEmpty,
            "refresh must not eagerly list a collapsed/unloaded descendant")
    }
}
