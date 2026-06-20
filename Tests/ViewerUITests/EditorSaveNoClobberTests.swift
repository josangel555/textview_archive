import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Wired-behavior coverage for the WRITE-TIME no-clobber save guard +
/// snapshot-on-save hook (TSK-768 / TSK-1103), driven through the real
/// `EditorCoordinator.saveEditor` path.
///
/// THE INCIDENT (2026-06-20): a file was open + dirty in the editor; a
/// background process rewrote it ON DISK; ⌘S blind-overwrote the disk change
/// with no warning and no recovery. These tests reproduce that exact sequence
/// and pin that the guard now:
///   1. refuses the silent overwrite (presents a conflict),
///   2. honours each resolution (overwrite / reload / cancel),
///   3. preserves the clean-buffer-reloads-no-prompt path,
///   4. records a recoverable Local History version on every successful save.
///
/// TEETH: `test_dirtyBuffer_diskChangedUnderneath_doesNotSilentlyOverwrite`
/// goes RED if the pre-write guard in `saveEditor` is removed (the save would
/// then clobber the disk change — verified by reverting the guard).
@MainActor
final class EditorSaveNoClobberTests: XCTestCase {

    private var tmpDir: URL!
    private var historyDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorSaveNoClobberTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        historyDir = tmpDir.appendingPathComponent("history")
        try FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        suiteName = "EditorSaveNoClobberTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        let model = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
        // Inject a temp-dir Local History store so snapshot-on-save is
        // observable and isolated from the user's real history.
        model.editor.localHistoryStore = LocalHistoryStore(directory: historyDir)
        return model
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

    private func openAndSeed(_ url: URL, in model: DocumentModel) -> UUID {
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id)
        return id
    }

    /// Stat helper: the file's current `(mtime, size)`, or `(nil, nil)`.
    private func stat(_ url: URL) -> (mtime: Date?, size: Int?) {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (a?[.modificationDate] as? Date, a?[.size] as? Int)
    }

    /// Rewrite `url` on disk so its fingerprint differs from the buffer's
    /// baseline — simulating a background process. Polls (no fixed sleep) until
    /// the on-disk `(mtime, size)` has actually moved relative to the pre-write
    /// stat, so the conflict guard reliably observes an external change even
    /// when mtime resolution is coarse. The caller passes content whose LENGTH
    /// differs from the buffer baseline so the size dimension alone already
    /// proves the change; the poll just hardens against same-length cases.
    private func backgroundWrite(_ url: URL, _ contents: String) throws {
        let before = stat(url)
        // Retry the write until the fingerprint demonstrably changed. On a
        // same-length rewrite with sub-second mtime, the first write may land in
        // the same mtime tick — re-write until stat moves (bounded).
        for _ in 0..<200 {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            let after = stat(url)
            let mtimeMoved = before.mtime != after.mtime
            let sizeMoved = before.size != after.size
            if mtimeMoved || sizeMoved { return }
        }
        XCTFail("background write never produced an observable fingerprint change")
    }

    // MARK: - The data-loss reproduction (TEETH)

    func test_dirtyBuffer_diskChangedUnderneath_doesNotSilentlyOverwrite() throws {
        let url = try writeFile("incident.md", "original line\n")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        // User edits in the buffer (dirty, blue dot).
        model.editor.updateEditorText("my unsaved edit\n", forTabID: id)
        XCTAssertTrue(model.editor.editorBuffers[id]?.isDirty == true)

        // A background process rewrites the file on disk under the open buffer.
        try backgroundWrite(url, "BACKGROUND PROCESS WROTE THIS\n")

        // The conflict prompt is presented (not silently bypassed). Drive it to
        // Cancel so nothing is written — the disk change must survive.
        var promptShown = false
        var offeredActions: [SaveConflictAction] = []
        model.editor.saveConflictPromptOverride = { _, actions in
            promptShown = true
            offeredActions = actions
            return .cancel
        }

        let ok = model.editor.saveEditor(forTabID: id)
        XCTAssertFalse(ok, "a cancelled conflict must report the save did not complete")
        XCTAssertTrue(promptShown,
            "⌘S over a changed disk + dirty buffer MUST present a conflict, not write")
        XCTAssertEqual(offeredActions, SaveConflictDecision.conflictActions)
        // The crux: the disk still holds the BACKGROUND write, NOT the buffer.
        XCTAssertEqual(diskString(at: url), "BACKGROUND PROCESS WROTE THIS\n",
            "the no-clobber guard MUST NOT overwrite the external change")
        // The user's edits are still in the buffer (nothing lost on either side).
        XCTAssertEqual(model.editor.editorBuffers[id]?.text, "my unsaved edit\n")
        XCTAssertTrue(model.editor.editorBuffers[id]?.isDirty == true)
    }

    func test_conflict_overwrite_keepsMine_thenWrites() throws {
        let url = try writeFile("ov.md", "original\n")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        model.editor.updateEditorText("mine\n", forTabID: id)
        try backgroundWrite(url, "theirs\n")

        model.editor.saveConflictPromptOverride = { _, _ in .overwrite }
        let ok = model.editor.saveEditor(forTabID: id)
        XCTAssertTrue(ok, "overwrite must complete the save")
        XCTAssertEqual(diskString(at: url), "mine\n",
            "overwrite (keep mine) writes the buffer over the disk change")
        XCTAssertFalse(model.editor.editorBuffers[id]?.isDirty == true,
            "after the overwrite the buffer is clean")
    }

    func test_conflict_reload_discardsMine_takesDisk() throws {
        let url = try writeFile("rl.md", "original\n")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        model.editor.updateEditorText("mine\n", forTabID: id)
        try backgroundWrite(url, "theirs\n")

        model.editor.saveConflictPromptOverride = { _, _ in .reload }
        let ok = model.editor.saveEditor(forTabID: id)
        XCTAssertFalse(ok, "reload resolves the conflict WITHOUT writing the original")
        // Disk keeps the external change; buffer reloaded to it.
        XCTAssertEqual(diskString(at: url), "theirs\n",
            "reload must not write the buffer over the external change")
        if case .loaded(let f)? = model.tabs.tabs.first(where: { $0.id == id })?.state {
            XCTAssertEqual(f.contents, "theirs\n", "reload pulled the disk bytes")
        } else {
            XCTFail("tab must be .loaded with the on-disk content after reload")
        }
        XCTAssertFalse(model.tabs.tabs.first(where: { $0.id == id })?.isDirty == true)
    }

    func test_conflict_saveAsCopy_leavesOriginalUntouched() throws {
        let url = try writeFile("sc.md", "original\n")
        let copyURL = tmpDir.appendingPathComponent("sc-copy.md")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        model.editor.updateEditorText("mine\n", forTabID: id)
        try backgroundWrite(url, "theirs\n")

        var copyRequestedForTab: UUID?
        model.editor.onSaveAsCopy = { tabID in
            copyRequestedForTab = tabID
            // Stand in for the NSSavePanel: write the copy to a known path.
            return (try? model.saveCopy(ofTabAt: 0, to: copyURL)) ?? false
        }
        model.editor.saveConflictPromptOverride = { _, _ in .saveAsCopy }

        let ok = model.editor.saveEditor(forTabID: id)
        XCTAssertFalse(ok, "save-as-copy resolves WITHOUT writing the original")
        XCTAssertEqual(copyRequestedForTab, id, "the copy hook fires for the right tab")
        XCTAssertEqual(diskString(at: url), "theirs\n",
            "the original keeps the external change")
        XCTAssertEqual(diskString(at: copyURL), "mine\n",
            "the copy holds the user's edits")
        // The buffer stays dirty against the original (edits not yet persisted there).
        XCTAssertTrue(model.editor.editorBuffers[id]?.isDirty == true)
    }

    func test_conflict_viewDiff_firesHook_andDoesNotWrite() throws {
        let url = try writeFile("vd.md", "original\n")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        model.editor.updateEditorText("mine\n", forTabID: id)
        try backgroundWrite(url, "theirs\n")

        var diffRequested: (UUID, URL)?
        model.editor.onViewSaveConflictDiff = { tabID, u in diffRequested = (tabID, u) }
        model.editor.saveConflictPromptOverride = { _, _ in .viewDiff }

        let ok = model.editor.saveEditor(forTabID: id)
        XCTAssertFalse(ok, "view-diff defers the decision; no write")
        XCTAssertEqual(diffRequested?.0, id)
        XCTAssertEqual(diffRequested?.1, url)
        XCTAssertEqual(diskString(at: url), "theirs\n",
            "view-diff must not overwrite the external change")
    }

    // MARK: - Non-regression: the normal paths still work

    func test_dirtyBuffer_diskUnchanged_savesNormally_noPrompt() throws {
        let url = try writeFile("normal.md", "v1\n")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        model.editor.updateEditorText("v2\n", forTabID: id)

        var promptShown = false
        model.editor.saveConflictPromptOverride = { _, _ in promptShown = true; return .cancel }
        let ok = model.editor.saveEditor(forTabID: id)
        XCTAssertTrue(ok, "a normal save (disk unchanged) must complete")
        XCTAssertFalse(promptShown, "no conflict when the disk is unchanged")
        XCTAssertEqual(diskString(at: url), "v2\n")
    }

    func test_cleanBuffer_diskChanged_reloadsWithoutPrompt() throws {
        let url = try writeFile("clean.md", "v1\n")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        XCTAssertFalse(model.editor.editorBuffers[id]?.isDirty == true,
            "precondition: buffer is clean")
        try backgroundWrite(url, "external v2\n")

        var promptShown = false
        model.editor.saveConflictPromptOverride = { _, _ in promptShown = true; return .cancel }
        let ok = model.editor.saveEditor(forTabID: id)
        XCTAssertFalse(ok, "a clean buffer over a changed disk reloads — it does not write")
        XCTAssertFalse(promptShown,
            "clean buffer + changed disk is the normal reload path: NO prompt (must not regress)")
        // Disk untouched (we reloaded, didn't write).
        XCTAssertEqual(diskString(at: url), "external v2\n")
        if case .loaded(let f)? = model.tabs.tabs.first(where: { $0.id == id })?.state {
            XCTAssertEqual(f.contents, "external v2\n", "clean buffer reloaded the disk bytes")
        }
    }

    // MARK: - Snapshot-on-save (TSK-1103)

    func test_successfulSave_recordsLocalHistoryVersion() throws {
        let url = try writeFile("hist.md", "v1\n")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        model.editor.updateEditorText("v2 saved\n", forTabID: id)
        XCTAssertTrue(model.editor.saveEditor(forTabID: id))

        let versions = model.editor.localHistoryStore.versions(for: url.path)
        XCTAssertEqual(versions.count, 1, "a successful save records exactly one version")
        let restored = versions.first.flatMap {
            model.editor.localHistoryStore.contentString(of: $0, for: url.path)
        }
        XCTAssertEqual(restored, "v2 saved\n",
            "the snapshot must hold the just-saved text so an overwrite is recoverable")
    }

    func test_overwriteResolution_alsoRecordsHistory() throws {
        // The keep-mine overwrite path is the one most likely to lose the disk
        // change — so it MUST record a recoverable version of what we wrote.
        let url = try writeFile("ovhist.md", "original\n")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        model.editor.updateEditorText("mine kept\n", forTabID: id)
        try backgroundWrite(url, "theirs\n")
        model.editor.saveConflictPromptOverride = { _, _ in .overwrite }
        XCTAssertTrue(model.editor.saveEditor(forTabID: id))

        let versions = model.editor.localHistoryStore.versions(for: url.path)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(
            versions.first.flatMap {
                model.editor.localHistoryStore.contentString(of: $0, for: url.path)
            },
            "mine kept\n")
    }

    func test_failedConflict_cancel_recordsNoHistory() throws {
        let url = try writeFile("nohist.md", "original\n")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        model.editor.updateEditorText("mine\n", forTabID: id)
        try backgroundWrite(url, "theirs\n")
        model.editor.saveConflictPromptOverride = { _, _ in .cancel }
        XCTAssertFalse(model.editor.saveEditor(forTabID: id))

        XCTAssertTrue(model.editor.localHistoryStore.versions(for: url.path).isEmpty,
            "a save that never wrote must record no history version")
    }

    func test_multipleSaves_accumulateVersions() throws {
        let url = try writeFile("multi.md", "v1\n")
        let model = makeModel()
        let id = openAndSeed(url, in: model)
        for text in ["a\n", "b\n", "c\n"] {
            model.editor.updateEditorText(text, forTabID: id)
            XCTAssertTrue(model.editor.saveEditor(forTabID: id))
        }
        let versions = model.editor.localHistoryStore.versions(for: url.path)
        XCTAssertEqual(versions.count, 3,
            "three distinct successful saves record three versions")
    }
}
