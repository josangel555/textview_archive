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

    /// TSK-625 — automated scripts must never `killall` by the shared exec
    /// name: the owner's installed /Applications app and every test bundle
    /// are both named `MarkdownViewer`, so a bare killall SIGTERMs the
    /// owner's running app. Test spawns are tagged `MDV_TEST_INSTANCE=1`
    /// and reaped by tag. reset-and-launch.sh / reset-tcc.sh are exempt:
    /// they are owner-invoked utilities whose PURPOSE is restarting the
    /// owner's own app.
    func test_automatedScripts_neverBareKillallByExecName() throws {
        let exempt: Set<String> = ["reset-and-launch.sh", "reset-tcc.sh"]
        let scriptsDir = Self.repoRoot.appendingPathComponent("scripts")
        let scripts = try FileManager.default
            .contentsOfDirectory(at: scriptsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sh" && !exempt.contains($0.lastPathComponent) }
        XCTAssertFalse(scripts.isEmpty, "scripts/ enumeration must not be vacuous")
        for url in scripts {
            let body = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in body.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("#") else { continue }
                XCTAssertFalse(
                    t.contains("killall MarkdownViewer"),
                    "\(url.lastPathComponent):\(n + 1) bare killall by shared exec "
                    + "name — kills the owner's running app; reap by "
                    + "MDV_TEST_INSTANCE tag instead (TSK-625)")
            }
        }
    }

    /// TSK-139 — LSP test cleanup must reap spawned child processes with an
    /// AWAITED `addTeardownBlock`, never a detached `defer { Task { … } }`:
    /// the detached Task is never awaited, so the test (or the whole process)
    /// exits with sourcekit-lsp/fake-server children still alive. The fix
    /// swapped every site (commit 6703798); this pin fails if any test file
    /// reverts a process-reaping call to the fire-and-forget shape.
    func test_lspTestCleanup_neverFireAndForgetProcessReap() throws {
        let testsDir = Self.repoRoot.appendingPathComponent("Tests")
        let files = FileManager.default
            .enumerator(at: testsDir, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "Tests/ enumeration must not be vacuous")
        for url in files {
            let body = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in body.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("//") else { continue }
                let detached = t.contains("defer { Task")
                let reapsProcess = t.contains("closeAll(") || t.contains("shutdown(")
                XCTAssertFalse(
                    detached && reapsProcess,
                    "\(url.lastPathComponent):\(n + 1) fire-and-forget process reap "
                    + "in a detached Task — use an awaited addTeardownBlock (TSK-139)")
            }
        }
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
