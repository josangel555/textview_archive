import XCTest
@testable import ViewerCore
import ViewerKit

/// TSK-671 — persistence of the per-category default view-mode overrides.
/// Primitives-only `[categoryRaw: modeRaw]` dict, like `themeOverrideRaw`: a
/// renamed/removed enum case (or any tampered value) must degrade out on read
/// rather than crash or pin an invalid mode.
final class PreferencesStoreViewModeDefaultsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    /// The persistence key (a stable contract — exercised directly in the
    /// degrade test where we tamper the raw dict the store reads).
    private let key = "MarkdownViewer.viewModeDefaults"

    override func setUp() {
        suiteName = "PrefsViewModeDefaults-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func test_default_isEmpty() {
        let store = PreferencesStore(defaults: defaults)
        XCTAssertTrue(store.viewModeDefaults.isEmpty)
        XCTAssertNil(store.viewModeDefault(for: .markdown))
    }

    func test_setAndGet_roundTripsAcrossInstances() {
        let store = PreferencesStore(defaults: defaults)
        store.setViewModeDefault(.source, for: .markdown)
        store.setViewModeDefault(.source, for: .plainText)
        // A fresh store over the same defaults reads back the persisted pins.
        let other = PreferencesStore(defaults: defaults)
        XCTAssertEqual(other.viewModeDefault(for: .markdown), .source)
        XCTAssertEqual(other.viewModeDefault(for: .plainText), .source)
        XCTAssertEqual(other.viewModeDefaults,
                       [.markdown: .source, .plainText: .source])
    }

    func test_clearOnePin_removesOnlyThatEntry() {
        let store = PreferencesStore(defaults: defaults)
        store.setViewModeDefault(.source, for: .markdown)
        store.setViewModeDefault(.hex, for: .image)
        store.setViewModeDefault(nil, for: .markdown)
        XCTAssertNil(store.viewModeDefault(for: .markdown))
        XCTAssertEqual(store.viewModeDefault(for: .image), .hex)
    }

    func test_clearingLastPin_removesTheKeyEntirely() {
        let store = PreferencesStore(defaults: defaults)
        store.setViewModeDefault(.source, for: .markdown)
        XCTAssertNotNil(defaults.object(forKey: key))
        store.setViewModeDefault(nil, for: .markdown)
        XCTAssertNil(defaults.object(forKey: key),
                     "an empty map must remove the key, not persist an empty dict")
    }

    func test_overwritingPin_replacesValue() {
        let store = PreferencesStore(defaults: defaults)
        store.setViewModeDefault(.source, for: .markdown)
        store.setViewModeDefault(.editor, for: .markdown)
        XCTAssertEqual(store.viewModeDefault(for: .markdown), .editor)
        XCTAssertEqual(store.viewModeDefaults.count, 1)
    }

    func test_staleKeysAndValues_degradeOutOnRead() {
        // Simulate a renamed enum case / tampered prefs: one valid entry plus a
        // bogus category key and a bogus mode value. Only the valid pair must
        // survive — no crash, no invalid mode pinned.
        defaults.set(
            ["markdown": "source",       // valid
             "no_such_category": "hex",  // unknown FileCategory → dropped
             "code": "no_such_mode"],    // unknown ViewMode → dropped
            forKey: key)
        let store = PreferencesStore(defaults: defaults)
        XCTAssertEqual(store.viewModeDefaults, [.markdown: .source])
        XCTAssertNil(store.viewModeDefault(for: .code))
    }
}
