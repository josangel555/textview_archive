import XCTest
@testable import ViewerCore
import ViewerKit

/// WAVE 2b item 6 — universal "Open As…". Host-safe (pure data + FS
/// scratch under the per-user tmpdir, no UI). Pins:
///   - `TabSnapshot.categoryOverride` round-trips AND is downgrade-safe
///     (a legacy JSON with no key decodes to nil = auto-detect).
///   - `DocumentController.open(forcedCategory:)` forces the chosen
///     viewer for ANY file, including a binary opened as text / sqlite.
///   - `TextFileLoader.load(forceText:)` decodes NUL-heavy bytes instead
///     of throwing `.binaryFile`.
///   - `ViewModeOptions` forced-category mode lists.
final class OpenAsCategoryOverrideTests: XCTestCase {

    // MARK: - TabSnapshot persistence

    func test_tabSnapshot_categoryOverride_roundTrips() throws {
        let snap = TabSnapshot(path: "/tmp/x.db", viewMode: "source",
                               categoryOverride: FileCategory.sqlite.rawValue)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(TabSnapshot.self, from: data)
        XCTAssertEqual(back, snap)
        XCTAssertEqual(back.categoryOverride, "sqlite")
    }

    func test_tabSnapshot_legacyJSON_withoutKey_decodesToNil() throws {
        // A pre-WAVE-2b on-disk tab has no `categoryOverride` key. The
        // synthesized optional must decode to nil (downgrade guard), not
        // throw — otherwise an old session file fails to restore.
        let legacy = #"{"path":"/tmp/a.md","viewMode":"rendered"}"#
        let snap = try JSONDecoder().decode(
            TabSnapshot.self, from: Data(legacy.utf8))
        XCTAssertEqual(snap.path, "/tmp/a.md")
        XCTAssertNil(snap.categoryOverride, "missing key → nil = auto-detect")
    }

    func test_tabSnapshot_nilOverride_omitsOrNullsKey() throws {
        // nil should not break round-trip either.
        let snap = TabSnapshot(path: "/tmp/a.md", viewMode: "rendered")
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(TabSnapshot.self, from: data)
        XCTAssertNil(back.categoryOverride)
    }

    // MARK: - Forced-category open

    private func writeScratch(_ name: String, bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenAsTests-\(UUID().uuidString)-\(name)")
        try Data(bytes).write(to: url)
        return url
    }

    func test_open_binary_forcedAsText_loadsAsText_notHex() throws {
        // A NUL-heavy "binary" blob. Auto-detect → .binary (HEX); forced
        // .plainText → .loaded (text), proving "Open As… text" on a binary.
        let bytes: [UInt8] = [0x68, 0x69, 0x00, 0x00, 0x01, 0x02, 0x6F, 0x6B]
        let url = try writeScratch("blob.bin", bytes: bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let ctl = DocumentController()

        // Auto-detect routes a NUL-heavy blob to .binary.
        if case .binary = ctl.open(url: url) {} else {
            XCTFail("expected auto-detect to be .binary")
        }
        // Forced text → .loaded.
        guard case .loaded(let file) = ctl.open(url: url, forcedCategory: .plainText) else {
            return XCTFail("expected forced .plainText to load as text")
        }
        XCTAssertEqual(file.byteCount, bytes.count)
    }

    func test_open_anyFile_forcedAsSQLite_isPreview() throws {
        // A plain text file forced to SQLite → .preview(.sqlite), so the
        // SQLite viewer (which reads the URL) takes over.
        let url = try writeScratch("data.txt", bytes: Array("name,age\nA,1\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let ctl = DocumentController()
        guard case .preview(_, let cat) = ctl.open(url: url, forcedCategory: .sqlite) else {
            return XCTFail("expected forced .sqlite to be a .preview state")
        }
        XCTAssertEqual(cat, .sqlite)
    }

    func test_open_anyFile_forcedAsBinary_isHex() throws {
        let url = try writeScratch("note.md", bytes: Array("# hi\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let ctl = DocumentController()
        if case .binary = ctl.open(url: url, forcedCategory: .binary) {} else {
            XCTFail("expected forced .binary to be .binary (HEX)")
        }
    }

    func test_loader_forceText_decodesNulBytes() throws {
        let bytes: [UInt8] = [0x41, 0x00, 0x42, 0x00, 0x43]  // "A.B.C" with NULs
        let url = try writeScratch("nul.bin", bytes: bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        // Without forceText this throws .binaryFile.
        XCTAssertThrowsError(try TextFileLoader().load(url: url))
        // With forceText it decodes (Latin-1, lossless byte map).
        let file = try TextFileLoader().load(url: url, forceText: true)
        XCTAssertEqual(file.byteCount, bytes.count)
    }

    // MARK: - ViewModeOptions forced-category

    func test_availableModes_forcedSQLite_isHexOnly() {
        let url = URL(fileURLWithPath: "/tmp/x.txt")
        // SQLite renders via .preview; only HEX is a meaningful ViewMode.
        XCTAssertEqual(ViewModeOptions.availableModes(for: url, forcedCategory: .sqlite), [.hex])
        XCTAssertEqual(ViewModeOptions.defaultMode(for: url, forcedCategory: .sqlite), .hex)
    }

    func test_availableModes_forcedText_offersTableAndFormatted() {
        // A `.db` forced to plainText should still let the user pick
        // Table (CSV lens) + Formatted even though the extension isn't csv.
        let url = URL(fileURLWithPath: "/tmp/mydb.db")
        let modes = ViewModeOptions.availableModes(for: url, forcedCategory: .plainText)
        XCTAssertTrue(modes.contains(.source))
        XCTAssertTrue(modes.contains(.table))
        XCTAssertTrue(modes.contains(.formatted))
        XCTAssertTrue(modes.contains(.hex))
    }

    func test_availableModes_forcedMarkdown_offersRendered() {
        let url = URL(fileURLWithPath: "/tmp/x.bin")
        let modes = ViewModeOptions.availableModes(for: url, forcedCategory: .markdown)
        XCTAssertTrue(modes.contains(.rendered))
        XCTAssertEqual(ViewModeOptions.defaultMode(for: url, forcedCategory: .markdown), .rendered)
    }
}
