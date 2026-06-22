import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Host coverage for the Edit ▸ Transformations MODEL wiring (TSK-1113):
/// `makeActiveFileUpperCase()` / `makeActiveFileLowerCase()` /
/// `capitalizeActiveFile()`. The underlying `TextTransform` engine is pinned by
/// `TextTransformTests`, and the menu UI is render (VM/owner) — but the
/// DocumentModel methods that the menu items invoke (the
/// `applyTextTransformToActiveFile` write-through-to-disk path) had NO host
/// coverage. These pin that wiring: an active text file's bytes on disk become
/// the transformed form, the call reports success, and the no-op / no-active-file
/// contracts (return false, leave disk untouched) hold. A logic regression in the
/// model layer (wrong transform routed, write skipped, no-op misreported) fails
/// here on the host gate even though the menu pixels are VM-only.
@MainActor
final class DocumentModelTextTransformTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentModelTextTransformTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DocumentModelTextTransformTests-\(UUID().uuidString)"
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

    // MARK: - Uppercase

    func test_makeActiveFileUpperCase_writesUppercasedToDisk_andReturnsTrue() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "abc\ndef ghi\n")
        model.open(url: url)
        XCTAssertTrue(model.makeActiveFileUpperCase(),
            "uppercasing changed content must report success")
        XCTAssertEqual(diskContents(url), "ABC\nDEF GHI\n",
            "the active file's bytes on disk must be uppercased")
    }

    // MARK: - Lowercase

    func test_makeActiveFileLowerCase_writesLowercasedToDisk_andReturnsTrue() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "ABC\nDeF GhI\n")
        model.open(url: url)
        XCTAssertTrue(model.makeActiveFileLowerCase())
        XCTAssertEqual(diskContents(url), "abc\ndef ghi\n")
    }

    // MARK: - Capitalize

    func test_capitalizeActiveFile_capitalizesEachWord_andReturnsTrue() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "hello world\nfoo bar\n")
        model.open(url: url)
        XCTAssertTrue(model.capitalizeActiveFile())
        XCTAssertEqual(diskContents(url), "Hello World\nFoo Bar\n",
            "capitalize must title-case each word (Foundation .capitalized parity)")
    }

    // MARK: - No-op contract

    func test_transform_isNoOp_whenAlreadyInTargetForm_returnsFalse_andLeavesDiskUntouched() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "ABC\nDEF\n")
        model.open(url: url)
        XCTAssertFalse(model.makeActiveFileUpperCase(),
            "already-uppercase content is a no-op → false (no spurious save/dirty)")
        XCTAssertEqual(diskContents(url), "ABC\nDEF\n", "no-op must not rewrite the file")
    }

    // MARK: - No active file contract

    func test_transform_returnsFalse_whenNoActiveTextFile() {
        let model = makeModel()
        XCTAssertFalse(model.makeActiveFileUpperCase(),
            "no active text file → the transform is a no-op (false)")
        XCTAssertFalse(model.makeActiveFileLowerCase())
        XCTAssertFalse(model.capitalizeActiveFile())
    }

    // MARK: - Independence (each routes its own transform)

    func test_eachMethodRoutesItsOwnTransform() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "MiXeD case\n")
        model.open(url: url)
        XCTAssertTrue(model.makeActiveFileLowerCase())
        XCTAssertEqual(diskContents(url), "mixed case\n")
        // Re-open the now-lowercased file and uppercase it — proves the upper
        // path routes uppercase, not a stale closure from the prior call.
        model.open(url: url)
        XCTAssertTrue(model.makeActiveFileUpperCase())
        XCTAssertEqual(diskContents(url), "MIXED CASE\n")
    }
}
