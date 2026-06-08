import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-101 — Settings → Appearance → Theme must survive a relaunch.
///
/// The existing `PreferencesStoreTests` cover the *storage* round-trip
/// (`themeOverrideRaw` survives a fresh `PreferencesStore`), but the actual bug
/// was in the WIRING: `DocumentModel.themeOverride` was an in-memory-only
/// `@Published`, so a chosen Light/Dark reverted to Follow System on every
/// reload. The fix added a `didSet` write-through + an `init` restore. A
/// storage-only test would stay green if either of those were deleted — so
/// these tests exercise the model↔store seam directly: that's the regression
/// the ticket is about.
@MainActor
final class ThemeOverridePersistenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "ThemeOverridePersistenceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Picking a theme writes through to the store (the `didSet`), so it is
    /// durable the instant the user changes the picker.
    func test_themeOverride_didSetWritesThroughToPreferences() {
        let prefs = PreferencesStore(defaults: defaults)
        let model = DocumentModel(preferences: prefs)
        XCTAssertNil(prefs.themeOverrideRaw, "fresh install = Follow System")

        model.themeOverride = .xcodeLight
        XCTAssertEqual(prefs.themeOverrideRaw, "xcodeLight",
            "setting themeOverride must persist immediately via the didSet")
    }

    /// A relaunch is a fresh `DocumentModel` over the same persisted store: the
    /// chosen theme must come back (the `init` restore), not reset to nil.
    func test_themeOverride_restoredFromPreferencesOnRelaunch() {
        let prefs = PreferencesStore(defaults: defaults)
        let first = DocumentModel(preferences: prefs)
        first.themeOverride = .xcodeDark

        // Simulate relaunch: a brand-new model reading the same store.
        let relaunched = DocumentModel(preferences: PreferencesStore(defaults: defaults))
        XCTAssertEqual(relaunched.themeOverride, .xcodeDark,
            "the persisted override must be reapplied on init, not forgotten")
    }

    /// Clearing back to Follow System persists the *absence* of an override —
    /// the next launch starts on Follow System, not the last explicit theme.
    func test_themeOverride_clearedToNil_revertsToFollowSystemAcrossRelaunch() {
        let prefs = PreferencesStore(defaults: defaults)
        let model = DocumentModel(preferences: prefs)
        model.themeOverride = .xcodeLight
        model.themeOverride = nil
        XCTAssertNil(prefs.themeOverrideRaw, "clearing the override must clear the persisted value")

        let relaunched = DocumentModel(preferences: PreferencesStore(defaults: defaults))
        XCTAssertNil(relaunched.themeOverride, "a cleared override stays cleared across relaunch")
    }

    /// A stale/renamed raw value (e.g. a theme that no longer exists) must
    /// degrade to Follow System on restore — never crash on a force-unwrap.
    func test_themeOverride_unknownRawDegradesToFollowSystem() {
        let prefs = PreferencesStore(defaults: defaults)
        prefs.themeOverrideRaw = "aThemeThatNoLongerExists"

        let model = DocumentModel(preferences: PreferencesStore(defaults: defaults))
        XCTAssertNil(model.themeOverride,
            "an unknown persisted theme name maps to nil (Follow System), not a crash")
    }
}
