import XCTest
@testable import ViewerCore

final class PluginGrantStoreTests: XCTestCase {

    private var spawned: [URL] = []

    /// Per-test temp file. Tracks every allocation so `tearDown` can
    /// unconditionally clean up — the previous shape leaked
    /// `MDVGrants-<uuid>.json` under `/var/folders/.../T/` whenever
    /// a test crashed before its `defer` ran.
    private func tempFile() -> URL {
        // Per CLAUDE.md: never touch ~/Documents from automated paths.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDVGrants-\(UUID().uuidString).json")
        spawned.append(url)
        return url
    }

    override func tearDown() {
        for url in spawned {
            try? FileManager.default.removeItem(at: url)
        }
        spawned.removeAll()
        super.tearDown()
    }

    func test_status_required_for_unseen_plugin() {
        let store = PluginGrantStore(url: tempFile())
        XCTAssertEqual(
            store.status(pluginID: "com.x", declaredCapabilities: ["ui.sidebar"]),
            .required
        )
    }

    func test_record_then_status_reflects_decision() {
        // Cleanup handled by tearDown via `spawned`.
        let file = tempFile()
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
        // Cleanup handled by tearDown via `spawned`.
        let file = tempFile()
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
        // Cleanup handled by tearDown via `spawned`.
        let file = tempFile()
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
        // Cleanup handled by tearDown via `spawned`.
        let file = tempFile()
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
        // Cleanup handled by tearDown via `spawned`.
        let file = tempFile()
        let store = PluginGrantStore(url: file)
        store.record(pluginID: "a", version: "1", capabilities: ["ui.sidebar"], decision: .granted)
        store.record(pluginID: "b", version: "1", capabilities: ["shell.exec"], decision: .denied)
        let all = store.allGrants()
        XCTAssertEqual(Set(all.keys), ["a", "b"])
        XCTAssertEqual(all["a"]?.decision, .granted)
        XCTAssertEqual(all["b"]?.decision, .denied)
    }

    // MARK: PERSIST-06 — forward-compat + fail-safe decoding

    /// A v1 file (no `schemaVersion` key) must still load.
    func test_legacyFileWithoutSchemaVersion_stillLoads() throws {
        let file = tempFile()
        let json = """
        {
          "grants": {
            "com.x": {
              "grantedAt": "2026-05-17T12:00:00Z",
              "capabilities": ["ui.sidebar"],
              "version": "1.0.0",
              "decision": "granted"
            }
          }
        }
        """
        try json.write(to: file, atomically: true, encoding: .utf8)
        let store = PluginGrantStore(url: file)
        XCTAssertEqual(
            store.status(pluginID: "com.x", declaredCapabilities: ["ui.sidebar"]),
            .granted
        )
    }

    /// An unknown `decision` value (from a newer build) must decode to
    /// `.denied` — fail closed, never silently grant.
    func test_unknownDecision_failsClosedToDenied() throws {
        let file = tempFile()
        let json = """
        {
          "schemaVersion": 1,
          "grants": {
            "com.x": {
              "grantedAt": "2026-05-17T12:00:00Z",
              "capabilities": ["ui.sidebar"],
              "version": "1.0.0",
              "decision": "maybe-later"
            }
          }
        }
        """
        try json.write(to: file, atomically: true, encoding: .utf8)
        let store = PluginGrantStore(url: file)
        XCTAssertEqual(
            store.status(pluginID: "com.x", declaredCapabilities: ["ui.sidebar"]),
            .denied,
            "an unrecognized decision must fail closed to .denied (PERSIST-06)"
        )
    }

    /// A newer-schema file must NOT be reset-to-empty, and a subsequent
    /// record must NOT overwrite it (so the newer build's fields aren't
    /// truncated).
    func test_newerSchema_isNotResetAndWritesAreSuppressed() throws {
        let file = tempFile()
        let newer = """
        {
          "schemaVersion": 99,
          "futureField": {"some": "data"},
          "grants": {
            "com.x": {
              "grantedAt": "2026-05-17T12:00:00Z",
              "capabilities": ["ui.sidebar"],
              "version": "1.0.0",
              "decision": "granted"
            }
          }
        }
        """
        try newer.write(to: file, atomically: true, encoding: .utf8)
        let store = PluginGrantStore(url: file)
        // We still surface what we could decode (the existing grant).
        XCTAssertEqual(
            store.status(pluginID: "com.x", declaredCapabilities: ["ui.sidebar"]),
            .granted
        )
        // A record() must not clobber the newer file.
        store.record(pluginID: "com.y", version: "1", capabilities: ["shell.exec"], decision: .granted)
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("futureField"),
            "newer-schema file must be preserved verbatim, not overwritten (PERSIST-06)")
        XCTAssertFalse(onDisk.contains("com.y"),
            "writes must be suppressed while a newer schema is on disk")
    }

    /// An oversized grants file is treated as corrupt and not inflated.
    func test_oversizedFile_isIgnoredOnLoad() throws {
        let file = tempFile()
        // Build a structurally-valid but huge grants object.
        let pad = String(repeating: "x", count: 4000)
        var entries: [String] = []
        for i in 0..<200 {
            entries.append("""
            "com.\(i).\(pad)": {"grantedAt":"2026-05-17T12:00:00Z","capabilities":["ui.sidebar"],"version":"1","decision":"granted"}
            """)
        }
        let json = "{\"schemaVersion\":1,\"grants\":{" + entries.joined(separator: ",") + "}}"
        try json.write(to: file, atomically: true, encoding: .utf8)
        // File is well over 256 KiB; the maxSize guard refuses it.
        let store = PluginGrantStore(url: file)
        XCTAssertEqual(
            store.status(pluginID: "com.0.\(pad)", declaredCapabilities: ["ui.sidebar"]),
            .required,
            "oversized file should be ignored → no grants loaded"
        )
    }
}
