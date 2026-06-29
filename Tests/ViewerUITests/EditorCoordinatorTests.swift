import XCTest
import Combine
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Pure-logic state-machine coverage for `EditorCoordinator`, mirroring
/// the `TabCoordinatorTests` and `FindCoordinatorTests` pattern (Quality
/// #2, 2026-05-25).
///
/// Exercises the coordinator surface in isolation (no DocumentModel)
/// using a fresh TabCoordinator + injected effect closures. The
/// dirty-close / external-edit NSAlert sites are driven via the
/// `dirtyClosePromptOverride` / `externalEditPromptOverride` test
/// seams so this suite runs cleanly headless.
///
/// Heavy cross-coordinator scenarios live in
/// `EditorCoordinatorInteractionTests` so failures point at the
/// specific seam rather than at arithmetic in this file.
@MainActor
final class EditorCoordinatorTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorCoordinatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String = "x") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Class-wrapped capture box used by the wiring closures below so
    /// test assertions can read the mutations without needing inout
    /// semantics in closure capture.
    private final class CaptureBox {
        var replaceLog: [(Int, ViewerCore.Tab)] = []
        var cursorMirrorLog: [CMCursorPosition] = []
        var pauseCount = 0
        var resumeCount = 0
        var reloadLog: [(URL, Int)] = []
    }

    private func wire(_ ec: EditorCoordinator, _ tc: TabCoordinator) -> CaptureBox {
        let box = CaptureBox()
        ec.tabsSnapshot = { [tc] in tc.tabs.tabs }
        ec.activeTabIDSnapshot = { [tc] in tc.tabs.selected?.id }
        ec.onReplaceTab = { [tc, box] idx, tab in
            box.replaceLog.append((idx, tab))
            tc.replace(at: idx, with: tab)
        }
        ec.onCursorMirrorToStatusBar = { [box] pos in
            box.cursorMirrorLog.append(pos)
        }
        ec.onPauseFileWatcher = { [box] in box.pauseCount += 1 }
        ec.onResumeFileWatcherIfApplicable = { [box] _ in box.resumeCount += 1 }
        ec.watchedURLSnapshot = { nil }
        ec.onReloadFromDisk = { [box] url, idx in box.reloadLog.append((url, idx)) }
        return box
    }

    // MARK: - Initial state

    func test_initial_state_isEmpty() {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        XCTAssertNil(ec.editorGotoLine)
        XCTAssertEqual(ec.editorIndentation, .spaces(2))
        XCTAssertFalse(ec.saveEditorOnBlur)
        XCTAssertTrue(ec.editorCursorByTab.isEmpty)
        XCTAssertTrue(ec.editorScrollByTab.isEmpty)
        XCTAssertTrue(ec.pendingEditorDiagnostics.isEmpty)
        XCTAssertFalse(ec.hasAnyUnsavedEdits)
    }

    // MARK: - Cursor + scroll persistence

    func test_recordEditorCursor_storesAndMirrors() {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        let box = wire(ec, tc)
        let id = UUID()
        let pos = CMCursorPosition(line: 12, column: 4, head: 100, rangeCount: 1)
        ec.recordEditorCursor(pos, forTabID: id)
        XCTAssertEqual(ec.editorCursorByTab[id]?.line, 12)
        XCTAssertEqual(ec.editorCursorByTab[id]?.column, 4)
        XCTAssertEqual(box.cursorMirrorLog.count, 1,
            "cursor mirror callback must fire so status bar L:C updates")
        XCTAssertEqual(box.cursorMirrorLog.first?.line, 12)
    }

    func test_recordEditorScroll_storesPerTab() {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        _ = wire(ec, tc)
        let a = UUID(), b = UUID()
        ec.recordEditorScroll(
            CMScrollPosition(top: 100, left: 0, viewportFromLine: 5, viewportToLine: 30),
            forTabID: a
        )
        ec.recordEditorScroll(
            CMScrollPosition(top: 250, left: 0, viewportFromLine: 10, viewportToLine: 35),
            forTabID: b
        )
        XCTAssertEqual(ec.editorScrollByTab[a]?.top, 100)
        XCTAssertEqual(ec.editorScrollByTab[b]?.top, 250)
    }

    // MARK: - Insert-at-cursor request (TSK-299)

    func test_insertIntoEditor_setsRequestWithText() {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        _ = wire(ec, tc)
        XCTAssertNil(ec.editorInsertRequest)
        ec.insertIntoEditor("Jun 7, 2026")
        XCTAssertEqual(ec.editorInsertRequest?.text, "Jun 7, 2026")
    }

    func test_insertIntoEditor_consecutiveCallsAreDistinct() {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        _ = wire(ec, tc)
        ec.insertIntoEditor("stamp")
        let first = ec.editorInsertRequest
        ec.insertIntoEditor("stamp") // same text — must still re-fire
        let second = ec.editorInsertRequest
        XCTAssertNotNil(first); XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second,
            "identical-text inserts need distinct nonces so both dispatch")
    }

    func test_insertIntoEditor_emptyIsNoOp() {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        _ = wire(ec, tc)
        ec.insertIntoEditor("")
        XCTAssertNil(ec.editorInsertRequest)
    }

    // MARK: - Pending diagnostics fan-out

    func test_pendingDiagnostics_consumeClears() {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        _ = wire(ec, tc)
        let id = UUID()
        let diag = CMDiagnostic(
            from: 0, to: 1, severity: .error, message: "boom", source: nil
        )
        ec.pendingEditorDiagnostics[id] = [diag]
        XCTAssertEqual(ec.pendingEditorDiagnostics[id]?.count, 1)
        ec.consumePendingEditorDiagnostics(forTabID: id)
        XCTAssertNil(ec.pendingEditorDiagnostics[id])
    }

    func test_setEditorDiagnostics_pushesToMatchingOpenEditorTab() throws {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        _ = wire(ec, tc)
        let url = try writeFile("a.swift", "let x = 1\n")
        let file = TextFile(url: url, contents: "let x = 1\n", encoding: .utf8,
                            byteCount: 10, modifiedTime: nil)
        tc.append(Tab(url: url, state: .loaded(file)))
        let id = tc.selected!.id
        // Seed the buffer (setEditorDiagnostics requires a buffer to
        // do position translation).
        _ = tc.editorBuffer(forTabID: id)
        let lspDiag = LSPDiagnostic(
            range: LSPRange(
                start: LSPPosition(line: 0, character: 0),
                end: LSPPosition(line: 0, character: 1)
            ),
            severity: .error, code: nil, source: nil, message: "boom"
        )
        ec.setEditorDiagnostics([lspDiag], forURL: url)
        XCTAssertNotNil(ec.pendingEditorDiagnostics[id])
        XCTAssertFalse((ec.pendingEditorDiagnostics[id] ?? []).isEmpty)
    }

    // MARK: - Spell + LSP diagnostics merge (TSK-1146)

    func test_mergeEditorDiagnostics_sortsByDocumentOffset() {
        let lsp = [CMDiagnostic(from: 5, to: 7, severity: .error, message: "e", source: "lsp")]
        let spell = [
            CMDiagnostic(from: 1, to: 4, severity: .info, message: "s1", source: "spell"),
            CMDiagnostic(from: 10, to: 13, severity: .info, message: "s2", source: "spell"),
        ]
        XCTAssertEqual(
            EditorCoordinator.mergeEditorDiagnostics(lsp, spell).map(\.from), [1, 5, 10])
    }

    func test_setEditorSpellDiagnostics_mapsIssuesAndPublishes() {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        _ = wire(ec, tc)
        let id = UUID()
        ec.setEditorSpellDiagnostics(
            [SpellingIssue(word: "teh", range: NSRange(location: 3, length: 3), line: 1, column: 4)],
            forTabID: id)
        let d = ec.pendingEditorDiagnostics[id]
        XCTAssertEqual(d?.count, 1)
        XCTAssertEqual(d?.first?.from, 3)
        XCTAssertEqual(d?.first?.source, "spell")
    }

    func test_setEditorSpellDiagnostics_emptyClearsSpellLayer() {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        _ = wire(ec, tc)
        let id = UUID()
        ec.setEditorSpellDiagnostics(
            [SpellingIssue(word: "x", range: NSRange(location: 0, length: 1), line: 1, column: 1)],
            forTabID: id)
        XCTAssertEqual(ec.pendingEditorDiagnostics[id]?.count, 1)
        ec.setEditorSpellDiagnostics([], forTabID: id)
        XCTAssertEqual(ec.pendingEditorDiagnostics[id]?.count, 0)
    }

    func test_lspAndSpell_coexist_neitherClobbers() throws {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        _ = wire(ec, tc)
        let url = try writeFile("a.swift", "let x = 1\n")
        let file = TextFile(url: url, contents: "let x = 1\n", encoding: .utf8,
                            byteCount: 10, modifiedTime: nil)
        tc.append(Tab(url: url, state: .loaded(file)))
        let id = tc.selected!.id
        _ = tc.editorBuffer(forTabID: id)
        let lspDiag = LSPDiagnostic(
            range: LSPRange(start: LSPPosition(line: 0, character: 0),
                            end: LSPPosition(line: 0, character: 1)),
            severity: .error, code: nil, source: nil, message: "boom")
        ec.setEditorDiagnostics([lspDiag], forURL: url)
        let lspCount = ec.pendingEditorDiagnostics[id]?.count ?? 0
        XCTAssertGreaterThan(lspCount, 0)
        // Adding spell must NOT drop the LSP diags.
        ec.setEditorSpellDiagnostics(
            [SpellingIssue(word: "x", range: NSRange(location: 4, length: 1), line: 1, column: 5)],
            forTabID: id)
        let combined = ec.pendingEditorDiagnostics[id] ?? []
        XCTAssertEqual(combined.count, lspCount + 1)
        XCTAssertTrue(combined.contains { $0.source == "spell" })
        XCTAssertTrue(combined.contains { $0.source != "spell" }, "LSP diag survived")
        // Re-publishing LSP must KEEP the spell layer (the source-tracking point).
        ec.setEditorDiagnostics([lspDiag], forURL: url)
        XCTAssertTrue((ec.pendingEditorDiagnostics[id] ?? []).contains { $0.source == "spell" },
                      "LSP re-publish must not clobber spell")
    }

    func test_shouldSpellCheckEditor_proseUnderCap_true() {
        XCTAssertTrue(EditorCoordinator.shouldSpellCheckEditor(
            url: URL(fileURLWithPath: "/a/b.md"), textLength: 100))
        XCTAssertTrue(EditorCoordinator.shouldSpellCheckEditor(
            url: URL(fileURLWithPath: "/a/b.txt"), textLength: 100))
    }

    func test_shouldSpellCheckEditor_codeOverCapNilEmpty_false() {
        XCTAssertFalse(EditorCoordinator.shouldSpellCheckEditor(
            url: URL(fileURLWithPath: "/a/b.swift"), textLength: 100))   // code
        XCTAssertFalse(EditorCoordinator.shouldSpellCheckEditor(
            url: URL(fileURLWithPath: "/a/b.md"), textLength: 300_000))  // over cap
        XCTAssertFalse(EditorCoordinator.shouldSpellCheckEditor(url: nil, textLength: 100))
        XCTAssertFalse(EditorCoordinator.shouldSpellCheckEditor(
            url: URL(fileURLWithPath: "/a/b.md"), textLength: 0))        // empty
    }

    func test_isMarkdownProse() {
        XCTAssertTrue(EditorCoordinator.isMarkdownProse(url: URL(fileURLWithPath: "/a.md")))
        XCTAssertFalse(EditorCoordinator.isMarkdownProse(url: URL(fileURLWithPath: "/a.txt")))
        XCTAssertFalse(EditorCoordinator.isMarkdownProse(url: URL(fileURLWithPath: "/a.swift")))
    }

    func test_runEditorSpellPass_codeFile_publishesNoSpell() {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        _ = wire(ec, tc)
        let id = UUID()
        // A code file is gated out — no spell layer published even with misspellings.
        ec.runEditorSpellPass(text: "mispeld wrods everywher",
                              url: URL(fileURLWithPath: "/a.swift"), forTabID: id)
        XCTAssertNil(ec.pendingEditorDiagnostics[id])
    }

    func test_setEditorSpellDiagnostics_unchangedEmpty_noRepublish() async {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        _ = wire(ec, tc)
        let id = UUID()
        var count = 0
        let sub = ec.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        // Empty spell on a fresh tab is a no-op — must NOT publish (no churn for
        // code files that clear the empty layer on every keystroke).
        ec.setEditorSpellDiagnostics([], forTabID: id)
        await Task.yield()
        XCTAssertEqual(count, 0)
    }

    func test_setEditorDiagnostics_unknownURL_isNoOp() throws {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        _ = wire(ec, tc)
        let url = try writeFile("a.swift", "x")
        let other = try writeFile("other.swift", "x")
        let file = TextFile(url: url, contents: "x", encoding: .utf8,
                            byteCount: 1, modifiedTime: nil)
        tc.append(Tab(url: url, state: .loaded(file)))
        let id = tc.selected!.id
        _ = tc.editorBuffer(forTabID: id)
        let lspDiag = LSPDiagnostic(
            range: LSPRange(
                start: LSPPosition(line: 0, character: 0),
                end: LSPPosition(line: 0, character: 1)
            ),
            severity: .error, code: nil, source: nil, message: "boom"
        )
        ec.setEditorDiagnostics([lspDiag], forURL: other)
        XCTAssertNil(ec.pendingEditorDiagnostics[id],
            "diagnostics for an unrelated URL must not leak into other open tabs")
    }

    // MARK: - editorBuffers forwarding

    func test_editorBuffer_forwardsToTabCoordinator() throws {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        _ = wire(ec, tc)
        let url = try writeFile("a.swift", "let x = 1\n")
        let file = TextFile(url: url, contents: "let x = 1\n", encoding: .utf8,
                            byteCount: 10, modifiedTime: nil)
        tc.append(Tab(url: url, state: .loaded(file)))
        let id = tc.selected!.id
        let buf = ec.editorBuffer(forTabID: id)
        XCTAssertNotNil(buf)
        XCTAssertEqual(buf?.text, "let x = 1\n")
        XCTAssertEqual(ec.editorBuffers[id]?.text, "let x = 1\n",
            "editorBuffers forwarder must read through TabCoordinator")
    }

    func test_updateEditorText_flipsDirtyDot() throws {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        let box = wire(ec, tc)
        let url = try writeFile("a.swift", "v1")
        let file = TextFile(url: url, contents: "v1", encoding: .utf8,
                            byteCount: 2, modifiedTime: nil)
        tc.append(Tab(url: url, state: .loaded(file)))
        let id = tc.selected!.id
        _ = ec.editorBuffer(forTabID: id)
        ec.updateEditorText("v2", forTabID: id)
        XCTAssertTrue(ec.editorBuffers[id]?.isDirty == true)
        XCTAssertFalse(box.replaceLog.isEmpty,
            "onReplaceTab must fire so the dirty-dot Tab snapshot mirrors")
        XCTAssertTrue(tc.tabs.tabs[0].isDirty)
    }

    func test_updateEditorText_sameText_isNoOp() throws {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        let box = wire(ec, tc)
        let url = try writeFile("a.swift", "stable")
        let file = TextFile(url: url, contents: "stable", encoding: .utf8,
                            byteCount: 6, modifiedTime: nil)
        tc.append(Tab(url: url, state: .loaded(file)))
        let id = tc.selected!.id
        _ = ec.editorBuffer(forTabID: id)
        let replacesBefore = box.replaceLog.count
        ec.updateEditorText("stable", forTabID: id)
        XCTAssertEqual(box.replaceLog.count, replacesBefore,
            "identical-text update must not fire a tab replace")
        XCTAssertFalse(tc.tabs.tabs[0].isDirty)
    }

    func test_discardEditorBuffer_clearsDirtyMirror() throws {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        let box = wire(ec, tc)
        let url = try writeFile("a.swift", "v1")
        let file = TextFile(url: url, contents: "v1", encoding: .utf8,
                            byteCount: 2, modifiedTime: nil)
        tc.append(Tab(url: url, state: .loaded(file)))
        let id = tc.selected!.id
        _ = ec.editorBuffer(forTabID: id)
        ec.updateEditorText("dirty", forTabID: id)
        XCTAssertTrue(tc.tabs.tabs[0].isDirty)
        box.replaceLog.removeAll()
        ec.discardEditorBuffer(forTabID: id)
        XCTAssertNil(ec.editorBuffers[id])
        XCTAssertFalse(tc.tabs.tabs[0].isDirty)
        XCTAssertEqual(box.replaceLog.count, 1,
            "discard must fire one tab replace to clear the dirty dot")
    }

    // MARK: - hasAnyUnsavedEdits

    func test_hasAnyUnsavedEdits_followsTabIsDirty() throws {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        _ = wire(ec, tc)
        let url = try writeFile("a.swift", "v1")
        let file = TextFile(url: url, contents: "v1", encoding: .utf8,
                            byteCount: 2, modifiedTime: nil)
        tc.append(Tab(url: url, state: .loaded(file)))
        let id = tc.selected!.id
        XCTAssertFalse(ec.hasAnyUnsavedEdits)
        _ = ec.editorBuffer(forTabID: id)
        ec.updateEditorText("v2", forTabID: id)
        XCTAssertTrue(ec.hasAnyUnsavedEdits)
    }

    // MARK: - confirmCloseIfDirty (with test seam override)

    func test_confirmCloseIfDirty_cleanTab_returnsNil() throws {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        _ = wire(ec, tc)
        let url = try writeFile("a.swift", "v1")
        let file = TextFile(url: url, contents: "v1", encoding: .utf8,
                            byteCount: 2, modifiedTime: nil)
        tc.append(Tab(url: url, state: .loaded(file)))
        XCTAssertNil(ec.confirmCloseIfDirty(at: 0),
            "clean tab must short-circuit without invoking the prompt")
    }

    func test_confirmCloseIfDirty_dirtyTab_runsOverride() throws {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        _ = wire(ec, tc)
        let url = try writeFile("a.swift", "v1")
        let file = TextFile(url: url, contents: "v1", encoding: .utf8,
                            byteCount: 2, modifiedTime: nil)
        tc.append(Tab(url: url, state: .loaded(file)))
        let id = tc.selected!.id
        _ = ec.editorBuffer(forTabID: id)
        ec.updateEditorText("dirty", forTabID: id)
        var overrideCalled = false
        ec.dirtyClosePromptOverride = { tab in
            overrideCalled = true
            XCTAssertEqual(tab.id, id)
            return .discard
        }
        let outcome = ec.confirmCloseIfDirty(at: 0)
        XCTAssertTrue(overrideCalled)
        XCTAssertEqual(outcome, .discard)
    }

    func test_confirmCloseIfDirty_outOfBoundsIndex_returnsNil() {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        _ = wire(ec, tc)
        XCTAssertNil(ec.confirmCloseIfDirty(at: 42))
    }

    // MARK: - Goto line nonce

    func test_editorGotoLine_setter_publishes() async {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        _ = wire(ec, tc)
        var count = 0
        let sub = ec.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        ec.editorGotoLine = CMGotoLineRequest(line: 42, select: false)
        await Task.yield()
        XCTAssertGreaterThan(count, 0,
            "editorGotoLine assignment must publish so CodeMirror view picks it up")
        XCTAssertEqual(ec.editorGotoLine?.line, 42)
    }

    // MARK: - Save path with injected effects

    func test_saveEditor_pausesAndResumesWatcher() throws {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        let box = wire(ec, tc)
        let url = try writeFile("a.swift", "v1")
        let file = TextFile(url: url, contents: "v1", encoding: .utf8,
                            byteCount: 2, modifiedTime: nil)
        tc.append(Tab(url: url, state: .loaded(file)))
        let id = tc.selected!.id
        _ = ec.editorBuffer(forTabID: id)
        ec.updateEditorText("v2", forTabID: id)
        XCTAssertTrue(ec.saveEditor(forTabID: id))
        XCTAssertEqual(box.pauseCount, 1,
            "save must pause file watcher to avoid race with self-write")
        XCTAssertEqual(box.resumeCount, 1,
            "save must resume watcher in defer")
        XCTAssertFalse(tc.tabs.tabs[0].isDirty,
            "successful save must clear the dirty dot")
    }

    func test_saveActiveEditor_noSelection_returnsFalse() {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        _ = wire(ec, tc)
        XCTAssertFalse(ec.saveActiveEditor())
    }

    // MARK: - EDIT-S2-SAVE: single write stamp drives buffer + TextFile

    func test_saveEditor_buffersBaselineMatchesRefreshedTextFile() throws {
        // The post-save buffer baseline (markSaved) and the refreshed
        // .loaded TextFile.modifiedTime must come from the SAME write
        // stamp — not two independent stats that could read different
        // mtimes if the file is touched between them.
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        let box = wire(ec, tc)
        let url = try writeFile("s2.txt", "v1")
        let file = TextFile(url: url, contents: "v1", encoding: .utf8,
                            byteCount: 2, modifiedTime: nil)
        tc.append(Tab(url: url, state: .loaded(file)))
        let id = tc.selected!.id
        _ = ec.editorBuffer(forTabID: id)
        ec.updateEditorText("v2-longer", forTabID: id)
        XCTAssertTrue(ec.saveEditor(forTabID: id))

        let savedBaseline = ec.editorBuffers[id]?.lastSavedMTime
        XCTAssertNotNil(savedBaseline)
        guard let tab = tc.tabs.tabs.first(where: { $0.id == id }),
              case .loaded(let refreshed) = tab.state else {
            return XCTFail("tab must be .loaded after save")
        }
        XCTAssertEqual(refreshed.modifiedTime, savedBaseline,
            "TextFile.modifiedTime must equal the buffer's saved baseline (one stamp)")
        XCTAssertEqual(refreshed.byteCount, "v2-longer".utf8.count,
            "byteCount must reflect the on-disk size from the same stamp")
        _ = box  // silence unused
    }

    // MARK: - FW-7: lost-event window reconciliation

    func test_saveEditor_externalWriteInUnwatchedWindow_cleanBuffer_reloads() throws {
        // Simulate another process writing the file AFTER our save but
        // while the watcher is still paused: do it from the resume hook.
        // The post-resume reconcile must notice the divergence and, since
        // the buffer is clean post-save, trigger a straight reload (no
        // prompt, nothing to lose).
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        let box = wire(ec, tc)
        let url = try writeFile("fw7.txt", "v1")
        let file = TextFile(url: url, contents: "v1", encoding: .utf8,
                            byteCount: 2, modifiedTime: nil)
        tc.append(Tab(url: url, state: .loaded(file)))
        let id = tc.selected!.id
        _ = ec.editorBuffer(forTabID: id)
        ec.updateEditorText("my save", forTabID: id)

        // Resume hook stands in for "watcher comes back up" — and we use
        // that exact moment to land a racing external write so the
        // fingerprint diverges from the stamp we just wrote.
        ec.onResumeFileWatcherIfApplicable = { [box] _ in
            box.resumeCount += 1
            Thread.sleep(forTimeInterval: 0.05) // ensure a distinct mtime
            try? "clobbered by another process".write(
                to: url, atomically: true, encoding: .utf8)
        }

        XCTAssertTrue(ec.saveEditor(forTabID: id))
        XCTAssertEqual(box.reloadLog.count, 1,
            "lost external write on a clean buffer must trigger a reload")
        XCTAssertEqual(box.reloadLog.first?.0, url)
    }

    func test_saveEditor_noExternalWrite_doesNotReload() throws {
        // The common case: nothing else touches the file. The post-resume
        // reconcile must be a NO-OP — the disk fingerprint equals the
        // stamp we just wrote, so no spurious reload.
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        let box = wire(ec, tc)
        let url = try writeFile("fw7-noop.txt", "v1")
        let file = TextFile(url: url, contents: "v1", encoding: .utf8,
                            byteCount: 2, modifiedTime: nil)
        tc.append(Tab(url: url, state: .loaded(file)))
        let id = tc.selected!.id
        _ = ec.editorBuffer(forTabID: id)
        ec.updateEditorText("clean save", forTabID: id)
        XCTAssertTrue(ec.saveEditor(forTabID: id))
        XCTAssertTrue(box.reloadLog.isEmpty,
            "an undisturbed save must not spuriously reload")
    }

    func test_saveEditor_lostWindowWrite_whileDirtyAgain_promptsConflict() throws {
        // Edge case: the user typed again after the save completed (so
        // the buffer is dirty again) AND an external write raced in the
        // unwatched window. That's a genuine conflict → prompt, not a
        // silent reload that would drop the re-typed edits.
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        let box = wire(ec, tc)
        let url = try writeFile("fw7-conflict.txt", "v1")
        let file = TextFile(url: url, contents: "v1", encoding: .utf8,
                            byteCount: 2, modifiedTime: nil)
        tc.append(Tab(url: url, state: .loaded(file)))
        let id = tc.selected!.id
        _ = ec.editorBuffer(forTabID: id)
        ec.updateEditorText("first save", forTabID: id)

        var promptCalled = false
        ec.externalEditPromptOverride = { _ in promptCalled = true; return .keepEdits }
        ec.onResumeFileWatcherIfApplicable = { [box] _ in
            box.resumeCount += 1
            // External write races in...
            Thread.sleep(forTimeInterval: 0.05)
            try? "external clobber".write(to: url, atomically: true, encoding: .utf8)
            // ...and the user keeps typing, re-dirtying the buffer before
            // the reconcile reads isDirty.
            ec.updateEditorText("re-typed after save", forTabID: id)
        }

        XCTAssertTrue(ec.saveEditor(forTabID: id))
        XCTAssertTrue(promptCalled,
            "dirty-again + lost external write must surface the conflict prompt")
        XCTAssertTrue(box.reloadLog.isEmpty,
            "conflict path must not silently reload")
    }

    func test_saveEditor_noBuffer_returnsFalse() {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        _ = wire(ec, tc)
        XCTAssertFalse(ec.saveEditor(forTabID: UUID()))
    }

    // MARK: - External-edit conflict prompt (with test seam override)

    func test_externalEditPrompt_keepEdits_refreshesFingerprint() throws {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        let box = wire(ec, tc)
        let url = try writeFile("conflict.txt", "original")
        let file = TextFile(url: url, contents: "original", encoding: .utf8,
                            byteCount: 8, modifiedTime: nil)
        tc.append(Tab(url: url, state: .loaded(file)))
        let id = tc.selected!.id
        _ = ec.editorBuffer(forTabID: id)
        ec.updateEditorText("local edits", forTabID: id)
        // Simulate an external write so the on-disk fingerprint differs.
        Thread.sleep(forTimeInterval: 0.05)
        try "external".write(to: url, atomically: true, encoding: .utf8)
        ec.externalEditPromptOverride = { _ in .keepEdits }
        let outcome = ec.presentExternalEditConflict(forTabID: id, at: 0, url: url)
        XCTAssertEqual(outcome, .keepEdits)
        XCTAssertTrue(box.reloadLog.isEmpty,
            "Keep My Edits must NOT trigger a reload")
        XCTAssertTrue(ec.editorBuffers[id]?.isDirty == true,
            "Keep My Edits must leave the dirty flag intact (preserve user work)")
    }

    func test_externalEditPrompt_discardAndReload_dropsBufferAndReloads() throws {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        let box = wire(ec, tc)
        let url = try writeFile("conflict.txt", "original")
        let file = TextFile(url: url, contents: "original", encoding: .utf8,
                            byteCount: 8, modifiedTime: nil)
        tc.append(Tab(url: url, state: .loaded(file)))
        let id = tc.selected!.id
        _ = ec.editorBuffer(forTabID: id)
        ec.updateEditorText("local edits", forTabID: id)
        ec.externalEditPromptOverride = { _ in .discardAndReload }
        let outcome = ec.presentExternalEditConflict(forTabID: id, at: 0, url: url)
        XCTAssertEqual(outcome, .discardAndReload)
        XCTAssertNil(ec.editorBuffers[id],
            "discard branch must drop the buffer")
        XCTAssertFalse(tc.tabs.tabs[0].isDirty,
            "discard branch must clear the dirty dot")
        XCTAssertEqual(box.reloadLog.count, 1)
        XCTAssertEqual(box.reloadLog.first?.0, url)
        XCTAssertEqual(box.reloadLog.first?.1, 0)
    }

    // MARK: - Independence — editor mutations don't touch find/CSV state

    func test_pendingDiagnostics_doesNotMutateOtherEditorState() {
        let tc = TabCoordinator()
        let ec = EditorCoordinator(tabCoordinator: tc)
        _ = wire(ec, tc)
        let id = UUID()
        ec.recordEditorCursor(
            CMCursorPosition(line: 5, column: 0, head: 0, rangeCount: 1), forTabID: id
        )
        let diag = CMDiagnostic(
            from: 0, to: 1, severity: .error, message: "boom", source: nil
        )
        ec.pendingEditorDiagnostics[id] = [diag]
        XCTAssertEqual(ec.editorCursorByTab[id]?.line, 5,
            "diagnostics mutation must not clobber cursor record")
    }
}
