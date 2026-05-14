import XCTest
@testable import ViewerCore

final class PreferencesStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "PreferencesStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Sidebar width

    func test_sidebarWidth_defaultsTo240() {
        let store = PreferencesStore(defaults: defaults)
        XCTAssertEqual(store.sidebarWidth, 240)
    }

    func test_sidebarWidth_roundTrips() {
        let store = PreferencesStore(defaults: defaults)
        store.sidebarWidth = 300
        let other = PreferencesStore(defaults: defaults)
        XCTAssertEqual(other.sidebarWidth, 300)
    }

    func test_setSidebarWidth_clampsLow() {
        let store = PreferencesStore(defaults: defaults)
        store.setSidebarWidth(50)
        XCTAssertEqual(store.sidebarWidth, PreferencesStore.minSidebarWidth)
    }

    func test_setSidebarWidth_clampsHigh() {
        let store = PreferencesStore(defaults: defaults)
        store.setSidebarWidth(9999)
        XCTAssertEqual(store.sidebarWidth, PreferencesStore.maxSidebarWidth)
    }

    // MARK: Last folder

    func test_lastFolder_defaultsToNil() {
        let store = PreferencesStore(defaults: defaults)
        XCTAssertNil(store.lastFolderURL)
    }

    func test_lastFolder_roundTrips() {
        let store = PreferencesStore(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/somewhere")
        store.lastFolderURL = url
        let other = PreferencesStore(defaults: defaults)
        XCTAssertEqual(other.lastFolderURL, url)
    }

    func test_lastFolder_clearsOnSetNil() {
        let store = PreferencesStore(defaults: defaults)
        store.lastFolderURL = URL(fileURLWithPath: "/tmp/x")
        store.lastFolderURL = nil
        let other = PreferencesStore(defaults: defaults)
        XCTAssertNil(other.lastFolderURL)
    }
}
