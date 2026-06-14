import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-350 — host coverage for the in-place "Align Markdown Tables" editor
/// command. The table-alignment LOGIC is pinned in
/// `ViewerCoreTests.FormatterTests`; this verifies the DocumentModel command
/// rewrites the active editor buffer (and no-ops off-markdown / when unchanged).
/// Host-safe (temp files, no window).
@MainActor
final class MarkdownTableFormatModelTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDTableFormatTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "MDTableFormatTests-\(UUID().uuidString)"
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
            preferences: PreferencesStore(defaults: defaults))
    }

    /// Open `name` with `body`, force editor mode, seed its buffer; return the id.
    private func openEditor(_ name: String, _ body: String,
                            in model: DocumentModel) throws -> UUID {
        let url = tmpDir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        model.open(url: url)
        let id = model.tabs.selected!.id
        var t = model.tabs.tabs[0]
        t.viewMode = .editor
        model.tabCoordinator.replace(at: 0, with: t)
        _ = model.editor.editorBuffer(forTabID: id)  // seed from .loaded
        return id
    }

    func test_alignsRaggedTable_inActiveBuffer() throws {
        let model = makeModel()
        let id = try openEditor("doc.md", """
        | Name | Age |
        |---|---|
        | Alice | 30 |
        """, in: model)
        XCTAssertTrue(model.canAlignMarkdownTables)
        XCTAssertTrue(model.formatMarkdownTablesInActiveEditor())
        XCTAssertEqual(model.editor.editorBuffer(forTabID: id)?.text, """
        | Name  | Age |
        | ----- | --- |
        | Alice | 30  |
        """)
    }

    func test_noOp_whenAlreadyAligned() throws {
        let aligned = """
        | A   | B   |
        | --- | --- |
        | 1   | 2   |
        """
        let model = makeModel()
        _ = try openEditor("doc.md", aligned, in: model)
        XCTAssertFalse(model.formatMarkdownTablesInActiveEditor(),
                       "an already-aligned table is a no-op (no spurious dirtying)")
    }

    func test_noOp_forNonMarkdownFile() throws {
        let model = makeModel()
        _ = try openEditor("notes.txt", "| a | b |\n|---|---|\n", in: model)
        XCTAssertFalse(model.canAlignMarkdownTables)
        XCTAssertFalse(model.formatMarkdownTablesInActiveEditor(),
                       "table alignment is markdown-only")
    }
}
