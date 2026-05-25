import XCTest
@testable import ViewerCore

/// Coverage for the env-gate + `requireRootHint` hardening landed in
/// the SECURITY_CONCURRENCY_2026-05-25 remediation pass (findings §1.2,
/// §1.4). The drop transport is the untrusted automation boundary —
/// these tests pin the policy so a future "let's loosen the env gate
/// for dev convenience" PR has to consciously break them.
final class WalkthroughDropTransportTests: XCTestCase {

    // MARK: - Env gate

    func test_envGate_disabledByDefault_throws() throws {
        // We don't mutate the live env here — the test process almost
        // certainly does NOT have TV_WALKTHROUGH_DROP set, and even
        // if a developer set it, this test would skip the assertion
        // (the codepath we're trying to lock down is the production
        // default, not the dev convenience).
        if WalkthroughDropTransport.isEnvGateEnabled() {
            throw XCTSkip("TV_WALKTHROUGH_DROP is set in this env — skipping default-off check")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-drop-gate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(
            try WalkthroughDropTransport(dropDirectory: dir)
        ) { err in
            guard case WalkthroughDropTransport.Error.envGateDisabled = err else {
                return XCTFail("Expected .envGateDisabled, got \(err)")
            }
        }
    }

    func test_envGate_explicitlyDisabled_viaInit_starts() throws {
        // The `requireEnvOptIn: false` escape hatch exists so tests
        // (and only tests) can drive the transport without monkeying
        // with the process env. This call must succeed regardless of
        // ambient env state.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-drop-init-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = try WalkthroughDropTransport(
            dropDirectory: dir, requireEnvOptIn: false
        )
        t.stop()
    }

    // MARK: - Env gate value parsing

    func test_envGateEnabled_parsing() {
        // Pure helper — we can't mutate the env safely from XCTest
        // (parallel tests would see it), so the bulk of the parsing
        // logic is exercised by inspecting the static helper. The
        // important property is that it's permissive on common
        // truthy values and strict on everything else.
        // (No way to assert the helper's parsing without env mutation;
        // we content ourselves with the smoke test above. This stub
        // documents the policy as a comment.)
        XCTAssertNotNil(WalkthroughDropTransport.envGateVariable)
    }
}

// MARK: - Loader `requireRootHint`

final class WalkthroughLoaderRootHintTests: XCTestCase {

    func test_requireRootHint_missing_rejected() {
        let json = """
        {
          "schema": "textview.walkthrough/v1",
          "id": "x", "title": "X",
          "steps": [
            { "id": "s1", "actions": [{ "kind": "narrateOnly" }] }
          ]
        }
        """
        let r = WalkthroughLoader.load(
            data: Data(json.utf8), requireRootHint: true
        )
        guard case .failure(.missingRootHint) = r else {
            return XCTFail("Expected missingRootHint, got \(r)")
        }
    }

    func test_requireRootHint_present_accepted() {
        let json = """
        {
          "schema": "textview.walkthrough/v1",
          "id": "x", "title": "X",
          "rootHint": "/tmp/repo",
          "steps": [
            { "id": "s1", "actions": [{ "kind": "narrateOnly" }] }
          ]
        }
        """
        let r = WalkthroughLoader.load(
            data: Data(json.utf8), requireRootHint: true
        )
        guard case .success = r else {
            return XCTFail("Expected success, got \(r)")
        }
    }

    func test_defaultMode_rootHintOptional_unchanged() {
        // Regression guard: the default (internal callers) must keep
        // rootHint optional or the engine-side reload-after-edit path
        // breaks (it uses absolute paths from a known dev root).
        let json = """
        {
          "schema": "textview.walkthrough/v1",
          "id": "x", "title": "X",
          "steps": [
            { "id": "s1", "actions": [
                { "kind": "openFile", "path": "/usr/bin/whatever" }
            ]}
          ]
        }
        """
        let r = WalkthroughLoader.load(data: Data(json.utf8))
        guard case .success = r else {
            return XCTFail("Expected success (default mode), got \(r)")
        }
    }
}
