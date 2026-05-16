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

    // MARK: Source word-wrap (Batch A)

    func test_sourceWordWrap_defaultsToFalse() {
        let store = PreferencesStore(defaults: defaults)
        XCTAssertFalse(store.sourceWordWrap)
    }

    func test_sourceWordWrap_roundTrips() {
        let store = PreferencesStore(defaults: defaults)
        store.sourceWordWrap = true
        let other = PreferencesStore(defaults: defaults)
        XCTAssertTrue(other.sourceWordWrap)
    }

    // MARK: Show invisible chars (Batch A)

    func test_showInvisibleChars_defaultsToFalse() {
        let store = PreferencesStore(defaults: defaults)
        XCTAssertFalse(store.showInvisibleChars)
    }

    func test_showInvisibleChars_roundTrips() {
        let store = PreferencesStore(defaults: defaults)
        store.showInvisibleChars = true
        let other = PreferencesStore(defaults: defaults)
        XCTAssertTrue(other.showInvisibleChars)
    }

    // MARK: UI scale (Batch B)

    func test_uiScale_defaultsTo1() {
        let store = PreferencesStore(defaults: defaults)
        XCTAssertEqual(store.uiScale, 1.0, accuracy: 0.001)
    }

    func test_uiScale_roundTrips() {
        let store = PreferencesStore(defaults: defaults)
        store.uiScale = 1.25
        let other = PreferencesStore(defaults: defaults)
        XCTAssertEqual(other.uiScale, 1.25, accuracy: 0.001)
    }

    func test_uiScale_clampsLow_onSet() {
        let store = PreferencesStore(defaults: defaults)
        store.uiScale = 0.1
        XCTAssertEqual(store.uiScale, PreferencesStore.minUIScale, accuracy: 0.001)
    }

    func test_uiScale_clampsHigh_onSet() {
        let store = PreferencesStore(defaults: defaults)
        store.uiScale = 10.0
        XCTAssertEqual(store.uiScale, PreferencesStore.maxUIScale, accuracy: 0.001)
    }

    func test_uiScale_clampsOnRead_whenStoreHasOutOfRangeValue() {
        // Simulate a corrupted / hand-edited defaults plist.
        defaults.set(99.0, forKey: "MarkdownViewer.uiScale")
        let store = PreferencesStore(defaults: defaults)
        XCTAssertLessThanOrEqual(store.uiScale, PreferencesStore.maxUIScale)
        XCTAssertGreaterThanOrEqual(store.uiScale, PreferencesStore.minUIScale)
    }

    func test_uiScale_bounds_are_sensible() {
        XCTAssertLessThan(PreferencesStore.minUIScale, 1.0)
        XCTAssertGreaterThan(PreferencesStore.maxUIScale, 1.0)
        XCTAssertGreaterThan(PreferencesStore.uiScaleStep, 0)
    }
}
