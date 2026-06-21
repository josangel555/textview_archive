import XCTest
@testable import ViewerCore

/// TSK-1206 — teeth for surfacing walkthroughs in the Extensions inventory:
/// the catalog-entry → snapshot → item projection, and that the inventory lists
/// walkthroughs of kind `.walkthrough`.
final class ExtensionsInventoryWalkthroughTests: XCTestCase {

    private func entry(_ id: String, _ title: String,
                       subtitle: String? = nil, author: String? = nil) -> WalkthroughCatalog.Entry {
        WalkthroughCatalog.Entry(
            url: URL(fileURLWithPath: "/lib/\(id).json"), scriptID: id, schema: .v1,
            title: title, subtitle: subtitle, author: author, stepCount: 1)
    }

    func test_snapshot_fromCatalogEntry_mapsFields() {
        let snap = ExtensionsInventory.snapshot(from:
            entry("tour1", "Getting Started", subtitle: "intro", author: "jos"))
        XCTAssertEqual(snap.id, "tour1")
        XCTAssertEqual(snap.title, "Getting Started")
        XCTAssertEqual(snap.subtitle, "intro")
        XCTAssertEqual(snap.author, "jos")
        XCTAssertFalse(snap.isBundled, "library walkthroughs are user scripts, not bundled")

        let item = ExtensionsInventory.item(from: snap)
        XCTAssertEqual(item.kind, .walkthrough)
        XCTAssertEqual(item.name, "Getting Started")
        XCTAssertEqual(item.status, .available)
    }

    func test_inventory_listsWalkthroughsAlongsidePlugins() {
        let inv = ExtensionsInventory(
            plugins: [],
            walkthroughs: [ExtensionsInventory.snapshot(from: entry("a", "A")),
                           ExtensionsInventory.snapshot(from: entry("b", "B"))])
        XCTAssertEqual(inv.items(of: .walkthrough).map(\.name), ["A", "B"])
    }
}
