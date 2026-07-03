import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-1483 — one-shot editor-request routing (the "snippets insert at wrong
/// focus" class). Three layers pinned on the host:
///
///   1. `CMOneShotRouting.paneMayApply` — the pure pane-eligibility matrix
///      (targeted → only the stamped tab's pane; untargeted → active pane only).
///   2. `CMOneShotLedger` — exactly-once consumption app-wide (kills both the
///      mounted-sibling fan-out and the stale replay on (re)mount).
///   3. Model-layer stamping — every production creator of a one-shot request
///      stamps the ACTIVE tab as target (snippet insert, snippet tab-stop
///      selects, goto-line forwarder, date-time insert).
///
/// See docs/FOCUS_ROUTING.md for the audit + rule this enforces.
@MainActor
final class OneShotRoutingTests: XCTestCase {

    // MARK: - paneMayApply (pure matrix)

    func test_targeted_appliesOnlyOnMatchingPane() {
        let tab = UUID()
        XCTAssertTrue(
            CMOneShotRouting.paneMayApply(target: tab, paneTabID: tab, isActivePane: false),
            "the stamped tab's pane may apply even while inactive (open-at-line mounts next pass)")
        XCTAssertTrue(
            CMOneShotRouting.paneMayApply(target: tab, paneTabID: tab, isActivePane: true))
    }

    func test_targeted_neverAppliesOnAnotherPane_evenTheActiveOne() {
        let tab = UUID(), other = UUID()
        XCTAssertFalse(
            CMOneShotRouting.paneMayApply(target: tab, paneTabID: other, isActivePane: true),
            "a request stamped for tab A must never apply on tab B's pane — the fan-out bug")
        XCTAssertFalse(
            CMOneShotRouting.paneMayApply(target: tab, paneTabID: other, isActivePane: false))
    }

    func test_targeted_nilPaneIdentity_doesNotApply() {
        XCTAssertFalse(
            CMOneShotRouting.paneMayApply(target: UUID(), paneTabID: nil, isActivePane: true),
            "a pane without tab identity can't claim a targeted request")
    }

    func test_untargeted_appliesOnActivePaneOnly() {
        XCTAssertTrue(
            CMOneShotRouting.paneMayApply(target: nil, paneTabID: UUID(), isActivePane: true),
            "legacy untargeted requests keep working on the active pane")
        XCTAssertFalse(
            CMOneShotRouting.paneMayApply(target: nil, paneTabID: UUID(), isActivePane: false),
            "an inactive mounted sibling must not apply an untargeted request")
    }

    // MARK: - CMOneShotLedger (exactly-once)

    func test_ledger_consumesExactlyOnce() {
        let ledger = CMOneShotLedger()
        let id = UUID()
        XCTAssertTrue(ledger.consume(id), "first sighting dispatches")
        XCTAssertFalse(ledger.consume(id),
            "second sighting (another pane / a remount / a warm re-attach) must not replay")
        XCTAssertTrue(ledger.isConsumed(id))
        XCTAssertFalse(ledger.isConsumed(UUID()))
    }

    func test_ledger_distinctIds_eachConsumeOnce() {
        let ledger = CMOneShotLedger()
        let a = UUID(), b = UUID()
        XCTAssertTrue(ledger.consume(a))
        XCTAssertTrue(ledger.consume(b), "a fresh nonce id is a fresh request")
        XCTAssertFalse(ledger.consume(a))
        XCTAssertFalse(ledger.consume(b))
    }

    func test_ledger_capacityEvictsOldestFirst() {
        let ledger = CMOneShotLedger(capacity: 2)
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertTrue(ledger.consume(a))
        XCTAssertTrue(ledger.consume(b))
        XCTAssertTrue(ledger.consume(c))       // evicts a
        XCTAssertFalse(ledger.isConsumed(a), "FIFO eviction drops the oldest id")
        XCTAssertTrue(ledger.isConsumed(b))
        XCTAssertTrue(ledger.isConsumed(c))
    }

    // MARK: - Model-layer target stamping (integration)

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneShotRoutingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "OneShotRoutingTests-\(UUID().uuidString)"
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

    private func openEditorTab(_ model: DocumentModel) throws {
        let url = tmpDir.appendingPathComponent("doc.md")
        try "x\n".write(to: url, atomically: true, encoding: .utf8)
        model.open(url: url)
        var t = model.tabs.tabs[0]
        t.viewMode = .editor
        model.tabCoordinator.replace(at: 0, with: t)
    }

    func test_insertSnippet_stampsInsertWithSelectedTab() throws {
        let model = makeModel()
        try openEditorTab(model)
        let link = SnippetLibrary.builtIns.first { $0.id == "md.link" }!
        XCTAssertTrue(model.insertSnippet(link))
        XCTAssertEqual(model.editorInsertRequest?.target, model.tabs.selected?.id,
            "snippet insert must be addressed to the active tab's pane")
        XCTAssertNotNil(model.editorInsertRequest?.target)
    }

    func test_insertSnippet_stampsTabStopSelectWithSelectedTab() throws {
        let model = makeModel()
        try openEditorTab(model)
        let link = SnippetLibrary.builtIns.first { $0.id == "md.link" }!
        XCTAssertTrue(model.insertSnippet(link))
        // md.link has tab stops → a session began and selected the first stop.
        XCTAssertTrue(model.isSnippetSessionActive)
        XCTAssertEqual(model.editorSelectRequest?.target, model.tabs.selected?.id,
            "tab-stop caret walk must stay addressed to the tab the snippet landed in")
    }

    func test_insertDateAndTime_stampsSelectedTab() throws {
        let model = makeModel()
        try openEditorTab(model)
        model.insertDateAndTime()
        XCTAssertEqual(model.editorInsertRequest?.target, model.tabs.selected?.id)
        XCTAssertNotNil(model.editorInsertRequest?.target)
    }

    func test_gotoLineForwarder_stampsActiveTab_preservingNonce() throws {
        let model = makeModel()
        try openEditorTab(model)
        let req = CMGotoLineRequest(line: 42, select: true)
        model.editorGotoLine = req
        let stored = model.editor.editorGotoLine
        XCTAssertEqual(stored?.target, model.tabs.selected?.id,
            "untargeted goto is stamped with the active tab at the model boundary")
        XCTAssertEqual(stored?.id, req.id, "stamping must not re-mint the nonce id")
        XCTAssertEqual(stored?.line, 42)
        XCTAssertEqual(stored?.select, true)
    }

    func test_gotoLineForwarder_respectsExplicitTarget() throws {
        let model = makeModel()
        try openEditorTab(model)
        let explicit = UUID()
        model.editorGotoLine = CMGotoLineRequest(line: 7, target: explicit)
        XCTAssertEqual(model.editor.editorGotoLine?.target, explicit,
            "an already-targeted request passes through unchanged")
    }

    func test_gotoLineForwarder_noTabs_leavesTargetNil() {
        let model = makeModel()
        model.editorGotoLine = CMGotoLineRequest(line: 3)
        XCTAssertNil(model.editor.editorGotoLine?.target,
            "no selected tab → stays untargeted (active-pane-only rule)")
    }
}
