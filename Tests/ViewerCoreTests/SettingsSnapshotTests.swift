import XCTest
@testable import ViewerCore
import ViewerKit

/// TSK-681 — Export/Import settings: the portable `SettingsSnapshot` and the
/// PreferencesStore export/apply round-trip. Pure (UserDefaults suites);
/// host-safe.
final class SettingsSnapshotTests: XCTestCase {

    private func store(_ tag: String) -> (PreferencesStore, String) {
        let suite = "SettingsSnapshot-\(tag)-\(UUID().uuidString)"
        return (PreferencesStore(defaults: UserDefaults(suiteName: suite)!), suite)
    }

    override func tearDown() {
        // suites are unique per test; nothing global to reset
        super.tearDown()
    }

    func test_export_capturesUserPrefs_andVersion() {
        let (a, suite) = store("export"); defer { a.defaults.removePersistentDomain(forName: suite) }
        a.zoom = 1.5
        a.sourceWordWrap = true
        a.themeOverrideRaw = "dark"
        a.sourceFontName = "Menlo"
        a.hexBytesPerRow = 32
        a.previewMetadataVisible = false
        a.setViewModeDefault(.source, for: .markdown)

        let s = a.exportSettings()
        XCTAssertEqual(s.version, PreferencesStore.settingsSnapshotVersion)
        XCTAssertEqual(s.zoom, 1.5)
        XCTAssertEqual(s.sourceWordWrap, true)
        XCTAssertEqual(s.themeOverride, "dark")
        XCTAssertEqual(s.sourceFontName, "Menlo")
        XCTAssertEqual(s.hexBytesPerRow, 32)
        XCTAssertEqual(s.previewMetadataVisible, false)
        XCTAssertEqual(s.viewModeDefaults, ["markdown": "source"])
    }

    func test_vimModeEnabled_roundTripsAcrossStores() throws {
        let (a, sa) = store("vim-src"); defer { a.defaults.removePersistentDomain(forName: sa) }
        a.vimModeEnabled = true
        let data = try JSONEncoder().encode(a.exportSettings())
        let snap = try JSONDecoder().decode(SettingsSnapshot.self, from: data)
        XCTAssertEqual(snap.vimModeEnabled, true, "snapshot carries vimModeEnabled")

        let (b, sb) = store("vim-dst"); defer { b.defaults.removePersistentDomain(forName: sb) }
        XCTAssertFalse(b.vimModeEnabled, "fresh store defaults off")
        b.applySettings(snap)
        XCTAssertTrue(b.vimModeEnabled, "applySettings transfers vimModeEnabled across stores")
    }

    func test_jsonRoundTrip() throws {
        let (a, suite) = store("json"); defer { a.defaults.removePersistentDomain(forName: suite) }
        a.zoom = 2.0
        a.editorIndentGuides = true
        a.setViewModeDefault(.editor, for: .code)

        let s = a.exportSettings()
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(SettingsSnapshot.self, from: data)
        XCTAssertEqual(decoded, s, "snapshot survives a JSON encode/decode round trip")
    }

    func test_apply_transfersAcrossStores() throws {
        let (a, sa) = store("src"); defer { a.defaults.removePersistentDomain(forName: sa) }
        a.zoom = 1.8
        a.sourceWordWrap = true
        a.themeOverrideRaw = "solarized-light"
        a.hexBytesPerRow = 64
        a.previewMetadataVisible = false
        a.setViewModeDefault(.source, for: .markdown)

        let data = try JSONEncoder().encode(a.exportSettings())
        let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: data)

        let (b, sb) = store("dst"); defer { b.defaults.removePersistentDomain(forName: sb) }
        b.applySettings(snapshot)
        XCTAssertEqual(b.zoom, 1.8)
        XCTAssertEqual(b.sourceWordWrap, true)
        XCTAssertEqual(b.themeOverrideRaw, "solarized-light")
        XCTAssertEqual(b.hexBytesPerRow, 64)
        XCTAssertEqual(b.previewMetadataVisible, false)
        XCTAssertEqual(b.viewModeDefault(for: .markdown), .source)
    }

    func test_apply_onlyTouchesPresentFields() {
        let (b, suite) = store("partial"); defer { b.defaults.removePersistentDomain(forName: suite) }
        b.sourceWordWrap = true            // pre-existing, NOT in the snapshot
        var partial = SettingsSnapshot()
        partial.zoom = 2.5                 // the only carried field
        b.applySettings(partial)
        XCTAssertEqual(b.zoom, 2.5)
        XCTAssertEqual(b.sourceWordWrap, true, "a field absent from the snapshot is left untouched")
    }

    func test_apply_dropsStaleViewModeKeys() {
        let (b, suite) = store("stale"); defer { b.defaults.removePersistentDomain(forName: suite) }
        var s = SettingsSnapshot()
        s.viewModeDefaults = ["markdown": "source", "no_such_cat": "hex", "code": "no_such_mode"]
        b.applySettings(s)
        XCTAssertEqual(b.viewModeDefaults, [.markdown: .source],
                       "unknown category / mode keys are dropped on apply")
    }

    func test_export_omitsEmptyViewModeDefaults() {
        let (a, suite) = store("empty"); defer { a.defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(a.exportSettings().viewModeDefaults,
                     "no per-type defaults ⇒ the field is omitted (not an empty object)")
    }
}
