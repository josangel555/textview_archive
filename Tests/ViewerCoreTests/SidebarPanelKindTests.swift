import XCTest
@testable import ViewerCore

/// Pure-logic tests for the unified `SidebarPanelKind` enum + the
/// `SidebarPanelRegistry` ordering surface + the
/// `SidebarPanelVisibility` round-trip.
///
/// These cover the seam the future activity-bar UI will read from.
/// They live in `ViewerCoreTests` (not `ViewerUITests`) so they
/// stay host-runnable per the project's "no UI on host" rule.
final class SidebarPanelKindTests: XCTestCase {

    // MARK: - SidebarPanelKind / appStorageKey contracts

    /// Persistence keys are a public contract — renaming any of them
    /// would invalidate per-user layout state on the next launch.
    /// Pinned with explicit equality so a rename can't slip through.
    /// Note: `.git` uses the legacy `gitPanel.height` key so the
    /// case-name evolution didn't break existing user defaults.
    func test_appStorageKeys_are_stable() {
        XCTAssertEqual(SidebarPanelKind.files.appStorageKey,
                       "MarkdownViewer.sidebar.files.height")
        XCTAssertEqual(SidebarPanelKind.bookmarks.appStorageKey,
                       "MarkdownViewer.sidebar.bookmarks.height")
        XCTAssertEqual(SidebarPanelKind.searchAnywhere.appStorageKey,
                       "MarkdownViewer.sidebar.searchAnywhere.height")
        XCTAssertEqual(SidebarPanelKind.git.appStorageKey,
                       "MarkdownViewer.sidebar.gitPanel.height")
        XCTAssertEqual(SidebarPanelKind.claudeTimeline.appStorageKey,
                       "MarkdownViewer.sidebar.claudeTimeline.height")
        XCTAssertEqual(SidebarPanelKind.lspOutline.appStorageKey,
                       "MarkdownViewer.sidebar.lspOutline.height")
        XCTAssertEqual(SidebarPanelKind.lspNavigation.appStorageKey,
                       "MarkdownViewer.sidebar.lspNavigation.height")
        XCTAssertEqual(SidebarPanelKind.lspProblems.appStorageKey,
                       "MarkdownViewer.sidebar.lspProblems.height")
        XCTAssertEqual(SidebarPanelKind.pluginSections.appStorageKey,
                       "MarkdownViewer.sidebar.pluginSections.height")
    }

    /// The pre-refactor type-alias `SidebarPanel` must still resolve.
    /// Several call sites continue to spell it that way; we removed
    /// the old enum and replaced it with a type-alias to
    /// `SidebarPanelKind`, so the alias must compile + behave the
    /// same as the new enum.
    func test_typealias_compiles_and_matches() {
        let viaAlias: SidebarPanel = .bookmarks
        XCTAssertEqual(viaAlias, SidebarPanelKind.bookmarks)
    }

    /// `.gitPanel` is exposed as a static alias for `.git` so old
    /// call sites + the original test suite compile.
    func test_gitPanel_alias_matches_git() {
        XCTAssertEqual(SidebarPanelKind.gitPanel, SidebarPanelKind.git)
        XCTAssertEqual(SidebarPanelKind.gitPanel.appStorageKey,
                       SidebarPanelKind.git.appStorageKey)
    }

    // MARK: - SidebarPanelRegistry default order

    /// FILES sits at the top — pinned with an explicit head check so
    /// a future reorder can't silently demote it back to the bottom.
    func test_defaultOrder_putsFilesFirst() {
        XCTAssertEqual(SidebarPanelRegistry.defaultOrder.first, .files)
    }

    /// Full canonical order. Pinned so an inadvertent shuffle is
    /// caught at test time.
    func test_defaultOrder_isExpected() {
        XCTAssertEqual(
            SidebarPanelRegistry.defaultOrder,
            [
                .files,
                .bookmarks,
                .searchAnywhere,
                .git,
                .claudeTimeline,
                .lspOutline,
                .lspNavigation,
                .lspProblems,
                .pluginSections,
            ]
        )
    }

    /// Every enum case must appear in the registry exactly once —
    /// stops a future panel from being added to the enum but
    /// forgotten in the registry.
    func test_defaultOrder_coversEveryCase() {
        XCTAssertTrue(SidebarPanelRegistry.coversAllCases)
        XCTAssertEqual(
            SidebarPanelRegistry.defaultOrder.count,
            SidebarPanelKind.allCases.count
        )
        XCTAssertEqual(
            Set(SidebarPanelRegistry.defaultOrder),
            Set(SidebarPanelKind.allCases)
        )
    }

    // MARK: - SidebarPanelVisibility

    /// Fresh visibility (default-constructed) has nothing hidden.
    /// Important: a brand-new install must show every panel.
    func test_visibility_defaultShowsAll() {
        let v = SidebarPanelVisibility()
        for kind in SidebarPanelKind.allCases {
            XCTAssertTrue(v.isVisible(kind),
                          "\(kind) should be visible on a fresh install")
        }
    }

    func test_visibility_setVisibleFalse_hidesPanel() {
        var v = SidebarPanelVisibility()
        v.setVisible(.bookmarks, false)
        XCTAssertFalse(v.isVisible(.bookmarks))
        XCTAssertTrue(v.isVisible(.files))
    }

    func test_visibility_toggle_flips() {
        var v = SidebarPanelVisibility()
        XCTAssertTrue(v.isVisible(.git))
        v.toggle(.git)
        XCTAssertFalse(v.isVisible(.git))
        v.toggle(.git)
        XCTAssertTrue(v.isVisible(.git))
    }

    func test_visibility_roundTrip_throughEncodedString() {
        var v = SidebarPanelVisibility()
        v.setVisible(.bookmarks, false)
        v.setVisible(.lspProblems, false)
        let encoded = v.encoded()
        let decoded = SidebarPanelVisibility.decoded(encoded)
        XCTAssertEqual(decoded.hidden, v.hidden)
        XCTAssertFalse(decoded.isVisible(.bookmarks))
        XCTAssertFalse(decoded.isVisible(.lspProblems))
        XCTAssertTrue(decoded.isVisible(.files))
    }

    /// Unknown tokens in the persisted string don't crash + don't
    /// shadow existing cases. Future case removal must not bork
    /// older settings.
    func test_visibility_decoded_dropsUnknownTokens() {
        let v = SidebarPanelVisibility.decoded("bookmarks,bogusCase,git")
        XCTAssertEqual(v.hidden, [.bookmarks, .git])
    }

    func test_visibility_decoded_emptyString_isEmpty() {
        let v = SidebarPanelVisibility.decoded("")
        XCTAssertTrue(v.hidden.isEmpty)
    }

    /// Round-trip through a UserDefaults suite — covers the actual
    /// runtime persistence path used by the (future) visibility
    /// toggle UI.
    func test_visibility_savesAndLoadsFromUserDefaults() {
        let suite = "SidebarPanelVisibilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var v = SidebarPanelVisibility()
        v.setVisible(.claudeTimeline, false)
        v.save(to: defaults)

        let loaded = SidebarPanelVisibility.load(from: defaults)
        XCTAssertEqual(loaded.hidden, [.claudeTimeline])
        XCTAssertFalse(loaded.isVisible(.claudeTimeline))
        XCTAssertTrue(loaded.isVisible(.files))
    }

    /// Missing key on first launch → all visible.
    func test_visibility_loadWithoutKey_isAllVisible() {
        let suite = "SidebarPanelVisibilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let loaded = SidebarPanelVisibility.load(from: defaults)
        XCTAssertTrue(loaded.hidden.isEmpty)
    }

    /// The storage key for the visibility set is part of the public
    /// contract too (same reasoning as the per-panel height keys).
    func test_visibility_storageKey_isStable() {
        XCTAssertEqual(SidebarPanelVisibility.storageKey,
                       "MarkdownViewer.sidebar.hiddenPanels")
    }

    // MARK: - Resize-state persistence round-trip
    //
    // Fix #2 (remember resize state across restarts): write a height
    // through a binding-like setter, then "relaunch" by constructing
    // a fresh defaults handle pointing at the same suite + reading
    // back through `SidebarPanelHeights.readClamped`. Failure mode
    // we want to catch: an init-time write that clobbers the
    // persisted value with the default.

    func test_persistedHeight_survivesRelaunch() {
        let suite = "SidebarPanelHeightsRelaunch.\(UUID().uuidString)"
        let writeHandle = UserDefaults(suiteName: suite)!
        defer { writeHandle.removePersistentDomain(forName: suite) }

        // First "launch": user drags Bookmarks to 280pt and ends
        // the drag → the divider's onEnded commit writes 280 to
        // the per-panel @AppStorage key.
        writeHandle.set(280.0, forKey: SidebarPanelKind.bookmarks.appStorageKey)

        // Second "launch": a brand-new defaults handle (same suite,
        // since UserDefaults is global per suite name across the
        // process) — must read back the persisted 280, NOT the
        // default 220.
        let readHandle = UserDefaults(suiteName: suite)!
        let value = SidebarPanelHeights.readClamped(.bookmarks,
                                                    from: readHandle)
        XCTAssertEqual(value, 280.0,
                       "Persisted height should survive a relaunch")
    }

    func test_persistedHeight_perPanelKey_doesNotBleed() {
        // Writing one panel's height should never affect another's
        // — the per-panel `appStorageKey` is the isolation barrier.
        let suite = "SidebarPanelHeightsIsolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(300.0, forKey: SidebarPanelKind.git.appStorageKey)

        XCTAssertEqual(SidebarPanelHeights.readClamped(.git, from: defaults),
                       300.0)
        // All other panels still read their defaults — no key bleed.
        XCTAssertEqual(SidebarPanelHeights.readClamped(.bookmarks,
                                                       from: defaults),
                       SidebarPanelKind.bookmarks.defaultHeight)
        XCTAssertEqual(SidebarPanelHeights.readClamped(.lspProblems,
                                                       from: defaults),
                       SidebarPanelKind.lspProblems.defaultHeight)
    }
}
