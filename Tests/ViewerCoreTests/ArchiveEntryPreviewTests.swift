import XCTest
@testable import ViewerCore

/// TSK-1469 — the archive entry → inline-preview classification.
final class ArchiveEntryPreviewTests: XCTestCase {

    func test_utf8Text_previewsAsText() {
        let p = ArchiveEntryPreview.classify(
            name: "README.md", bytes: Data("# Hello\nworld".utf8))
        XCTAssertEqual(p, .text("# Hello\nworld", truncated: false))
    }

    func test_png_sniffedByMagicBytes_evenWithLyingName() {
        // The name says .txt; the bytes say PNG — bytes win.
        var bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        bytes.append(Data(repeating: 0xAB, count: 64))
        let p = ArchiveEntryPreview.classify(name: "sneaky.txt", bytes: bytes)
        XCTAssertEqual(p, .image(bytes, format: .png))
    }

    func test_jpegAndGif_sniffed() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 1, count: 16)
        XCTAssertEqual(ArchiveEntryPreview.classify(name: "a", bytes: jpeg),
                       .image(jpeg, format: .jpeg))
        let gif = Data("GIF89a".utf8) + Data(repeating: 2, count: 16)
        XCTAssertEqual(ArchiveEntryPreview.classify(name: "b", bytes: gif),
                       .image(gif, format: .gif))
    }

    func test_binaryBytes_classifyAsBinary_notMojibakeText() {
        // NUL-laden bytes must never render as garbage text.
        let bytes = Data([0x00, 0x01, 0x02, 0x00, 0xFE, 0x00, 0x10, 0x00])
        let p = ArchiveEntryPreview.classify(name: "blob.bin", bytes: bytes)
        XCTAssertEqual(p, .binary(byteCount: 8))
    }

    func test_overCap_withoutBytes_isTooBig() {
        let p = ArchiveEntryPreview.classify(
            name: "huge.log", bytes: Data(), fullSize: 50_000_000)
        XCTAssertEqual(p, .tooBig(byteCount: 50_000_000))
    }

    func test_overCap_withTextPrefix_isTruncatedTextPeek() {
        // A 50 MB log still gets a text PEEK from its prefix bytes.
        let head = String(repeating: "log line\n", count: 10)
        let p = ArchiveEntryPreview.classify(
            name: "huge.log", bytes: Data(head.utf8), fullSize: 50_000_000)
        XCTAssertEqual(p, .text(head, truncated: true))
    }

    func test_overCap_image_isTooBig_notInlined() {
        var bytes = Data([0x89, 0x50, 0x4E, 0x47])
        bytes.append(Data(repeating: 0, count: 32))
        let p = ArchiveEntryPreview.classify(
            name: "poster.png", bytes: bytes, fullSize: 30_000_000)
        XCTAssertEqual(p, .tooBig(byteCount: 30_000_000))
    }

    func test_tornUTF8Prefix_trimsTheTornTail() {
        // "héllo" cut mid-é: the torn continuation byte is trimmed, not fatal.
        var bytes = Data("abc".utf8)
        bytes.append(0xC3)  // first byte of a 2-byte sequence, tail missing
        let p = ArchiveEntryPreview.classify(
            name: "cut.txt", bytes: bytes, fullSize: 10_000_000)
        XCTAssertEqual(p, .text("abc", truncated: true))
    }

    func test_corruptArchiveError_mapsToUnreadable() {
        struct Boom: LocalizedError {
            var errorDescription: String? { "unzip exited 9: bad zipfile" }
        }
        let p = ArchiveEntryPreview.failed(Boom())
        XCTAssertEqual(p, .unreadable(reason: "unzip exited 9: bad zipfile"))
    }

    func test_realZipFixture_endToEnd_textAndCorrupt() throws {
        // End-to-end on a REAL zip via the hardened catalog pipe: list →
        // bytes → classify; and a corrupt zip surfaces .unreadable, no crash.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-1469-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inner = dir.appendingPathComponent("hello.txt")
        try "zip payload ✓".write(to: inner, atomically: true, encoding: .utf8)
        let zip = dir.appendingPathComponent("t.zip")
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        make.currentDirectoryURL = dir
        make.arguments = ["-q", "-j", zip.path, inner.path]
        try make.run()
        make.waitUntilExit()
        guard make.terminationStatus == 0 else {
            throw XCTSkip("zip tool unavailable")
        }

        let bytes = try ArchiveCatalog.zipEntryBytes(named: "hello.txt", fromZipAt: zip)
        XCTAssertEqual(ArchiveEntryPreview.classify(name: "hello.txt", bytes: bytes),
                       .text("zip payload ✓", truncated: false))

        // Corrupt: truncate the zip and expect a mapped .unreadable.
        let corrupt = dir.appendingPathComponent("corrupt.zip")
        let zipData = try Data(contentsOf: zip)
        try zipData.prefix(20).write(to: corrupt)
        do {
            _ = try ArchiveCatalog.zipEntryBytes(named: "hello.txt", fromZipAt: corrupt)
            XCTFail("corrupt zip must throw")
        } catch {
            guard case .unreadable = ArchiveEntryPreview.failed(error) else {
                return XCTFail("corrupt zip must map to .unreadable")
            }
        }
    }

    // MARK: - previewPlan (TSK-1469 preview-on-select extraction gate)

    func test_previewPlan_skipsHugeEntries_withoutExtracting() {
        let big = ArchiveEntryPreview.previewCap + 1
        XCTAssertEqual(
            ArchiveEntryPreview.previewPlan(sizeBytes: big, isDirectory: false),
            .skip(.tooBig(byteCount: big)),
            "an entry known to exceed the cap must never be extracted to peek")
    }

    func test_previewPlan_readsWithinCap_andUnknownSize() {
        XCTAssertEqual(
            ArchiveEntryPreview.previewPlan(sizeBytes: 1024, isDirectory: false), .read)
        XCTAssertEqual(
            ArchiveEntryPreview.previewPlan(sizeBytes: nil, isDirectory: false), .read,
            "unknown size → read; the byte-level cap in classify still protects us")
        XCTAssertEqual(
            ArchiveEntryPreview.previewPlan(
                sizeBytes: ArchiveEntryPreview.previewCap, isDirectory: false), .read,
            "exactly at the cap still reads")
    }

    func test_previewPlan_directory_isSkipped() {
        guard case .skip(.unreadable) = ArchiveEntryPreview.previewPlan(
            sizeBytes: 0, isDirectory: true) else {
            return XCTFail("a directory entry has no byte preview")
        }
    }
}
