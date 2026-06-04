import XCTest
@testable import ViewerCore

/// Pure-logic tests for `PanelDockLayout` — the persisted per-panel
/// fixed-size store for docked tool windows (UX-E / #227).
///
/// Mirrors `TerminalPaneLayoutTests` / `PanelEdgeTests`: host-runnable (no
/// UI), pins the storage key + the `kind:edge:size` wire format, covers the
/// fixed-default (not-tiny) open size, the floor clamp, the NO-maximum
/// (corruption-ceiling-only) contract, and the UserDefaults round-trip.
final class PanelDockLayoutTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suite = "PanelDockLayoutTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    // MARK: - defaults are sensible (not tiny), per edge

    func test_emptyLayout_usesPerEdgeDefaults_notTiny() {
        let l = PanelDockLayout()
        // A freshly docked panel opens at a comfortable default — never tiny.
        XCTAssertEqual(l.size(.git, on: .right), PanelDockLayout.defaultRightWidth)
        XCTAssertEqual(l.size(.git, on: .bottom), PanelDockLayout.defaultBottomHeight)
        // Sanity: the defaults are well above the floor.
        XCTAssertGreaterThan(PanelDockLayout.defaultRightWidth, PanelDockLayout.minSize)
        XCTAssertGreaterThan(PanelDockLayout.defaultBottomHeight, PanelDockLayout.minSize)
    }

    func test_defaultSize_perEdge() {
        XCTAssertEqual(PanelDockLayout.defaultSize(for: .right), PanelDockLayout.defaultRightWidth)
        XCTAssertEqual(PanelDockLayout.defaultSize(for: .bottom), PanelDockLayout.defaultBottomHeight)
    }

    // MARK: - per-(kind, edge) keying — sizes don't collide across docks

    func test_size_isKeyedPerEdge() {
        var l = PanelDockLayout()
        l.setSize(340, for: .git, on: .right)
        l.setSize(200, for: .git, on: .bottom)
        // Same panel, two docks, two independent remembered sizes.
        XCTAssertEqual(l.size(.git, on: .right), 340)
        XCTAssertEqual(l.size(.git, on: .bottom), 200)
        // A different panel on the same edge is unaffected (default).
        XCTAssertEqual(l.size(.lspProblems, on: .right), PanelDockLayout.defaultRightWidth)
    }

    // MARK: - floor clamp

    func test_setSize_belowFloor_clampsToMin() {
        var l = PanelDockLayout()
        l.setSize(10, for: .git, on: .right)
        XCTAssertEqual(l.size(.git, on: .right), PanelDockLayout.minSize)
    }

    // MARK: - NO maximum (only a corruption ceiling, far above any display)

    func test_noUXMaximum_largeSizesSurviveUpToCorruptionCeiling() {
        var l = PanelDockLayout()
        // A genuinely large (but plausible on a big display) width must be
        // kept verbatim — there is NO UX maximum (brief item 2).
        l.setSize(4000, for: .git, on: .right)
        XCTAssertEqual(l.size(.git, on: .right), 4000)
        // Only a hostile / corrupt value is clamped, and only to the
        // far-above-any-display corruption ceiling.
        l.setSize(999_999, for: .git, on: .right)
        XCTAssertEqual(l.size(.git, on: .right), PanelDockLayout.maxSize)
        // The corruption ceiling is far larger than any real display.
        XCTAssertGreaterThan(PanelDockLayout.maxSize, 50_000)
    }

    func test_clamp_nonFinite() {
        XCTAssertEqual(PanelDockLayout.clamp(.nan), PanelDockLayout.defaultRightWidth)
        XCTAssertEqual(PanelDockLayout.clamp(.infinity), PanelDockLayout.maxSize)
        XCTAssertEqual(PanelDockLayout.clamp(-.infinity), PanelDockLayout.minSize)
    }

    // MARK: - encode / decode round-trip

    func test_encoded_isSortedStable_andInteger() {
        var l = PanelDockLayout()
        l.setSize(340.7, for: .git, on: .right)
        l.setSize(200, for: .bookmarks, on: .bottom)
        // Sorted by token; sizes emitted as rounded integers.
        XCTAssertEqual(l.encoded(), "bookmarks:bottom:200,git:right:341")
    }

    func test_roundTrip_throughEncodedString() {
        var l = PanelDockLayout()
        l.setSize(360, for: .git, on: .right)
        l.setSize(180, for: .lspProblems, on: .bottom)
        let decoded = PanelDockLayout.decoded(l.encoded())
        XCTAssertEqual(decoded, l)
        XCTAssertEqual(decoded.size(.git, on: .right), 360)
        XCTAssertEqual(decoded.size(.lspProblems, on: .bottom), 180)
    }

    func test_decoded_emptyString_isAllDefaults() {
        let l = PanelDockLayout.decoded("")
        XCTAssertEqual(l, PanelDockLayout())
        XCTAssertEqual(l.size(.git, on: .right), PanelDockLayout.defaultRightWidth)
    }

    // MARK: - malformed / unknown token drop (forward-compat)

    func test_decoded_dropsUnknownKindEdgeAndMalformed() {
        let l = PanelDockLayout.decoded(
            "git:right:340,bogusPanel:right:200,bookmarks:sideways:300," +
            "noSize:right,bookmarks:bottom:220,extra:right:100:weird"
        )
        XCTAssertEqual(l.size(.git, on: .right), 340)
        XCTAssertEqual(l.size(.bookmarks, on: .bottom), 220)
        // The bogus kind, unknown edge, missing-size and triple-size tokens
        // all contributed nothing.
        var expected = PanelDockLayout()
        expected.setSize(340, for: .git, on: .right)
        expected.setSize(220, for: .bookmarks, on: .bottom)
        XCTAssertEqual(l, expected)
    }

    func test_decoded_clampsHostileStoredValues() {
        let l = PanelDockLayout.decoded("git:right:5,bookmarks:right:999999")
        XCTAssertEqual(l.size(.git, on: .right), PanelDockLayout.minSize)
        XCTAssertEqual(l.size(.bookmarks, on: .right), PanelDockLayout.maxSize)
    }

    // MARK: - UserDefaults load / save

    func test_savesAndLoadsFromUserDefaults() {
        let d = freshDefaults()
        var l = PanelDockLayout()
        l.setSize(340, for: .git, on: .right)
        l.save(to: d)

        let loaded = PanelDockLayout.load(from: d)
        XCTAssertEqual(loaded, l)
        XCTAssertEqual(loaded.size(.git, on: .right), 340)
    }

    func test_loadWithoutKey_isAllDefaults() {
        let d = freshDefaults()
        let loaded = PanelDockLayout.load(from: d)
        XCTAssertEqual(loaded, PanelDockLayout())
    }

    func test_save_survivesRelaunch() {
        let suite = "PanelDockRelaunch.\(UUID().uuidString)"
        let writeHandle = UserDefaults(suiteName: suite)!
        defer { writeHandle.removePersistentDomain(forName: suite) }

        var l = PanelDockLayout()
        l.setSize(420, for: .lspProblems, on: .bottom)
        l.save(to: writeHandle)

        let readHandle = UserDefaults(suiteName: suite)!
        let loaded = PanelDockLayout.load(from: readHandle)
        XCTAssertEqual(loaded.size(.lspProblems, on: .bottom), 420)
    }

    // MARK: - storage-key stability (public contract)

    func test_storageKey_isStable() {
        XCTAssertEqual(PanelDockLayout.storageKey,
                       "MarkdownViewer.sidebar.panelDockSizes")
    }
}
