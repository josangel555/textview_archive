import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-718 (hot exit) — host-safe behavioural coverage for the unsaved-buffer
/// capture / restore model layer that backs "restore unsaved edits on
/// relaunch". The on-disk wire (`TabSnapshot.unsavedText`) is pinned in
/// `ViewerCoreTests.TabSnapshotUnsavedTextPersistenceTests`; this file pins the
/// three live-model pieces that move data in and out of it:
///
///   1. `dedupedSnapshotTabs` serializes a live tab's `unsavedText` onto the
///      `TabSnapshot` (the WRITE side that `makeSnapshot` runs).
///   2. `captureUnsavedTextForAllTabs` stamps a dirty buffer's text onto its
///      tab (and clears a clean / oversized one) — the snapshot-boundary
///      capture wired into autosave / detach / quit.
///   3. `restoreUnsavedTextIfNeeded` overlays persisted text into a freshly
///      materialized `.loaded` tab so it comes back DIRTY — the read side wired
///      into `materializeIfNeeded`.
///
/// All synchronous + host-safe (`model.open` loads on the host; no window, no
/// WebView). The on-screen dirty dot / CM6 text is the VM-only render tail.
/// Filter: `swift test --filter ViewerUITests.HotExitTests`
@MainActor
final class HotExitTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HotExitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "HotExitTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        let m = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
        // TSK-1026: keep >1 MiB spill writes out of the user's real store.
        m.hotExitSpillDirectory = tmpDir.appendingPathComponent("spill", isDirectory: true)
        return m
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Open `url`, seed its editor buffer, return the tab id.
    private func openAndSeed(_ url: URL, in model: DocumentModel) -> UUID {
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id)
        return id
    }

    // MARK: - 1. dedupedSnapshotTabs carries unsavedText (write side)

    func test_dedupedSnapshotTabs_serializesUnsavedText() {
        var dirty = Tab(url: URL(fileURLWithPath: "/a/edited.swift"),
                        state: .empty, viewMode: .editor)
        dirty.unsavedText = "in-flight"
        let clean = Tab(url: URL(fileURLWithPath: "/a/clean.md"),
                        state: .empty, viewMode: .rendered)
        let (out, _) = SessionState.dedupedSnapshotTabs(from: [dirty, clean],
                                                        selectedIndex: nil)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].unsavedText, "in-flight")
        XCTAssertNil(out[1].unsavedText, "a clean tab persists no unsaved text")
    }

    // MARK: - 2. captureUnsavedTextForAllTabs (snapshot-boundary capture)

    func test_capture_stampsDirtyBufferText_ontoTab() throws {
        let url = try writeFile("a.txt", "disk")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        model.editor.updateEditorText("dirty edit", forTabID: id)
        XCTAssertTrue(model.editor.editorBuffers[id]?.isDirty == true)

        model.captureUnsavedTextForAllTabs()
        XCTAssertEqual(model.tabs.tabs[0].unsavedText, "dirty edit",
                       "a dirty buffer's text is captured onto the tab")
    }

    func test_capture_cleanBuffer_leavesUnsavedNil() throws {
        let url = try writeFile("a.txt", "disk")
        let model = makeModel()
        _ = openAndSeed(url, in: model)  // seeded but never edited → clean

        model.captureUnsavedTextForAllTabs()
        XCTAssertNil(model.tabs.tabs[0].unsavedText,
                     "a clean buffer must not persist any unsaved text")
    }

    func test_capture_clearsStaleUnsavedText_afterSave() throws {
        let url = try writeFile("a.txt", "disk")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        model.editor.updateEditorText("dirty edit", forTabID: id)
        model.captureUnsavedTextForAllTabs()
        XCTAssertEqual(model.tabs.tabs[0].unsavedText, "dirty edit")

        // Save → buffer clean → a re-capture must CLEAR the stale field, else a
        // saved file would falsely restore as dirty on relaunch.
        XCTAssertTrue(model.editor.saveEditor(forTabID: id))
        model.captureUnsavedTextForAllTabs()
        XCTAssertNil(model.tabs.tabs[0].unsavedText,
                     "saving clears the captured unsaved text")
    }

    func test_capture_oversizedBuffer_isNotPersisted() throws {
        let url = try writeFile("a.txt", "disk")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        // One byte over the cap → not captured (the file reloads from disk).
        let huge = String(repeating: "a", count: DocumentModel.hotExitMaxBytes + 1)
        model.editor.updateEditorText(huge, forTabID: id)
        XCTAssertTrue(model.editor.editorBuffers[id]?.isDirty == true)

        model.captureUnsavedTextForAllTabs()
        XCTAssertNil(model.tabs.tabs[0].unsavedText,
                     "an unsaved buffer over hotExitMaxBytes is not persisted")
    }

    func test_capture_atCapBoundary_isPersisted() throws {
        let url = try writeFile("a.txt", "disk")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        // Exactly at the cap → still captured (boundary is inclusive).
        let atCap = String(repeating: "b", count: DocumentModel.hotExitMaxBytes)
        model.editor.updateEditorText(atCap, forTabID: id)

        model.captureUnsavedTextForAllTabs()
        XCTAssertEqual(model.tabs.tabs[0].unsavedText?.utf8.count,
                       DocumentModel.hotExitMaxBytes)
    }

    // MARK: - 3. restoreUnsavedTextIfNeeded (materialize-time overlay)

    func test_restore_overlaysUnsavedText_andMarksDirty() throws {
        let url = try writeFile("a.txt", "disk content")
        let model = makeModel()
        model.open(url: url)
        let id = model.tabs.selected!.id
        // Simulate the lazy-restore carry: a freshly-loaded tab carrying the
        // persisted unsaved text (what `appendLazyTab(unsavedText:)` sets).
        var t = model.tabs.tabs[0]
        t.unsavedText = "restored edit"
        model.tabCoordinator.replace(at: 0, with: t)

        let did = model.restoreUnsavedTextIfNeeded(forTabAt: 0)
        XCTAssertTrue(did, "a loaded tab with unsavedText restores")
        XCTAssertEqual(model.editor.editorBuffer(forTabID: id)?.text, "restored edit",
                       "the buffer is overlaid with the persisted unsaved text")
        XCTAssertTrue(model.editor.editorBuffers[id]?.isDirty == true,
                      "the restored buffer is dirty vs the on-disk baseline")
        XCTAssertTrue(model.tabs.tabs[0].isDirty,
                      "the Tab.isDirty mirror flips so the dirty dot reappears")
    }

    func test_restore_noUnsavedText_isNoOp() throws {
        let url = try writeFile("a.txt", "disk content")
        let model = makeModel()
        model.open(url: url)
        let did = model.restoreUnsavedTextIfNeeded(forTabAt: 0)
        XCTAssertFalse(did, "a clean restored tab has nothing to overlay")
        XCTAssertFalse(model.tabs.tabs[0].isDirty)
    }

    func test_restore_roundTripThroughCapture_preservesEdit() throws {
        // The full loop: edit → capture → (serialize would persist) → restore
        // into a fresh tab → same dirty content. Pins capture and restore are
        // inverses at the model layer (the on-disk hop is covered separately).
        let url = try writeFile("a.txt", "original")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        model.editor.updateEditorText("user typed this", forTabID: id)
        model.captureUnsavedTextForAllTabs()
        let captured = model.tabs.tabs[0].unsavedText
        XCTAssertEqual(captured, "user typed this")

        // Fresh model + fresh tab carrying the captured text (the relaunch).
        let model2 = makeModel()
        model2.open(url: url)
        let id2 = model2.tabs.selected!.id
        var t = model2.tabs.tabs[0]
        t.unsavedText = captured
        model2.tabCoordinator.replace(at: 0, with: t)
        XCTAssertTrue(model2.restoreUnsavedTextIfNeeded(forTabAt: 0))
        XCTAssertEqual(model2.editor.editorBuffer(forTabID: id2)?.text,
                       "user typed this")
    }

    // MARK: - 4. hot-exit clobber guard (TSK-1025)

    func test_restore_seedsHotExitBaseline_soExternalChangeIsDetected() throws {
        let url = try writeFile("a.txt", "disk content now")
        let model = makeModel()
        model.open(url: url)
        let id = model.tabs.selected!.id
        // The persisted hot-exit baseline names an OLDER fingerprint than the
        // current disk (simulating: the file changed while the app was closed).
        let oldBase = Date(timeIntervalSince1970: 1_000)
        var t = model.tabs.tabs[0]
        t.unsavedText = "my in-flight edit"
        t.unsavedBaseMTime = oldBase
        t.unsavedBaseSize = 7                    // != the current file size
        model.tabCoordinator.replace(at: 0, with: t)

        XCTAssertTrue(model.restoreUnsavedTextIfNeeded(forTabAt: 0))
        let buf = try XCTUnwrap(model.editor.editorBuffers[id])
        // The buffer baseline is the HOT-EXIT one, NOT the just-read disk one.
        XCTAssertEqual(buf.lastSavedMTime, oldBase)
        XCTAssertEqual(buf.lastSavedSize, 7)
        // TEETH: the existing conflict path now sees the file as externally
        // changed (pre-fix the baseline was the current disk → no conflict →
        // the in-flight edit silently clobbered the external change).
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertTrue(buf.hasExternalEdit(
            currentMTime: attrs[.modificationDate] as? Date,
            currentSize: attrs[.size] as? Int),
            "seeding the hot-exit baseline makes the external change detectable")
    }

    func test_restore_matchingBaseline_noFalseConflict() throws {
        let url = try writeFile("a.txt", "disk content")
        let model = makeModel()
        model.open(url: url)
        let id = model.tabs.selected!.id
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let curMTime = attrs[.modificationDate] as? Date
        let curSize = attrs[.size] as? Int
        // Baseline == current disk (file UNCHANGED since hot-exit).
        var t = model.tabs.tabs[0]
        t.unsavedText = "edit"
        t.unsavedBaseMTime = curMTime
        t.unsavedBaseSize = curSize
        model.tabCoordinator.replace(at: 0, with: t)

        XCTAssertTrue(model.restoreUnsavedTextIfNeeded(forTabAt: 0))
        let buf = try XCTUnwrap(model.editor.editorBuffers[id])
        XCTAssertFalse(buf.hasExternalEdit(currentMTime: curMTime, currentSize: curSize),
                       "an unchanged file must not raise a false conflict on restore")
    }

    // MARK: - 5. large-buffer sidecar spill (TSK-1026)

    func test_capture_oversizedBuffer_spillsAndRestores() throws {
        // A >1 MiB dirty buffer is SPILLED to a sidecar (not inlined, not
        // dropped) and restored on relaunch. TEETH: pre-1026 the buffer was
        // silently discarded, so restore had nothing.
        let url = try writeFile("big.txt", "disk")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        let huge = String(repeating: "z", count: DocumentModel.hotExitMaxBytes + 4096)
        model.editor.updateEditorText(huge, forTabID: id)
        model.captureUnsavedTextForAllTabs()
        XCTAssertNil(model.tabs.tabs[0].unsavedText, "over the cap → not inlined")
        XCTAssertEqual(HotExitSpill.read(forPath: url.path, in: model.hotExitSpillDirectory), huge,
                       "the large buffer is spilled to the sidecar")

        // Relaunch: fresh model + tab (same scratch spill dir, no inline text)
        // → restore reads the spill back.
        let model2 = makeModel()
        model2.open(url: url)
        let id2 = model2.tabs.selected!.id
        XCTAssertTrue(model2.restoreUnsavedTextIfNeeded(forTabAt: 0))
        XCTAssertEqual(model2.editor.editorBuffer(forTabID: id2)?.text, huge,
                       "the >1 MiB unsaved buffer is restored from the spill")
    }
}
