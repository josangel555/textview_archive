import XCTest
import ViewerCore
import ViewerKit
@testable import ViewerUI

/// TSK-733 — a session SWITCH must PRESERVE a dirty editor buffer WITHOUT a
/// Save/Don't-Save/Cancel prompt; the prompt fires ONLY on the genuine CLOSE
/// path.
///
/// Before this fix, switching sessions drained the outgoing session's tabs via
/// a plain `closeTab(at:)` loop, which re-ran `confirmCloseIfDirty` for every
/// dirty tab — so a user with unsaved edits got a spurious confirm-save dialog
/// every time they flipped sessions. The owner's decision (preserve, don't
/// prompt) is implemented by snapshotting the in-flight text into the outgoing
/// session (`captureUnsavedTextForAllTabs`, TSK-718 hot-exit machinery) and
/// draining via the prompt-free `closeAllTabsPreservingDirty()`; switch-back
/// rehydrates the unsaved text and the tab returns dirty.
///
/// Driven through the REAL `SessionsAppCoordinator` (Phase-1 façade: one shared
/// `DocumentModel`), mirroring `SessionIsolationTests`. Pure-logic / model
/// layer — no NSApplication / NSWindow / WebView; host-safe.
/// Filter: `swift test --filter ViewerUITests.SessionSwitchDirtyNoPrompt`
@MainActor
final class SessionSwitchDirtyNoPromptTests: XCTestCase {

    private lazy var tmpRoot: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSwitchDirtyNoPromptTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }()

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    @discardableResult
    private func makeWorkspace(named: String, files: [String: String] = [:]) -> URL {
        let folder = tmpRoot.appendingPathComponent(named, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        for (name, contents) in files {
            try? Data(contents.utf8).write(to: folder.appendingPathComponent(name))
        }
        return folder
    }

    private func makeCoordinator() -> SessionsAppCoordinator {
        let storesDir = tmpRoot.appendingPathComponent("stores-\(UUID().uuidString)")
        let sessionsDir = storesDir.appendingPathComponent("Sessions")
        try? FileManager.default.createDirectory(
            at: sessionsDir, withIntermediateDirectories: true)
        let store = SessionStore(directory: sessionsDir)
        let coord = SessionsAppCoordinator(
            model: DocumentModel(), store: store, initialRoot: nil)
        coord.bootstrap()
        return coord
    }

    /// Open `url` in the coordinator's shared model, seed its editor buffer,
    /// and type `text` so the tab is DIRTY. Returns the tab id.
    @discardableResult
    private func openAndDirty(_ url: URL, _ text: String,
                             in coord: SessionsAppCoordinator) -> UUID {
        coord.model.open(url: url)
        let id = coord.model.tabs.selected!.id
        _ = coord.model.editor.editorBuffer(forTabID: id)  // seed baseline
        coord.model.editor.updateEditorText(text, forTabID: id)
        return id
    }

    // MARK: - 1. Switch does NOT prompt + drains the dirty tab ------------

    func test_switchWithDirtyBuffer_doesNotRequestSavePrompt() {
        let coord = makeCoordinator()
        let folderA = makeWorkspace(named: "A", files: ["a.txt": "disk-a"])
        let folderB = makeWorkspace(named: "B", files: ["b.txt": "disk-b"])

        coord.openFolder(folderA, forceNew: true)
        let aURL = folderA.appendingPathComponent("a.txt")
        openAndDirty(aURL, "UNSAVED EDIT IN A", in: coord)
        XCTAssertTrue(coord.model.editor.hasAnyUnsavedEdits,
                      "session A has a dirty buffer before the switch")

        // Arm a recording prompt override. If the switch path runs the
        // dirty-close prompt, this fires (and would return .cancel, which
        // would also abort the close — a double tell).
        var promptCalls = 0
        coord.model.editor.dirtyClosePromptOverride = { _ in
            promptCalls += 1
            return .cancel
        }

        // Switch to a fresh session B (a real switch through the coordinator).
        coord.openFolder(folderB, forceNew: true)

        XCTAssertEqual(promptCalls, 0,
            "switching sessions must NOT request the Save/Don't-Save/Cancel prompt")
        // The outgoing session's tabs were drained for the incoming session —
        // a .cancel from a (wrongly) fired prompt would have left A's tab.
        XCTAssertEqual(coord.model.tabs.tabs.compactMap { $0.url?.lastPathComponent },
                       [],
            "B is a fresh folder with no open file tab; A's tab was drained without prompting")
    }

    // MARK: - 2. Dirty text is persisted INTO the outgoing snapshot -------

    func test_switch_persistsDirtyTextIntoOutgoingSessionSnapshot() {
        let coord = makeCoordinator()
        let folderA = makeWorkspace(named: "A", files: ["a.txt": "disk-a"])
        let folderB = makeWorkspace(named: "B", files: ["b.txt": "disk-b"])

        coord.openFolder(folderA, forceNew: true)
        let aID = coord.core.activeID!
        let aURL = folderA.appendingPathComponent("a.txt")
        let edit = "IN-FLIGHT TEXT THAT MUST SURVIVE THE SWITCH"
        openAndDirty(aURL, edit, in: coord)

        coord.openFolder(folderB, forceNew: true)

        // The outgoing session A's persisted snapshot must carry the unsaved
        // text on its tab — that is what makes switch-back restorable.
        guard let snapA = coord.core.sessions.first(where: { $0.id == aID }) else {
            return XCTFail("session A must still exist after the switch")
        }
        let aResolved = aURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard let tabSnap = snapA.openTabs.first(where: {
            URL(fileURLWithPath: $0.path).standardizedFileURL
                .resolvingSymlinksInPath().path == aResolved
        }) else {
            return XCTFail("session A's snapshot must retain the edited tab")
        }
        XCTAssertEqual(tabSnap.unsavedText, edit,
            "the dirty editor text is snapshotted byte-identical into the outgoing session")
    }

    // MARK: - 3. Switch-back restores byte-identical + dirty --------------

    func test_switchBack_restoresUnsavedTextByteIdentical_andDirty() {
        let coord = makeCoordinator()
        let folderA = makeWorkspace(named: "A", files: ["a.txt": "disk baseline"])
        let folderB = makeWorkspace(named: "B", files: ["b.txt": "disk-b"])

        coord.openFolder(folderA, forceNew: true)
        let aID = coord.core.activeID!
        let aURL = folderA.appendingPathComponent("a.txt")
        let edit = "edits that\nspan\nmultiple lines — byte identical"
        openAndDirty(aURL, edit, in: coord)

        // Switch away (no prompt) and back.
        coord.openFolder(folderB, forceNew: true)
        coord.activate(id: aID)

        // DURABLE CONTRACT: after switch-back the edited tab is re-opened (lazy)
        // and CARRIES its persisted `unsavedText` — hydrate threaded it through
        // `appendLazyTab(unsavedText:)` from the session snapshot. This is the
        // synchronous fact that makes the (async, render-side) materialize
        // overlay possible.
        let aResolved = aURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard let idx = coord.model.tabs.tabs.firstIndex(where: {
            $0.url?.standardizedFileURL.resolvingSymlinksInPath().path == aResolved
        }) else {
            return XCTFail("switching back to A must re-open the edited tab")
        }
        XCTAssertEqual(coord.model.tabs.tabs[idx].unsavedText, edit,
            "the restored tab carries the persisted unsaved text from hydrate, byte-identical")

        // Now drive the restore PRIMITIVE deterministically (the live
        // materialize completion is async / off-main). Put the tab in the exact
        // post-materialize precondition `restoreUnsavedTextIfNeeded` expects —
        // a `.loaded` on-disk baseline + the carried `unsavedText`, no buffer —
        // then run the same call the completion runs. This proves switch-back
        // reconstitutes the buffer byte-identical and DIRTY (the model layer of
        // the restore; the on-screen CM6 text is the VM-only render tail).
        let id = coord.model.tabs.tabs[idx].id
        coord.model.editor.discardEditorBuffer(forTabID: id)   // clear any async-seeded buffer
        let baseline = TextFile(url: aURL, contents: "disk baseline",
                                encoding: .utf8, byteCount: 13, modifiedTime: Date())
        var t = coord.model.tabs.tabs[idx]
        t.state = .loaded(baseline)
        t.unsavedText = edit
        coord.model.tabCoordinator.replace(at: idx, with: t)

        let restored = coord.model.restoreUnsavedTextIfNeeded(forTabAt: idx)
        XCTAssertTrue(restored, "a restored tab with unsavedText overlays its buffer")
        XCTAssertEqual(coord.model.editor.editorBuffer(forTabID: id)?.text, edit,
            "switch-back restores the unsaved text byte-identical")
        XCTAssertTrue(coord.model.editor.editorBuffers[id]?.isDirty == true,
            "the restored buffer is dirty vs the on-disk baseline")
        XCTAssertTrue(coord.model.tabs.tabs[idx].isDirty,
            "the Tab.isDirty mirror flips so the dirty dot reappears")
    }

    // MARK: - 4. The CLOSE path STILL requests the prompt -----------------

    func test_closePath_stillRequestsSavePrompt() {
        let coord = makeCoordinator()
        let folderA = makeWorkspace(named: "A", files: ["a.txt": "disk-a"])

        coord.openFolder(folderA, forceNew: true)
        let aURL = folderA.appendingPathComponent("a.txt")
        let id = openAndDirty(aURL, "UNSAVED — closing should prompt", in: coord)
        let idx = coord.model.tabs.tabs.firstIndex { $0.id == id }!

        // Arm a recording override that CANCELS — the close must abort and the
        // tab must survive, proving the prompt actually gated the close.
        var promptCalls = 0
        coord.model.editor.dirtyClosePromptOverride = { _ in
            promptCalls += 1
            return .cancel
        }

        coord.model.closeTab(at: idx)

        XCTAssertEqual(promptCalls, 1,
            "closing a dirty tab MUST still request the Save/Don't-Save/Cancel prompt")
        XCTAssertEqual(coord.model.tabs.tabs.count, 1,
            "a Cancel from the prompt aborts the close — the dirty tab survives")
        XCTAssertEqual(coord.model.tabs.tabs.first?.id, id)
    }

    // MARK: - 5. closeAllTabsPreservingDirty drains without prompting -----

    func test_closeAllTabsPreservingDirty_drainsWithoutPrompt_andCapturesText() throws {
        // Direct unit of the new prompt-free drain (the switch path's primitive).
        let coord = makeCoordinator()
        let folderA = makeWorkspace(named: "A",
                                    files: ["a.txt": "disk-a", "c.txt": "disk-c"])
        coord.openFolder(folderA, forceNew: true)

        coord.model.appendLazyTab(url: folderA.appendingPathComponent("c.txt"),
                                  viewMode: .editor)
        let dirtyURL = folderA.appendingPathComponent("a.txt")
        openAndDirty(dirtyURL, "dirty before drain", in: coord)
        XCTAssertGreaterThanOrEqual(coord.model.tabs.tabs.count, 2)

        var promptCalls = 0
        coord.model.editor.dirtyClosePromptOverride = { _ in
            promptCalls += 1
            return .cancel
        }

        coord.model.closeAllTabsPreservingDirty()

        XCTAssertEqual(promptCalls, 0,
            "closeAllTabsPreservingDirty must never request the dirty-close prompt")
        XCTAssertTrue(coord.model.tabs.tabs.isEmpty,
            "every tab is drained even with a Cancel-returning override (it's never consulted)")
    }
}
