import XCTest
@testable import ViewerCore

/// Host tests for the merged Extensions catalog (TSK-338 — Merge Plugins).
///
/// These pin the *behaviour* of the unified inventory — dedupe, ordering,
/// filtering, status mapping — so a logic regression fails the host gate.
/// The render layer (a consolidated Extensions view) is validated
/// separately on the VM; this suite is the model contract it projects.
final class ExtensionsInventoryTests: XCTestCase {

    private typealias Item = ExtensionsInventory.ExtensionItem

    // MARK: - Identity

    func test_id_is_namespaced_by_kind() {
        let plugin = Item(rawID: "x", kind: .plugin, name: "X", status: .enabled)
        let walk = Item(rawID: "x", kind: .walkthrough, name: "X", status: .available)
        XCTAssertEqual(plugin.id, "plugin:x")
        XCTAssertEqual(walk.id, "walkthrough:x")
        // Same rawID, different kind ⇒ distinct ids ⇒ both survive dedupe.
        let inv = ExtensionsInventory(items: [plugin, walk])
        XCTAssertEqual(inv.items.count, 2)
    }

    // MARK: - Dedupe

    func test_dedupe_keeps_first_occurrence() {
        let first = Item(rawID: "a", kind: .plugin, name: "First", status: .enabled)
        let dup = Item(rawID: "a", kind: .plugin, name: "Second", status: .disabled)
        let inv = ExtensionsInventory(items: [first, dup])
        XCTAssertEqual(inv.items.count, 1)
        XCTAssertEqual(inv.items.first?.name, "First",
                       "first occurrence (higher-trust source) must win")
    }

    // MARK: - Ordering

    func test_order_groups_plugins_before_walkthroughs() {
        let walk = Item(rawID: "w", kind: .walkthrough, name: "AAA", status: .available)
        let plugin = Item(rawID: "p", kind: .plugin, name: "zzz", status: .enabled)
        let inv = ExtensionsInventory(items: [walk, plugin])
        XCTAssertEqual(inv.items.map(\.kind), [.plugin, .walkthrough],
                       "plugins group sorts ahead of walkthroughs regardless of name")
    }

    func test_order_active_before_inactive_within_kind() {
        let disabled = Item(rawID: "a", kind: .plugin, name: "Alpha", status: .disabled)
        let enabled = Item(rawID: "z", kind: .plugin, name: "Zeta", status: .enabled)
        let inv = ExtensionsInventory(items: [disabled, enabled])
        XCTAssertEqual(inv.items.map(\.rawID), ["z", "a"],
                       "active (enabled) item sorts ahead of inactive even though its name is later")
    }

    func test_order_is_case_insensitive_by_name_then_stable_by_rawID() {
        let b = Item(rawID: "b", kind: .plugin, name: "beta", status: .enabled)
        let aUpper = Item(rawID: "a", kind: .plugin, name: "Alpha", status: .enabled)
        // Two items with the SAME display name — tiebreak on rawID.
        let same1 = Item(rawID: "y", kind: .plugin, name: "Same", status: .enabled)
        let same2 = Item(rawID: "x", kind: .plugin, name: "Same", status: .enabled)
        let inv = ExtensionsInventory(items: [b, aUpper, same1, same2])
        XCTAssertEqual(inv.items.map(\.rawID), ["a", "b", "x", "y"],
                       "case-insensitive name order; equal names break ties on rawID")
    }

    func test_order_is_deterministic_regardless_of_input_order() {
        let mk = { (id: String, kind: ExtensionsInventory.Kind, name: String, s: ExtensionsInventory.Status) in
            Item(rawID: id, kind: kind, name: name, status: s)
        }
        let a = mk("p1", .plugin, "Bravo", .enabled)
        let b = mk("p2", .plugin, "Alpha", .disabled)
        let c = mk("w1", .walkthrough, "Tour", .available)
        let forward = ExtensionsInventory(items: [a, b, c]).items.map(\.id)
        let reversed = ExtensionsInventory(items: [c, b, a]).items.map(\.id)
        XCTAssertEqual(forward, reversed,
                       "the merged order must not depend on the order snapshots arrived in")
    }

    // MARK: - Queries

    func test_items_of_kind_filters_and_preserves_order() {
        let p1 = Item(rawID: "p1", kind: .plugin, name: "P1", status: .enabled)
        let w1 = Item(rawID: "w1", kind: .walkthrough, name: "W1", status: .available)
        let p2 = Item(rawID: "p2", kind: .plugin, name: "P2", status: .enabled)
        let inv = ExtensionsInventory(items: [p1, w1, p2])
        XCTAssertEqual(inv.items(of: .plugin).map(\.rawID), ["p1", "p2"])
        XCTAssertEqual(inv.items(of: .walkthrough).map(\.rawID), ["w1"])
    }

    func test_counts_per_kind() {
        let inv = ExtensionsInventory(items: [
            Item(rawID: "p1", kind: .plugin, name: "P1", status: .enabled),
            Item(rawID: "p2", kind: .plugin, name: "P2", status: .disabled),
            Item(rawID: "w1", kind: .walkthrough, name: "W1", status: .available),
        ])
        XCTAssertEqual(inv.counts()[.plugin], 2)
        XCTAssertEqual(inv.counts()[.walkthrough], 1)
    }

    func test_isEmpty() {
        XCTAssertTrue(ExtensionsInventory(items: []).isEmpty)
        XCTAssertFalse(ExtensionsInventory(items: [
            Item(rawID: "p", kind: .plugin, name: "P", status: .enabled)
        ]).isEmpty)
    }

    // MARK: - Filtering

    func test_filtered_matches_name_id_and_author_case_insensitively() {
        let inv = ExtensionsInventory(items: [
            Item(rawID: "com.acme.notes", kind: .plugin, name: "Sticky Notes",
                 author: "Acme Corp", status: .enabled),
            Item(rawID: "tour.intro", kind: .walkthrough, name: "Getting Started",
                 author: "TextView", status: .available),
        ])
        XCTAssertEqual(inv.filtered("sticky").map(\.rawID), ["com.acme.notes"],
                       "matches by name, case-insensitively")
        XCTAssertEqual(inv.filtered("INTRO").map(\.rawID), ["tour.intro"],
                       "matches by rawID")
        XCTAssertEqual(inv.filtered("acme").map(\.rawID), ["com.acme.notes"],
                       "matches by author")
        XCTAssertEqual(Set(inv.filtered("e").map(\.rawID)),
                       ["com.acme.notes", "tour.intro"],
                       "a substring present in both rows matches both")
    }

    func test_filtered_empty_query_returns_full_catalog() {
        let items = [
            Item(rawID: "p", kind: .plugin, name: "P", status: .enabled),
            Item(rawID: "w", kind: .walkthrough, name: "W", status: .available),
        ]
        let inv = ExtensionsInventory(items: items)
        XCTAssertEqual(inv.filtered("").count, 2)
        XCTAssertEqual(inv.filtered("   \n  ").count, 2,
                       "whitespace-only query is treated as empty")
    }

    func test_filtered_no_match_returns_empty() {
        let inv = ExtensionsInventory(items: [
            Item(rawID: "p", kind: .plugin, name: "Notes", status: .enabled)
        ])
        XCTAssertTrue(inv.filtered("nonexistent").isEmpty)
    }

    // MARK: - Status.isActive

    func test_status_isActive_classification() {
        XCTAssertTrue(ExtensionsInventory.Status.enabled.isActive)
        XCTAssertTrue(ExtensionsInventory.Status.available.isActive)
        XCTAssertFalse(ExtensionsInventory.Status.disabled.isActive)
        XCTAssertFalse(ExtensionsInventory.Status.awaitingGrant.isActive)
        XCTAssertFalse(ExtensionsInventory.Status.denied.isActive)
        XCTAssertFalse(ExtensionsInventory.Status.failed.isActive)
    }

    // MARK: - Kind metadata

    func test_kind_displayNames() {
        XCTAssertEqual(ExtensionsInventory.Kind.plugin.displayName, "Plugins")
        XCTAssertEqual(ExtensionsInventory.Kind.walkthrough.displayName, "Walkthroughs")
    }

    func test_kind_ordering_is_total_and_stable() {
        // Comparable conformance must place plugin < walkthrough.
        XCTAssertTrue(ExtensionsInventory.Kind.plugin < .walkthrough)
        XCTAssertFalse(ExtensionsInventory.Kind.walkthrough < .plugin)
    }
}
