import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-1417 — teeth for wiring the built-but-ORPHANED RSS feed reader to a
/// reachable entry. The FeedReaderView + its parser/fetcher/subscription store/
/// refresh scheduler/OPML were fully host-tested but instantiated NOWHERE — the
/// owner chose FINISH → `openFeedReader()` now opens it as a hosted "Feeds" tab
/// (File → Feed Reader + the `show-feed-reader` verb). This pins the
/// reachability wiring (the pane render is the VM/pixel tail).
@MainActor
final class FeedReaderWiringTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedWiring-\(UUID().uuidString)")
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
                suiteName: "Feed-\(UUID().uuidString)")!))
    }

    func test_openFeedReader_opensHostedTab() throws {
        let model = makeModel()
        let before = model.tabs.tabs.count

        let id = model.openFeedReader()   // opens the hosted tab synchronously

        XCTAssertGreaterThan(model.tabs.tabs.count, before,
                             "Feed Reader opens a hosted tab (reachable — was orphaned)")
        XCTAssertNotNil(model.hostedView(forID: id),
                        "the opened tab hosts a real embedded view (the FeedReaderView)")
    }
}
