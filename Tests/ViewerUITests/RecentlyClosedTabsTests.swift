import XCTest
import ViewerCore
import ViewerKit
@testable import ViewerUI

/// Owner asks, 2026-07-28:
///   1. a Recently Closed list in the menu,
///   2. ⇧⌘T reopens the last closed item,
///   3. transient (ephemeral preview) opens stay OUT of Open Recent.
///
/// The menu itself is AppKit, but everything it shows and does is model
/// state — pinned here so a regression fails on the host gate.
@MainActor
final class RecentlyClosedTabsTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentlyClosedTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "RecentlyClosedTests-\(UUID().uuidString)"
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
    private func file(_ name: String, _ body: String = "hello") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        return url
    }

    // MARK: close → list → reopen

    func test_closingATab_putsItInRecentlyClosed_andReopenBringsItBack() throws {
        let model = makeModel()
        let a = try file("a.md")
        model.open(url: a)
        XCTAssertEqual(model.tabs.tabs.compactMap(\.url), [a])

        model.closeTab(at: 0)
        XCTAssertEqual(model.recentlyClosed.entries.map(\.url), [a],
                       "a closed tab must be offered for reopen")

        XCTAssertTrue(model.reopenLastClosedTab())
        XCTAssertEqual(model.tabs.tabs.compactMap(\.url), [a])
        XCTAssertTrue(model.recentlyClosed.isEmpty,
                      "a reopened tab is no longer closed")
    }

    /// ⇧⌘T pressed repeatedly must walk back through the close history.
    func test_repeatedReopen_walksBackThroughTheHistory() throws {
        let model = makeModel()
        let a = try file("a.md"), b = try file("b.md")
        model.open(url: a)
        model.open(url: b)
        // Close b (index 1) then a (index 0).
        model.closeTab(at: 1)
        model.closeTab(at: 0)

        XCTAssertTrue(model.reopenLastClosedTab())      // a — closed last
        XCTAssertTrue(model.reopenLastClosedTab())      // b
        XCTAssertEqual(Set(model.tabs.tabs.compactMap(\.url)), Set([a, b]))
        XCTAssertFalse(model.reopenLastClosedTab(),
                       "nothing left → the caller beeps / the menu disables")
    }

    func test_reopeningRestoresTheLensTheTabWasClosedIn() throws {
        let model = makeModel()
        let a = try file("a.md")
        model.open(url: a)
        model.setCurrentViewMode(.source)
        XCTAssertEqual(model.tabs.selected?.viewMode, .source)

        model.closeTab(at: 0)
        XCTAssertTrue(model.reopenLastClosedTab())
        XCTAssertEqual(model.tabs.selected?.viewMode, .source,
                       "reopening should land back in the lens it was closed in")
    }

    func test_closeOthers_and_closeToRight_recordEveryClosedTab() throws {
        let model = makeModel()
        let a = try file("a.md"), b = try file("b.md"), c = try file("c.md")
        for u in [a, b, c] { model.open(url: u) }

        model.closeOtherTabs(keeping: 0)
        XCTAssertEqual(Set(model.recentlyClosed.entries.map(\.url)), Set([b, c]))
        XCTAssertEqual(model.tabs.tabs.compactMap(\.url), [a])

        model.recentlyClosed.clear()
        model.open(url: b)
        model.open(url: c)
        model.closeTabsToRight(of: 0)
        XCTAssertEqual(Set(model.recentlyClosed.entries.map(\.url)), Set([b, c]))
    }

    /// A blank New Tab has nothing to reopen.
    func test_closingABlankTab_recordsNothing() {
        let model = makeModel()
        model.newTab()
        guard let i = model.tabs.selectedIndex else { return XCTFail("no tab") }
        model.closeTab(at: i)
        XCTAssertTrue(model.recentlyClosed.isEmpty)
    }

    /// An ephemeral preview (single-click peek, git-diff tab) is transient by
    /// construction — closing it must not bury the real files in the list.
    func test_closingAPreviewTab_recordsNothing() throws {
        let model = makeModel()
        let a = try file("a.md")
        model.openPreview(url: a)
        XCTAssertEqual(model.tabs.selected?.isPreview, true, "precondition: ephemeral tab")

        model.closeTab(at: 0)
        XCTAssertTrue(model.recentlyClosed.isEmpty,
                      "transient tabs must stay out of Recently Closed")
    }

    // MARK: transient opens stay out of Open Recent

    func test_previewOpen_doesNotEnterRecents_butAnExplicitOpenDoes() throws {
        let model = makeModel()
        let peeked = try file("peeked.md")
        let opened = try file("opened.md")

        model.openPreview(url: peeked)
        XCTAssertFalse(model.recents.contains { $0.url == peeked },
                       "a single-click peek is browsing, not opening")

        model.open(url: opened)
        XCTAssertTrue(model.recents.contains { $0.url == opened },
                      "an explicit open must still be recorded")
    }

    /// Committing to a peeked file (editing it promotes the preview tab)
    /// makes it a real open, so it SHOULD appear in recents at that point.
    func test_promotingAPreviewByEditing_recordsItInRecents() throws {
        let model = makeModel()
        let a = try file("a.md")
        model.openPreview(url: a)
        XCTAssertFalse(model.recents.contains { $0.url == a })

        guard let id = model.tabs.selected?.id else { return XCTFail("no tab") }
        model.updateEditorText("edited", forTabID: id)

        XCTAssertEqual(model.tabs.selected?.isPreview, false, "editing promotes the tab")
        XCTAssertTrue(model.recents.contains { $0.url == a },
                      "a promoted preview is a genuine open")
    }

    /// Reopening a file from anywhere clears it from Recently Closed, so the
    /// menu never offers to reopen something that is already open.
    func test_openingAClosedFileByAnotherRoute_dropsItFromTheList() throws {
        let model = makeModel()
        let a = try file("a.md")
        model.open(url: a)
        model.closeTab(at: 0)
        XCTAssertEqual(model.recentlyClosed.entries.count, 1)

        model.open(url: a)                     // reopened the ordinary way
        XCTAssertTrue(model.recentlyClosed.isEmpty)
    }

    /// A file deleted after it was closed must not open an error tab.
    func test_reopeningADeletedFile_isANoOp() throws {
        let model = makeModel()
        let a = try file("a.md")
        model.open(url: a)
        model.closeTab(at: 0)
        try FileManager.default.removeItem(at: a)

        _ = model.reopenLastClosedTab()
        XCTAssertFalse(model.tabs.tabs.contains { $0.url == a },
                       "a vanished file must not be resurrected as an error tab")
    }
}
