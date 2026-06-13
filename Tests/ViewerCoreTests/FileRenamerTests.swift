import XCTest
@testable import ViewerCore

/// TSK-283 — the headless disk side of "rename from the file nav".
/// Real temp dirs only; never the owner's filesystem.
final class FileRenamerTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileRenamerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func test_renameFile_movesOnDisk_preservesContents() throws {
        let src = try write("old.txt", "hello")
        let dst = try FileRenamer.rename(at: src, to: "new.txt")
        XCTAssertEqual(dst.lastPathComponent, "new.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path),
                       "old name is gone")
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "hello",
                       "contents survive the rename")
    }

    func test_renameDirectory_movesWholeSubtree() throws {
        let dir = tmp.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("child.txt"))
        let dst = try FileRenamer.rename(at: dir, to: "renamed")
        XCTAssertEqual(dst.lastPathComponent, "renamed")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dst.appendingPathComponent("child.txt").path),
            "the directory's contents move with it")
    }

    /// TEETH for the no-overwrite collision guard: a different file already
    /// at the target name must NOT be clobbered. Remove the inode-aware
    /// `targetExists` check in FileRenamer and this fails (rename(2) would
    /// silently replace `keep.txt`).
    func test_renameOntoExistingDifferentFile_throws_andLeavesBothIntact() throws {
        let src = try write("src.txt", "SRC")
        _ = try write("keep.txt", "KEEP")
        XCTAssertThrowsError(try FileRenamer.rename(at: src, to: "keep.txt")) { err in
            XCTAssertEqual(err as? FileRenamer.RenameError,
                           .targetExists(tmp.appendingPathComponent("keep.txt").path))
        }
        XCTAssertEqual(try String(contentsOf: src, encoding: .utf8), "SRC",
                       "source untouched on collision")
        XCTAssertEqual(try String(contentsOf: tmp.appendingPathComponent("keep.txt"),
                                  encoding: .utf8), "KEEP",
                       "the existing target is never overwritten")
    }

    /// A case-only rename must NOT be mistaken for a collision (it resolves
    /// to the same inode). TEETH for the inode comparison: a naive
    /// "dest exists → throw" would wrongly reject this.
    func test_caseOnlyRename_isAllowed() throws {
        let src = try write("readme.md", "R")
        let dst = try FileRenamer.rename(at: src, to: "README.md")
        XCTAssertEqual(dst.lastPathComponent, "README.md")
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "R")
    }

    func test_invalidNames_areRejected_withoutTouchingDisk() throws {
        let src = try write("a.txt", "A")
        for bad in ["", "  ", "a/b", "..", ".", "x\u{0}y"] {
            XCTAssertThrowsError(try FileRenamer.rename(at: src, to: bad),
                                 "‘\(bad)’ must be rejected") { err in
                XCTAssertEqual(err as? FileRenamer.RenameError, .invalidName(bad))
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path),
                      "a rejected name never moves the source")
    }

    func test_renameToSameName_throwsUnchanged() throws {
        let src = try write("same.txt", "S")
        XCTAssertThrowsError(try FileRenamer.rename(at: src, to: "same.txt")) { err in
            XCTAssertEqual(err as? FileRenamer.RenameError, .unchanged)
        }
    }

    func test_missingSource_throws() {
        let ghost = tmp.appendingPathComponent("does-not-exist.txt")
        XCTAssertThrowsError(try FileRenamer.rename(at: ghost, to: "x.txt")) { err in
            XCTAssertEqual(err as? FileRenamer.RenameError, .sourceMissing(ghost.path))
        }
    }

    /// A leading-whitespace name is trimmed; a `.dotfile` target is allowed.
    func test_nameIsTrimmed_andDotfileAllowed() throws {
        let src = try write("notes.txt", "N")
        let dst = try FileRenamer.rename(at: src, to: "  .gitignore  ")
        XCTAssertEqual(dst.lastPathComponent, ".gitignore")
    }
}
