import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-1269 slice 1 — host coverage for `DocumentModel.reconcileExternalEdit`,
/// the DECISION half of wiring `ExternalEditReconciler` (3-way auto-merge) into
/// the dirty-buffer external-change flow. Pins that base/ours/theirs are sourced
/// correctly (base = buffer.originalText, ours = buffer.text, theirs = disk) and
/// that each `Outcome` plus the no-buffer / unreadable-disk nil guards hold. The
/// APPLY of an outcome (buffer-replace + CM6 redisplay) and routing refreshTab /
/// the watcher through it are slices 2/3 (render → review).
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
}
