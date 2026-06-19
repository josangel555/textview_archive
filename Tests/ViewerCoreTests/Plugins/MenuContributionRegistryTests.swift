import XCTest
@testable import ViewerCore

/// Tests for the contribution → menu-item mapping (TSK-754). These pin
/// the tree-building + ordering + enabled-flag behaviour the AppKit menu
/// builder consumes, so a logic regression fails on the host gate even
/// though the actual on-screen NSMenu is VM-only.
@MainActor
final class MenuContributionRegistryTests: XCTestCase {

    private func entry(
        plugin: String = "p",
        item: String,
        title: String,
        submenu: String? = nil,
        order: Int = 100,
        invoke: (@MainActor () -> Void)? = {}
    ) -> MenuContributionRegistry.Entry {
        MenuContributionRegistry.Entry(
            pluginID: plugin, itemID: item, title: title,
            submenu: submenu, order: order, invoke: invoke
        )
    }

    func test_empty_registry_yields_empty_model() {
        let reg = MenuContributionRegistry()
        XCTAssertTrue(reg.menuModel().isEmpty)
    }

    // Top-level items (no submenu) map into `topLevel`; named submenus
    // group their items under `submenus`.
    func test_topLevel_and_submenu_split() {
        let reg = MenuContributionRegistry()
        reg.register(entry(item: "a", title: "Top A"))
        reg.register(entry(item: "b", title: "Sub B", submenu: "Tools"))
        reg.register(entry(item: "c", title: "Sub C", submenu: "Tools"))

        let model = reg.menuModel()
        XCTAssertFalse(model.isEmpty)
        XCTAssertEqual(model.topLevel.map(\.title), ["Top A"])
        XCTAssertEqual(model.submenus.count, 1)
        XCTAssertEqual(model.submenus[0].title, "Tools")
        XCTAssertEqual(model.submenus[0].items.map(\.title), ["Sub B", "Sub C"])
    }

    // `order` ascending drives item order; ties break by plugin id then
    // item id (stable, deterministic).
    func test_ordering_by_order_then_id() {
        let reg = MenuContributionRegistry()
        reg.register(entry(plugin: "z", item: "i", title: "Late", order: 200))
        reg.register(entry(plugin: "a", item: "j", title: "Early", order: 10))
        reg.register(entry(plugin: "a", item: "b", title: "TieA", order: 50))
        reg.register(entry(plugin: "a", item: "a", title: "TieB", order: 50))

        let model = reg.menuModel()
        // order 10, then (50: item a before item b), then 200.
        XCTAssertEqual(model.topLevel.map(\.title), ["Early", "TieB", "TieA", "Late"])
    }

    // A nil `invoke` (Tier A noop) maps to a disabled item; a non-nil
    // invoke maps to an enabled item.
    func test_nil_invoke_maps_to_disabled_item() {
        let reg = MenuContributionRegistry()
        reg.register(entry(item: "noop", title: "Inert", invoke: nil))
        reg.register(entry(item: "live", title: "Active", invoke: {}))

        let model = reg.menuModel()
        let byTitle = Dictionary(uniqueKeysWithValues: model.topLevel.map { ($0.title, $0.enabled) })
        XCTAssertEqual(byTitle["Inert"], false)
        XCTAssertEqual(byTitle["Active"], true)
    }

    // First-seen submenu order is preserved across the sorted entries —
    // two submenus appear in the order their first item is encountered.
    func test_submenu_first_seen_order_preserved() {
        let reg = MenuContributionRegistry()
        reg.register(entry(item: "x", title: "X", submenu: "Beta", order: 10))
        reg.register(entry(item: "y", title: "Y", submenu: "Alpha", order: 20))
        let model = reg.menuModel()
        XCTAssertEqual(model.submenus.map(\.title), ["Beta", "Alpha"])
    }

    func test_dropAll_removes_only_that_plugin() {
        let reg = MenuContributionRegistry()
        reg.register(entry(plugin: "p1", item: "a", title: "A"))
        reg.register(entry(plugin: "p2", item: "b", title: "B"))
        reg.dropAll(forPlugin: "p1")
        XCTAssertEqual(reg.menuModel().topLevel.map(\.title), ["B"])
        XCTAssertEqual(reg.entries(forPlugin: "p1").count, 0)
        XCTAssertEqual(reg.entries(forPlugin: "p2").count, 1)
    }

    // The invoke closure round-trips through the model: the menu builder
    // finds it via `(pluginID, itemID)` in `all`, so verify it fires.
    func test_invoke_closure_runs() {
        let reg = MenuContributionRegistry()
        var fired = false
        reg.register(entry(item: "go", title: "Go", invoke: { fired = true }))
        let found = reg.all.first { $0.itemID == "go" }
        found?.invoke?()
        XCTAssertTrue(fired)
    }
}
