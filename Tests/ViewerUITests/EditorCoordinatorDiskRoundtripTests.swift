import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// End-to-end disk round-trip coverage driven through the new
/// `EditorCoordinator` surface (Quality #2, 2026-05-25).
///
/// Mirrors `EditorFlowIntegrationTests` but exercises the coordinator's
/// public API directly (`model.editor.X`) rather than going through the
/// DocumentModel forwarders. Pins that the extraction preserved the
/// disk-write contract end-to-end: load file → edit through editor →
/// save → re-read disk matches the buffer text.
///
/// The forwarder tests in `DocumentModelEditorForwarderTests` cover
/// the inverse path (DocumentModel.saveX → coordinator → disk). This
/// file is the "direct coordinator → disk" half.
@MainActor
final class EditorCoordinatorDiskRoundtripTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorCoordinatorDiskRoundtripTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "EditorCoordinatorDiskRoundtripTests-\(UUID().uuidString)"
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

    private func diskString(at url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private func diskBytes(at url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    /// Open `url` in `model` and return the seeded editor coordinator
    /// handles for further mutation.
    private func openAndSeed(_ url: URL, in model: DocumentModel) -> UUID {
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id)
        return id
    }

    // MARK: - Direct coordinator save → disk roundtrip

    func test_directCoordinatorSave_writesEditedTextToDisk() throws {
        let url = try writeFile("d_a.txt", "hello")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        model.editor.updateEditorText("hello world", forTabID: id)
        XCTAssertTrue(model.editor.editorBuffers[id]?.isDirty == true)
        XCTAssertTrue(model.editor.saveEditor(forTabID: id))
        XCTAssertEqual(diskString(at: url), "hello world")
        XCTAssertFalse(model.editor.editorBuffers[id]?.isDirty == true,
            "save must clear the buffer's dirty flag")
        XCTAssertFalse(model.tabs.tabs[0].isDirty,
            "save must clear the Tab.isDirty mirror")
    }

    func test_directCoordinatorSave_writesShorterFile_andClearsHistory() throws {
        let url = try writeFile("d_b.txt", "hello world")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        model.editor.updateEditorText("hello", forTabID: id)
        XCTAssertTrue(model.editor.saveEditor(forTabID: id))
        XCTAssertEqual(diskString(at: url), "hello")
        XCTAssertEqual(diskBytes(at: url)?.count, 5)
    }

    func test_directCoordinatorSave_emptyDocument_savesEmptyFile() throws {
        let url = try writeFile("d_c.txt", "non-empty")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        model.editor.updateEditorText("", forTabID: id)
        XCTAssertTrue(model.editor.saveEditor(forTabID: id))
        XCTAssertEqual(diskString(at: url), "")
        XCTAssertEqual(diskBytes(at: url)?.count, 0)
    }

    func test_directCoordinatorSave_replaceWholeContent_writesExactMatch() throws {
        let url = try writeFile("d_d.txt", "old")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        let fresh = "totally different\nlines\nwith newlines\n"
        model.editor.updateEditorText(fresh, forTabID: id)
        XCTAssertTrue(model.editor.saveEditor(forTabID: id))
        XCTAssertEqual(diskString(at: url), fresh)
    }

    func test_directCoordinatorSave_utf8RoundTripsEmojiAndAccents() throws {
        let url = try writeFile("d_emoji.txt", "")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        let payload = "héllo 🌟 — café\nworld 🚀\n"
        model.editor.updateEditorText(payload, forTabID: id)
        XCTAssertTrue(model.editor.saveEditor(forTabID: id))
        XCTAssertEqual(diskString(at: url), payload)
        XCTAssertEqual(diskBytes(at: url), payload.data(using: .utf8))
    }

    func test_directCoordinatorSave_multiCyclePersistsLatest() throws {
        let url = try writeFile("d_multi.txt", "v1")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        for version in ["v2", "v3 - much longer than v2", "v4"] {
            model.editor.updateEditorText(version, forTabID: id)
            XCTAssertTrue(model.editor.saveEditor(forTabID: id))
            XCTAssertEqual(diskString(at: url), version)
        }
    }

    func test_directCoordinatorSave_largePayloadByteExact() throws {
        let url = try writeFile("d_large.txt", "")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        let line = "the quick brown fox jumps over the lazy dog\n"
        let payload = String(repeating: line, count: 2_700)
        XCTAssertGreaterThan(payload.utf8.count, 100_000)
        model.editor.updateEditorText(payload, forTabID: id)
        XCTAssertTrue(model.editor.saveEditor(forTabID: id))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), payload)
    }

    // MARK: - saveActiveEditor (entry-point pinning)

    func test_saveActiveEditor_writesSelectedTabsBuffer() throws {
        let url = try writeFile("d_active.txt", "before")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        model.editor.updateEditorText("after-active", forTabID: id)
        XCTAssertTrue(model.editor.saveActiveEditor(),
            "menu-style ⌘S entry must save the currently selected tab")
        XCTAssertEqual(diskString(at: url), "after-active")
    }

    func test_saveActiveEditor_noSelectionReturnsFalse() {
        let model = makeModel()
        XCTAssertFalse(model.editor.saveActiveEditor(),
            "no-selection case returns false rather than crashing")
    }

    // MARK: - Per-tab buffer isolation through coordinator

    func test_directCoordinatorEdits_perTabIsolation() throws {
        let urlA = try writeFile("d_iso_a.txt", "alpha-disk")
        let urlB = try writeFile("d_iso_b.txt", "beta-disk")
        let model = makeModel()
        model.open(url: urlA)
        let aID = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: aID)
        model.editor.updateEditorText("alpha-edited", forTabID: aID)
        model.openInNewTab(urlB)
        let bID = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: bID)
        model.editor.updateEditorText("beta-edited", forTabID: bID)
        // Switch back to A; both buffers must carry the right text.
        if let idxA = model.tabs.tabs.firstIndex(where: { $0.id == aID }) {
            model.selectTab(at: idxA)
        }
        XCTAssertEqual(model.editor.editorBuffer(forTabID: aID)?.text, "alpha-edited")
        XCTAssertEqual(model.editor.editorBuffer(forTabID: bID)?.text, "beta-edited")
        XCTAssertEqual(diskString(at: urlA), "alpha-disk", "neither file written yet")
        XCTAssertEqual(diskString(at: urlB), "beta-disk")
    }

    // MARK: - Refresh of .loaded tab state after save

    func test_directCoordinatorSave_refreshesLoadedTextFileState() throws {
        let url = try writeFile("d_state.txt", "old")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        model.editor.updateEditorText("new contents", forTabID: id)
        XCTAssertTrue(model.editor.saveEditor(forTabID: id))
        // The TextFile inside Tab.state must reflect the new bytes so
        // downstream cache keys (rendered HTML, highlight cache) pick
        // up the new identity instead of serving pre-save content.
        guard let tab = model.tabs.tabs.first(where: { $0.id == id }),
              case .loaded(let file) = tab.state else {
            return XCTFail("tab must be .loaded after save")
        }
        XCTAssertEqual(file.contents, "new contents")
        XCTAssertEqual(file.byteCount, "new contents".data(using: .utf8)?.count)
    }

    // MARK: - hasAnyUnsavedEdits across the save cycle

    func test_hasAnyUnsavedEdits_flipsAcrossSaveCycle() throws {
        let url = try writeFile("d_dirty.txt", "clean")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        XCTAssertFalse(model.editor.hasAnyUnsavedEdits)
        model.editor.updateEditorText("dirty", forTabID: id)
        XCTAssertTrue(model.editor.hasAnyUnsavedEdits)
        XCTAssertTrue(model.editor.saveEditor(forTabID: id))
        XCTAssertFalse(model.editor.hasAnyUnsavedEdits)
    }

    // MARK: - same-text update is a no-op (no spurious dirty flips)

    func test_directCoordinatorUpdateText_sameText_doesNotMarkDirty() throws {
        let url = try writeFile("d_same.txt", "stable")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        model.editor.updateEditorText("stable", forTabID: id)
        XCTAssertFalse(model.editor.editorBuffers[id]?.isDirty == true)
        XCTAssertFalse(model.tabs.tabs[0].isDirty)
    }
}
