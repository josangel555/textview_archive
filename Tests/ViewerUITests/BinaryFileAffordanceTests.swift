import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-605 / TSK-606: the binary-file affordance contract.
///
/// 605 — a binary file (e.g. `mydb.db.bak`, a SQLite backup with a
/// non-.db extension) must offer the type dropdown: the chip mounts for
/// any URL, `openAsCategories` is universal, the magic-byte sniff floats
/// SQLite to the front, and forcing the override routes to the SQLite
/// preview lens.
///
/// 606 — a true binary (bytes don't decode as text) must NOT offer the
/// Source/Editor lens: `availableViewModes == [.hex]` and the toolbar's
/// Editor/Render primaries hide.
///
/// Both behaviors exist in the current model; these tests pin them as
/// regression guards (the owner reports came from an earlier build).
@MainActor
final class BinaryFileAffordanceTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BinaryAffordance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "BinaryAffordance-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await super.tearDown()
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            bookmarks: BookmarksStore(storeURL: tmpDir.appendingPathComponent("bookmarks.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    /// A minimal real SQLite database file (header magic + 4KB page),
    /// written under a non-.db extension so only the SNIFF can identify it.
    private func writeSQLiteBackup(named name: String) throws -> URL {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let magic = Array("SQLite format 3\0".utf8)
        bytes.replaceSubrange(0..<magic.count, with: magic)
        bytes[16] = 0x10; bytes[17] = 0x00  // page size 4096
        let url = tmpDir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// True binary garbage (NUL-laden, never decodes as text).
    private func writeBinaryGarbage(named name: String) throws -> URL {
        var bytes: [UInt8] = []
        for i in 0..<2048 { bytes.append(UInt8((i &* 37) % 256)) }
        bytes[0] = 0x00; bytes[1] = 0xFF
        let url = tmpDir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: - TSK-606: no Source lens for true binary

    func test_binaryFile_offersHexOnly_noSourceOrRenderPrimary() throws {
        let url = try writeBinaryGarbage(named: "blob.bak")
        let m = makeModel()
        m.open(url: url)

        XCTAssertEqual(m.availableViewModes, [.hex],
                       "a true binary offers only the HEX lens")
        XCTAssertFalse(m.showsEditorPrimary,
                       "no Source/Editor button for a true binary (TSK-606)")
        XCTAssertFalse(m.showsRenderPrimary,
                       "no Render button for a true binary")
    }

    // MARK: - TSK-605: type dropdown reachable + SQLite sniff + override routing

    func test_binaryFile_typeChipMountGate_holds() throws {
        let url = try writeBinaryGarbage(named: "blob.bak")
        let m = makeModel()
        m.open(url: url)
        // The chip (BottomAttributesBar.TypeControlMenu) mounts whenever
        // currentURL is non-nil — pin that gate for the binary case.
        XCTAssertNotNil(m.currentURL,
                        "binary tab must keep a currentURL so the type chip mounts")
        XCTAssertTrue(m.openAsCategories(for: url).contains(.sqlite),
                      "the universal Open-As menu must include SQLite")
    }

    func test_sqliteBackup_sniffFloatsSQLiteFirst() throws {
        let url = try writeSQLiteBackup(named: "mydb.db.bak")
        let m = makeModel()
        XCTAssertEqual(m.openAsCategories(for: url).first, .sqlite,
                       "magic-byte sniff must float SQLite to the front "
                       + "for a SQLite backup with a non-.db extension")
    }

    func test_sqliteOverride_routesToPreviewLens() throws {
        let url = try writeSQLiteBackup(named: "mydb.db.bak")
        let m = makeModel()
        m.open(url: url)
        m.setCurrentCategoryOverride(.sqlite)

        XCTAssertEqual(m.currentCategory, .sqlite,
                       "the override must stick as the effective category")
        XCTAssertEqual(m.availableViewModes, [.preview, .hex],
                       "forcing SQLite must offer the native preview lens "
                       + "(the SQLite browser) plus HEX")
        XCTAssertEqual(m.currentViewMode, .preview,
                       "the override re-opens into the SQLite preview")
    }
}
