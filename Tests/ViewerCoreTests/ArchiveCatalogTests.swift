import XCTest
@testable import ViewerCore

/// TSK-311 — the archive-browse core. Fixtures are built with the SAME
/// system tools the catalog shells out to (`zip`, `tar`), so the tests
/// exercise the real parse + pipe paths end-to-end on the host.
final class ArchiveCatalogTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveCatalogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("hello zip".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("nested file content".utf8)
            .write(to: dir.appendingPathComponent("sub/with space.md"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func shell(_ tool: String, _ args: [String], cwd: URL) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    private func makeZip() throws -> URL {
        let zip = dir.appendingPathComponent("fixture.zip")
        XCTAssertEqual(try shell("/usr/bin/zip", ["-r", zip.path, "a.txt", "sub"], cwd: dir), 0)
        return zip
    }

    private func makeTarGz() throws -> URL {
        let tgz = dir.appendingPathComponent("fixture.tar.gz")
        XCTAssertEqual(try shell("/usr/bin/tar", ["-czf", tgz.path, "a.txt", "sub"], cwd: dir), 0)
        return tgz
    }

    func test_kindDetection() {
        func k(_ name: String) -> ArchiveCatalog.Kind? {
            ArchiveCatalog.kind(for: URL(fileURLWithPath: "/tmp/\(name)"))
        }
        XCTAssertEqual(k("a.zip"), .zip)
        XCTAssertEqual(k("A.JAR"), .zip)
        XCTAssertEqual(k("a.tar"), .tar)
        XCTAssertEqual(k("a.tar.gz"), .tarGz)
        XCTAssertEqual(k("a.tgz"), .tarGz)
        XCTAssertEqual(k("a.tar.bz2"), .tarBz2)
        XCTAssertNil(k("a.7z"), "7z stays icon-only in v1 (no system tool)")
        XCTAssertNil(k("a.txt"))
    }

    func test_zip_list_and_extract_withSpacesAndNesting() throws {
        let zip = try makeZip()
        let (entries, truncated) = try ArchiveCatalog.list(zip)
        XCTAssertFalse(truncated)
        XCTAssertTrue(entries.contains { $0.name == "a.txt" && $0.sizeBytes == 9 })
        XCTAssertTrue(entries.contains { $0.name == "sub/with space.md" },
                      "names with spaces must survive the unzip -l parse")
        XCTAssertTrue(entries.contains { $0.name == "sub/" && $0.isDirectory })

        let extracted = try ArchiveCatalog.extractEntry(named: "sub/with space.md", from: zip)
        defer { try? FileManager.default.removeItem(
            at: extracted.deletingLastPathComponent()) }
        XCTAssertEqual(try String(contentsOf: extracted, encoding: .utf8),
                       "nested file content")
        XCTAssertEqual(extracted.lastPathComponent, "with space.md",
                       "temp leaf keeps the display name")
        XCTAssertTrue(extracted.path.hasPrefix(
            FileManager.default.temporaryDirectory.path),
            "extraction lands in OUR temp dir, never an archive-chosen path")
    }

    // TSK-1001: an archive entry name that looks like a CLI option must NOT be
    // interpreted as one — a `--` terminator precedes the positional path/member.
    // An option-like (non-existent) member therefore errors cleanly instead of
    // running, say, unzip's `--help`. Normal extraction still works (proving the
    // `--` doesn't break the happy path).
    func test_optionLikeEntryName_isNotTreatedAsAFlag() throws {
        let zip = try makeZip()
        XCTAssertThrowsError(try ArchiveCatalog.extractEntry(named: "--help", from: zip),
                             "an option-like entry name must error, not run unzip --help")
        XCTAssertThrowsError(try ArchiveCatalog.zipEntryBytes(named: "--version", fromZipAt: zip))
        let ok = try ArchiveCatalog.extractEntry(named: "a.txt", from: zip)
        defer { try? FileManager.default.removeItem(at: ok.deletingLastPathComponent()) }
        XCTAssertEqual(try String(contentsOf: ok, encoding: .utf8), "hello zip")
    }

    func test_tarGz_list_and_extract() throws {
        let tgz = try makeTarGz()
        let (entries, _) = try ArchiveCatalog.list(tgz)
        XCTAssertTrue(entries.contains { $0.name == "a.txt" })
        let extracted = try ArchiveCatalog.extractEntry(named: "a.txt", from: tgz)
        defer { try? FileManager.default.removeItem(
            at: extracted.deletingLastPathComponent()) }
        XCTAssertEqual(try String(contentsOf: extracted, encoding: .utf8), "hello zip")
    }

    /// The zip-slip class: a hostile `../…` entry name must not let the
    /// extraction write outside our temp dir — structurally impossible
    /// here (stdout pipe + app-chosen destination), pinned anyway.
    func test_hostileEntryName_cannotEscape_andLeafSanitizes() throws {
        // Build a zip CONTAINING a ../-prefixed name: zip normally refuses,
        // so simulate at the two seams we own: (1) the sanitizer, (2) an
        // extraction attempt with a hostile NAME against a real archive —
        // the tool simply finds no such member (non-zero exit → throw),
        // and nothing is written anywhere.
        XCTAssertEqual(ArchiveCatalog.sanitizedLeaf(of: "../../etc/passwd"), "passwd")
        XCTAssertEqual(ArchiveCatalog.sanitizedLeaf(of: "..\\..\\evil"), "_.._evil",
                       "backslashes neutralized")
        XCTAssertEqual(ArchiveCatalog.sanitizedLeaf(of: "..."), "entry")
        XCTAssertEqual(ArchiveCatalog.sanitizedLeaf(of: "dir/.hidden"), "hidden",
                       "leading dots stripped — no surprise dotfiles")

        let zip = try makeZip()
        XCTAssertThrowsError(
            try ArchiveCatalog.extractEntry(named: "../../etc/passwd", from: zip)
        ) { err in
            guard case ArchiveCatalog.ArchiveError.toolFailed = err else {
                return XCTFail("expected toolFailed for a missing member, got \(err)")
            }
        }
    }

    func test_unsupportedKind_throws() {
        XCTAssertThrowsError(
            try ArchiveCatalog.list(URL(fileURLWithPath: "/tmp/x.7z"))
        ) { err in
            XCTAssertEqual(err as? ArchiveCatalog.ArchiveError, .unsupportedKind)
        }
    }

    func test_unzipListParser_directly() {
        let sample = """
        Archive:  /tmp/fixture.zip
          Length      Date    Time    Name
        ---------  ---------- -----   ----
                9  06-12-2026 19:00   a.txt
                0  06-12-2026 19:00   sub/
               19  06-12-2026 19:00   sub/with space.md
        ---------                     -------
               28                     3 files
        """
        let entries = ArchiveCatalog.parseUnzipList(sample)
        XCTAssertEqual(entries.count, 3, "header/footer rows must not parse as entries")
        XCTAssertEqual(entries.first?.name, "a.txt")
        XCTAssertEqual(entries.first?.sizeBytes, 9)
        XCTAssertEqual(entries.last?.name, "sub/with space.md")
    }
}
