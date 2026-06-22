import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Host coverage for the whitespace-cleanup + line-ending MODEL wiring (TSK-1225,
/// completing the applyTextTransformToActiveFile-family trio with TSK-1113 /
/// TSK-1224): `trimTrailingWhitespaceInActiveFile`, `ensureFinalNewlineInActiveFile`,
/// `convertActiveFileLineEnding(to:)`. The TextCleanup / LineEndingConverter
/// engines are pinned by their own tests and the menu items are render — but the
/// DocumentModel methods the menu invokes (write-through-to-disk) had NO host
/// coverage. These pin that wiring with teeth: an active file's bytes on disk
/// become the cleaned/converted form, success is reported, the detected-ending
/// behavior holds (ensureFinalNewline uses the FILE's own ending), and the
/// no-op / no-active-file contracts (false, disk untouched) hold.
@MainActor
final class DocumentModelCleanupTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentModelCleanupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DocumentModelCleanupTests-\(UUID().uuidString)"
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

    // MARK: - Trim trailing whitespace

    func test_trimTrailingWhitespaceInActiveFile_stripsTrailingSpacesTabs_preservesTerminators() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "a  \nb\t\nc\n")
        model.open(url: url)
        XCTAssertTrue(model.trimTrailingWhitespaceInActiveFile())
        XCTAssertEqual(diskContents(url), "a\nb\nc\n")
    }

    func test_trimTrailingWhitespace_isNoOp_whenNothingTrailing_returnsFalse() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "abc\ndef\n")
        model.open(url: url)
        XCTAssertFalse(model.trimTrailingWhitespaceInActiveFile())
        XCTAssertEqual(diskContents(url), "abc\ndef\n")
    }

    // MARK: - Ensure final newline (uses the file's own ending)

    func test_ensureFinalNewlineInActiveFile_appendsLF_whenMissing() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "abc")
        model.open(url: url)
        XCTAssertTrue(model.ensureFinalNewlineInActiveFile())
        XCTAssertEqual(diskContents(url), "abc\n")
    }

    func test_ensureFinalNewlineInActiveFile_usesDetectedCRLF_onCRLFFile() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "a\r\nb")   // CRLF body, no final terminator
        model.open(url: url)
        XCTAssertTrue(model.ensureFinalNewlineInActiveFile())
        XCTAssertEqual(diskContents(url), "a\r\nb\r\n",
            "the appended terminator matches the file's detected CRLF ending")
    }

    func test_ensureFinalNewline_isNoOp_whenAlreadyTerminated_returnsFalse() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "abc\n")
        model.open(url: url)
        XCTAssertFalse(model.ensureFinalNewlineInActiveFile())
        XCTAssertEqual(diskContents(url), "abc\n")
    }

    // MARK: - Convert line ending

    func test_convertActiveFileLineEnding_toCRLF_rewritesTerminators() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "a\nb\nc\n")
        model.open(url: url)
        XCTAssertTrue(model.convertActiveFileLineEnding(to: .crlf))
        XCTAssertEqual(diskContents(url), "a\r\nb\r\nc\r\n")
    }

    func test_convertActiveFileLineEnding_toLF_fromCRLF() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "a\r\nb\r\nc\r\n")
        model.open(url: url)
        XCTAssertTrue(model.convertActiveFileLineEnding(to: .lf))
        XCTAssertEqual(diskContents(url), "a\nb\nc\n")
    }

    func test_convertActiveFileLineEnding_isNoOp_whenAlreadyTarget_returnsFalse() throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "a\nb\n")
        model.open(url: url)
        XCTAssertFalse(model.convertActiveFileLineEnding(to: .lf),
            "already-LF content converted to LF is a no-op → false")
        XCTAssertEqual(diskContents(url), "a\nb\n")
    }

    // MARK: - No active file contract

    func test_cleanupOps_returnFalse_whenNoActiveTextFile() {
        let model = makeModel()
        XCTAssertFalse(model.trimTrailingWhitespaceInActiveFile())
        XCTAssertFalse(model.ensureFinalNewlineInActiveFile())
        XCTAssertFalse(model.convertActiveFileLineEnding(to: .crlf))
    }
}
