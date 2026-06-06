import XCTest
@testable import ViewerUI

/// Coverage for `DocumentModel.repoRelativePath(of:root:)` — the pure path
/// helper that yields a file's slash-joined path relative to a repo root,
/// or nil when it's outside. Was untested. The load-bearing edge is the
/// **sibling-prefix guard**: `/proj` must NOT swallow `/proj-sibling`
/// (a string `hasPrefix` without the trailing-slash boundary would). The
/// helper is `nonisolated` + does pure path math (standardize + resolve
/// symlinks), so no filesystem objects are created.
final class RepoRelativePathTests: XCTestCase {

    private let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("RepoRelPathTests-\(UUID().uuidString)")

    private func rel(_ url: URL, _ root: URL) -> String? {
        DocumentModel.repoRelativePath(of: url, root: root)
    }

    func test_exactRoot_isEmptyString() {
        let root = base.appendingPathComponent("repo")
        XCTAssertEqual(rel(root, root), "")
    }

    func test_directChild_isFileName() {
        let root = base.appendingPathComponent("repo")
        XCTAssertEqual(rel(root.appendingPathComponent("README.md"), root), "README.md")
    }

    func test_nestedChild_isSlashJoined_noLeadingSlash() {
        let root = base.appendingPathComponent("repo")
        let url = root.appendingPathComponent("src/app/main.swift")
        let r = rel(url, root)
        XCTAssertEqual(r, "src/app/main.swift")
        XCTAssertFalse(r?.hasPrefix("/") ?? true, "no leading slash")
    }

    func test_outsideRoot_isNil() {
        let root = base.appendingPathComponent("repoA")
        let other = base.appendingPathComponent("repoB/file.md")
        XCTAssertNil(rel(other, root))
    }

    /// The boundary guard: a sibling whose name merely *starts with* the
    /// root's last path component must not be treated as inside it.
    func test_siblingPrefix_isNotInsideRoot() {
        let root = base.appendingPathComponent("proj")
        let sibling = base.appendingPathComponent("proj-sibling/x.md")
        XCTAssertNil(rel(sibling, root),
                     "/proj must not match /proj-sibling (trailing-slash boundary)")
    }

    func test_trailingSlashOnRoot_matchesNonTrailing() {
        let root = base.appendingPathComponent("repo")
        let rootSlash = URL(fileURLWithPath: root.path + "/", isDirectory: true)
        let url = root.appendingPathComponent("a.md")
        XCTAssertEqual(rel(url, rootSlash), rel(url, root))
        XCTAssertEqual(rel(url, rootSlash), "a.md")
    }

    func test_nonNormalizedURL_isStandardizedBeforeCompare() {
        let root = base.appendingPathComponent("repo")
        // repo/sub/../b.md  →  repo/b.md  →  "b.md"
        let messy = root.appendingPathComponent("sub/../b.md")
        XCTAssertEqual(rel(messy, root), "b.md")
    }
}
