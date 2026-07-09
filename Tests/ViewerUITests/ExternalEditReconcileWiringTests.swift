import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-1269/1165 — host coverage for wiring `ExternalEditReconciler` (3-way
/// auto-merge) into the dirty-buffer external-change flow.
///   • DECISION (`reconcileExternalEdit`): base/ours/theirs are sourced correctly
///     (base = buffer.originalText, ours = buffer.text, theirs = disk) and each
///     `Outcome` plus the no-buffer / unreadable-disk nil guards hold.
///   • APPLY (`applyExternalAutoMerge`, slices 2/3): a non-overlapping `.autoMerged`
///     is applied to the buffer and kept DIRTY (baseline preserved for Revert); a
///     `.conflict` returns false with the buffer untouched (caller shows the banner).
/// The only remaining tail is the LIVE CM6 redisplay after an external merge, which
/// reuses the proven clean-reload `setEditorBuffer` path (VM/on-screen UNVERIFIED —
/// it needs a real watcher fire, so it isn't cleanly scene-drivable).
@MainActor
final class ExternalEditReconcileWiringTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalEditReconcileWiringTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "ExternalEditReconcileWiringTests-\(UUID().uuidString)"
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

    /// Open `url` + seed its editor buffer (via the seeding getter), returning the tab id.
    private func openSeeded(_ url: URL, in model: DocumentModel) -> UUID {
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id)   // seed from the tab's .loaded state
        return id
    }

    // disk == base → no external change (even with local edits present)
    func test_noExternalChange_whenDiskMatchesBaseline() throws {
        let url = try writeFile("a.txt", "line1\nline2\n")
        let model = makeModel()
        let id = openSeeded(url, in: model)
        model.editor.updateEditorText("LOCAL\nline2\n", forTabID: id)   // local edits; disk untouched
        XCTAssertEqual(model.reconcileExternalEdit(forTabID: id, url: url), .noExternalChange)
    }

    // local == base (no local edits) + disk changed → take disk wholesale
    func test_cleanReload_whenNoLocalEditsButDiskChanged() throws {
        let url = try writeFile("b.txt", "line1\nline2\n")
        let model = makeModel()
        let id = openSeeded(url, in: model)
        try "line1\nDISK\n".write(to: url, atomically: true, encoding: .utf8)   // external change, buffer clean
        XCTAssertEqual(model.reconcileExternalEdit(forTabID: id, url: url), .cleanReload("line1\nDISK\n"))
    }

    // local + disk diverge in NON-overlapping regions → auto-merge keeps both
    func test_autoMerged_whenNonOverlapping() throws {
        let url = try writeFile("c.txt", "a\nb\nc\n")
        let model = makeModel()
        let id = openSeeded(url, in: model)
        model.editor.updateEditorText("X\nb\nc\n", forTabID: id)            // local edits line 1
        try "a\nb\nZ\n".write(to: url, atomically: true, encoding: .utf8)   // disk edits line 3
        guard case .autoMerged(let merged)? = model.reconcileExternalEdit(forTabID: id, url: url) else {
            return XCTFail("expected .autoMerged for non-overlapping edits")
        }
        XCTAssertTrue(merged.contains("X") && merged.contains("Z"),
            "auto-merge must keep BOTH non-overlapping edits; got: \(merged)")
    }

    // local + disk edit the SAME region → conflict (git-style markers)
    func test_conflict_whenOverlapping() throws {
        let url = try writeFile("d.txt", "a\nb\nc\n")
        let model = makeModel()
        let id = openSeeded(url, in: model)
        model.editor.updateEditorText("LOCAL\nb\nc\n", forTabID: id)        // local edits line 1
        try "DISK\nb\nc\n".write(to: url, atomically: true, encoding: .utf8)  // disk edits line 1 (overlap)
        guard case .conflict(_, let count)? = model.reconcileExternalEdit(forTabID: id, url: url) else {
            return XCTFail("expected .conflict for overlapping edits")
        }
        XCTAssertGreaterThanOrEqual(count, 1)
    }

    // no editor buffer for the tab id → nil (caller falls back to the prompt)
    func test_nil_whenNoEditorBuffer() throws {
        let url = try writeFile("e.txt", "x\n")
        let model = makeModel()
        XCTAssertNil(model.reconcileExternalEdit(forTabID: UUID(), url: url),
            "no buffer for an unknown tab id → nil (non-seeding access)")
    }

    // unreadable disk path → nil
    func test_nil_whenDiskUnreadable() throws {
        let url = try writeFile("f.txt", "x\n")
        let model = makeModel()
        let id = openSeeded(url, in: model)
        let gone = tmpDir.appendingPathComponent("does-not-exist.txt")
        XCTAssertNil(model.reconcileExternalEdit(forTabID: id, url: gone),
            "unreadable disk path → nil")
    }

    // MARK: - slices 2/3: applyExternalAutoMerge (APPLY the outcome)

    private func diskFingerprint(_ url: URL) -> (Date?, Int?) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.modificationDate] as? Date, attrs?[.size] as? Int)
    }

    // non-overlapping local + disk edits → merge is APPLIED to the buffer, which
    // stays DIRTY (originalText untouched so the user still saves the merge).
    func test_applyAutoMerge_appliesMerge_andKeepsBufferDirty() throws {
        let url = try writeFile("g.txt", "a\nb\nc\n")
        let model = makeModel()
        let id = openSeeded(url, in: model)
        model.editor.updateEditorText("X\nb\nc\n", forTabID: id)            // local edits line 1
        try "a\nb\nZ\n".write(to: url, atomically: true, encoding: .utf8)   // disk edits line 3
        let (mtime, size) = diskFingerprint(url)

        let applied = model.applyExternalAutoMerge(
            forTabID: id, url: url, diskMTime: mtime, diskSize: size)

        XCTAssertTrue(applied, "non-overlapping edits must auto-merge+apply")
        let buf = model.editor.editorBuffers[id]
        XCTAssertNotNil(buf)
        XCTAssertTrue(buf!.text.contains("X") && buf!.text.contains("Z"),
            "applied buffer must carry BOTH edits; got: \(buf!.text)")
        XCTAssertTrue(buf!.isDirty,
            "merge stays dirty so the user saves it (baseline preserved for Revert)")
    }

    // overlapping edits → NOT applied (returns false); the caller surfaces the
    // conflict banner. The buffer keeps the user's local text untouched.
    func test_applyAutoMerge_returnsFalse_onConflict_bufferUntouched() throws {
        let url = try writeFile("h.txt", "a\nb\nc\n")
        let model = makeModel()
        let id = openSeeded(url, in: model)
        model.editor.updateEditorText("LOCAL\nb\nc\n", forTabID: id)          // local edits line 1
        try "DISK\nb\nc\n".write(to: url, atomically: true, encoding: .utf8)  // disk edits line 1 (overlap)
        let (mtime, size) = diskFingerprint(url)

        let applied = model.applyExternalAutoMerge(
            forTabID: id, url: url, diskMTime: mtime, diskSize: size)

        XCTAssertFalse(applied, "overlapping edits must NOT silently merge")
        XCTAssertEqual(model.editor.editorBuffers[id]?.text, "LOCAL\nb\nc\n",
            "on conflict the buffer's local text is left intact for the banner flow")
    }

    // no buffer for the tab id → false (caller falls through to its normal path)
    func test_applyAutoMerge_returnsFalse_whenNoBuffer() throws {
        let url = try writeFile("i.txt", "x\n")
        let model = makeModel()
        XCTAssertFalse(model.applyExternalAutoMerge(
            forTabID: UUID(), url: url, diskMTime: nil, diskSize: nil))
    }

    // MARK: - TSK-1171: 3-way conflict resolution entry points

    // Overlapping edits → beginConflictResolution yields a model with the conflict;
    // resolving + applying writes the resolved text into the (still-dirty) buffer.
    func test_beginAndApplyConflictResolution_writesResolvedText() throws {
        let url = try writeFile("j.txt", "a\nb\nc\n")
        let model = makeModel()
        let id = openSeeded(url, in: model)
        model.editor.updateEditorText("a\nOURS\nc\n", forTabID: id)             // local edits line 2
        try "a\nTHEIRS\nc\n".write(to: url, atomically: true, encoding: .utf8)  // disk edits line 2 (overlap)

        let resModel = try XCTUnwrap(
            model.beginConflictResolution(forTabID: id, url: url),
            "an overlapping edit must produce a resolution model")
        XCTAssertEqual(resModel.conflicts.count, 1)
        resModel.select(.ours, at: 0)
        let resolved = try XCTUnwrap(resModel.resolvedText)
        XCTAssertEqual(resolved, "a\nOURS\nc\n")

        let (mtime, size) = diskFingerprint(url)
        XCTAssertTrue(model.applyConflictResolution(
            resolved, forTabID: id, diskMTime: mtime, diskSize: size))
        let buf = model.editor.editorBuffers[id]
        XCTAssertEqual(buf?.text, "a\nOURS\nc\n", "resolved text lands in the buffer")
        XCTAssertTrue(buf?.isDirty == true, "resolution stays dirty so the user saves it")
    }

    // No overlap (clean auto-merge) → nil (nothing to resolve interactively).
    func test_beginConflictResolution_nil_whenNoConflict() throws {
        let url = try writeFile("k.txt", "a\nb\nc\n")
        let model = makeModel()
        let id = openSeeded(url, in: model)
        model.editor.updateEditorText("X\nb\nc\n", forTabID: id)            // line 1
        try "a\nb\nZ\n".write(to: url, atomically: true, encoding: .utf8)   // line 3 (no overlap)
        XCTAssertNil(model.beginConflictResolution(forTabID: id, url: url),
            "non-overlapping edits auto-merge — no interactive resolution needed")
    }
}
