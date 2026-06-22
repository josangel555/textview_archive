import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Host coverage for the Edit ▸ Lines MODEL wiring (TSK-1224, sibling of the
/// TSK-1113 case-transform coverage): `sortActiveFileLines(ascending:)`,
/// `reverseActiveFileLines`, `removeDuplicateActiveFileLines`,
/// `removeEmptyActiveFileLines`, `collapseBlankActiveFileLines`. The `LineOps`
/// engine is pinned by its own tests and the AppKit menu items are render — but
/// the DocumentModel methods the menu invokes (the `applyTextTransformToActiveFile`
/// write-through-to-disk path) had NO host coverage. These pin that wiring with
/// teeth: an active file's bytes on disk become the LineOps-transformed form,
/// success is reported, and the no-op / no-active-file contracts (false, disk
/// untouched) hold. A model-layer regression (wrong op routed, write skipped,
/// no-op misreported) fails the host gate even though the menu pixels are VM-only.
@MainActor
final class DocumentModelLineOpsTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentModelLineOpsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DocumentModelLineOpsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func diskContents(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Sort

    func test_sortActiveFileLines_ascending_sortsOnDisk_andReturnsTrue() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "c\na\nb\n")
        model.open(url: url)
        XCTAssertTrue(model.sortActiveFileLines(ascending: true))
        XCTAssertEqual(diskContents(url), "a\nb\nc\n")
    }

    func test_sortActiveFileLines_descending_sortsDescending() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "a\nb\nc\n")
        model.open(url: url)
        XCTAssertTrue(model.sortActiveFileLines(ascending: false))
        XCTAssertEqual(diskContents(url), "c\nb\na\n")
    }

    // MARK: - Reverse

    func test_reverseActiveFileLines_reversesLineOrder() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "x\ny\nz\n")
        model.open(url: url)
        XCTAssertTrue(model.reverseActiveFileLines())
        XCTAssertEqual(diskContents(url), "z\ny\nx\n")
    }

    // MARK: - Remove duplicates

    func test_removeDuplicateActiveFileLines_keepsFirstOccurrence_preservesOrder() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "a\na\nb\na\n")
        model.open(url: url)
        XCTAssertTrue(model.removeDuplicateActiveFileLines())
        XCTAssertEqual(diskContents(url), "a\nb\n")
    }

    // MARK: - Remove empty (incl. whitespace-only)

    func test_removeEmptyActiveFileLines_dropsBlankAndWhitespaceOnly() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "a\n  \nb\n")
        model.open(url: url)
        XCTAssertTrue(model.removeEmptyActiveFileLines())
        XCTAssertEqual(diskContents(url), "a\nb\n",
            "whitespace-only lines are blank → removed")
    }

    // MARK: - Collapse blank runs

    func test_collapseBlankActiveFileLines_collapsesRunsToSingleBlank() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "a\n\n\n\nb\n")
        model.open(url: url)
        XCTAssertTrue(model.collapseBlankActiveFileLines())
        XCTAssertEqual(diskContents(url), "a\n\nb\n",
            "a run of 2+ blank lines collapses to exactly one")
    }

    // MARK: - No-op contract

    func test_lineOp_isNoOp_whenContentUnchanged_returnsFalse_andLeavesDiskUntouched() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "a\nb\nc\n")
        model.open(url: url)
        XCTAssertFalse(model.sortActiveFileLines(ascending: true),
            "already-sorted content is a no-op → false (no spurious save)")
        XCTAssertEqual(diskContents(url), "a\nb\nc\n", "no-op must not rewrite the file")
    }

    // MARK: - No active file contract

    func test_lineOps_returnFalse_whenNoActiveTextFile() {
        let model = makeModel()
        XCTAssertFalse(model.sortActiveFileLines(ascending: true))
        XCTAssertFalse(model.reverseActiveFileLines())
        XCTAssertFalse(model.removeDuplicateActiveFileLines())
        XCTAssertFalse(model.removeEmptyActiveFileLines())
        XCTAssertFalse(model.collapseBlankActiveFileLines())
    }

    // MARK: - CRLF preservation (terminator-aware wiring)

    func test_sortActiveFileLines_preservesCRLFTerminator() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "c\r\na\r\nb\r\n")
        model.open(url: url)
        XCTAssertTrue(model.sortActiveFileLines(ascending: true))
        XCTAssertEqual(diskContents(url), "a\r\nb\r\nc\r\n",
            "the file's dominant CRLF ending is preserved by the transform")
    }
}
