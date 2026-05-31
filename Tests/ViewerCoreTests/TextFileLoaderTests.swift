import XCTest
@testable import ViewerCore

final class TextFileLoaderTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownViewerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeFile(_ name: String, _ contents: String, encoding: String.Encoding = .utf8) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: encoding)
        return url
    }

    private func writeBytes(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func test_loadsUTF8File() throws {
        let url = try writeFile("hello.txt", "hello, world\n")
        let file = try TextFileLoader().load(url: url)
        XCTAssertEqual(file.contents, "hello, world\n")
        XCTAssertEqual(file.encoding, .utf8)
        XCTAssertEqual(file.byteCount, 13)
        XCTAssertEqual(file.url, url)
    }

    func test_loadsEmptyFile() throws {
        let url = try writeFile("empty.txt", "")
        let file = try TextFileLoader().load(url: url)
        XCTAssertEqual(file.contents, "")
        XCTAssertEqual(file.byteCount, 0)
    }

    func test_throwsOnMissingFile() {
        let url = tmpDir.appendingPathComponent("nope.txt")
        XCTAssertThrowsError(try TextFileLoader().load(url: url)) { error in
            XCTAssertEqual(error as? FileLoadError, .fileNotFound)
        }
    }

    func test_fallsBackToWindowsCP1252() throws {
        // 0xC3 0x28 is invalid UTF-8. Both bytes are defined in
        // Windows-1252, so I18N-01 now reports CP1252 (the superset of
        // Latin-1 that decodes the smart-quote / em-dash bytes Windows
        // text actually uses). 0xC3 maps to Ã in both, so the decoded
        // text is unchanged — only the surfaced encoding is more accurate.
        let url = try writeBytes("cp1252.txt", [0xC3, 0x28])
        let file = try TextFileLoader().load(url: url)
        XCTAssertEqual(file.encoding, .windowsCP1252)
        XCTAssertEqual(file.contents, "Ã(")
    }

    func test_fallsBackToLatin1_forCP1252UndefinedByte() throws {
        // 0x81 is undefined in CP1252, so String(.windowsCP1252) fails
        // and the total Latin-1 fallback catches it (I18N-01 keeps the
        // Latin-1 backstop).
        let url = try writeBytes("latin.txt", [0x41, 0x81, 0x42])
        let file = try TextFileLoader().load(url: url)
        XCTAssertEqual(file.encoding, .isoLatin1)
    }

    func test_rejectsOversizedFile() throws {
        let url = try writeFile("big.txt", String(repeating: "x", count: 100))
        let loader = TextFileLoader(maxBytes: 10)
        XCTAssertThrowsError(try loader.load(url: url)) { error in
            guard case .tooLarge(let bytes, let ceiling) = error as? FileLoadError else {
                return XCTFail("expected .tooLarge, got \(error)")
            }
            XCTAssertEqual(bytes, 100)
            XCTAssertEqual(ceiling, 10, "ceiling must report the loader's read limit")
        }
    }

    // MARK: B4 — UTF-16 BOM detection

    func test_loadsUTF16LE_withBOM() throws {
        let bom: [UInt8] = [0xFF, 0xFE]
        // "hi" in UTF-16-LE: h = 0x68, 0x00, i = 0x69, 0x00
        let body: [UInt8] = [0x68, 0x00, 0x69, 0x00]
        let url = try writeBytes("u16le.txt", bom + body)
        let file = try TextFileLoader().load(url: url)
        XCTAssertEqual(file.contents, "hi")
        XCTAssertEqual(file.encoding, .utf16LittleEndian)
    }

    func test_loadsUTF16BE_withBOM() throws {
        let bom: [UInt8] = [0xFE, 0xFF]
        let body: [UInt8] = [0x00, 0x68, 0x00, 0x69]
        let url = try writeBytes("u16be.txt", bom + body)
        let file = try TextFileLoader().load(url: url)
        XCTAssertEqual(file.contents, "hi")
        XCTAssertEqual(file.encoding, .utf16BigEndian)
    }

    func test_loadsUTF8_withBOM() throws {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let body = Array("héllo".utf8)
        let url = try writeBytes("u8bom.txt", bom + body)
        let file = try TextFileLoader().load(url: url)
        XCTAssertEqual(file.contents, "héllo")
        XCTAssertEqual(file.encoding, .utf8)
    }

    // MARK: B5 — binary blob guard

    func test_binaryFile_isRejected() throws {
        let bytes: [UInt8] = [0x7F, 0x45, 0x4C, 0x46, 0x00, 0x01, 0x00, 0x00] // ELF-like
        let url = try writeBytes("binary.bin", bytes)
        XCTAssertThrowsError(try TextFileLoader().load(url: url)) { error in
            XCTAssertEqual(error as? FileLoadError, .binaryFile)
        }
    }

    func test_textFileWithoutNUL_loadsCleanly() throws {
        let url = try writeFile("clean.txt", "no NULs here, just text\n")
        XCTAssertNoThrow(try TextFileLoader().load(url: url))
    }

    func test_binaryGuard_onlySamplesFirst8KB() throws {
        // 8 KB of clean text + a NUL way past the sample boundary -> still accepted
        // (we trade some false negatives for fast, allocation-free sniffing).
        let prefix = String(repeating: "a", count: 9000)
        let url = try writeBytes("late-nul.txt", Array(prefix.utf8) + [0x00])
        XCTAssertNoThrow(try TextFileLoader().load(url: url))
    }

    // MARK: - Two-tier read cap (large-file read-only)

    /// Set a file's on-disk size to `size` WITHOUT writing the bytes,
    /// using a sparse truncate. APFS reports the logical size from stat
    /// while allocating ~nothing on disk, so we can exercise the ceiling
    /// gate (which checks size BEFORE reading) without a 512 MB write.
    /// The bytes that ARE read back (for files below the ceiling) are
    /// NUL — fine for the size-tag tests, which assert on the flag, not
    /// the contents. Encoding-decode tests write real bytes instead.
    private func makeSparseFile(_ name: String, size: Int) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
        return url
    }

    /// A file just above the OLD 32 MiB cap now LOADS (the new default
    /// ceiling is 512 MiB). It also lands above the 64 MiB watermark? No
    /// — 33 MB is below 64 MiB, so it loads but is NOT tagged large.
    func test_fileAboveOld32MBCap_nowLoads() throws {
        // 33 MiB — above the retired 32 MiB gate, below the 64 MiB soft
        // watermark. A sparse NUL file would trip the binary guard, so
        // write real text: a single 'a' repeated. Writing 33 MiB to a
        // temp dir is cheap and avoids the binary-sniff NUL false-fail.
        let bytes = 33 * 1024 * 1024
        let url = try writeFile("just-over-32.txt", String(repeating: "a", count: bytes))
        let file = try TextFileLoader().load(url: url)
        XCTAssertEqual(file.byteCount, bytes)
        XCTAssertFalse(file.isLargeReadOnly,
            "33 MiB is below the 64 MiB soft watermark — must not be tagged large")
    }

    /// A file above the soft watermark loads AND is tagged
    /// `isLargeReadOnly` so the view layer degrades gracefully.
    func test_fileAboveSoftWarn_loadsAndIsTaggedLarge() throws {
        // 65 MiB of real text — above the 64 MiB watermark, below the
        // 512 MiB ceiling. Use a small custom watermark to keep the test
        // cheap rather than writing 65 MB: a 1 KiB watermark with a 2 KiB
        // file proves the tagging boundary without a big write.
        let url = try writeFile("over-warn.txt", String(repeating: "b", count: 2048))
        let loader = TextFileLoader(readableMaxBytes: 512 * 1024 * 1024, softWarnBytes: 1024)
        let file = try loader.load(url: url)
        XCTAssertEqual(file.byteCount, 2048)
        XCTAssertTrue(file.isLargeReadOnly,
            "2 KiB > 1 KiB watermark — must be tagged large")
    }

    /// A file at/below the soft watermark is NOT tagged large.
    func test_fileBelowSoftWarn_notTaggedLarge() throws {
        let url = try writeFile("under-warn.txt", String(repeating: "c", count: 512))
        let loader = TextFileLoader(readableMaxBytes: 512 * 1024 * 1024, softWarnBytes: 1024)
        let file = try loader.load(url: url)
        XCTAssertFalse(file.isLargeReadOnly,
            "512 B < 1 KiB watermark — must not be tagged large")
    }

    /// A file above the HARD ceiling still throws `.tooLarge`, carrying
    /// the ceiling. Uses a sparse truncate so we set a >ceiling stat size
    /// without allocating/writing the bytes — the loader checks size
    /// BEFORE reading, so this stays fast and disk-cheap. (If the loader
    /// were ever reordered to read-before-stat, this would try to
    /// allocate the full size — keep the stat-first ordering.)
    func test_fileAboveCeiling_throwsTooLarge_withCeiling() throws {
        let ceiling = 4 * 1024 * 1024 // 4 MiB test ceiling
        let url = try makeSparseFile("over-ceiling.bin", size: ceiling + 1)
        let loader = TextFileLoader(readableMaxBytes: ceiling, softWarnBytes: 1024)
        XCTAssertThrowsError(try loader.load(url: url)) { error in
            guard case .tooLarge(let bytes, let reportedCeiling) = error as? FileLoadError else {
                return XCTFail("expected .tooLarge, got \(error)")
            }
            XCTAssertEqual(bytes, ceiling + 1)
            XCTAssertEqual(reportedCeiling, ceiling)
        }
    }

    /// Back-compat: `TextFileLoader(maxBytes:)` still works and maps to
    /// the hard read ceiling. The soft watermark is clamped to never
    /// exceed the ceiling.
    func test_backCompatMaxBytesInit_mapsToCeiling() throws {
        let loader = TextFileLoader(maxBytes: 100)
        XCTAssertEqual(loader.readableMaxBytes, 100)
        XCTAssertEqual(loader.maxBytes, 100)
        XCTAssertLessThanOrEqual(loader.softWarnBytes, 100,
            "soft watermark must not exceed a smaller-than-default ceiling")
    }

    // MARK: - Encoding regressions at the (small custom) watermark

    /// UTF-16 LE with BOM still decodes correctly and is tagged large
    /// when above the watermark. Regression guard: the BOM sniff runs on
    /// the full Data before String decode, and the large-flag is derived
    /// from data.count — verify both agree on the BOM path.
    func test_utf16LE_BOM_decodesAndTagsLarge() throws {
        let bom: [UInt8] = [0xFF, 0xFE]
        // "hi" repeated to push byteCount above a tiny watermark.
        var body: [UInt8] = []
        for _ in 0..<64 { body += [0x68, 0x00, 0x69, 0x00] } // "hi" x 64
        let url = try writeBytes("u16le-large.txt", bom + body)
        let loader = TextFileLoader(readableMaxBytes: 512 * 1024 * 1024, softWarnBytes: 16)
        let file = try loader.load(url: url)
        XCTAssertEqual(file.encoding, .utf16LittleEndian)
        XCTAssertEqual(file.contents, String(repeating: "hi", count: 64))
        XCTAssertTrue(file.isLargeReadOnly)
    }

    /// BOM-less UTF-16 LE still decodes (via the NUL-parity heuristic)
    /// and is tagged large above the watermark.
    func test_utf16NoBOM_decodesAndTagsLarge() throws {
        // ASCII-heavy UTF-16 LE without a BOM: NUL at every odd index.
        var body: [UInt8] = []
        for _ in 0..<64 { body += [0x41, 0x00] } // 'A' x 64
        let url = try writeBytes("u16nobom-large.txt", body)
        let loader = TextFileLoader(readableMaxBytes: 512 * 1024 * 1024, softWarnBytes: 16)
        let file = try loader.load(url: url)
        XCTAssertEqual(file.encoding, .utf16LittleEndian)
        XCTAssertEqual(file.contents, String(repeating: "A", count: 64))
        XCTAssertTrue(file.isLargeReadOnly)
    }

    /// Latin-1 fallback still decodes and is tagged large above the
    /// watermark.
    func test_latin1_decodesAndTagsLarge() throws {
        // 0x81 is invalid UTF-8 AND undefined in CP1252 (so the audited
        // CP1252-before-Latin1 ladder falls through to the Latin-1 last
        // resort) but valid Latin-1; repeat to clear a tiny watermark.
        let url = try writeBytes("latin-large.txt", Array(repeating: [0x81, 0x28], count: 64).flatMap { $0 })
        let loader = TextFileLoader(readableMaxBytes: 512 * 1024 * 1024, softWarnBytes: 16)
        let file = try loader.load(url: url)
        XCTAssertEqual(file.encoding, .isoLatin1)
        XCTAssertTrue(file.isLargeReadOnly)
    }

    /// `isLargeReadOnly` must NOT participate in TextFile equality
    /// (mirrors `modifiedTime`). Two same-(url,byteCount,encoding) files
    /// that disagree on the flag still compare equal so SwiftUI diffing
    /// doesn't churn. Guards the DocumentState.== dedup path.
    func test_isLargeReadOnly_notPartOfEquality() {
        let url = URL(fileURLWithPath: "/tmp/x.txt")
        let small = TextFile(url: url, contents: "x", encoding: .utf8,
                             byteCount: 1, isLargeReadOnly: false)
        let large = TextFile(url: url, contents: "x", encoding: .utf8,
                             byteCount: 1, isLargeReadOnly: true)
        XCTAssertEqual(small, large,
            "isLargeReadOnly is a derived signal, not an identity field")
    }
}
