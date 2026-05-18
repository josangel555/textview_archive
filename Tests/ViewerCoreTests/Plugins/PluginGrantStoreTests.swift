import XCTest
@testable import ViewerCore

final class PluginGrantStoreTests: XCTestCase {

    private func tempFile() -> URL {
        // Per CLAUDE.md: never touch ~/Documents from automated paths.
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MDVGrants-\(UUID().uuidString).json")
    }

    func test_status_required_for_unseen_plugin() {
        let store = PluginGrantStore(url: tempFile())
        XCTAssertEqual(
            store.status(pluginID: "com.x", declaredCapabilities: ["ui.sidebar"]),
            .required
        )
    }

    func test_record_then_status_reflects_decision() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = PluginGrantStore(url: file)
        store.record(
            pluginID: "com.x", version: "1.0.0",
            capabilities: ["ui.sidebar", "shell.exec"], decision: .granted
        )
        XCTAssertEqual(
            store.status(pluginID: "com.x",
                         declaredCapabilities: ["ui.sidebar", "shell.exec"]),
            .granted
        )
        // A subset is also covered.
        XCTAssertEqual(
            store.status(pluginID: "com.x", declaredCapabilities: ["ui.sidebar"]),
            .granted
        )
    }

    func test_capability_growth_re_prompts() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = PluginGrantStore(url: file)
        store.record(
            pluginID: "com.x", version: "1.0.0",
            capabilities: ["ui.sidebar"], decision: .granted
        )
        // Plugin update declares an additional capability — must re-prompt.
        XCTAssertEqual(
            store.status(pluginID: "com.x",
                         declaredCapabilities: ["ui.sidebar", "shell.exec"]),
            .required
        )
    }

    func test_denied_decision_is_persisted_distinctly() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = PluginGrantStore(url: file)
        store.record(
            pluginID: "com.x", version: "1.0.0",
            capabilities: ["ui.sidebar"], decision: .denied
        )
        XCTAssertEqual(
            store.status(pluginID: "com.x", declaredCapabilities: ["ui.sidebar"]),
            .denied
        )
        // Verify it round-trips through disk.
        let reopen = PluginGrantStore(url: file)
        XCTAssertEqual(
            reopen.status(pluginID: "com.x", declaredCapabilities: ["ui.sidebar"]),
            .denied
        )
    }

    func test_revoke_returns_status_to_required() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = PluginGrantStore(url: file)
        store.record(
            pluginID: "com.x", version: "1.0.0",
            capabilities: ["ui.sidebar"], decision: .granted
        )
        store.revoke(pluginID: "com.x")
        XCTAssertEqual(
            store.status(pluginID: "com.x", declaredCapabilities: ["ui.sidebar"]),
            .required
        )
    }

    func test_allGrants_returns_snapshot() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = PluginGrantStore(url: file)
        store.record(pluginID: "a", version: "1", capabilities: ["ui.sidebar"], decision: .granted)
        store.record(pluginID: "b", version: "1", capabilities: ["shell.exec"], decision: .denied)
        let all = store.allGrants()
        XCTAssertEqual(Set(all.keys), ["a", "b"])
        XCTAssertEqual(all["a"]?.decision, .granted)
        XCTAssertEqual(all["b"]?.decision, .denied)
    }
}
