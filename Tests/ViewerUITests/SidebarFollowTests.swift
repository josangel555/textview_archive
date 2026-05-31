import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Coverage for the pin / follow-active-tab feature (item9). Host-safe
/// (constructs DocumentModel directly, no window). Run with a class filter.
@MainActor
final class SidebarFollowTests: XCTestCase {

    private var tmp: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarFollow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        suite = "SidebarFollow-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmp.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    private func file(_ rel: String, _ body: String = "x") throws -> URL {
        let url = tmp.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_toggle_flipsFlag() {
        let model = makeModel()
        XCTAssertFalse(model.sidebarFollowsActiveTab)
        model.toggleSidebarFollowsActiveTab()
        XCTAssertTrue(model.sidebarFollowsActiveTab)
    }

    // Following a tab inside the root selects it (and doesn't change the root).
    func test_follow_selectsFileWithinRoot_noReRoot() throws {
        let root = tmp.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = try file("proj/a.md")
        let b = try file("proj/sub/b.md")
        let model = makeModel()
        model.sidebar.setRoot(root)
        model.sidebarFollowsActiveTab = true

        model.open(url: a)
        model.open(url: b)   // selectTab fires followActiveTabIfNeeded

        XCTAssertEqual(model.sidebar.rootURL?.standardizedFileURL.resolvingSymlinksInPath().path,
                       root.standardizedFileURL.resolvingSymlinksInPath().path,
                       "follow must not change the root")
        XCTAssertEqual(model.sidebar.selectedURL?.standardizedFileURL.resolvingSymlinksInPath().path,
                       b.standardizedFileURL.resolvingSymlinksInPath().path,
                       "follow must select the active tab's file inside the root")
    }

    // Following a tab OUTSIDE the root must NOT re-root (no jarring jump).
    func test_follow_outsideRoot_doesNotReRoot() throws {
        let root = tmp.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inside = try file("proj/a.md")
        let outside = try file("elsewhere/x.md")
        let model = makeModel()
        model.sidebar.setRoot(root)
        model.open(url: inside)
        model.sidebarFollowsActiveTab = true

        model.openInNewTab(outside)   // distinct tab outside the root

        XCTAssertEqual(model.sidebar.rootURL?.standardizedFileURL.resolvingSymlinksInPath().path,
                       root.standardizedFileURL.resolvingSymlinksInPath().path,
                       "following a tab outside the root must NOT re-root")
    }

    // With follow OFF, switching to a tab in the sidebar tree must not select
    // that file (the follow reveal is what selects within the subtree). The
    // open path's own root-level selection is unrelated and unchanged.
    func test_followOff_doesNotSelectFileInTree() throws {
        let root = tmp.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = try file("proj/a.md")
        let b = try file("proj/sub/b.md")
        let model = makeModel()
        model.sidebar.setRoot(root)
        // follow stays OFF
        model.open(url: a)
        model.open(url: b)
        let bPath = b.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertNotEqual(model.sidebar.selectedURL?.standardizedFileURL.resolvingSymlinksInPath().path,
                          bPath,
                          "with follow off, opening a tab must not select its file in the subtree")
    }
}
