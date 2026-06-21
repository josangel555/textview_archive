import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-1107 — teeth for wiring the Walkthroughs browser to a reachable entry.
/// `showWalkthroughsBrowser()` opens the catalog browser as a hosted tab
/// (reachable via File ▸ Walkthroughs + the show-walkthroughs command); the list
/// render + Run are review. `runWalkthrough` on a bogus URL is a safe no-op.
@MainActor
final class WalkthroughsBrowserWiringTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("WTBrowser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmp.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: UserDefaults(
                suiteName: "WTBrowser-\(UUID().uuidString)")!))
    }

    func test_showWalkthroughsBrowser_opensHostedTab() {
        let model = makeModel()
        let before = model.tabs.tabs.count
        model.showWalkthroughsBrowser()
        XCTAssertGreaterThan(model.tabs.tabs.count, before,
                             "the Walkthroughs browser opens a hosted tab (reachable)")
    }

    func test_runWalkthrough_bogusURL_isSafeNoOp() {
        // A missing/invalid walkthrough file must not crash the run path.
        makeModel().runWalkthrough(at: tmp.appendingPathComponent("nope.json"))
    }
}
