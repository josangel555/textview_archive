import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Headless (T1m) coverage for the editable-HEX dirty/save/close surface
/// on `DocumentModel` (#234) — the data-loss-adjacent path the audit
/// flagged as having ZERO unit tests:
///   `setHexDirty`, `stashHexBytes`, `saveHexEdits(_:forTabID:)`,
///   `saveHexEdits(forTabID:)`, `isHexDirtyTab(at:)`, the `hexDirtyBytes`
///   per-tab dict, and the close-confirm Save/Discard routing.
///
/// Mirrors `EditorCoordinatorInteractionTests`' DI shape (hermetic
/// `DocumentModel` + temp-dir scratch). Asserts the model-side bytes
/// behavior only — the two NSAlert branches (`presentHexSaveFailure` /
/// `presentHexSymlinkPrompt`) call `runModal()` directly and are left to
/// indirect / DI coverage, matching the audit's scope note.
@MainActor
final class HexDirtySaveClose_Audit_Sources_ViewerUI_DocumentModel_swift_Tests: HeadlessUITestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HexDirtyAuditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "HexDirtyAuditTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
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
    private func writeBinary(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try Data(bytes).write(to: url, options: .atomic)
        return url
    }

    /// Open a file and put the tab into a HEX-dirty state by driving the
    /// same calls `HexView` makes on a dirty transition. Returns model,
    /// tab id, url, and the dirty bytes stashed.
    private func openHexDirtyTab(_ name: String) throws -> (DocumentModel, UUID, URL, Data) {
        let url = try writeBinary(name, [0x00, 0x01, 0x02, 0x03])
        let model = makeModel()
        model.open(url: url)
        let id = model.tabs.selected!.id
        let dirtyBytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        model.stashHexBytes(dirtyBytes, forTabID: id)
        model.setHexDirty(true, forTabID: id)
        return (model, id, url, dirtyBytes)
    }

    // MARK: - Dirty mirroring + stash

    func test_setHexDirty_mirrorsTabIsDirtyDot() throws {
        let (model, id, _, _) = try openHexDirtyTab("dirty_dot.bin")
        let idx = model.tabs.tabs.firstIndex(where: { $0.id == id })!
        XCTAssertTrue(model.tabs.tabs[idx].isDirty,
            "setHexDirty(true) must mirror onto Tab.isDirty (the TabBar dot + close gate)")
        XCTAssertTrue(model.isHexDirtyTab(at: idx),
            "a stashed-bytes tab must be recognized as HEX-dirty")
    }

    func test_setHexDirtyFalse_clearsDotAndDropsStash() throws {
        let (model, id, _, _) = try openHexDirtyTab("clear_dot.bin")
        let idx = model.tabs.tabs.firstIndex(where: { $0.id == id })!
        model.setHexDirty(false, forTabID: id)
        XCTAssertFalse(model.tabs.tabs[idx].isDirty,
            "setHexDirty(false) must clear the dot")
        XCTAssertFalse(model.isHexDirtyTab(at: idx),
            "clearing dirty must drop the stashed bytes")
    }

    // MARK: - ⌘S save (saveHexEdits(_:forTabID:))

    func test_saveHexEdits_writesBytes_clearsDot_dropsStash() throws {
        let (model, id, url, dirtyBytes) = try openHexDirtyTab("save_bytes.bin")
        let idx = model.tabs.tabs.firstIndex(where: { $0.id == id })!
        XCTAssertTrue(model.saveHexEdits(dirtyBytes, forTabID: id),
            "save of a normal temp-dir file must succeed")
        XCTAssertEqual(try Data(contentsOf: url), dirtyBytes,
            "the edited bytes must land on disk")
        XCTAssertFalse(model.tabs.tabs[idx].isDirty,
            "a successful save clears the dirty dot")
        XCTAssertFalse(model.isHexDirtyTab(at: idx),
            "a successful save drops the stashed bytes (no leak)")
    }

    func test_saveHexEdits_refreshesLoadedBinaryBaseline() throws {
        let (model, id, _, dirtyBytes) = try openHexDirtyTab("save_baseline.bin")
        let idx = model.tabs.tabs.firstIndex(where: { $0.id == id })!
        XCTAssertTrue(model.saveHexEdits(dirtyBytes, forTabID: id))
        // The tab's loaded BinaryFile must reflect the saved bytes so a
        // re-render shows the new baseline.
        if case .binary(let file) = model.tabs.tabs[idx].state {
            XCTAssertEqual(file.data, dirtyBytes,
                "post-save BinaryFile baseline must equal the written bytes")
            XCTAssertEqual(file.totalByteCount, dirtyBytes.count)
            XCTAssertFalse(file.isTruncated)
        } else {
            XCTFail("tab must be in .binary state with the post-save bytes")
        }
    }

    // MARK: - Close-confirm Save routes via isHexDirtyTab → saveHexEdits

    func test_closeConfirmSave_routesToHexWriter_notEditorWriter() throws {
        let (model, id, url, dirtyBytes) = try openHexDirtyTab("close_save.bin")
        // No editor buffer exists for this tab, so if the close path wrongly
        // routed to saveEditor it would be a no-op (or fail) and the bytes
        // would never reach disk. Routing via isHexDirtyTab is what makes
        // the Save branch write the binary.
        XCTAssertNil(model.editorBuffers[id],
            "precondition: a HEX-dirty tab has no text editor buffer")
        model.editor.dirtyClosePromptOverride = { _ in .save }
        model.closeTab(at: 0)
        XCTAssertTrue(model.tabs.isEmpty,
            "Save + close must remove the tab")
        XCTAssertEqual(try Data(contentsOf: url), dirtyBytes,
            "close-confirm Save must route through the HEX writer and persist the edited bytes")
    }

    // MARK: - Close-confirm Discard empties hexDirtyBytes (no write, no leak)

    func test_closeConfirmDiscard_dropsStash_andDoesNotWrite() throws {
        let url = try writeBinary("close_discard.bin", [0x00, 0x01, 0x02, 0x03])
        let original = try Data(contentsOf: url)
        let model = makeModel()
        model.open(url: url)
        let id = model.tabs.selected!.id
        model.stashHexBytes(Data([0xFF, 0xFF]), forTabID: id)
        model.setHexDirty(true, forTabID: id)
        XCTAssertTrue(model.isHexDirtyTab(at: 0))
        model.editor.dirtyClosePromptOverride = { _ in .discard }
        model.closeTab(at: 0)
        XCTAssertTrue(model.tabs.isEmpty, "Discard + close removes the tab")
        XCTAssertEqual(try Data(contentsOf: url), original,
            "Discard must NOT touch disk; the original bytes survive")
        // The stash for the (now closed) tab id must be gone so a later
        // same-id reuse can't resurrect the dropped edits.
        XCTAssertNil(model.peekHexDirtyBytesForTest(id),
            "Discard must empty hexDirtyBytes for the closed tab")
    }

    // MARK: - Close-confirm Cancel keeps the tab + stash

    func test_closeConfirmCancel_keepsTabAndStash() throws {
        let (model, id, _, dirtyBytes) = try openHexDirtyTab("close_cancel.bin")
        model.editor.dirtyClosePromptOverride = { _ in .cancel }
        model.closeTab(at: 0)
        XCTAssertEqual(model.tabs.tabs.count, 1, "Cancel must leave the tab open")
        XCTAssertTrue(model.isHexDirtyTab(at: 0),
            "Cancel must preserve the HEX-dirty stash")
        XCTAssertEqual(model.peekHexDirtyBytesForTest(id), dirtyBytes,
            "Cancel must keep the exact stashed bytes")
    }

    // MARK: - saveHexEdits(forTabID:) — stash-only overload

    func test_stashOnlySave_usesStashedBytes() throws {
        let (model, id, url, dirtyBytes) = try openHexDirtyTab("stash_save.bin")
        XCTAssertTrue(model.saveHexEdits(forTabID: id),
            "the stash-only overload must save the stashed bytes")
        XCTAssertEqual(try Data(contentsOf: url), dirtyBytes)
        XCTAssertFalse(model.isHexDirtyTab(at: 0))
    }

    func test_stashOnlySave_returnsFalseWhenNothingStashed() throws {
        let url = try writeBinary("nothing_stashed.bin", [0x00])
        let model = makeModel()
        model.open(url: url)
        let id = model.tabs.selected!.id
        XCTAssertFalse(model.saveHexEdits(forTabID: id),
            "no stash → the close-confirm Save overload must report nothing to save")
    }

    // MARK: - Leak: every close path empties the stash for the closed tab

    func test_noStashLeak_afterDiscardClose() throws {
        let url = try writeBinary("leak_check.bin", [0x01, 0x02])
        let model = makeModel()
        model.open(url: url)
        let id = model.tabs.selected!.id
        model.stashHexBytes(Data([0xAB]), forTabID: id)
        model.setHexDirty(true, forTabID: id)
        model.editor.dirtyClosePromptOverride = { _ in .discard }
        model.closeTab(at: 0)
        XCTAssertNil(model.peekHexDirtyBytesForTest(id),
            "hexDirtyBytes must hold no entry for any closed tab")
    }
}
