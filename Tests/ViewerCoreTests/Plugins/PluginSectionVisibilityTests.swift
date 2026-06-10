import XCTest
@testable import ViewerCore

/// TSK-614 — the "Hide Section" dismiss affordance for plugin sidebar
/// sections (the always-on ROW COUNTS section had no way off the
/// screen). Pins the visibility state machine headlessly:
/// disable drops the section + persists; enable restores it (bundled
/// plugins re-register from the dormant stash, no launch hook re-run);
/// a persisted dismissal survives "relaunch" (a fresh registry on the
/// same defaults). The context-menu / Settings rendering is the VM lane;
/// both UI surfaces call exactly `setEnabled(_:enabled:)`.
@MainActor
final class PluginSectionVisibilityTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "PluginVisibility-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await super.tearDown()
    }

    private func makeRegistry() -> PluginRegistry {
        PluginRegistry(grantStore: PluginGrantStore(), defaults: defaults)
    }

    private func registerRowCounter(into registry: PluginRegistry) {
        let entry = SidebarSectionRegistry.Entry(
            pluginID: RowCounterPlugin.id,
            sectionID: "row-counts",
            title: "ROW COUNTS",
            icon: "number.square",
            order: 500,
            collapsedByDefault: false,
            provider: RowCounterPlugin.rows(for:)
        )
        registry.registerBundledSidebarSection(
            manifest: RowCounterPlugin.manifest, entry: entry)
    }

    func test_hide_dropsSectionAndPersists() {
        let registry = makeRegistry()
        registerRowCounter(into: registry)
        XCTAssertEqual(registry.sidebarSections.all.count, 1)

        registry.setEnabled(RowCounterPlugin.id, enabled: false)

        XCTAssertTrue(registry.sidebarSections.all.isEmpty,
                      "hidden section must not be offered to the sidebar")
        XCTAssertEqual(registry.loaded[RowCounterPlugin.id]?.enabled, false,
                       "plugin stays listed (Settings re-enable path) but disabled")
        XCTAssertTrue(registry.persistedDisabledIDs.contains(RowCounterPlugin.id),
                      "dismissal must persist")
    }

    func test_reEnable_restoresBundledSectionWithoutRelaunch() {
        let registry = makeRegistry()
        registerRowCounter(into: registry)
        registry.setEnabled(RowCounterPlugin.id, enabled: false)

        registry.setEnabled(RowCounterPlugin.id, enabled: true)

        XCTAssertEqual(registry.sidebarSections.all.count, 1,
                       "bundled section must re-register from the dormant stash")
        XCTAssertEqual(registry.sidebarSections.all.first?.sectionID, "row-counts")
        XCTAssertEqual(registry.loaded[RowCounterPlugin.id]?.enabled, true)
        XCTAssertFalse(registry.persistedDisabledIDs.contains(RowCounterPlugin.id),
                       "re-enable must clear the persisted dismissal")
    }

    func test_persistedDismissal_survivesRelaunch() {
        let first = makeRegistry()
        registerRowCounter(into: first)
        first.setEnabled(RowCounterPlugin.id, enabled: false)

        // "Relaunch": a fresh registry on the same defaults runs the
        // same launch-time registration the app does.
        let second = makeRegistry()
        registerRowCounter(into: second)

        XCTAssertTrue(second.sidebarSections.all.isEmpty,
                      "a dismissed section must stay hidden across relaunch")
        XCTAssertEqual(second.loaded[RowCounterPlugin.id]?.enabled, false)

        // ...and re-enabling AFTER relaunch still restores it (the
        // registered-while-disabled entry was parked, not dropped).
        second.setEnabled(RowCounterPlugin.id, enabled: true)
        XCTAssertEqual(second.sidebarSections.all.count, 1)
    }

    func test_doubleDisable_doesNotDuplicateDormantEntries() {
        let registry = makeRegistry()
        registerRowCounter(into: registry)
        registry.setEnabled(RowCounterPlugin.id, enabled: false)
        registry.setEnabled(RowCounterPlugin.id, enabled: false)  // no-op
        registry.setEnabled(RowCounterPlugin.id, enabled: true)
        XCTAssertEqual(registry.sidebarSections.all.count, 1,
                       "idempotent disable must not duplicate the section on re-enable")
    }
}
