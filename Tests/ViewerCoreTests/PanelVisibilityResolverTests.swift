import XCTest
@testable import ViewerCore

/// Pure-logic tests for the three-state visibility model:
/// `PanelOverride` × data-presence → on-screen visibility, plus the
/// `PanelVisibilityOverrides` persistence round-trip.
final class PanelVisibilityResolverTests: XCTestCase {

    // MARK: - 3-state × dataPresent truth table (6 rows)

    func test_resolver_truthTable() {
        // .auto defers to the heuristic.
        XCTAssertTrue(PanelVisibilityResolver.isVisible(.git, override: .auto, dataPresent: true))
        XCTAssertFalse(PanelVisibilityResolver.isVisible(.git, override: .auto, dataPresent: false))
        // .shown forces on regardless of data.
        XCTAssertTrue(PanelVisibilityResolver.isVisible(.git, override: .shown, dataPresent: true))
        XCTAssertTrue(PanelVisibilityResolver.isVisible(.git, override: .shown, dataPresent: false))
        // .hidden forces off regardless of data.
        XCTAssertFalse(PanelVisibilityResolver.isVisible(.git, override: .hidden, dataPresent: true))
        XCTAssertFalse(PanelVisibilityResolver.isVisible(.git, override: .hidden, dataPresent: false))
    }

    /// `.shown` on a no-data panel resolves visible — the key property
    /// the rejected two-state boolean model could not express (it would
    /// be a dead button).
    func test_resolver_shown_forcesNoDataPanelVisible() {
        XCTAssertTrue(
            PanelVisibilityResolver.isVisible(.git, override: .shown, dataPresent: false),
            "Forcing .shown must surface a panel even with no data (e.g. Git in a non-repo folder)"
        )
    }

    // MARK: - PanelOverride enum

    func test_override_allCases() {
        XCTAssertEqual(Set(PanelOverride.allCases), [.auto, .shown, .hidden])
    }

    // MARK: - PanelVisibilityOverrides defaults

    func test_overrides_defaultIsAuto() {
        let o = PanelVisibilityOverrides()
        for kind in SidebarPanelKind.allCases {
            XCTAssertEqual(o.state(kind), .auto,
                           "\(kind) should default to .auto on a fresh install")
        }
    }

    func test_init_dropsAutoEntries() {
        let o = PanelVisibilityOverrides(map: [.git: .auto, .bookmarks: .hidden])
        XCTAssertEqual(o, PanelVisibilityOverrides(map: [.bookmarks: .hidden]))
        XCTAssertEqual(o.encoded(), "bookmarks:hidden")
    }

    // MARK: - set / toggle semantics

    func test_set_assignsAndAutoRemoves() {
        var o = PanelVisibilityOverrides()
        o.set(.git, .shown)
        XCTAssertEqual(o.state(.git), .shown)
        o.set(.git, .auto)   // .auto removes the entry
        XCTAssertEqual(o.state(.git), .auto)
        XCTAssertEqual(o.encoded(), "")
    }

    func test_toggle_visibleGoesHidden() {
        var o = PanelVisibilityOverrides()
        o.toggle(.git, currentlyVisible: true)
        XCTAssertEqual(o.state(.git), .hidden)
    }

    func test_toggle_hiddenGoesShown() {
        var o = PanelVisibilityOverrides()
        // A panel currently hidden (whether .auto-hidden for no data or
        // explicitly .hidden) toggles to .shown.
        o.toggle(.git, currentlyVisible: false)
        XCTAssertEqual(o.state(.git), .shown)
    }

    func test_toggle_isFlipWhatYouSee_overTwoClicks() {
        var o = PanelVisibilityOverrides()
        // First click on a no-data (.auto-hidden) panel → .shown.
        var visible = PanelVisibilityResolver.isVisible(.git, override: o.state(.git), dataPresent: false)
        o.toggle(.git, currentlyVisible: visible)
        XCTAssertEqual(o.state(.git), .shown)
        // Second click (now visible) → .hidden.
        visible = PanelVisibilityResolver.isVisible(.git, override: o.state(.git), dataPresent: false)
        o.toggle(.git, currentlyVisible: visible)
        XCTAssertEqual(o.state(.git), .hidden)
    }

    // MARK: - encode / decode round-trip

    func test_encoded_isSortedStable() {
        var o = PanelVisibilityOverrides()
        o.set(.git, .shown)
        o.set(.bookmarks, .hidden)
        XCTAssertEqual(o.encoded(), "bookmarks:hidden,git:shown")
    }

    func test_roundTrip_throughEncodedString() {
        var o = PanelVisibilityOverrides()
        o.set(.git, .shown)
        o.set(.lspProblems, .hidden)
        let decoded = PanelVisibilityOverrides.decoded(o.encoded())
        XCTAssertEqual(decoded, o)
        XCTAssertEqual(decoded.state(.git), .shown)
        XCTAssertEqual(decoded.state(.lspProblems), .hidden)
        XCTAssertEqual(decoded.state(.files), .auto)
    }

    func test_decoded_emptyString_isAllAuto() {
        let o = PanelVisibilityOverrides.decoded("")
        XCTAssertEqual(o, PanelVisibilityOverrides())
    }

    // MARK: - unknown-token drop

    func test_decoded_dropsUnknownKind() {
        let o = PanelVisibilityOverrides.decoded("git:shown,bogusPanel:hidden,bookmarks:hidden")
        XCTAssertEqual(o, PanelVisibilityOverrides(map: [.git: .shown, .bookmarks: .hidden]))
    }

    func test_decoded_dropsUnknownStateToken() {
        let o = PanelVisibilityOverrides.decoded("git:maybe,bookmarks:shown")
        // Unknown state token ⇒ that panel falls back to .auto.
        XCTAssertEqual(o.state(.git), .auto)
        XCTAssertEqual(o.state(.bookmarks), .shown)
    }

    func test_decoded_skipsMalformedTokens() {
        let o = PanelVisibilityOverrides.decoded("git,bookmarks:hidden,:shown,a:b:c")
        XCTAssertEqual(o, PanelVisibilityOverrides(map: [.bookmarks: .hidden]))
    }

    // MARK: - UserDefaults load / save

    func test_savesAndLoadsFromUserDefaults() {
        let suite = "PanelVisibilityOverridesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var o = PanelVisibilityOverrides()
        o.set(.claudeTimeline, .shown)
        o.save(to: defaults)

        let loaded = PanelVisibilityOverrides.load(from: defaults)
        XCTAssertEqual(loaded, o)
        XCTAssertEqual(loaded.state(.claudeTimeline), .shown)
    }

    func test_loadWithoutKey_isAllAuto() {
        let suite = "PanelVisibilityOverridesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let loaded = PanelVisibilityOverrides.load(from: defaults)
        XCTAssertEqual(loaded, PanelVisibilityOverrides())
    }

    // MARK: - storage-key stability (public contract)

    func test_storageKey_isStable() {
        XCTAssertEqual(PanelVisibilityOverrides.storageKey,
                       "MarkdownViewer.sidebar.panelOverrides")
    }
}
