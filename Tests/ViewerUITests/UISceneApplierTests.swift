import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-492 (Layer 1) — host tests for the deterministic UI-scene → model-state
/// mapping that the visual-eval harness (`scripts/vm-uitest.sh`) depends on.
/// Before the extraction this logic lived in the MarkdownViewer EXECUTABLE
/// target (un-test-linked), so the scene catalog had NO regression guard — a
/// scene silently failing to enter its state would make the harness capture the
/// wrong pixels (a false green). These pin the model-state contract; the pixel
/// capture itself stays the VM lane.
@MainActor
final class UISceneApplierTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("UISceneApplierTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeModel() -> DocumentModel {
        let defaults = UserDefaults(suiteName: "UISceneApplierTests-\(UUID().uuidString)")!
        return DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmp.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults))
    }

    @discardableResult
    private func apply(_ scene: String, _ model: DocumentModel, previewFile: URL? = nil) -> String {
        UISceneApplier.apply(scene: scene, to: model, previewFile: previewFile, tabsBaseDir: tmp)
    }

    func test_terminalPaneRight_entersExactState() {
        let model = makeModel()
        let status = apply("terminal-paneright", model)
        XCTAssertTrue(model.terminalPane.isOpen, "the terminal pane must be open")
        XCTAssertEqual(model.terminalPane.paneEdge, .right, "paneright docks the pane on the right edge")
        XCTAssertEqual(model.terminalPane.height, 320, "deterministic height")
        XCTAssertGreaterThanOrEqual(model.terminalPane.tabs.count, 2, "default terminal tab count is 2")
        XCTAssertTrue(status.contains("edge=right"), "status reflects the applied edge: \(status)")
    }

    func test_terminalDefaultEdge_isBottom_notInheritedFromPrefs() {
        // A bare `terminal` scene must DETERMINISTICALLY dock .bottom (the state
        // leak the T5 tests caught), not inherit a persisted edge.
        let model = makeModel()
        apply("terminal", model)
        XCTAssertEqual(model.terminalPane.paneEdge, .bottom)
        XCTAssertTrue(model.terminalPane.isOpen)
    }

    func test_previewScene_opensEphemeralPreview() throws {
        let model = makeModel()
        let file = tmp.appendingPathComponent("doc.md")
        try "# hi\n".write(to: file, atomically: true, encoding: .utf8)
        let status = apply("preview", model, previewFile: file)
        XCTAssertNotNil(model.tabs.previewTabID, "the preview slot must be populated")
        XCTAssertTrue(status.contains("preview=true"), "status: \(status)")
    }

    func test_previewScene_withoutFile_isAGuardedNoop() {
        let model = makeModel()
        let status = apply("preview", model, previewFile: nil)
        XCTAssertNil(model.tabs.previewTabID, "no file ⇒ nothing opened")
        XCTAssertTrue(status.contains("needs MDV_PREVIEW_FILE"), "status: \(status)")
    }

    func test_tabsScene_opensNPermanentTabs_firstSelected() {
        let model = makeModel()
        apply("tabs-3", model)
        XCTAssertEqual(model.tabs.tabs.count, 3, "tabs-3 opens exactly 3 permanent tabs")
        XCTAssertEqual(model.tabs.selectedIndex, 0, "the FIRST tab is selected (unscrolled strip)")
    }

    func test_landingScene_isANamedNoop_leavingEmptyState() {
        // TSK-760: the 'landing' scene shows the empty-state surface (New File /
        // recents). It must be a recognised no-op — NOT fall through to "unknown
        // scene" — and must not open any tab or the terminal.
        let model = makeModel()
        let status = apply("landing", model)
        XCTAssertTrue(status.contains("landing"), "named landing scene, not unknown: \(status)")
        XCTAssertFalse(status.contains("unknown"), "must be recognised: \(status)")
        XCTAssertTrue(model.tabs.tabs.isEmpty, "landing opens no tabs (empty state)")
        XCTAssertFalse(model.terminalPane.isOpen, "landing leaves the terminal closed")
    }

    func test_lspRenameScene_presentsThePromptOverAnEditorBackdrop() {
        // TSK-640 render tail: the 'lsp-rename' scene must put the rename prompt
        // sheet on screen (isLSPRenamePromptPresented) over an open editor tab,
        // so the VM harness can capture it and assert the mdv.lspRename.* views
        // are actually VISIBLE. A scene that silently failed to present would
        // make the capture a false green — this pins the model-state contract.
        let model = makeModel()
        let status = apply("lsp-rename", model)
        XCTAssertTrue(model.isLSPRenamePromptPresented,
                      "the rename prompt sheet must be presented for the capture")
        XCTAssertEqual(model.tabs.tabs.count, 1, "an editor backdrop tab is open behind the sheet")
        XCTAssertTrue(status.contains("renamePrompt=true"), "status: \(status)")
        XCTAssertFalse(status.contains("unknown"), "must be a recognised scene: \(status)")
    }

    func test_folderOnlyScene_reachesNoFileFolderContext() {
        // TSK-738: the status footer regressed-hidden when a folder is open but
        // no file tab is selected. This scene reaches that exact state (close the
        // auto-opened tab, open a folder root) so the VM lane can assert the
        // footer (mdv.statusBar) is still on screen. Pins the model contract: the
        // broadened gate predicate (hasOpenContext) is TRUE while currentURL is
        // nil — the precise condition the old gate hid the footer on.
        let model = makeModel()
        let f = tmp.appendingPathComponent("preopened.md")
        try? "# x\n".write(to: f, atomically: true, encoding: .utf8)
        model.open(url: f)
        XCTAssertFalse(model.tabs.tabs.isEmpty, "precondition: a file tab is open")
        let status = apply("folder-only", model)
        XCTAssertTrue(model.tabs.tabs.isEmpty, "folder-only closes all file tabs")
        XCTAssertNotNil(model.sidebar.rootURL, "a folder root is open")
        XCTAssertNil(model.currentURL, "no file selected — the regressed state")
        XCTAssertTrue(model.hasOpenContext,
                      "hasOpenContext true via the folder root — the broadened footer gate (TSK-738)")
        XCTAssertTrue(status.contains("hasContext=true"), "status: \(status)")
    }

    #if DEBUG
    func test_codeActionsScene_presentsThePickerOverAnEditorBackdrop() {
        // TSK-640 render tail (sibling of lsp-rename): the 'code-actions' scene
        // must drive the code-action picker into .presenting with canned actions
        // over an open editor tab, so the VM harness can capture it and assert
        // mdv.codeActions.* are VISIBLE. Pins the model-state contract; the
        // pixel/AX capture is the VM lane.
        let model = makeModel()
        let status = apply("code-actions", model)
        guard case .presenting(let actions) = model.codeActionPicker else {
            return XCTFail("the picker must be .presenting; got \(model.codeActionPicker)")
        }
        XCTAssertEqual(actions.count, 2, "the two canned actions are presented")
        XCTAssertEqual(model.tabs.tabs.count, 1, "an editor backdrop tab is open behind the picker")
        XCTAssertTrue(status.contains("picker=presenting"), "status: \(status)")
        XCTAssertFalse(status.contains("unknown"), "must be a recognised scene: \(status)")
    }
    #endif

    func test_unknownScene_isReportedNotApplied() {
        let model = makeModel()
        let status = apply("bogus-scene", model)
        XCTAssertTrue(status.contains("unknown scene"), "status: \(status)")
        XCTAssertFalse(model.terminalPane.isOpen, "an unknown scene changes nothing")
    }
}
