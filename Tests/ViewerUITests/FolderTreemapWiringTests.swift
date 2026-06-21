import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-506 — teeth for wiring the built-but-unreachable FolderTreemapView to a
/// reachable entry. `showFolderTreemap()` opens it as a hosted tab (the view's
/// model scans the folder off-main itself); with no project root it's a no-op.
/// (The Canvas treemap render is VM/review; this pins the reachability wiring.)
@MainActor
final class FolderTreemapWiringTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TreemapWiring-\(UUID().uuidString)")
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
                suiteName: "Treemap-\(UUID().uuidString)")!))
    }

    func test_showFolderTreemap_opensHostedTab() throws {
        try "a".write(to: tmp.appendingPathComponent("f1.txt"), atomically: true, encoding: .utf8)
        try "bbbb".write(to: tmp.appendingPathComponent("f2.txt"), atomically: true, encoding: .utf8)

        let model = makeModel()
        model.sidebar.setRoot(tmp)
        let before = model.tabs.tabs.count

        model.showFolderTreemap()   // opens the hosted tab synchronously
        XCTAssertGreaterThan(model.tabs.tabs.count, before,
                             "Folder Sizes treemap opens a hosted tab (reachable)")
    }

    func test_showFolderTreemap_noProjectRoot_isNoOp() {
        let model = makeModel()   // no setRoot → no project root
        let before = model.tabs.tabs.count
        model.showFolderTreemap()
        XCTAssertEqual(model.tabs.tabs.count, before,
                       "no project root → no-op (no spurious tab)")
    }
}
