import XCTest
@testable import ViewerCore

/// Wires the example Tier B plugin fixture at
/// `Tests/Fixtures/plugins/com.example.tv.hello/` end-to-end through
/// the registry. This is the "would a third-party Tier B plugin
/// ship?" smoke test.
@MainActor
final class ExamplePluginBTests: XCTestCase {

    private var grantsFile: URL!

    override func setUp() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDVGrantsExample-\(UUID().uuidString).json")
        grantsFile = tmp
        await MainActor.run {
            PluginRegistry.shared._resetForTests()
            PluginRegistry.shared.grantStore = PluginGrantStore(url: tmp)
        }
    }

    override func tearDown() async throws {
        if let f = grantsFile { try? FileManager.default.removeItem(at: f) }
    }

    /// Locate the bundled fixture. The package fixture lives at the
    /// repo's `Tests/Fixtures/plugins/com.example.tv.hello/`; we
    /// resolve it via the source path of this test file rather than
    /// `Bundle.module` because the fixture isn't a declared SwiftPM
    /// resource (it'd confuse the build).
    private func fixturePluginsDir() -> URL {
        // `#filePath` is the absolute .swift path of this test source.
        // From there, walk up to Tests/, then into Fixtures/plugins/.
        // (Don't use `#file` — Swift 6 collapses that to a "short"
        // form that breaks path math.)
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent()   // Plugins/
            .deletingLastPathComponent()   // ViewerCoreTests/
            .deletingLastPathComponent()   // Tests/  (start point)
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("plugins")
    }

    func test_example_plugin_loads_and_returns_three_rows() throws {
        let pluginsDir = fixturePluginsDir()
        XCTAssertTrue(FileManager.default.fileExists(atPath: pluginsDir.path),
                      "fixture dir missing: \(pluginsDir.path)")
        // Grant the example's capabilities so it loads.
        PluginRegistry.shared.grantStore.record(
            pluginID: "com.example.tv.hello", version: "0.1.0",
            capabilities: ["shell.exec", "ui.sidebar"], decision: .granted
        )
        let results = PluginRegistry.shared.loadAll(from: pluginsDir)
        XCTAssertEqual(results.count, 1)
        guard let r = results.first else { return }
        if case .loaded = r.status {} else {
            XCTFail("expected .loaded, got \(r.status)")
        }
        let entries = PluginRegistry.shared.sidebarSections.all
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "HELLO")
        let rows = entries[0].provider(.init(openFileContents: [:]))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].label, "Hello, plugin")
        XCTAssertEqual(rows[0].detail, "v1")
        XCTAssertEqual(rows[2].detail, nil)
    }
}
