import XCTest
@testable import ViewerCore

/// Host tests for the LIVE bridge that snapshots the running
/// `PluginRegistry` into the unified Extensions catalog
/// (TSK-338 — Merge Plugins).
///
/// Unlike the pure-model suites, these load a real plugin into the shared
/// registry and assert the bridge reflects it — so a regression in the
/// registry-read wiring (the seam the consolidated view depends on) fails
/// the host gate, not just the model logic.
@MainActor
final class ExtensionsInventoryLiveTests: XCTestCase {

    private var grantStoreFile: URL!

    override func setUp() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDVExtGrantsTest-\(UUID().uuidString).json")
        grantStoreFile = tmp
        await MainActor.run {
            PluginRegistry.shared._resetForTests()
            PluginRegistry.shared.grantStore = PluginGrantStore(url: tmp)
        }
    }

    override func tearDown() async throws {
        await MainActor.run { PluginRegistry.shared._resetForTests() }
        if let f = grantStoreFile { try? FileManager.default.removeItem(at: f) }
    }

    private func makePluginsDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDVExtPluginsTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writePlugin(in pluginsDir: URL, id: String, manifestJSON: String) throws {
        let folder = pluginsDir.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifestJSON.data(using: .utf8)!.write(
            to: folder.appendingPathComponent("plugin.json"))
    }

    private func grant(_ id: String, _ caps: [String]) {
        PluginRegistry.shared.grantStore.record(
            pluginID: id, version: "1.0.0", capabilities: caps, decision: .granted)
    }

    func test_live_bridge_snapshots_a_granted_loaded_plugin() throws {
        let dir = try makePluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePlugin(in: dir, id: "com.test.live", manifestJSON: #"""
        {
          "id": "com.test.live", "name": "Live Notes", "version": "3.2.1",
          "author": { "name": "Bridge Co." },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["ui.sidebar"],
          "contributes": [
            { "type": "sidebar_section", "id": "s1", "title": "S1",
              "provider": { "tier": "A" } }
          ]
        }
        """#)
        grant("com.test.live", ["ui.sidebar"])
        _ = PluginRegistry.shared.loadAll(from: dir)

        let snaps = ExtensionsInventory.pluginSnapshots()
        guard let s = snaps.first(where: { $0.id == "com.test.live" }) else {
            return XCTFail("loaded plugin missing from live snapshot")
        }
        XCTAssertEqual(s.name, "Live Notes")
        XCTAssertEqual(s.version, "3.2.1")
        XCTAssertEqual(s.author, "Bridge Co.")
        XCTAssertEqual(s.capabilities, ["ui.sidebar"])
        XCTAssertFalse(s.isBundled)
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.grant, .granted)

        // And it flows through the merged catalog as an active plugin.
        let inv = ExtensionsInventory.live(walkthroughs: [
            .init(id: "tour.x", title: "Tour X", isBundled: true)
        ])
        let item = inv.items.first { $0.rawID == "com.test.live" }
        XCTAssertEqual(item?.kind, .plugin)
        XCTAssertEqual(item?.status, .enabled)
        // Plugins sort ahead of the walkthrough.
        XCTAssertEqual(inv.items.map(\.kind).first, .plugin)
        XCTAssertEqual(inv.items.map(\.kind).last, .walkthrough)
    }

    func test_live_bridge_maps_awaiting_grant() throws {
        // A plugin whose caps the user hasn't decided on loads as
        // awaiting-grant; the bridge must surface that, not "enabled".
        let dir = try makePluginsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePlugin(in: dir, id: "com.test.needsgrant", manifestJSON: #"""
        {
          "id": "com.test.needsgrant", "name": "Needs Grant", "version": "1.0.0",
          "author": { "name": "Test" },
          "hostVersion": "0", "manifestVersion": 1,
          "capabilities": ["shell.exec"],
          "contributes": [
            { "type": "sidebar_section", "id": "s", "title": "S",
              "provider": { "tier": "B", "bin": "run.sh" } }
          ]
        }
        """#)
        // Deliberately NO grant recorded.
        _ = PluginRegistry.shared.loadAll(from: dir)

        let snaps = ExtensionsInventory.pluginSnapshots()
        if let s = snaps.first(where: { $0.id == "com.test.needsgrant" }) {
            XCTAssertEqual(s.grant, .required)
            XCTAssertEqual(ExtensionsInventory.item(from: s).status, .awaitingGrant)
        }
        // (If the registry drops an awaiting-grant plugin from `loaded`
        // entirely, the snapshot is simply empty — either way the bridge
        // must never report it as enabled.)
        let inv = ExtensionsInventory.live()
        XCTAssertFalse(inv.items.contains {
            $0.rawID == "com.test.needsgrant" && $0.status == .enabled
        }, "an ungranted plugin must never surface as enabled")
    }

    func test_live_bridge_empty_when_nothing_loaded() {
        let inv = ExtensionsInventory.live()
        XCTAssertTrue(inv.items(of: .plugin).isEmpty)
    }
}
