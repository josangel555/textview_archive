import XCTest
@testable import ViewerCore

/// TSK-1463 — teeth for the pure file-tree-op primitives: `FolderCreator`
/// (race-free non-colliding mkdir), `FileMover` (never-clobber move), and
/// `PathRebase` (the tab/bookmark retarget seam). Real temp dirs only.
final class FileTreeOpsTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileTreeOps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - FolderCreator

    func test_folderCreator_createsAndNumbersNonColliding() throws {
        let first = try FolderCreator.create(in: tmp)
        XCTAssertEqual(first.lastPathComponent, "untitled folder")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)

        let second = try FolderCreator.create(in: tmp)
        XCTAssertEqual(second.lastPathComponent, "untitled folder 2")
        let third = try FolderCreator.create(in: tmp)
        XCTAssertEqual(third.lastPathComponent, "untitled folder 3")
    }

    func test_folderCreator_rejectsTraversalNames() {
        for bad in ["", "a/b", "..", ".", "x\0y"] {
            XCTAssertThrowsError(try FolderCreator.create(in: tmp, baseName: bad),
                                 "'\(bad)' must be rejected")
        }
    }

    func test_folderCreator_rejectsNonDirectory() throws {
        let file = tmp.appendingPathComponent("f.txt")
        try Data("x".utf8).write(to: file)
        XCTAssertThrowsError(try FolderCreator.create(in: file))
    }

    // MARK: - FileMover

    func test_move_movesFileIntoDirectory() throws {
        let src = tmp.appendingPathComponent("a.txt")
        try Data("payload".utf8).write(to: src)
        let dest = tmp.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let moved = try FileMover.move(src, into: dest)
        XCTAssertEqual(moved.path, dest.appendingPathComponent("a.txt").path)
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "payload")
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
    }

    func test_move_neverClobbers_existingDestination() throws {
        let src = tmp.appendingPathComponent("a.txt")
        try Data("new".utf8).write(to: src)
        let dest = tmp.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let occupant = dest.appendingPathComponent("a.txt")
        try Data("precious".utf8).write(to: occupant)

        XCTAssertThrowsError(try FileMover.move(src, into: dest)) { error in
            XCTAssertEqual(error as? FileMover.MoveError,
                           .targetExists(occupant.path))
        }
        XCTAssertEqual(try String(contentsOf: occupant, encoding: .utf8), "precious",
                       "the occupant is byte-identical after the refused move")
        XCTAssertEqual(try String(contentsOf: src, encoding: .utf8), "new",
                       "the source is intact after the refused move")
    }

    func test_move_rejectsSameLocation_missingSource_andIntoItself() throws {
        let src = tmp.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: src)
        XCTAssertThrowsError(try FileMover.move(src, into: tmp)) { error in
            XCTAssertEqual(error as? FileMover.MoveError, .sameLocation)
        }
        XCTAssertThrowsError(try FileMover.move(tmp.appendingPathComponent("ghost"), into: tmp))

        let folder = tmp.appendingPathComponent("outer")
        let inner = folder.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        XCTAssertThrowsError(try FileMover.move(folder, into: inner)) { error in
            XCTAssertEqual(error as? FileMover.MoveError, .intoItself)
        }
    }

    // MARK: - PathRebase

    func test_rebase_exactMatch() {
        let old = URL(fileURLWithPath: "/w/a.txt")
        let new = URL(fileURLWithPath: "/w/b.txt")
        XCTAssertEqual(PathRebase.rebased(old, from: old, to: new)?.path, "/w/b.txt")
    }

    func test_rebase_descendantOfRenamedFolder() {
        let old = URL(fileURLWithPath: "/w/docs")
        let new = URL(fileURLWithPath: "/w/notes")
        let child = URL(fileURLWithPath: "/w/docs/sub/deep.md")
        XCTAssertEqual(PathRebase.rebased(child, from: old, to: new)?.path,
                       "/w/notes/sub/deep.md")
    }

    func test_rebase_unrelated_andSiblingPrefix_areNil() {
        let old = URL(fileURLWithPath: "/w/docs")
        let new = URL(fileURLWithPath: "/w/notes")
        XCTAssertNil(PathRebase.rebased(URL(fileURLWithPath: "/w/other/x.md"),
                                        from: old, to: new))
        // "/w/docs-archive" shares the string prefix but is NOT under /w/docs.
        XCTAssertNil(PathRebase.rebased(URL(fileURLWithPath: "/w/docs-archive/x.md"),
                                        from: old, to: new))
    }
}
