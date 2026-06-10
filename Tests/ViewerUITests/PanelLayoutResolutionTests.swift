import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Host-safe (pure @MainActor logic, no NSApplication / no window) tests
/// for the resolution building blocks the rails + sidebar + ContentView
/// will compose in the UI phase.
///
/// The actual `leftContainerVisible` predicate lives in `ContentView`
/// (built next phase) and is:
///
///     sidebar.isVisible
///       && panelLayout.railPanels(on: .left)
///            .contains { panelLayout.isVisible($0, dataPresent: ...) }
///
/// Here we exercise the two store-level pieces that predicate is built
/// from — `railPanels(on:)` and `isVisible(_:dataPresent:)` — plus the
/// data-presence feed, so the UI phase only has to wire them together.
@MainActor
final class PanelLayoutResolutionTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "PanelLayoutResolutionTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore() -> PanelLayoutStore {
        PanelLayoutStore(defaults: defaults)
    }

    /// Mirrors the future `leftContainerVisible` "≥1 left panel resolves
    /// visible" half (without the `sidebar.isVisible` master gate, which
    /// is a plain `&&` in ContentView).
    private func anyLeftPanelVisible(
        _ store: PanelLayoutStore,
        presence: [SidebarPanelKind: Bool]
    ) -> Bool {
        store.railPanels(on: .left).contains {
            store.isVisible($0, dataPresent: presence[$0] ?? false)
        }
    }

    /// Full `leftContainerVisible` predicate as composed in
    /// `ContentView`: the master switch AND ≥1 left panel resolving
    /// visible. Kept here (not just the `&&`-free half above) so the
    /// exact composition the view uses is pinned — the master-gate
    /// short-circuit + the "rail brings the collapsed-by-emptiness
    /// sidebar back" case both ride on this shape.
    private func leftContainerVisible(
        sidebarVisible: Bool,
        _ store: PanelLayoutStore,
        presence: [SidebarPanelKind: Bool]
    ) -> Bool {
        sidebarVisible && anyLeftPanelVisible(store, presence: presence)
    }

    // MARK: - first-run .auto reproduces data-presence

    func test_firstRun_autoReproducesDataPresence() {
        let store = makeStore()   // empty overrides ⇒ all .auto
        // Root + repo: git present, claude/LSP absent.
        let presence = SidebarDataPresence.evaluate(
            .init(hasRoot: true, hasRepo: true)
        )
        for kind in SidebarPanelKind.allCases {
            XCTAssertEqual(
                store.isVisible(kind, dataPresent: presence[kind] ?? false),
                presence[kind],
                "\(kind): fresh-install .auto must resolve === data-presence"
            )
        }
    }

    // MARK: - all panels on .left by default

    func test_default_allPanelsOnLeftRail() {
        let store = makeStore()
        XCTAssertEqual(store.railPanels(on: .left), SidebarPanelRegistry.defaultOrder)
        XCTAssertEqual(store.railPanels(on: .right), [])
        XCTAssertEqual(store.railPanels(on: .bottom), [])
    }

    // MARK: - leftContainer "≥1 visible" half

    /// No folder open, no data anywhere, all .auto ⇒ only the
    /// always-on panels (bookmarks / pluginSections) resolve visible, so
    /// the left container would still show (those panels are always
    /// present). This matches today's behavior: an empty sidebar still
    /// renders Bookmarks.
    func test_noData_alwaysOnPanelsKeepLeftContainerVisible() {
        let store = makeStore()
        let presence = SidebarDataPresence.evaluate(.init())   // all false except always-on
        XCTAssertTrue(anyLeftPanelVisible(store, presence: presence),
                      "Bookmarks/plugins are always present ⇒ left container stays visible")
    }

    /// When the user explicitly `.hidden`s EVERY left panel, no left
    /// panel resolves visible ⇒ the left container collapses (even
    /// though the always-on panels have data).
    func test_allLeftPanelsHidden_collapsesLeftContainer() {
        let store = makeStore()
        for kind in SidebarPanelKind.allCases {
            store.setOverride(kind, .hidden)
        }
        // Even with a full data-present folder, everything is forced off.
        let presence = SidebarDataPresence.evaluate(
            .init(hasRoot: true, hasRepo: true,
                  hasLSPLanguage: true, claudeHasTranscripts: true)
        )
        XCTAssertFalse(anyLeftPanelVisible(store, presence: presence),
                       "All-hidden ⇒ no left panel resolves visible ⇒ container collapses")
    }

    // MARK: - master switch short-circuits leftContainerVisible

    /// `sidebar.isVisible == false` ⇒ container hidden regardless of how
    /// any left panel resolves (the menu "Toggle Sidebar" master switch
    /// kills the whole left shoulder). The accordion and the left rail
    /// hide together; ContentView gates the rail on the same flag.
    func test_masterSwitchOff_hidesLeftContainer_regardlessOfPanels() {
        let store = makeStore()
        // Full data present — every left panel WOULD resolve visible.
        let presence = SidebarDataPresence.evaluate(
            .init(hasRoot: true, hasRepo: true,
                  hasLSPLanguage: true, claudeHasTranscripts: true)
        )
        XCTAssertTrue(anyLeftPanelVisible(store, presence: presence))
        XCTAssertFalse(
            leftContainerVisible(sidebarVisible: false, store, presence: presence),
            "Master switch off must hide the container even when panels resolve visible"
        )
        XCTAssertTrue(
            leftContainerVisible(sidebarVisible: true, store, presence: presence),
            "Master switch on + panels visible ⇒ container shows"
        )
    }

    /// "Rail brings the collapsed-by-emptiness sidebar back": with the
    /// master switch ON but every left panel `.hidden`, the container
    /// collapses; clicking a rail button to force one panel `.shown`
    /// flips `leftContainerVisible` back to true. (The rail itself stays
    /// visible across this — it's gated only on the master switch.)
    func test_railShownPanel_restoresCollapsedContainer() {
        let store = makeStore()
        for kind in SidebarPanelKind.allCases { store.setOverride(kind, .hidden) }
        let presence = SidebarDataPresence.evaluate(
            .init(hasRoot: true, hasRepo: true)
        )
        XCTAssertFalse(
            leftContainerVisible(sidebarVisible: true, store, presence: presence),
            "All-hidden ⇒ container collapsed even with master switch on"
        )
        // Click a rail button (toggle a currently-hidden panel → .shown).
        store.toggle(.bookmarks, dataPresent: presence[.bookmarks] ?? false)
        XCTAssertEqual(store.override(for: .bookmarks), .shown)
        XCTAssertTrue(
            leftContainerVisible(sidebarVisible: true, store, presence: presence),
            "Forcing one left panel .shown must restore the collapsed container"
        )
    }

    // MARK: - rail toggle of a no-data panel forces it visible

    /// Clicking the Git rail button in a non-repo folder must surface
    /// the panel (the rejected two-state model's dead-button case).
    func test_toggleNoDataPanel_goesShown_andFlipsResolution() {
        let store = makeStore()
        // Git with no repo: data absent, .auto ⇒ not visible.
        XCTAssertFalse(store.isVisible(.git, dataPresent: false))
        store.toggle(.git, dataPresent: false)
        XCTAssertEqual(store.override(for: .git), .shown)
        XCTAssertTrue(store.isVisible(.git, dataPresent: false),
                      "Forcing .shown must surface a no-data panel")
    }

    /// A panel that's visible-by-data toggles to .hidden and resolves
    /// hidden even though its data is still present.
    func test_toggleDataPresentPanel_goesHidden() {
        let store = makeStore()
        XCTAssertTrue(store.isVisible(.git, dataPresent: true))
        store.toggle(.git, dataPresent: true)
        XCTAssertEqual(store.override(for: .git), .hidden)
        XCTAssertFalse(store.isVisible(.git, dataPresent: true))
    }

    // MARK: - reveal-on-toggle-on expands the section (TSK-609)

    /// Flipping a panel ON via the rail must also EXPAND its section:
    /// Git/Claude keep their own disclosure state (`@AppStorage` on
    /// `expandedStateKey`), and a click that only mounts a collapsed
    /// header reads as "the button does nothing" — the owner-reported
    /// inert buttons 4/5/6 (git / claudeTimeline / lspOutline).
    func test_toggleOn_writesExpandedState_forCollapsedSections() {
        let store = makeStore()
        for kind in [SidebarPanelKind.git, .claudeTimeline, .lspOutline] {
            // Simulate the section having been collapsed by the user.
            defaults.set(false, forKey: kind.expandedStateKey)
            store.toggle(kind, dataPresent: false)   // OFF (auto+no data) → ON
            XCTAssertTrue(defaults.bool(forKey: kind.expandedStateKey),
                "toggling \(kind) ON must expand its section, not mount a collapsed header")
        }
    }

    /// Toggling a panel OFF must NOT touch the disclosure state — a
    /// hidden section keeps whatever expansion it had for the next show.
    func test_toggleOff_leavesExpandedStateAlone() {
        let store = makeStore()
        defaults.set(false, forKey: SidebarPanelKind.git.expandedStateKey)
        store.toggle(.git, dataPresent: true)   // visible-by-data → .hidden
        XCTAssertEqual(store.override(for: .git), .hidden)
        XCTAssertFalse(defaults.bool(forKey: SidebarPanelKind.git.expandedStateKey),
            "hiding a panel must not rewrite its collapsed/expanded state")
    }

    /// The disclosure keys are persisted contracts: `git` must keep its
    /// legacy key (existing user layouts), the rest derive stably.
    func test_expandedStateKeys_areStable() {
        XCTAssertEqual(SidebarPanelKind.git.expandedStateKey,
                       "MarkdownViewer.sidebar.gitExpanded")
        XCTAssertEqual(SidebarPanelKind.claudeTimeline.expandedStateKey,
                       "MarkdownViewer.sidebar.claudeTimeline.expanded")
        XCTAssertEqual(SidebarPanelKind.lspOutline.expandedStateKey,
                       "MarkdownViewer.sidebar.lspOutline.expanded")
    }

    // MARK: - moving a panel off .left changes which rail it shows on

    func test_setEdge_movesPanelBetweenRails() {
        let store = makeStore()
        store.setEdge(.git, .right)
        XCTAssertFalse(store.railPanels(on: .left).contains(.git))
        XCTAssertTrue(store.railPanels(on: .right).contains(.git))
        // Order on the left is preserved minus the moved panel.
        XCTAssertEqual(
            store.railPanels(on: .left),
            SidebarPanelRegistry.defaultOrder.filter { $0 != .git }
        )
    }
}
