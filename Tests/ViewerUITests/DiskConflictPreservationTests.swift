import XCTest
import ViewerCore
import ViewerKit
@testable import ViewerUI

/// Owner directive, 2026-07-28: *"don't delete anything — even the discarded
/// version should be in the Local History … Also allow a 3 way merge option
/// too. Never silently pick any version, or silently overwrite a change that
/// happened outside the app."*
///
/// The bug: `Merge…` fell through to `.keepEdits` — the button claimed to merge
/// and silently did Keep Mine, while the 3-pane resolution stack (TSK-1171)
/// shipped with no caller at all.
@MainActor
final class DiskConflictPreservationTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var historyDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskConflictPreservation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        historyDir = tmpDir.appendingPathComponent("history")
        try FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        suiteName = "DiskConflictPreservation-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// `historyEnabled: false` simulates the store legitimately refusing to
    /// keep a copy (disabled history / secret-like file / oversize).
    private func makeModel(historyEnabled: Bool = true) -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults),
            localHistory: LocalHistoryStore(directory: historyDir,
                                            isEnabled: { historyEnabled })
        )
    }

    /// Open `name`, type `edits` into its buffer, then change the file on disk —
    /// the exact divergence the banner exists for.
    private func conflictedTab(
        _ model: DocumentModel, name: String = "doc.md",
        base: String, mine: String, disk: String
    ) throws -> (url: URL, tabID: UUID) {
        let url = tmpDir.appendingPathComponent(name)
        try Data(base.utf8).write(to: url)
        model.open(url: url)
        let id = try XCTUnwrap(model.tabs.selected?.id)
        _ = model.editor.editorBuffer(forTabID: id)
        model.updateEditorText(mine, forTabID: id)
        try Data(disk.utf8).write(to: url)      // the external write
        model.activeDiskConflict = DiskConflictBannerInfo(tabID: id, index: 0, url: url)
        return (url, id)
    }

    private func historyContents(_ model: DocumentModel, _ url: URL) -> [String] {
        model.localHistoryStore.versions(for: url.path).compactMap {
            model.localHistoryStore.contentString(of: $0, for: url.path)
        }
    }

    // MARK: Merge — the reported bug

    /// "Merge…" must open a real 3-pane merge, NOT quietly keep mine.
    func test_mergeIntent_opensTheThreePaneMerge_insteadOfSilentlyKeepingMine() throws {
        let model = makeModel()
        let (_, id) = try conflictedTab(
            model,
            base: "one\ntwo\nthree\n",
            mine: "MINE\ntwo\nthree\n",
            disk: "THEIRS\ntwo\nthree\n")   // same region → a real conflict

        model.resolveDiskConflict(.merge)

        let session = try XCTUnwrap(model.activeConflictResolution,
                                    "Merge… must present the resolution sheet")
        XCTAssertEqual(session.id, id)
        XCTAssertGreaterThan(session.model.conflicts.count, 0)
        XCTAssertFalse(session.model.allResolved, "nothing may be pre-chosen for the user")
        XCTAssertNotNil(model.activeDiskConflict,
                        "the conflict stays unresolved until the user applies a merge")
    }

    /// Applying the merge writes the RESOLVED text — not one side.
    func test_applyingTheMerge_putsTheResolvedTextInTheBuffer_andKeepsItDirty() throws {
        let model = makeModel()
        let (_, id) = try conflictedTab(
            model,
            base: "one\ntwo\n", mine: "MINE\ntwo\n", disk: "THEIRS\ntwo\n")
        model.resolveDiskConflict(.merge)
        let session = try XCTUnwrap(model.activeConflictResolution)

        session.model.resolveAllRemaining(with: .bothOursFirst)
        let resolved = try XCTUnwrap(session.model.resolvedText)
        model.applyActiveConflictResolution(resolved)

        XCTAssertNil(model.activeConflictResolution)
        XCTAssertNil(model.activeDiskConflict)
        let buf = try XCTUnwrap(model.editor.editorBuffers[id])
        XCTAssertEqual(buf.text, resolved)
        XCTAssertTrue(buf.text.contains("MINE"), "the merge keeps my side")
        XCTAssertTrue(buf.text.contains("THEIRS"), "and theirs")
        XCTAssertTrue(buf.isDirty, "the resolution is unsaved until the user saves it")
    }

    /// Cancelling the sheet must not resolve anything — no side gets picked.
    func test_cancellingTheMerge_leavesTheConflictUnresolved() throws {
        let model = makeModel()
        let (_, id) = try conflictedTab(
            model, base: "one\n", mine: "MINE\n", disk: "THEIRS\n")
        model.resolveDiskConflict(.merge)
        XCTAssertNotNil(model.activeConflictResolution)

        model.cancelActiveConflictResolution()

        XCTAssertNil(model.activeConflictResolution)
        XCTAssertNotNil(model.activeDiskConflict, "the banner stays so the user can re-choose")
        XCTAssertEqual(model.editor.editorBuffers[id]?.text, "MINE\n",
                       "cancel must not change the buffer")
    }

    /// Non-overlapping edits have nothing to hand-resolve: both sides are kept
    /// by the auto-merge. Still explicit (a toast), never a silent side-pick.
    func test_mergeWithNonOverlappingEdits_autoMergesKeepingBothSides() throws {
        let model = makeModel()
        let (_, id) = try conflictedTab(
            model,
            base: "one\ntwo\nthree\n",
            mine: "MINE\ntwo\nthree\n",       // first line
            disk: "one\ntwo\nTHEIRS\n")       // last line — disjoint
        model.resolveDiskConflict(.merge)

        XCTAssertNil(model.activeConflictResolution, "no hand-resolution needed")
        let text = try XCTUnwrap(model.editor.editorBuffers[id]?.text)
        XCTAssertTrue(text.contains("MINE") && text.contains("THEIRS"),
                      "an auto-merge must keep BOTH sides, got: \(text)")
    }

    // MARK: nothing is deleted

    func test_takeDisk_putsMyDiscardedEditsInLocalHistory() throws {
        let model = makeModel()
        let (url, _) = try conflictedTab(
            model, base: "base\n", mine: "MY UNSAVED WORK\n", disk: "THEIRS\n")

        model.resolveDiskConflict(.takeDisk)

        XCTAssertTrue(historyContents(model, url).contains("MY UNSAVED WORK\n"),
                      "discarded edits must remain recoverable from Local History")
    }

    /// Keep Mine re-baselines against disk, so the next save overwrites the
    /// external write — capture it BEFORE the app forgets it happened.
    func test_keepMine_putsTheOverwrittenDiskVersionInLocalHistory() throws {
        let model = makeModel()
        let (url, _) = try conflictedTab(
            model, base: "base\n", mine: "MINE\n", disk: "THEIR EXTERNAL CHANGE\n")

        model.resolveDiskConflict(.keepMine)

        XCTAssertTrue(historyContents(model, url).contains("THEIR EXTERNAL CHANGE\n"),
                      "an outside change must never be overwritten without a copy")
    }

    func test_merge_capturesBothSidesBeforeReplacingTheBuffer() throws {
        let model = makeModel()
        let (url, _) = try conflictedTab(
            model, base: "one\n", mine: "MINE\n", disk: "THEIRS\n")

        model.resolveDiskConflict(.merge)

        let stored = historyContents(model, url)
        XCTAssertTrue(stored.contains("MINE\n"), "pre-merge edits must be recoverable")
        XCTAssertTrue(stored.contains("THEIRS\n"), "the disk version must be recoverable")
    }

    // MARK: never destroy silently when history refuses

    /// If Local History can't keep the copy, the user is ASKED. Cancel must
    /// abort the discard entirely — the edits survive.
    func test_whenHistoryCannotKeepTheCopy_cancelAbortsTheDiscard() throws {
        let model = makeModel(historyEnabled: false)
        let (_, id) = try conflictedTab(
            model, base: "base\n", mine: "PRECIOUS\n", disk: "THEIRS\n")

        var asked: (side: DocumentModel.ConflictSide, reason: String)?
        model.unpreservedDiscardPromptOverride = { _, side, reason in
            asked = (side, reason); return .cancel
        }

        model.resolveDiskConflict(.takeDisk)

        XCTAssertEqual(asked?.side, .mine, "the prompt must name what would be lost")
        XCTAssertFalse(asked?.reason.isEmpty ?? true, "and why it can't be kept")
        XCTAssertEqual(model.editor.editorBuffers[id]?.text, "PRECIOUS\n",
                       "cancelling must NOT discard the edits")
        XCTAssertNotNil(model.activeDiskConflict, "the conflict is still unresolved")
    }

    /// The same prompt, answered "discard anyway", honours the explicit choice.
    func test_whenHistoryCannotKeepTheCopy_userMayStillProceedExplicitly() throws {
        let model = makeModel(historyEnabled: false)
        let (_, id) = try conflictedTab(
            model, base: "base\n", mine: "MINE\n", disk: "THEIRS\n")
        model.unpreservedDiscardPromptOverride = { _, _, _ in .proceedAnyway }

        model.resolveDiskConflict(.takeDisk)

        XCTAssertNil(model.activeDiskConflict, "explicitly accepted → the conflict resolves")
        XCTAssertNil(model.editor.editorBuffers[id],
                     "the buffer was discarded, as the user chose")
    }

    /// A clean capture must NOT prompt — the prompt is for genuine data loss.
    func test_normalDiscard_doesNotPrompt() throws {
        let model = makeModel()
        let (_, _) = try conflictedTab(
            model, base: "base\n", mine: "MINE\n", disk: "THEIRS\n")
        var prompted = false
        model.unpreservedDiscardPromptOverride = { _, _, _ in prompted = true; return .cancel }

        model.resolveDiskConflict(.takeDisk)

        XCTAssertFalse(prompted, "history kept the copy — nothing to warn about")
    }
}
