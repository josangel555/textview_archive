import XCTest
@testable import ViewerCore

/// TSK-1495 — the archive→sidebar tree model: flat entries → nested nodes,
/// intermediate-dir synthesis, dirs-first sort, cap + truncation.
final class ArchiveTreeTests: XCTestCase {

    private func entry(_ name: String, dir: Bool = false, size: Int? = nil)
        -> ArchiveCatalog.Entry {
        ArchiveCatalog.Entry(name: name, isDirectory: dir, sizeBytes: size)
    }

    func test_buildsNestedTree_fromFlatPaths() {
        let r = ArchiveTree.build(entries: [
            entry("src/main.swift", size: 100),
            entry("src/util/helper.swift", size: 50),
            entry("README.md", size: 20),
        ])
        XCTAssertFalse(r.truncated)
        XCTAssertEqual(r.totalEntries, 3)
        // Root: "src" (dir) sorts before "README.md" (file) — dirs first.
        XCTAssertEqual(r.roots.map(\.name), ["src", "README.md"])
        let src = r.roots[0]
        XCTAssertTrue(src.isDirectory)
        // src children: "util" (dir) before "main.swift" (file).
        XCTAssertEqual(src.children.map(\.name), ["util", "main.swift"])
        XCTAssertEqual(src.path, "src")
        XCTAssertEqual(src.children[1].path, "src/main.swift")
        XCTAssertEqual(src.children[1].sizeBytes, 100)
    }

    func test_synthesizesIntermediateDirs_withoutExplicitDirEntry() {
        // No explicit "a/" or "a/b/" entries — only the deep file.
        let r = ArchiveTree.build(entries: [entry("a/b/c.txt", size: 5)])
        XCTAssertEqual(r.roots.map(\.name), ["a"])
        let a = r.roots[0]
        XCTAssertTrue(a.isDirectory)
        XCTAssertEqual(a.children.map(\.name), ["b"])
        XCTAssertTrue(a.children[0].isDirectory)
        XCTAssertEqual(a.children[0].children.map(\.name), ["c.txt"])
        XCTAssertFalse(a.children[0].children[0].isDirectory)
    }

    func test_explicitDirEntry_isADirectory_evenWhenEmpty() {
        let r = ArchiveTree.build(entries: [entry("emptydir/", dir: true)])
        XCTAssertEqual(r.roots.count, 1)
        XCTAssertTrue(r.roots[0].isDirectory)
        XCTAssertEqual(r.roots[0].name, "emptydir")
        XCTAssertTrue(r.roots[0].children.isEmpty)
    }

    func test_trailingSlashName_treatedAsDirectory() {
        let r = ArchiveTree.build(entries: [entry("logs/", dir: false)])
        XCTAssertTrue(r.roots[0].isDirectory, "a trailing-slash name is a dir even if the flag is false")
    }

    func test_cap_truncatesAndFlags() {
        let many = (0..<10).map { entry("f\($0).txt", size: 1) }
        let r = ArchiveTree.build(entries: many, nodeCap: 4)
        XCTAssertTrue(r.truncated)
        XCTAssertEqual(r.totalEntries, 10)
        XCTAssertEqual(r.roots.count, 4, "only the first cap entries are woven in")
    }

    func test_emptyArchive() {
        let r = ArchiveTree.build(entries: [])
        XCTAssertTrue(r.roots.isEmpty)
        XCTAssertFalse(r.truncated)
        XCTAssertEqual(r.totalEntries, 0)
    }

    func test_mergesFilesUnderSharedDir() {
        let r = ArchiveTree.build(entries: [
            entry("d/one.txt", size: 1),
            entry("d/two.txt", size: 2),
        ])
        XCTAssertEqual(r.roots.count, 1, "one shared 'd' dir, not two")
        XCTAssertEqual(r.roots[0].children.map(\.name), ["one.txt", "two.txt"])
    }
}
