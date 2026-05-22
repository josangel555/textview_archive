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

    // MARK: Legacy uiScale → zoom migration

    /// Legacy users with only `MarkdownViewer.uiScale` set on disk
    /// (no `MarkdownViewer.zoom`) should see that value adopted as
    /// the unified `zoom` on first read after upgrade.
    func test_zoom_migratesFromLegacyUIScale_whenZoomMissing() {
        defaults.set(1.30, forKey: "MarkdownViewer.uiScale")
        let store = PreferencesStore(defaults: defaults)
        XCTAssertEqual(store.zoom, 1.30, accuracy: 0.001)
    }

    /// When both keys exist (user had tuned both before upgrade),
    /// pick the larger — preserves whichever surface they'd actually
    /// blown up rather than silently shrinking the UI.
    func test_zoom_migration_picksMaxOfZoomAndLegacyUIScale() {
        defaults.set(1.10, forKey: "MarkdownViewer.zoom")
        defaults.set(1.40, forKey: "MarkdownViewer.uiScale")
        let store = PreferencesStore(defaults: defaults)
        XCTAssertEqual(store.zoom, 1.40, accuracy: 0.001)
    }

    /// First explicit set of `zoom` after migration drops the legacy
    /// key, so subsequent reads don't keep resurrecting it.
    func test_zoom_setter_clearsLegacyUIScaleKey() {
        defaults.set(1.30, forKey: "MarkdownViewer.uiScale")
        let store = PreferencesStore(defaults: defaults)
        store.zoom = 1.10
        XCTAssertNil(defaults.object(forKey: "MarkdownViewer.uiScale"))
        XCTAssertEqual(store.zoom, 1.10, accuracy: 0.001)
    }
}
