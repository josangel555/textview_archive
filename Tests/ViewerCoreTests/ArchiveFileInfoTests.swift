import XCTest
@testable import ViewerCore

/// TSK-807 — the archive "Archive" summary for the file-info panel. Builds a
/// real `.zip` fixture (shelling out to the system `zip`) and asserts the
/// extracted rows. Host-safe.
final class ArchiveFileInfoTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-archive-info-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// Build content/{a.txt,b.txt,sub/c.txt} then `zip -r` it → 3 files, 2 dirs.
    private func makeZip() throws -> URL {
        let content = tmpDir.appendingPathComponent("content")
        let sub = content.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try String(repeating: "a", count: 10).write(
            to: content.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try String(repeating: "b", count: 20).write(
            to: content.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try String(repeating: "c", count: 30).write(
            to: sub.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)

        let zipURL = tmpDir.appendingPathComponent("fixture.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = tmpDir
        p.arguments = ["-r", "-q", zipURL.path, "content"]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "zip fixture creation failed")
        return zipURL
    }

    private func value(_ rows: [ArchiveFileInfo.Row], _ label: String) -> String? {
        rows.first(where: { $0.label == label })?.value
    }

    func test_zip_formatFileAndFolderCounts() throws {
        let zip = try makeZip()
        let rows = ArchiveFileInfo.summaryRows(for: zip)
        XCTAssertEqual(value(rows, "Format"), "Zip")
        XCTAssertEqual(value(rows, "Files"), "3", "a.txt, b.txt, sub/c.txt")
        XCTAssertEqual(value(rows, "Folders"), "2", "content/ and content/sub/")
    }

    func test_zip_reportsUncompressedSize() throws {
        let zip = try makeZip()
        let rows = ArchiveFileInfo.summaryRows(for: zip)
        // unzip -l reports per-entry uncompressed sizes; the sum (10+20+30=60 B)
        // renders via ByteCountFormatter. Assert it's present + non-empty rather
        // than an exact locale-formatted string.
        let size = value(rows, "Uncompressed")
        XCTAssertNotNil(size)
        XCTAssertFalse(size?.isEmpty ?? true)
        XCTAssertTrue(size?.contains("60") ?? false, "60 bytes total uncompressed")
    }

    func test_jarIsZip() throws {
        // A .jar is a zip — kind() maps it, so it gets the same summary.
        let zip = try makeZip()
        let jar = tmpDir.appendingPathComponent("fixture.jar")
        try FileManager.default.copyItem(at: zip, to: jar)
        XCTAssertEqual(value(ArchiveFileInfo.summaryRows(for: jar), "Format"), "Zip")
    }

    func test_nonArchive_yieldsEmpty() throws {
        let txt = tmpDir.appendingPathComponent("notes.txt")
        try "not an archive\n".write(to: txt, atomically: true, encoding: .utf8)
        XCTAssertTrue(ArchiveFileInfo.summaryRows(for: txt).isEmpty)
    }
}
