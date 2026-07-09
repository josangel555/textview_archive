import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1500 — host tests for the "recover a deleted file" model glue: the
/// enumeration (recents ∩ gone-from-disk ∩ has-history) and the recreate+open
/// dispatch. The atomic create-from-version PRIMITIVE + its fencing are pinned
/// by FileResurrectionTests; these pin the model wiring on real fixtures.
@MainActor
final class DocumentModelResurrectionTests: XCTestCase {

    private var workspace: URL!
    private var historyDir: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResurrectWS-\(UUID().uuidString)")
        historyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResurrectHist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
        try? FileManager.default.removeItem(at: historyDir)
    }

    private func makeModel() -> DocumentModel {
        let defaults = UserDefaults(suiteName: "Resurrect-\(UUID().uuidString)")!
        return DocumentModel(
            history: HistoryStore(storeURL: workspace.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults),
            localHistory: LocalHistoryStore(directory: historyDir))
    }

    /// Create a file under the workspace, snapshot it to Local History, delete
    /// it, open the workspace folder (sets the root), and record it as a recent.
    @discardableResult
    private func seedDeletedFileWithHistory(_ model: DocumentModel, content: String) -> URL {
        let file = workspace.appendingPathComponent("notes/todo.md")
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? content.write(to: file, atomically: true, encoding: .utf8)
        _ = model.localHistoryStore.snapshot(
            path: file.standardizedFileURL.path, content: content, at: Date())
        try? FileManager.default.removeItem(at: file)
        model.openFolder(workspace)                      // sets sidebar.rootURL
        model.recents = [HistoryEntry(url: file, kind: .file, lastOpenedAt: Date())]
        return file
    }

    func test_recoverableDeletedFiles_listsDeletedButVersioned() {
        let model = makeModel()
        let file = seedDeletedFileWithHistory(model, content: "hello\n")
        XCTAssertEqual(model.recoverableDeletedFiles().map(\.standardizedFileURL),
                       [file.standardizedFileURL])
    }

    func test_recoverableDeletedFiles_excludesFilesThatStillExist() {
        let model = makeModel()
        let file = seedDeletedFileWithHistory(model, content: "x\n")
        try? "back\n".write(to: file, atomically: true, encoding: .utf8)   // reappears
        XCTAssertTrue(model.recoverableDeletedFiles().isEmpty,
                      "a file that still exists on disk is not 'recoverable'")
    }

    func test_resurrect_recreatesWithExactContent_andReturnsCreated() {
        let model = makeModel()
        let file = seedDeletedFileWithHistory(model, content: "line one\nline two\n")
        let outcome = model.resurrectFile(at: file)
        XCTAssertEqual(outcome, .created)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "recreated on disk")
        XCTAssertEqual(try? String(contentsOf: file, encoding: .utf8),
                       "line one\nline two\n", "content byte-equal to the stored version (U6)")
    }

    func test_resurrect_whenFileReappeared_refuses_andLeavesLiveContentUntouched() {
        let model = makeModel()
        let file = seedDeletedFileWithHistory(model, content: "old\n")
        try? "LIVE — do not clobber\n".write(to: file, atomically: true, encoding: .utf8)
        let outcome = model.resurrectFile(at: file)
        XCTAssertEqual(outcome, .refusedExists, "never overwrite (U3)")
        XCTAssertEqual(try? String(contentsOf: file, encoding: .utf8),
                       "LIVE — do not clobber\n", "the live file is untouched")
    }
}
