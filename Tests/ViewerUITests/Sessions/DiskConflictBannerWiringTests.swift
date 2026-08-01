import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-1166 — host-safe behavioural coverage for the non-modal disk-conflict
/// resolution wired behind the `DiskConflictBanner`. The banner's on-screen
/// visibility (above the CM6 WebView) is the T5 occlusion tier (blocked on the
/// VM Screen-Recording grant, TSK-1334); THIS file pins the model layer that is
/// fully host-testable: `DocumentModel.resolveDiskConflict(_:)` applying each
/// intent through the shared `EditorCoordinator.applyExternalEditOutcome` (the
/// same side-effect the modal `presentExternalEditConflict` uses, so the two
/// surfaces can't drift) and clearing `activeDiskConflict`.
///
/// Filter: `swift test --filter ViewerUITests.DiskConflictBannerWiringTests`
@MainActor
final class DiskConflictBannerWiringTests: XCTestCase {
    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskConflictTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DiskConflictTests-\(UUID().uuidString)"
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
            preferences: PreferencesStore(defaults: defaults))
    }
    @discardableResult
    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    /// Open `url`, seed + dirty its editor buffer, raise a conflict banner for it.
    private func openDirtyWithConflict(_ url: URL, in model: DocumentModel) -> UUID {
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id)
        model.editor.updateEditorText("my unsaved edit", forTabID: id)
        let index = model.tabs.selectedIndex ?? 0
        model.activeDiskConflict = DiskConflictBannerInfo(tabID: id, index: index, url: url)
        return id
    }

    func test_resolveKeepMine_keepsEdits_andClearsBanner() throws {
        let url = try writeFile("a.txt", "disk")
        let model = makeModel()
        let id = openDirtyWithConflict(url, in: model)
        XCTAssertTrue(model.editor.editorBuffers[id]?.isDirty == true, "precondition: dirty")

        model.resolveDiskConflict(.keepMine)
        XCTAssertNil(model.activeDiskConflict, "resolving clears the banner")
        XCTAssertEqual(model.editor.editorBuffers[id]?.text, "my unsaved edit",
                       "keepMine preserves the user's unsaved edits")
        XCTAssertTrue(model.editor.editorBuffers[id]?.isDirty == true,
                      "keepMine keeps the buffer dirty (originalText baseline untouched)")
    }

    func test_resolveTakeDisk_discardsEdits_andClearsBanner() throws {
        let url = try writeFile("a.txt", "disk original")
        let model = makeModel()
        let id = openDirtyWithConflict(url, in: model)
        // Simulate the external write the conflict is about.
        try "disk CHANGED".write(to: url, atomically: true, encoding: .utf8)

        model.resolveDiskConflict(.takeDisk)
        XCTAssertNil(model.activeDiskConflict, "resolving clears the banner")
        // takeDisk discards the dirty buffer (+ reloads from disk); the user's
        // unsaved edit is gone — the buffer is no longer the edited text.
        XCTAssertNotEqual(model.editor.editorBuffers[id]?.text, "my unsaved edit",
                          "takeDisk discards the unsaved edits")
    }

    /// CONTRACT CHANGE (2026-08-01, live false-conflict incident): when disk
    /// still MATCHES the buffer's last-saved baseline, the banner itself was a
    /// false alarm — a content-blind (mtime, size) mismatch from a same-bytes
    /// touch. `Merge…` used to dead-end here ("Couldn't merge", banner stuck),
    /// and the plausible-looking escape — Reload — swapped the buffer to the
    /// last-saved text. Now Merge… on a false conflict CLEARS the banner,
    /// keeps the edits, and adopts the fresh disk stamp. (The 2026-07-28
    /// "merge must never silently pick a side" rule is about REAL divergence —
    /// the next test still pins that: a real conflict opens the 3-pane sheet
    /// and the banner stays until it resolves.)
    func test_resolveMerge_onFalseConflict_clearsBanner_andKeepsEdits() throws {
        let url = try writeFile("a.txt", "disk")
        let model = makeModel()
        let id = openDirtyWithConflict(url, in: model)

        model.resolveDiskConflict(.merge)

        XCTAssertNil(model.activeDiskConflict,
                     "a false conflict (disk == baseline) must clear, not dead-end")
        XCTAssertNil(model.activeConflictResolution, "nothing to hand-resolve")
        XCTAssertEqual(model.editor.editorBuffers[id]?.text, "my unsaved edit",
                       "the unsaved edits are untouched")
        XCTAssertTrue(model.editor.editorBuffers[id]?.isDirty == true,
                      "the buffer stays dirty — nothing was saved or discarded")
    }

    /// I-01 root cause (2026-08-01): a watcher tick whose fingerprint mismatch
    /// is CONTENT-IDENTICAL churn (git checkout / stash / backup tooling) must
    /// not raise the conflict banner over a dirty buffer — the new stamp is
    /// adopted and the edits are left alone. This is the exact live-incident
    /// shape that previously led to Reload "restoring the previous version".
    func test_watcherTick_sameContentTouch_raisesNoBanner_andAdoptsStamp() throws {
        let url = try writeFile("a.txt", "disk")
        let model = makeModel()
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id)
        model.editor.updateEditorText("my unsaved edit", forTabID: id)

        // Rewrite IDENTICAL content until the mtime provably moves off the
        // buffer's load-time baseline (size can't move — same bytes).
        let baseline = model.editor.editorBuffers[id]?.lastSavedMTime
        var moved = false
        for _ in 0..<200 {
            try "disk".write(to: url, atomically: true, encoding: .utf8)
            let a = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let m = a?[.modificationDate] as? Date, m != baseline {
                moved = true; break
            }
        }
        XCTAssertTrue(moved, "test rig: mtime never moved off the baseline")

        model.reloadCurrentFile(matching: url)

        XCTAssertNil(model.activeDiskConflict,
                     "content-identical churn must not raise the conflict banner")
        XCTAssertEqual(model.editor.editorBuffers[id]?.text, "my unsaved edit",
                       "the dirty buffer is untouched")
        XCTAssertTrue(model.editor.editorBuffers[id]?.isDirty == true)
        XCTAssertNotEqual(model.editor.editorBuffers[id]?.lastSavedMTime, baseline,
                          "the fresh disk stamp is adopted so the touch stops re-firing")
        // Idempotent: a duplicate tick with the adopted stamp stays silent.
        model.reloadCurrentFile(matching: url)
        XCTAssertNil(model.activeDiskConflict)
    }

    /// With a REAL divergence, merge opens the 3-pane resolution sheet.
    func test_resolveMerge_withRealDivergence_opensTheResolutionSheet() throws {
        let url = try writeFile("a.txt", "disk")
        let model = makeModel()
        let id = openDirtyWithConflict(url, in: model)
        try "THEIR CHANGE".write(to: url, atomically: true, encoding: .utf8)

        model.resolveDiskConflict(.merge)

        let session = try XCTUnwrap(model.activeConflictResolution,
                                    "Merge… must present the 3-pane merge")
        XCTAssertEqual(session.id, id)
        XCTAssertNotNil(model.activeDiskConflict,
                        "unresolved until the user applies the merge")
    }

    func test_resolve_withNoActiveConflict_isNoOp() {
        let model = makeModel()
        XCTAssertNil(model.activeDiskConflict)
        model.resolveDiskConflict(.keepMine)   // must not crash
        XCTAssertNil(model.activeDiskConflict)
    }

    func test_bannerInfo_fileName_isLastPathComponent() {
        let info = DiskConflictBannerInfo(
            tabID: UUID(), index: 0, url: URL(fileURLWithPath: "/a/b/notes.md"))
        XCTAssertEqual(info.fileName, "notes.md")
    }
}
