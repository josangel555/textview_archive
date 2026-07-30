import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// The mode bar's "Split" segment (owner 2026-07-29: markdown's picker reads
/// Render | Split | Editor | HEX). Split is a LAYOUT — `.editor` plus the
/// split pane previewing the SAME file — not a new ViewMode case; these pin
/// the entry-building, the selection round-trip, and every transition.
@MainActor
final class SplitEditingModeTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SplitEditing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "SplitEditing-\(UUID().uuidString)"
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
    private func open(_ model: DocumentModel, _ name: String, _ body: String = "# hi\n") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        model.open(url: url)
        return url
    }

    // MARK: entries (pure)

    func test_markdown_getsTheSplitSegment_afterRendered() {
        let entries = DocumentModel.modeBarEntries(
            available: [.rendered, .editor, .source, .hex])
        XCTAssertEqual(entries, [.mode(.rendered), .splitEdit, .mode(.editor),
                                 .mode(.source), .mode(.hex)],
                       "Render | Split | Editor | … — Split sits after Rendered")
    }

    func test_filesWithoutRenderedOrEditor_getNoSplitSegment() {
        // Plain code file: no rendered preview.
        XCTAssertFalse(DocumentModel.modeBarEntries(available: [.editor, .source, .hex])
            .contains(.splitEdit))
        // HTML: rendered but read-only (no editor lens).
        XCTAssertFalse(DocumentModel.modeBarEntries(available: [.rendered, .source, .hex])
            .contains(.splitEdit))
        // Binary.
        XCTAssertFalse(DocumentModel.modeBarEntries(available: [.hex]).contains(.splitEdit))
    }

    // MARK: transitions

    func test_selectingSplit_entersEditorWithSameFileSplit() throws {
        let model = makeModel()
        let url = try open(model, "doc.md")

        model.setModeBarSelection(.splitEdit)

        XCTAssertEqual(model.currentViewMode, .editor, "main pane edits")
        XCTAssertEqual(model.tabCoordinator.splitURL, url, "split previews the same file")
        XCTAssertTrue(model.isSplitEditingActive)
        XCTAssertEqual(model.modeBarSelection, .splitEdit, "the picker reflects it")
    }

    func test_selectingAnotherMode_closesTheSameFileSplit() throws {
        let model = makeModel()
        _ = try open(model, "doc.md")
        model.setModeBarSelection(.splitEdit)

        model.setModeBarSelection(.mode(.rendered))

        XCTAssertEqual(model.currentViewMode, .rendered)
        XCTAssertNil(model.tabCoordinator.splitURL,
                     "leaving Split must not strand the same-file split pane")
        XCTAssertEqual(model.modeBarSelection, .mode(.rendered))
    }

    /// A split showing a DIFFERENT file is the ordinary side-by-side feature
    /// — the mode picker must not close someone else's pane.
    func test_modeChange_leavesADifferentFileSplitAlone() throws {
        let model = makeModel()
        _ = try open(model, "doc.md")
        let other = tmpDir.appendingPathComponent("other.md")
        try Data("# other\n".utf8).write(to: other)
        model.openInSplit(other)

        XCTAssertEqual(model.modeBarSelection, .mode(model.currentViewMode),
                       "a different-file split is not split-editing")
        model.setModeBarSelection(.mode(.source))
        XCTAssertEqual(model.tabCoordinator.splitURL, other,
                       "the unrelated split pane survives a mode change")
    }

    func test_switchingTabs_selectionFollowsTheActiveTab() throws {
        let model = makeModel()
        let md = try open(model, "doc.md")
        model.setModeBarSelection(.splitEdit)
        _ = try open(model, "plain.txt", "text\n")

        XCTAssertNotEqual(model.currentURL, md)
        XCTAssertFalse(model.isSplitEditingActive,
                       "the other tab is not in split-editing")
        XCTAssertEqual(model.modeBarSelection, .mode(model.currentViewMode))

        // Back on the markdown tab the segment lights up again.
        if let i = model.tabs.tabs.firstIndex(where: { $0.url == md }) {
            model.selectTab(at: i)
        }
        XCTAssertTrue(model.isSplitEditingActive)
        XCTAssertEqual(model.modeBarSelection, .splitEdit)
    }

    func test_splitEdit_withNoOpenFile_isANoOp() {
        let model = makeModel()
        model.setModeBarSelection(.splitEdit)
        XCTAssertNil(model.tabCoordinator.splitURL)
    }

    // MARK: the REAL surface — ContentToolbar's segment row (TSK-898)
    //
    // The first version of this feature edited the legacy ModeBar view, which
    // is never mounted; the partial-T6 pixel pass caught the toolbar showing
    // Render | Editor | HEX with no Split. These pin the live control.

    func test_toolbar_markdown_readsRenderSplitEditorHex() throws {
        let model = makeModel()
        _ = try open(model, "doc.md")
        XCTAssertEqual(model.toolbarModeSegments,
                       [.primary(.render), .split, .primary(.editor), .primary(.hex)],
                       "the owner's exact spec: Render | Split | Editor | HEX")
    }

    func test_toolbar_nonMarkdown_hasNoSplitSegment() throws {
        let model = makeModel()
        _ = try open(model, "plain.txt", "text\n")
        XCTAssertFalse(model.toolbarModeSegments.contains(.split),
                       "plain text has no rendered preview to split with")
    }

    func test_toolbar_tapSplit_entersAndClaimsSelectionExclusively() throws {
        let model = makeModel()
        _ = try open(model, "doc.md")

        model.selectToolbarSegment(.split)

        XCTAssertTrue(model.isSplitEditingActive)
        let p = model.viewModePresentation
        XCTAssertTrue(model.isToolbarSegmentSelected(.split, presentation: p))
        XCTAssertFalse(model.isToolbarSegmentSelected(.primary(.editor), presentation: p),
                       "two lit segments would read as a broken control")
    }

    func test_toolbar_tapPrimary_leavesSplitAndClosesTheSameFilePane() throws {
        let model = makeModel()
        _ = try open(model, "doc.md")
        model.selectToolbarSegment(.split)

        model.selectToolbarSegment(.primary(.render))

        XCTAssertFalse(model.isSplitEditingActive)
        XCTAssertNil(model.tabCoordinator.splitURL)
        let p = model.viewModePresentation
        XCTAssertTrue(model.isToolbarSegmentSelected(.primary(.render), presentation: p))
    }

    /// The toolbar wiring pin: the segment row must iterate
    /// `toolbarModeSegments`, not the raw primaries — that regression is
    /// exactly "the segment exists in the model but not on screen".
    func test_toolbar_iteratesTheSegmentRow_inSource() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Sources/ViewerUI/ContentToolbar.swift"),
            encoding: .utf8)
        XCTAssertTrue(src.contains("model.toolbarModeSegments"),
                      "the toolbar must build from the segment row")
        XCTAssertTrue(src.contains("mdv.viewMode.split"),
                      "the Split segment carries its AX id (VM tests target it)")
    }
}
