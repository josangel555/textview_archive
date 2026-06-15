import XCTest
@testable import ViewerCore

/// TSK-929 — follow an externally-renamed file by inode so an open tab updates
/// instead of showing "file not found".
final class RenameFollowerTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func write(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_findsRenamedFile_byInode() throws {
        let old = try write("old.txt")
        let inode = try XCTUnwrap(RenameFollower.inode(of: old))
        let new = dir.appendingPathComponent("new.txt")
        try FileManager.default.moveItem(at: old, to: new)

        let found = RenameFollower.findRenamed(inode: inode, inDirectory: dir)
        XCTAssertEqual(found?.lastPathComponent, "new.txt")
    }

    func test_trueDelete_returnsNil() throws {
        let f = try write("gone.txt")
        let inode = try XCTUnwrap(RenameFollower.inode(of: f))
        try FileManager.default.removeItem(at: f)
        XCTAssertNil(RenameFollower.findRenamed(inode: inode, inDirectory: dir))
    }

    func test_movedOutOfFolder_returnsNil() throws {
        let f = try write("moved.txt")
        let inode = try XCTUnwrap(RenameFollower.inode(of: f))
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-out-\(UUID().uuidString).txt")
        try FileManager.default.moveItem(at: f, to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertNil(RenameFollower.findRenamed(inode: inode, inDirectory: dir),
            "a file moved OUT of the folder is not a follow target")
    }

    func test_distinctFile_sameFolder_notMatched() throws {
        let a = try write("a.txt")
        _ = try write("b.txt")
        let inodeA = try XCTUnwrap(RenameFollower.inode(of: a))
        try FileManager.default.moveItem(at: a, to: dir.appendingPathComponent("a-renamed.txt"))
        // Must match a-renamed (a's inode), NOT the unrelated b.txt.
        XCTAssertEqual(
            RenameFollower.findRenamed(inode: inodeA, inDirectory: dir)?.lastPathComponent,
            "a-renamed.txt")
    }

    func test_inode_ofMissingFile_isNil() {
        XCTAssertNil(RenameFollower.inode(of: dir.appendingPathComponent("nope.txt")))
    }
}
