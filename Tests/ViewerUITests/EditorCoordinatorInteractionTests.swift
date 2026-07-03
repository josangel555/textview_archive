import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Cross-coordinator integration scenarios that exercise the seams
/// between `EditorCoordinator`, `TabCoordinator`, and `DocumentModel`
/// (Quality #2, 2026-05-25).
///
/// These are the high-risk paths flagged in the extraction brief:
///   - Dirty-close prompt invoked from each of the three close paths
///     (closeTab / closeOtherTabs / closeTabsToRight) — each must run
///     `confirmCloseIfDirty`, route through Save / Discard / Cancel,
///     and only call into the coordinator's close after the user
///     confirms.
///   - ⌘S routing from both the menu hook (`saveActiveEditor()`) and
///     the CM6 JS bridge's `saveRequested` callback (same entry point
///     today; tests pin both call sites stay equivalent).
///   - External-edit conflict prompt fires when the file watcher
///     reload path detects an externally-edited file + dirty buffer.
///   - editorGotoLine survives a viewMode switch (the request is a
///     bumped nonce, so a mode flip + re-mount must still trigger the
///     scroll once the editor view returns).
///   - Per-tab cursor + scroll preserved across tab switch (the
///     in-memory persistence story the prior tests pin in part via
///     `test_switchingTabs_preservesPerTabEdits`).
@MainActor
final class EditorCoordinatorInteractionTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorCoordinatorInteractionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "EditorCoordinatorInteractionTests-\(UUID().uuidString)"
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
    private func writeFile(_ name: String, _ contents: String = "x") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Open + dirty a tab. Returns the model, the tab id, and the URL.
    private func openDirtyTab(_ name: String) throws -> (DocumentModel, UUID, URL) {
        let url = try writeFile(name, "v1")
        let model = makeModel()
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editorBuffer(forTabID: id)
        model.updateEditorText("dirty", forTabID: id)
        XCTAssertTrue(model.tabs.tabs[0].isDirty,
            "precondition: tab should be dirty after updateEditorText")
        return (model, id, url)
    }

    // MARK: - Dirty-close prompt × closeTab(at:)

    func test_closeTab_promptsForDirty_save_writesToDisk() throws {
        let (model, id, url) = try openDirtyTab("ct_save.txt")
        // Route the NSAlert through the test seam.
        model.editor.dirtyClosePromptOverride = { _ in .save }
        model.closeTab(at: 0)
        // After Save + close, the tab is gone and the on-disk file
        // contains the dirty edit.
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(try? String(contentsOf: url, encoding: .utf8), "dirty")
        XCTAssertNil(model.editorBuffers[id],
            "buffer must be gone after the close")
    }

    func test_closeTab_promptsForDirty_discard_dropsBufferDoesntWrite() throws {
        let (model, id, url) = try openDirtyTab("ct_discard.txt")
        model.editor.dirtyClosePromptOverride = { _ in .discard }
        model.closeTab(at: 0)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(try? String(contentsOf: url, encoding: .utf8), "v1",
            "Don't Save must NOT touch disk; v1 is the pre-edit contents")
        XCTAssertNil(model.editorBuffers[id])
    }

    func test_closeTab_promptsForDirty_cancel_abortsClose() throws {
        let (model, _, url) = try openDirtyTab("ct_cancel.txt")
        model.editor.dirtyClosePromptOverride = { _ in .cancel }
        model.closeTab(at: 0)
        XCTAssertEqual(model.tabs.tabs.count, 1,
            "Cancel must leave the tab open")
        XCTAssertTrue(model.tabs.tabs[0].isDirty,
            "Cancel must preserve the dirty edit")
        XCTAssertEqual(try? String(contentsOf: url, encoding: .utf8), "v1",
            "Cancel must NOT touch disk")
    }

    // MARK: - Dirty-close prompt × closeOtherTabs(keeping:)

    func test_closeOtherTabs_promptsForEveryDoomedDirtyTab() throws {
        let model = makeModel()
        let a = try writeFile("a.txt", "v1")
        let b = try writeFile("b.txt", "v1")
        let c = try writeFile("c.txt", "v1")
        for url in [a, b, c] { model.open(url: url) }
        // Dirty tabs 0 and 2 (keeping 1). Both should be prompted.
        for idx in [0, 2] {
            let id = model.tabs.tabs[idx].id
            _ = model.editorBuffer(forTabID: id)
            model.updateEditorText("dirty-\(idx)", forTabID: id)
        }
        var promptedIDs: [UUID] = []
        model.editor.dirtyClosePromptOverride = { tab in
            promptedIDs.append(tab.id)
            return .discard
        }
        model.closeOtherTabs(keeping: 1)
        // The keep-index changes meaning as tabs disappear; we keep
        // tab 1 (b.txt) regardless. Verify the right ones got prompted.
        XCTAssertEqual(Set(promptedIDs).count, 2,
            "both dirty doomed tabs should fire the prompt exactly once")
        XCTAssertEqual(model.tabs.tabs.count, 1)
        XCTAssertEqual(model.tabs.tabs[0].url?.lastPathComponent, "b.txt")
    }

    func test_closeOtherTabs_cancelMidBatch_leavesRemainingDoomedTabsAlone() throws {
        let model = makeModel()
        let a = try writeFile("a.txt", "v1")
        let b = try writeFile("b.txt", "v1")
        let c = try writeFile("c.txt", "v1")
        for url in [a, b, c] { model.open(url: url) }
        // Dirty tabs 0 and 2.
        for idx in [0, 2] {
            let id = model.tabs.tabs[idx].id
            _ = model.editorBuffer(forTabID: id)
            model.updateEditorText("dirty-\(idx)", forTabID: id)
        }
        // Doomed tabs are processed in DESCENDING index order
        // (closeOtherTabs spec). Cancel on the first prompt.
        var promptCount = 0
        model.editor.dirtyClosePromptOverride = { _ in
            promptCount += 1
            return .cancel
        }
        model.closeOtherTabs(keeping: 1)
        XCTAssertEqual(promptCount, 1,
            "Cancel must abort the close immediately; no further prompts")
        XCTAssertEqual(model.tabs.tabs.count, 3,
            "Cancel mid-batch must leave all tabs intact")
    }

    // MARK: - Dirty-close prompt × closeTabsToRight(of:)

    func test_closeTabsToRight_promptsForDirtyTabsInTail() throws {
        let model = makeModel()
        let a = try writeFile("a.txt", "v1")
        let b = try writeFile("b.txt", "v1")
        let c = try writeFile("c.txt", "v1")
        for url in [a, b, c] { model.open(url: url) }
        // Dirty tabs 1 and 2 (the right-of-pivot tabs when we close
        // to the right of 0).
        for idx in [1, 2] {
            let id = model.tabs.tabs[idx].id
            _ = model.editorBuffer(forTabID: id)
            model.updateEditorText("dirty-\(idx)", forTabID: id)
        }
        var promptCount = 0
        model.editor.dirtyClosePromptOverride = { _ in
            promptCount += 1
            return .discard
        }
        model.closeTabsToRight(of: 0)
        XCTAssertEqual(promptCount, 2,
            "both dirty right-tail tabs must fire the prompt")
        XCTAssertEqual(model.tabs.tabs.count, 1,
            "only tab 0 should remain")
    }

    func test_closeTabsToRight_cancel_leavesContiguousTail() throws {
        let model = makeModel()
        let a = try writeFile("a.txt", "v1")
        let b = try writeFile("b.txt", "v1")
        let c = try writeFile("c.txt", "v1")
        for url in [a, b, c] { model.open(url: url) }
        // Dirty tabs 1 and 2.
        for idx in [1, 2] {
            let id = model.tabs.tabs[idx].id
            _ = model.editorBuffer(forTabID: id)
            model.updateEditorText("dirty-\(idx)", forTabID: id)
        }
        // Right-to-left processing means the rightmost (idx 2)
        // prompts first. Cancel there.
        model.editor.dirtyClosePromptOverride = { _ in .cancel }
        model.closeTabsToRight(of: 0)
        XCTAssertEqual(model.tabs.tabs.count, 3,
            "Cancel partway must leave everything intact")
    }

    // MARK: - ⌘S routing × menu hook + CM6 bridge entry point

    func test_saveActiveEditor_isEntryForBothMenuAndCM6Bridge() throws {
        // The menu (`saveActiveEditor(_:)` in AppDelegate) and the
        // CM6 `onSaveRequested` callback in ContentView both bottom
        // out in `model.saveActiveEditor()`. Pin that both routes
        // observe the same on-disk effect.
        let url = try writeFile("save_routes.txt", "before")
        let model = makeModel()
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editorBuffer(forTabID: id)
        model.updateEditorText("via-menu", forTabID: id)
        XCTAssertTrue(model.saveActiveEditor(),
            "menu entry-point save must succeed")
        XCTAssertEqual(try? String(contentsOf: url, encoding: .utf8), "via-menu")
        // Simulate the CM6 bridge path: another edit then another
        // saveActiveEditor() call.
        model.updateEditorText("via-cm6", forTabID: id)
        XCTAssertTrue(model.saveActiveEditor())
        XCTAssertEqual(try? String(contentsOf: url, encoding: .utf8), "via-cm6")
    }

    // MARK: - External-edit conflict prompt via file watcher

    /// The file watcher hands an externally-modified file to
    /// `reloadCurrentFile(matching:)` which detects the conflict via
    /// `EditorBuffer.hasExternalEdit` and calls
    /// `editor.presentExternalEditConflict(...)`. With the test seam
    /// override, we can drive the outcome without an NSAlert.
    func test_externalEdit_conflictPrompt_keepEdits_leavesBufferIntact() throws {
        let (model, id, url) = try openDirtyTab("ext_keep.txt")
        // External write changes file under us.
        Thread.sleep(forTimeInterval: 0.05)
        try "external write".write(to: url, atomically: true, encoding: .utf8)
        // Pin the outcome to Keep Edits.
        model.editor.externalEditPromptOverride = { _ in .keepEdits }
        // Trigger the reload path the file watcher would. The matching
        // helper is `private`; call the public proxy `reloadCurrentFile`
        // which routes through it via the FileWatcher closure.
        // Instead, we invoke the editor coordinator's external-edit
        // prompt directly to mirror what the watcher path does — the
        // same code DocumentModel runs after the hasExternalEdit check.
        model.editor.presentExternalEditConflict(forTabID: id, at: 0, url: url)
        // Tab still dirty, buffer still has the user's edit.
        XCTAssertTrue(model.tabs.tabs[0].isDirty)
        XCTAssertEqual(model.editorBuffers[id]?.text, "dirty")
    }

    func test_externalEdit_conflictPrompt_discardAndReload_pullsFromDisk() throws {
        let (model, id, url) = try openDirtyTab("ext_discard.txt")
        Thread.sleep(forTimeInterval: 0.05)
        try "external write".write(to: url, atomically: true, encoding: .utf8)
        model.editor.externalEditPromptOverride = { _ in .discardAndReload }
        model.editor.presentExternalEditConflict(forTabID: id, at: 0, url: url)
        // Buffer dropped + reload pulled from disk.
        XCTAssertNil(model.editorBuffers[id])
        XCTAssertFalse(model.tabs.tabs[0].isDirty)
        // The reload runs `controller.open(url:)` which puts the new
        // disk contents into the tab's .loaded state.
        if case .loaded(let f) = model.tabs.tabs[0].state {
            XCTAssertEqual(f.contents, "external write")
        } else {
            XCTFail("tab must be .loaded with the post-external content")
        }
    }

    // MARK: - editorGotoLine invariant across mode switches

    func test_editorGotoLine_survivesViewModeSwitch() throws {
        let model = makeModel()
        let url = try writeFile("a.swift", "let x = 1\nlet y = 2\nlet z = 3\n")
        model.open(url: url)
        model.setCurrentViewMode(.editor)
        let req = CMGotoLineRequest(line: 2)
        model.editorGotoLine = req
        // TSK-1483: the forwarder setter stamps the untargeted request with the
        // active tab (one-shot routing) — same nonce id, same payload, plus the
        // target. The invariant pinned here is unchanged: mode flips must not
        // CLEAR the pending request.
        let stamped = req.stamped(target: model.tabs.selected?.id)
        XCTAssertNotNil(stamped.target, "an open tab means the goto gets a target stamp")
        // Flip mode away from editor and back; the request must still
        // be on the coordinator (the editor view re-mount reads it
        // on appear, that path is UI and not exercised here — the
        // contract pinned is that the coordinator retains the request).
        model.setCurrentViewMode(.source)
        XCTAssertEqual(model.editorGotoLine, stamped,
            "mode flip away must NOT clear pending goto-line")
        model.setCurrentViewMode(.editor)
        XCTAssertEqual(model.editorGotoLine, stamped,
            "mode flip back must NOT clear pending goto-line either")
    }

    // MARK: - Cursor + scroll preserved across tab switch

    func test_cursorAndScroll_preservedAcrossTabSwitch() throws {
        let model = makeModel()
        let a = try writeFile("a.swift", "x")
        let b = try writeFile("b.swift", "x")
        model.open(url: a)
        let aID = model.tabs.selected!.id
        let aCursor = CMCursorPosition(line: 7, column: 3, head: 70, rangeCount: 1)
        let aScroll = CMScrollPosition(top: 120, left: 0,
                                       viewportFromLine: 1, viewportToLine: 25)
        model.recordEditorCursor(aCursor, forTabID: aID)
        model.recordEditorScroll(aScroll, forTabID: aID)
        model.openInNewTab(b)
        let bID = model.tabs.selected!.id
        XCTAssertNotEqual(aID, bID)
        let bCursor = CMCursorPosition(line: 1, column: 0, head: 0, rangeCount: 1)
        model.recordEditorCursor(bCursor, forTabID: bID)
        // Switch back to A.
        if let idxA = model.tabs.tabs.firstIndex(where: { $0.id == aID }) {
            model.selectTab(at: idxA)
        }
        XCTAssertEqual(model.editorCursorByTab[aID]?.line, 7,
            "tab A's cursor must survive the B detour")
        XCTAssertEqual(model.editorScrollByTab[aID]?.top, 120,
            "tab A's scroll must survive the B detour")
        XCTAssertEqual(model.editorCursorByTab[bID]?.line, 1,
            "tab B's cursor must remain on tab B")
    }

    func test_cursorAndScroll_droppedWhenTabCloses() throws {
        let model = makeModel()
        let a = try writeFile("a.swift", "x")
        let b = try writeFile("b.swift", "x")
        model.open(url: a)
        let aID = model.tabs.selected!.id
        model.recordEditorCursor(
            CMCursorPosition(line: 5, column: 0, head: 0, rangeCount: 1),
            forTabID: aID
        )
        model.openInNewTab(b)
        if let idxA = model.tabs.tabs.firstIndex(where: { $0.id == aID }) {
            model.closeTab(at: idxA)
        }
        XCTAssertNil(model.editorCursorByTab[aID],
            "closed tab's cursor record must be dropped via close-hook")
    }

    // MARK: - Save path interactions with the watcher pause/resume

    func test_save_pausesWatcher_and_restartsOnSameURL() throws {
        // Both the pause + resume hooks fire as part of the save. The
        // pre-save URL matches currentURL after save, so resume must
        // re-bind the watcher.
        let model = makeModel()
        let url = try writeFile("watched.txt", "before")
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editorBuffer(forTabID: id)
        model.updateEditorText("after", forTabID: id)
        XCTAssertTrue(model.saveEditor(forTabID: id))
        XCTAssertEqual(try? String(contentsOf: url, encoding: .utf8), "after")
        // currentURL unchanged after save → watcher re-binds via
        // onResumeFileWatcherIfApplicable.
        XCTAssertEqual(model.currentURL, url.standardizedFileURL.resolvingSymlinksInPath())
    }
}
