import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

@MainActor
final class EditorFlowIntegrationTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var historyStoreURL: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorFlowIntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "EditorFlowIntegrationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        historyStoreURL = tmpDir.appendingPathComponent("history.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: historyStoreURL),
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

    private func primeEditor(model: DocumentModel) -> (tabID: UUID, buf: EditorBuffer)? {
        guard let id = model.tabs.selected?.id,
              let buf = model.editorBuffer(forTabID: id) else { return nil }
        return (id, buf)
    }

    private func diskBytes(at url: URL) -> Data? { try? Data(contentsOf: url) }
    private func diskString(at url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    // MARK: - Load → edit → save → re-read disk

    func test_appendChars_writesToDisk() throws {
        let url = try writeFile("a.txt", "hello")
        let model = makeModel()
        model.open(url: url)
        guard let (tabID, _) = primeEditor(model: model) else {
            return XCTFail("editor buffer didn't materialize")
        }
        XCTAssertEqual(model.editorBuffer(forTabID: tabID)?.text, "hello")
        XCTAssertFalse(model.editorBuffer(forTabID: tabID)!.isDirty)

        model.updateEditorText("hello world", forTabID: tabID)
        XCTAssertTrue(model.editorBuffer(forTabID: tabID)!.isDirty)
        XCTAssertTrue(model.tabs.tabs.first(where: { $0.id == tabID })!.isDirty)

        XCTAssertTrue(model.saveEditor(forTabID: tabID))
        XCTAssertEqual(diskString(at: url), "hello world")
        XCTAssertFalse(model.tabs.tabs.first(where: { $0.id == tabID })!.isDirty)
        XCTAssertFalse(model.editorBuffer(forTabID: tabID)!.isDirty)
    }

    func test_deleteChars_writesShorterFile() throws {
        let url = try writeFile("b.txt", "hello world")
        let model = makeModel()
        model.open(url: url)
        let (tabID, _) = primeEditor(model: model)!
        model.updateEditorText("hello", forTabID: tabID)
        XCTAssertTrue(model.saveEditor(forTabID: tabID))
        XCTAssertEqual(diskString(at: url), "hello")
        XCTAssertEqual(diskBytes(at: url)?.count, 5)
    }

    func test_replaceWholeContent_writesExactMatch() throws {
        let url = try writeFile("c.txt", "old contents here")
        let model = makeModel()
        model.open(url: url)
        let (tabID, _) = primeEditor(model: model)!
        let fresh = "totally different lines\nwith newlines\n"
        model.updateEditorText(fresh, forTabID: tabID)
        XCTAssertTrue(model.saveEditor(forTabID: tabID))
        XCTAssertEqual(diskString(at: url), fresh)
    }

    func test_emptyDocument_savesEmptyFile() throws {
        let url = try writeFile("d.txt", "non-empty")
        let model = makeModel()
        model.open(url: url)
        let (tabID, _) = primeEditor(model: model)!
        model.updateEditorText("", forTabID: tabID)
        XCTAssertTrue(model.saveEditor(forTabID: tabID))
        XCTAssertEqual(diskString(at: url), "")
        XCTAssertEqual(diskBytes(at: url)?.count, 0)
    }

    func test_multiEditCycle_persistsLatest() throws {
        let url = try writeFile("e.txt", "v1")
        let model = makeModel()
        model.open(url: url)
        let (tabID, _) = primeEditor(model: model)!
        model.updateEditorText("v2", forTabID: tabID)
        XCTAssertTrue(model.saveEditor(forTabID: tabID))
        XCTAssertEqual(diskString(at: url), "v2")
        model.updateEditorText("v3 - much longer than before", forTabID: tabID)
        XCTAssertTrue(model.saveEditor(forTabID: tabID))
        XCTAssertEqual(diskString(at: url), "v3 - much longer than before")
        model.updateEditorText("v4", forTabID: tabID)
        XCTAssertTrue(model.saveEditor(forTabID: tabID))
        XCTAssertEqual(diskString(at: url), "v4")
    }

    func test_utf8RoundTrip_preservesEmojiAndNonASCII() throws {
        let url = try writeFile("u.txt", "")
        let model = makeModel()
        model.open(url: url)
        let (tabID, _) = primeEditor(model: model)!
        let payload = "héllo 🌟 — café\nworld 🚀\n"
        model.updateEditorText(payload, forTabID: tabID)
        XCTAssertTrue(model.saveEditor(forTabID: tabID))
        XCTAssertEqual(diskString(at: url), payload)
        XCTAssertEqual(diskBytes(at: url), payload.data(using: .utf8))
    }

    func test_saveActiveEditor_writesActiveTabsBuffer() throws {
        let url = try writeFile("active.txt", "before")
        let model = makeModel()
        model.open(url: url)
        let (tabID, _) = primeEditor(model: model)!
        model.updateEditorText("after via cmd-S", forTabID: tabID)
        XCTAssertTrue(model.saveActiveEditor())
        XCTAssertEqual(diskString(at: url), "after via cmd-S")
    }

    func test_saveActiveEditor_withNoSelection_returnsFalse() {
        let model = makeModel()
        XCTAssertFalse(model.saveActiveEditor())
    }

    func test_switchingTabs_preservesPerTabEdits() throws {
        let urlA = try writeFile("a.txt", "alpha-disk")
        let urlB = try writeFile("b.txt", "beta-disk")
        let model = makeModel()
        model.open(url: urlA)
        let aID = model.tabs.selected!.id
        _ = model.editorBuffer(forTabID: aID)
        model.updateEditorText("alpha-edited", forTabID: aID)
        model.openInNewTab(urlB)
        let bID = model.tabs.selected!.id
        XCTAssertNotEqual(aID, bID)
        _ = model.editorBuffer(forTabID: bID)
        model.updateEditorText("beta-edited", forTabID: bID)
        if let idxA = model.tabs.tabs.firstIndex(where: { $0.id == aID }) {
            model.selectTab(at: idxA)
        }
        XCTAssertEqual(model.editorBuffer(forTabID: aID)?.text, "alpha-edited")
        XCTAssertEqual(model.editorBuffer(forTabID: bID)?.text, "beta-edited")
        XCTAssertEqual(diskString(at: urlA), "alpha-disk")
        XCTAssertEqual(diskString(at: urlB), "beta-disk")
    }

    func test_discardEditorBuffer_clearsDirtAndDropsBuffer() throws {
        let url = try writeFile("d.txt", "disk")
        let model = makeModel()
        model.open(url: url)
        let (tabID, _) = primeEditor(model: model)!
        model.updateEditorText("local edits", forTabID: tabID)
        XCTAssertTrue(model.tabs.tabs.first(where: { $0.id == tabID })!.isDirty)
        model.discardEditorBuffer(forTabID: tabID)
        XCTAssertNil(model.editorBuffers[tabID])
        XCTAssertFalse(model.tabs.tabs.first(where: { $0.id == tabID })!.isDirty)
        XCTAssertEqual(diskString(at: url), "disk", "discard must not touch disk")
    }

    func test_externalEdit_detectedByBufferFingerprint() throws {
        let url = try writeFile("conflict.txt", "original")
        let model = makeModel()
        model.open(url: url)
        let (tabID, _) = primeEditor(model: model)!
        model.updateEditorText("local edits", forTabID: tabID)
        Thread.sleep(forTimeInterval: 0.05)
        try "external write".write(to: url, atomically: true, encoding: .utf8)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs[.modificationDate] as? Date
        let size = attrs[.size] as? Int
        XCTAssertTrue(
            model.editorBuffers[tabID]!.hasExternalEdit(currentMTime: mtime, currentSize: size),
            "buffer should detect external edit"
        )
    }

    func test_largeFile_roundTripsByteExact() throws {
        let url = try writeFile("large.txt", "")
        let model = makeModel()
        model.open(url: url)
        let (tabID, _) = primeEditor(model: model)!
        let line = "the quick brown fox jumps over the lazy dog\n"
        let payload = String(repeating: line, count: 2_700)
        XCTAssertGreaterThan(payload.utf8.count, 100_000)
        model.updateEditorText(payload, forTabID: tabID)
        XCTAssertTrue(model.saveEditor(forTabID: tabID))
        let reloaded = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(reloaded, payload)
        XCTAssertEqual(reloaded.utf8.count, payload.utf8.count)
    }

    func test_hasAnyUnsavedEdits_flipsWithBufferDirty() throws {
        let url = try writeFile("g.txt", "clean")
        let model = makeModel()
        model.open(url: url)
        let (tabID, _) = primeEditor(model: model)!
        XCTAssertFalse(model.hasAnyUnsavedEdits)
        model.updateEditorText("dirty", forTabID: tabID)
        XCTAssertTrue(model.hasAnyUnsavedEdits)
        XCTAssertTrue(model.saveEditor(forTabID: tabID))
        XCTAssertFalse(model.hasAnyUnsavedEdits)
    }

    func test_setSameText_isNoOp_doesNotMarkDirty() throws {
        let url = try writeFile("h.txt", "stable")
        let model = makeModel()
        model.open(url: url)
        let (tabID, _) = primeEditor(model: model)!
        model.updateEditorText("stable", forTabID: tabID)
        XCTAssertFalse(model.editorBuffer(forTabID: tabID)!.isDirty)
        XCTAssertFalse(model.tabs.tabs.first(where: { $0.id == tabID })!.isDirty)
    }

    func test_save_refreshesLoadedTextFile_inTabState() throws {
        let url = try writeFile("rehydrate.txt", "old")
        let model = makeModel()
        model.open(url: url)
        let (tabID, _) = primeEditor(model: model)!
        model.updateEditorText("new contents", forTabID: tabID)
        XCTAssertTrue(model.saveEditor(forTabID: tabID))
        guard let tab = model.tabs.tabs.first(where: { $0.id == tabID }),
              case .loaded(let file) = tab.state else {
            return XCTFail("tab state should be .loaded after save")
        }
        XCTAssertEqual(file.contents, "new contents")
    }

    func test_ensureEditorBuffer_preservesDirtyBuffer() throws {
        let url = try writeFile("idem.txt", "v0")
        let model = makeModel()
        model.open(url: url)
        let (tabID, _) = primeEditor(model: model)!
        model.updateEditorText("dirty-v1", forTabID: tabID)
        XCTAssertTrue(model.editorBuffers[tabID]!.isDirty)
        if case .loaded(let file) = model.tabs.tabs.first(where: { $0.id == tabID })!.state {
            model.ensureEditorBuffer(for: file, tabID: tabID)
        }
        XCTAssertEqual(model.editorBuffers[tabID]?.text, "dirty-v1")
        XCTAssertTrue(model.editorBuffers[tabID]!.isDirty)
    }
}
