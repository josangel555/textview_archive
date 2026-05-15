import XCTest
@testable import ViewerCore
import ViewerKit

final class WorkspaceStoreTests: XCTestCase {

    private var tmp: URL!
    private var store: WorkspaceStore!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdv-ws-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = WorkspaceStore(directory: tmp)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testRoundtripAutoSlot() throws {
        let snap = WorkspaceSnapshot(
            sidebarRootPath: "/tmp/proj",
            openTabs: [
                TabSnapshot(path: "/tmp/a.md", viewMode: "rendered"),
                TabSnapshot(path: "/tmp/b.swift", viewMode: "source"),
            ],
            selectedTabIndex: 1,
            zoom: 1.5,
            wordWrap: true,
            themeOverride: "xcodeDark"
        )
        store.saveAutoSlot(snap)
        let loaded = store.loadAutoSlot()
        XCTAssertEqual(loaded?.openTabs.count, 2)
        XCTAssertEqual(loaded?.openTabs[1].path, "/tmp/b.swift")
        XCTAssertEqual(loaded?.openTabs[1].viewMode, "source")
        XCTAssertEqual(loaded?.zoom, 1.5)
        XCTAssertEqual(loaded?.wordWrap, true)
        XCTAssertEqual(loaded?.themeOverride, "xcodeDark")
        XCTAssertEqual(loaded?.selectedTabIndex, 1)
        XCTAssertEqual(loaded?.schemaVersion, WorkspaceSnapshot.currentSchema)
    }

    func testNamedSaveLoadDelete() {
        let snap = WorkspaceSnapshot(
            sidebarRootPath: nil, openTabs: [],
            selectedTabIndex: nil, zoom: 1.0,
            wordWrap: false, themeOverride: nil
        )
        store.save(snap, name: "Project A")
        XCTAssertTrue(store.list().contains("Project A"))
        XCTAssertNotNil(store.load(name: "Project A"))
        store.delete(name: "Project A")
        XCTAssertFalse(store.list().contains("Project A"))
    }

    func testLoadMissingReturnsNil() {
        XCTAssertNil(store.loadAutoSlot())
        XCTAssertNil(store.load(name: "nonexistent"))
    }

    func testListExcludesAutoSlot() {
        let snap = WorkspaceSnapshot(
            sidebarRootPath: nil, openTabs: [],
            selectedTabIndex: nil, zoom: nil,
            wordWrap: nil, themeOverride: nil
        )
        store.saveAutoSlot(snap)
        store.save(snap, name: "MyProject")
        XCTAssertEqual(store.list(), ["MyProject"])
    }

    func testFilenameSanitization() {
        let snap = WorkspaceSnapshot(
            sidebarRootPath: nil, openTabs: [],
            selectedTabIndex: nil, zoom: nil,
            wordWrap: nil, themeOverride: nil
        )
        store.save(snap, name: "a/b:c\\d")
        // All path-illegal characters replaced with underscore.
        let names = store.list()
        XCTAssertTrue(names.contains("a_b_c_d"))
    }
}
