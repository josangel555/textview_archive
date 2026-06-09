import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Host-tier behaviour tests for the sidebar preview-tab feature
/// (TSK-306 / TSK-272 — see `docs/PREVIEW_TAB_DESIGN.md`), exercised at the
/// `DocumentModel` boundary the SwiftUI triggers actually call.
///
/// The model core (`TabsState.openPreview/promoteTab`) is unit-tested in
/// `TabsStatePreviewTests`; these pin the DocumentModel forwarder +
/// auto-promote-on-edit wiring — i.e. that `openPreview(url:)` reuses ONE
/// ephemeral slot and that every promotion path (re-open / Enter via
/// `open(url:)` / editing the buffer) clears the flag. The actual SwiftUI
/// gesture routing + italic affordance are the VM-only render layer
/// (Phase 2/3); these cover the host-testable behaviour beneath them, so a
/// logic regression fails the headless gate even though the pixels are VM-only.
///
/// Tier: window-free (drives DocumentModel directly, no NSWindow) — host-safe,
/// same harness as `DocumentModelEditorForwarderTests`.
@MainActor
final class DocumentModelPreviewTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentModelPreviewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DocumentModelPreviewTests-\(UUID().uuidString)"
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

    /// Tabs flagged ephemeral-preview, by title (stable, order-independent).
    private func previewTitles(_ model: DocumentModel) -> [String] {
        model.tabs.tabs.filter { $0.isPreview }.map { $0.title }
    }

    // MARK: - openPreview creates / reuses ONE ephemeral slot

    func test_openPreview_createsOnePreviewTab() throws {
        let model = makeModel()
        let a = try writeFile("a.txt", "alpha")
        model.openPreview(url: a)
        XCTAssertEqual(model.tabs.tabs.count, 1, "first preview reuses the blank slot")
        XCTAssertEqual(previewTitles(model), ["a.txt"], "the one tab is flagged preview")
        XCTAssertEqual(model.tabs.selected?.title, "a.txt")
        XCTAssertNotNil(model.tabs.previewTabID)
    }

    func test_openPreview_secondFile_reusesOneSlot() throws {
        let model = makeModel()
        let a = try writeFile("a.txt", "alpha")
        let b = try writeFile("b.txt", "bravo")
        model.openPreview(url: a)
        let firstID = model.tabs.previewTabID
        model.openPreview(url: b)
        // VSCode "scrub": at most ONE preview tab — b replaces a in place.
        XCTAssertEqual(model.tabs.tabs.count, 1, "preview slot is reused, not appended")
        XCTAssertEqual(previewTitles(model), ["b.txt"])
        XCTAssertEqual(model.tabs.previewTabID, firstID,
                       "same tab id reused — content swapped in place, not a new tab")
        XCTAssertNil(model.tabs.tabs.first { $0.title == "a.txt" },
                     "the previewed a.txt was replaced, not left behind")
    }

    // MARK: - Promotion paths (all three commit gestures)

    func test_openPreview_sameFileAgain_promotes() throws {
        // Models the second click of a double-click: re-opening the already-
        // previewed file finds it open and reveals-as-permanent.
        let model = makeModel()
        let a = try writeFile("a.txt", "alpha")
        model.openPreview(url: a)
        XCTAssertEqual(previewTitles(model), ["a.txt"])
        model.openPreview(url: a)
        XCTAssertEqual(model.tabs.tabs.count, 1, "no duplicate tab on re-open")
        XCTAssertTrue(previewTitles(model).isEmpty, "re-opening the preview promotes it")
        XCTAssertNil(model.tabs.previewTabID)
    }

    func test_open_promotesPreview() throws {
        // Enter / double-click route through `open(url:)`, which must commit
        // the ephemeral tab to permanent (no second tab).
        let model = makeModel()
        let a = try writeFile("a.txt", "alpha")
        model.openPreview(url: a)
        XCTAssertEqual(previewTitles(model), ["a.txt"])
        model.open(url: a)
        XCTAssertEqual(model.tabs.tabs.count, 1)
        XCTAssertTrue(previewTitles(model).isEmpty, "open() promotes the preview to permanent")
    }

    func test_editingPreview_promotes() throws {
        // Editing a preview's buffer must promote it — a dirty buffer can't be
        // silently discarded by the next single-click reusing the slot.
        let model = makeModel()
        let a = try writeFile("a.swift", "let x = 1\n")
        model.openPreview(url: a)
        let id = try XCTUnwrap(model.tabs.previewTabID)
        _ = model.editorBuffer(forTabID: id)   // materialize the buffer
        model.updateEditorText("let x = 2\n", forTabID: id)
        XCTAssertTrue(previewTitles(model).isEmpty,
                      "an edit commits the preview tab to permanent")
        XCTAssertNil(model.tabs.previewTabID)
        XCTAssertTrue(model.tabs.tabs[0].isDirty, "the edit still marks the tab dirty")
    }

    // MARK: - Never preview a file that already has a permanent tab

    func test_openPreview_alreadyOpenPermanent_revealsNotPreviews() throws {
        let model = makeModel()
        let a = try writeFile("a.txt", "alpha")
        model.open(url: a)                     // permanent tab
        XCTAssertTrue(previewTitles(model).isEmpty)
        model.openPreview(url: a)              // single-click the same file
        XCTAssertEqual(model.tabs.tabs.count, 1, "no second tab")
        XCTAssertTrue(previewTitles(model).isEmpty,
                      "an already-permanent file is revealed, never demoted to preview")
    }

    // MARK: - Preview is per-model / never duplicated across two distinct files

    func test_openPreview_invariant_atMostOnePreview() throws {
        let model = makeModel()
        let a = try writeFile("a.txt", "alpha")
        let b = try writeFile("b.txt", "bravo")
        let c = try writeFile("c.txt", "charlie")
        model.open(url: a)            // permanent
        model.openPreview(url: b)     // preview b
        model.openPreview(url: c)     // scrub to c (reuse slot)
        XCTAssertLessThanOrEqual(previewTitles(model).count, 1,
                                 "invariant: never two preview tabs")
        XCTAssertEqual(previewTitles(model), ["c.txt"])
        XCTAssertEqual(model.tabs.tabs.count, 2, "a (permanent) + one preview slot")
    }
}
