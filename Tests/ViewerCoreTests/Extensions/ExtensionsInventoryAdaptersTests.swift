import XCTest
@testable import ViewerCore

/// Host tests for the per-subsystem → unified-catalog adapters
/// (TSK-338 — Merge Plugins). These pin how each subsystem's own state
/// (plugin enable flag + grant decision, walkthrough script fields) maps
/// into the merged `ExtensionItem` — the wiring the consolidated view
/// relies on.
final class ExtensionsInventoryAdaptersTests: XCTestCase {

    private typealias Plugin = ExtensionsInventory.PluginSnapshot
    private typealias Walk = ExtensionsInventory.WalkthroughSnapshot

    // MARK: - Plugin status mapping (grant dominates the enable flag)

    func test_plugin_granted_and_enabled_maps_to_enabled() {
        let item = ExtensionsInventory.item(from: Plugin(
            id: "p", name: "P", version: "1.0", enabled: true, grant: .granted))
        XCTAssertEqual(item.status, .enabled)
    }

    func test_plugin_granted_but_disabled_maps_to_disabled() {
        let item = ExtensionsInventory.item(from: Plugin(
            id: "p", name: "P", version: "1.0", enabled: false, grant: .granted))
        XCTAssertEqual(item.status, .disabled)
    }

    func test_plugin_awaiting_grant_dominates_even_if_enabled() {
        // A required-but-undecided grant must surface as awaitingGrant,
        // NOT enabled — the plugin can't usefully contribute yet.
        let item = ExtensionsInventory.item(from: Plugin(
            id: "p", name: "P", version: "1.0", enabled: true, grant: .required))
        XCTAssertEqual(item.status, .awaitingGrant)
    }

    func test_plugin_denied_grant_maps_to_denied() {
        let item = ExtensionsInventory.item(from: Plugin(
            id: "p", name: "P", version: "1.0", enabled: false, grant: .denied))
        XCTAssertEqual(item.status, .denied)
    }

    func test_plugin_no_grant_falls_back_to_enable_flag() {
        // Bundled plugins have no grants; nil grant ⇒ status follows
        // the enable flag.
        XCTAssertEqual(
            ExtensionsInventory.item(from: Plugin(
                id: "b", name: "B", version: "1.0", isBundled: true,
                enabled: true, grant: nil)).status,
            .enabled)
        XCTAssertEqual(
            ExtensionsInventory.item(from: Plugin(
                id: "b", name: "B", version: "1.0", isBundled: true,
                enabled: false, grant: nil)).status,
            .disabled)
    }

    // MARK: - Plugin field projection

    func test_plugin_projects_version_author_and_capabilities_detail() {
        let item = ExtensionsInventory.item(from: Plugin(
            id: "com.acme.notes", name: "Notes", version: "2.1.0",
            author: "Acme", capabilities: ["ui.sidebar", "shell.exec"],
            isBundled: false, enabled: true, grant: .granted))
        XCTAssertEqual(item.kind, .plugin)
        XCTAssertEqual(item.rawID, "com.acme.notes")
        XCTAssertEqual(item.version, "2.1.0")
        XCTAssertEqual(item.author, "Acme")
        XCTAssertFalse(item.isBundled)
        // Capabilities are sorted into the detail line.
        XCTAssertEqual(item.detail, "Capabilities: shell.exec, ui.sidebar")
    }

    func test_plugin_with_no_capabilities_has_nil_detail() {
        let item = ExtensionsInventory.item(from: Plugin(
            id: "p", name: "P", version: "1.0", capabilities: [],
            enabled: true, grant: .granted))
        XCTAssertNil(item.detail)
    }

    func test_plugin_bundled_flag_carries_through() {
        let item = ExtensionsInventory.item(from: Plugin(
            id: "rowcount", name: "Row Counter", version: "1.0",
            isBundled: true, enabled: true, grant: nil))
        XCTAssertTrue(item.isBundled)
    }

    // MARK: - Walkthrough projection

    func test_walkthrough_projects_to_available_with_subtitle_detail() {
        let item = ExtensionsInventory.item(from: Walk(
            id: "tour.intro", title: "Getting Started",
            subtitle: "A quick tour", author: "TextView", isBundled: true))
        XCTAssertEqual(item.kind, .walkthrough)
        XCTAssertEqual(item.rawID, "tour.intro")
        XCTAssertEqual(item.name, "Getting Started")
        XCTAssertEqual(item.detail, "A quick tour")
        XCTAssertEqual(item.author, "TextView")
        XCTAssertNil(item.version, "walkthroughs carry no version")
        XCTAssertEqual(item.status, .available,
                       "a walkthrough on disk is always launchable on demand")
        XCTAssertTrue(item.isBundled)
    }

    // MARK: - Combined builder

    func test_combined_initializer_merges_and_orders_both_subsystems() {
        let inv = ExtensionsInventory(
            plugins: [
                Plugin(id: "p.beta", name: "Beta", version: "1.0",
                       enabled: false, grant: .granted),
                Plugin(id: "p.alpha", name: "Alpha", version: "1.0",
                       enabled: true, grant: .granted),
            ],
            walkthroughs: [
                Walk(id: "w.tour", title: "Tour", isBundled: true),
            ])
        // Plugins first (active before inactive), walkthrough last.
        XCTAssertEqual(inv.items.map(\.rawID), ["p.alpha", "p.beta", "w.tour"])
        XCTAssertEqual(inv.counts()[.plugin], 2)
        XCTAssertEqual(inv.counts()[.walkthrough], 1)
    }

    func test_combined_initializer_handles_empty_inputs() {
        let inv = ExtensionsInventory(plugins: [], walkthroughs: [])
        XCTAssertTrue(inv.isEmpty)
    }
}
