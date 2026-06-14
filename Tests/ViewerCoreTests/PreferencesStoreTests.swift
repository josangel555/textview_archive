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

    /// A direct write through the `sidebarWidth` set accessor (the path
    /// that bypasses `setSidebarWidth(_:)`) must still clamp, so an
    /// out-of-range value can't persist.
    func test_sidebarWidth_directSetClamps() {
        let store = PreferencesStore(defaults: defaults)
        store.sidebarWidth = 5000
        XCTAssertEqual(store.sidebarWidth, PreferencesStore.maxSidebarWidth)
        store.sidebarWidth = 10
        XCTAssertEqual(store.sidebarWidth, PreferencesStore.minSidebarWidth)
    }

    // MARK: Content font size (TSK-358)

    func test_contentFontSize_defaultsTo13() {
        let store = PreferencesStore(defaults: defaults)
        XCTAssertEqual(store.contentFontSize, PreferencesStore.defaultContentFontSize)
        XCTAssertEqual(store.contentFontSize, 13)
    }

    func test_contentFontSize_roundTrips() {
        let store = PreferencesStore(defaults: defaults)
        store.contentFontSize = 18
        XCTAssertEqual(PreferencesStore(defaults: defaults).contentFontSize, 18)
    }

    func test_contentFontSize_clampsOutOfRange() {
        let store = PreferencesStore(defaults: defaults)
        store.contentFontSize = 999
        XCTAssertEqual(store.contentFontSize, PreferencesStore.maxContentFontSize)
        store.contentFontSize = 1
        XCTAssertEqual(store.contentFontSize, PreferencesStore.minContentFontSize)
    }

    /// A tampered/legacy `_last.json` could carry a stored width outside
    /// `[160, 480]`. The getter must clamp it on read so the picker /
    /// layout never sees an out-of-range width.
    func test_sidebarWidth_clampsStaleStoredValueOnRead() {
        defaults.set(5000.0, forKey: "MarkdownViewer.sidebarWidth")
        XCTAssertEqual(
            PreferencesStore(defaults: defaults).sidebarWidth,
            PreferencesStore.maxSidebarWidth)

        defaults.set(10.0, forKey: "MarkdownViewer.sidebarWidth")
        XCTAssertEqual(
            PreferencesStore(defaults: defaults).sidebarWidth,
            PreferencesStore.minSidebarWidth)
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

    // MARK: Theme override (TSK-101 — persist Settings → Appearance → Theme)

    func test_themeOverride_defaultsToNil() {
        let store = PreferencesStore(defaults: defaults)
        XCTAssertNil(store.themeOverrideRaw, "no override persisted = Follow System")
    }

    func test_themeOverride_roundTrips() {
        let store = PreferencesStore(defaults: defaults)
        store.themeOverrideRaw = "xcodeLight"
        let other = PreferencesStore(defaults: defaults)
        XCTAssertEqual(other.themeOverrideRaw, "xcodeLight", "chosen theme survives a fresh store (relaunch)")
    }

    func test_themeOverride_nilClearsBackToFollowSystem() {
        let store = PreferencesStore(defaults: defaults)
        store.themeOverrideRaw = "xcodeDark"
        store.themeOverrideRaw = nil
        let other = PreferencesStore(defaults: defaults)
        XCTAssertNil(other.themeOverrideRaw, "clearing the override reverts to Follow System")
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

    // MARK: Editor indent guides (TSK-487)

    func test_editorIndentGuides_defaultsToFalse() {
        let store = PreferencesStore(defaults: defaults)
        XCTAssertFalse(store.editorIndentGuides,
                       "opt-in: default off so the editor's default look is unchanged")
    }

    func test_editorIndentGuides_roundTrips() {
        let store = PreferencesStore(defaults: defaults)
        store.editorIndentGuides = true
        let other = PreferencesStore(defaults: defaults)
        XCTAssertTrue(other.editorIndentGuides)
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

    // MARK: HEX bytes-per-row

    func test_hexBytesPerRow_defaultsTo16() {
        let store = PreferencesStore(defaults: defaults)
        XCTAssertEqual(store.hexBytesPerRow, 16)
    }

    func test_hexBytesPerRow_roundTripsAllowedValues() {
        let store = PreferencesStore(defaults: defaults)
        store.hexBytesPerRow = 32
        XCTAssertEqual(PreferencesStore(defaults: defaults).hexBytesPerRow, 32)
        store.hexBytesPerRow = 64
        XCTAssertEqual(PreferencesStore(defaults: defaults).hexBytesPerRow, 64)
    }

    func test_hexBytesPerRow_clampsArbitraryValuesOnWrite() {
        let store = PreferencesStore(defaults: defaults)
        store.hexBytesPerRow = 100        // -> 64
        XCTAssertEqual(store.hexBytesPerRow, 64)
        store.hexBytesPerRow = 24         // -> 32
        XCTAssertEqual(store.hexBytesPerRow, 32)
        store.hexBytesPerRow = 1          // -> 16
        XCTAssertEqual(store.hexBytesPerRow, 16)
    }

    func test_hexBytesPerRow_clampsStaleStoredValueOnRead() {
        // Simulate a future build that wrote an unsupported value.
        defaults.set(48, forKey: "MarkdownViewer.hexBytesPerRow")
        let store = PreferencesStore(defaults: defaults)
        XCTAssertEqual(store.hexBytesPerRow, 64) // clamped up via HexLayout
    }

    // MARK: Audio ffmpeg path (MP3 export, TSK-528)

    func test_audioFFmpegPath_defaultsToNil() {
        XCTAssertNil(PreferencesStore(defaults: defaults).audioFFmpegPath)
    }

    func test_audioFFmpegPath_roundTrips() {
        let store = PreferencesStore(defaults: defaults)
        store.audioFFmpegPath = "/opt/homebrew/bin/ffmpeg"
        let other = PreferencesStore(defaults: defaults)
        XCTAssertEqual(other.audioFFmpegPath, "/opt/homebrew/bin/ffmpeg")
    }

    func test_audioFFmpegPath_trimsWhitespace() {
        let store = PreferencesStore(defaults: defaults)
        store.audioFFmpegPath = "  /usr/local/bin/ffmpeg \n"
        XCTAssertEqual(store.audioFFmpegPath, "/usr/local/bin/ffmpeg")
    }

    func test_audioFFmpegPath_emptyOrWhitespace_clearsToNil() {
        let store = PreferencesStore(defaults: defaults)
        store.audioFFmpegPath = "/x/ffmpeg"
        store.audioFFmpegPath = "   "          // whitespace clears
        XCTAssertNil(store.audioFFmpegPath)
        XCTAssertNil(PreferencesStore(defaults: defaults).audioFFmpegPath)
    }

    func test_audioFFmpegPath_nilClears() {
        let store = PreferencesStore(defaults: defaults)
        store.audioFFmpegPath = "/x/ffmpeg"
        store.audioFFmpegPath = nil
        XCTAssertNil(store.audioFFmpegPath)
    }

    func test_audioFFmpegPath_staleWhitespaceStored_readsAsNil() {
        // A directly-written whitespace value degrades to auto-discovery, not a
        // bogus override fed to FFmpegLocator.
        defaults.set("   ", forKey: "MarkdownViewer.audioFFmpegPath")
        XCTAssertNil(PreferencesStore(defaults: defaults).audioFFmpegPath)
    }
}
