import XCTest
import ViewerCore

/// Textual pins for build/CI-infra invariants that have no runnable
/// surface on the host — the cheapest guard that still BITES when the
/// config regresses. Each assertion names the audited regression it
/// prevents; if one fails, read the named ticket before "fixing" the
/// test.
final class InfraInvariantTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func contents(_ rel: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(rel),
                   encoding: .utf8)
    }

    /// TSK-170 — the PR workflow must cache the SwiftPM + Rust build
    /// trees. Without these steps every PR run recompiles the entire
    /// dependency tree from scratch.
    func test_prWorkflow_cachesSwiftPMAndRustTrees() throws {
        let yml = try contents(".github/workflows/pr.yml")
        XCTAssertTrue(yml.contains("actions/cache@"),
                      "PR workflow lost its cache steps (TSK-170)")
        XCTAssertTrue(yml.contains("hashFiles('Package.resolved')"),
                      "SwiftPM cache no longer keyed on Package.resolved (TSK-170)")
        XCTAssertTrue(yml.contains("hashFiles('rust-core/Cargo.lock')"),
                      "Cargo cache no longer keyed on Cargo.lock (TSK-170)")
        // CARGO_TARGET_DIR must stay workspace-relative or actions/cache
        // can't see the Rust build dir at all (the silent variant).
        XCTAssertTrue(yml.contains("CARGO_TARGET_DIR: ${{ github.workspace }}"),
                      "CARGO_TARGET_DIR no longer pinned inside the workspace (TSK-170)")
    }

    /// TSK-171 — the VM `all` lane must not run the live-app
    /// ViewModeMatrixSmokeTests twice (build-app smoke gate + full
    /// sweep). Two independent layers: the all branch skips the gate
    /// explicitly, and build-app.sh's smoke gate is opt-IN.
    func test_vmAllLane_skipsDuplicateSmokeGate() throws {
        let vm = try contents("scripts/test-in-vm.sh")
        XCTAssertTrue(vm.contains("MDV_SKIP_SMOKE_GATE=1 build_all"),
                      "all lane no longer skips the pre-install smoke gate — "
                      + "ViewModeMatrixSmokeTests would run twice (TSK-171)")
        let build = try contents("scripts/build-app.sh")
        XCTAssertTrue(build.contains(#""${MDV_RUN_SMOKE_GATE:-0}" == "1""#),
                      "build-app.sh smoke gate is no longer opt-in — every "
                      + "build would open a window on the host (TSK-171 + "
                      + "the 2026-06-06 no-UI-on-host directive)")
    }

    /// TSK-191 — vm-smoke.sh's pre-launch reset must clear the directory
    /// SessionStore ACTUALLY writes. The audited bug reset a retired
    /// subdir name, so launches restored stale state the script believed
    /// it had wiped. PARITY pin: computes the real store directory and
    /// requires the script to reference the same path — if the store
    /// ever moves, this fails and forces the script update.
    func test_vmSmokeReset_targetsTheRealSessionsDir() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(env["MDV_SESSIONS_DIR"] != nil || env["MDV_APP_SUPPORT"] != nil,
                      "store redirected by harness env — parity unverifiable")
        let canonical = "Application Support/MarkdownViewer/Sessions"
        XCTAssertTrue(SessionStore.defaultDirectory().path.hasSuffix(canonical),
                      "SessionStore moved — update this pin AND vm-smoke.sh together")
        let smoke = try contents("scripts/vm-smoke.sh")
        XCTAssertTrue(smoke.contains(canonical),
                      "vm-smoke.sh resets a path SessionStore does not use (TSK-191)")
    }
}
