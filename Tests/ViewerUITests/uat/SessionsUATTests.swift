import XCTest
import Foundation

/// UAT executable companion — **group 7/12: Sessions (tabs-within-tabs /
/// nested workspaces)**.
///
/// Durable T4 live-app smoke for `docs/uat/smokes/sessions.md` (SESS-01..12).
/// Drives the assembled `dist/TextView.app` via the `--script` verb dispatcher
/// (the proven path from `ViewModeMatrixSmokeTests` / `GitPanelUATTests`),
/// captures a `DiagnosticDump` JSON per step, and asserts against the
/// authoritative `model.sessions` / `model.activeSessionID` projection plus the
/// `sidebar` / `tabCount` sub-fields.
///
/// ## Observability reality for THIS group (probed against a live dump)
///
/// The session **value layer** (list, active pointer, dedup, LRU, rename
/// guards, close pipeline) is fully observable from a scripted run and is
/// asserted hard below. The session **mount/façade layer** (per-session tab
/// capture & restore, sidebar re-root on switch, split/expansion/hidden reset,
/// panel layout, watcher pause/resume) is **NOT observable** from this harness,
/// and that is the headline finding (F-SESS-1).
///
/// **Root cause (verified, `main.swift:215`)**: the lifecycle bridge that the
/// Phase-1 façade swap rides on (`SessionsCoordinator.setLifecycle` → tab
/// reset + `hydrate` + sidebar re-root + watcher pause) is wired EXCLUSIVELY
/// inside `SessionsAppCoordinator.bootstrap()`. `bootstrap()` is gated behind
/// `MDV_SKIP_WORKSPACE_RESTORE != "1"` — and the test harness
/// (`AppLauncher.runScript`) ALWAYS sets `MDV_SKIP_WORKSPACE_RESTORE=1` so each
/// scenario starts clean. Net: in every scripted run the coordinator's
/// `lifecycle` stays `nil`, so `openFolder`/`activate`'s `lifecycle?.mount(snap)`
/// is a no-op. The session **list + activeID** update correctly (those are pure
/// value-layer), but the **model never re-hydrates** — tabs don't swap, the
/// sidebar never re-roots off the argv file's parent, nothing pauses.
///
/// Consequence: SESS-01 steps 5-6 (tab restore on switch), SESS-05 (per-session
/// split/expansion/hidden), SESS-06 (global-vs-per-session zoom across switch),
/// SESS-08 (watcher pause), SESS-09 (panel layout), and ALL relaunch-restore
/// halves (SESS-03 step 4, SESS-07, SESS-10) are un-automatable here and are
/// enumerated in the run log as manual/VM-lane gaps. They need either a
/// foreground VM session WITHOUT the skip flag, or a future test hook that
/// wires the lifecycle bridge under the clean-room flag.
///
/// TIER-JUSTIFY: T4 — the observable is the assembled bundle's real
/// cross-process AppDelegate↔SessionsAppCoordinator↔SessionsCoordinator↔
/// SessionStore wiring in a live process: the `--script` session verbs reach
/// the SAME coordinator the SwiftUI pills drive, the resolved-path dedup +
/// symlink collapse run against a real FS, the LRU close pipeline stages to a
/// real `Sessions/trash/`, and the dump round-trips the live `model.sessions`
/// projection. None of this is reachable from a bare headless `(model,
/// sessions)` pair without a process. Self-skips on the headless gate
/// (`isAppBuilt` false); runs for real on the VM/nightly lane or as a
/// host-occluded UAT run.
@MainActor
final class SessionsUATTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "SessionsUAT" }
    // Session verbs are cheap (value-layer), but we cycle several opens +
    // activates + closes per scenario with settle delays; give room.
    override class var defaultScenarioTimeout: TimeInterval { 60 }

    // MARK: - SESS-01 — Create two sessions; pills + resolved roots

    /// SESS-01 (observable half) + SESS-12 strip scaling.
    /// `session-open-folder` for two distinct folders creates two pills in
    /// creation order with the folder leaf as displayName and the RESOLVED
    /// (symlink-followed) path as `sidebarRootPath`; the second becomes active.
    ///
    /// NOTE (F-SESS-1): the SESS-01 promise that switching restores each
    /// session's tabs + re-roots the sidebar is NOT asserted here — the
    /// lifecycle bridge is nil under the harness's clean-room flag, so the
    /// façade swap never runs. See `test_SESS01_tabAndSidebar_doNotSwitch_probe`.
    func test_SESS01_twoSessions_pillsAndResolvedRoots() throws {
        let projA = try harness.makeDir("projA")
        let projB = try harness.makeDir("projB")
        let arg = try harness.writeFile("arg.txt", "scratch\n")
        let script = """
        session-open-folder \(projA.path)
        delay 0.3
        session-open-folder \(projB.path)
        delay 0.3
        """
        try runScenarios([
            Scenario(
                name: "two-sessions",
                argFile: arg,
                script: script,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    let names = sessionNames(last)
                    XCTAssertEqual(names, ["projA", "projB"],
                        "expected two pills in creation order projA,projB",
                        file: file, line: line)
                    // Resolved (realpath) roots — /var/folders is a symlink twin
                    // of /private/var/folders, so the persisted root is resolved.
                    let roots = sessionRoots(last)
                    XCTAssertEqual(roots.count, 2, file: file, line: line)
                    XCTAssertTrue(roots[0].hasSuffix("/projA"),
                        "root0 not projA: \(roots[0])", file: file, line: line)
                    XCTAssertTrue(roots[1].hasSuffix("/projB"),
                        "root1 not projB: \(roots[1])", file: file, line: line)
                    // Second session is active.
                    XCTAssertEqual(activeName(last), "projB",
                        "second-opened session should be active", file: file, line: line)
                })
        ])
    }

    /// SESS-01 variations: resolved-path DEDUP (re-open + symlink twin both
    /// collapse onto the existing pill) and FORCE-NEW (worktree twin) creates a
    /// genuine second pill over the same realpath.
    func test_SESS01_dedupAndForceNew() throws {
        let projA = try harness.makeDir("projA")
        let arg = try harness.writeFile("arg.txt", "scratch\n")
        // Symlink twin pointing at projA.
        let link = harness.tmpDir.appendingPathComponent("projA-link")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: projA)

        let script = """
        session-open-folder \(projA.path)
        delay 0.25
        session-open-folder \(projA.path)
        delay 0.25
        session-open-folder \(link.path)
        delay 0.25
        session-open-new \(projA.path)
        delay 0.25
        """
        try runScenarios([
            Scenario(
                name: "dedup-and-forcenew",
                argFile: arg,
                script: script,
                assert: { [self] dumps, file, line in
                    // Step 1: 1 pill.
                    XCTAssertEqual(sessionCount(dumps[0]), 1,
                        "first open should create exactly 1 session", file: file, line: line)
                    // Step 3 (re-open same path): still 1 (reveal, not dup).
                    XCTAssertEqual(sessionCount(dumps[2]), 1,
                        "re-open same path must NOT duplicate (reveal)", file: file, line: line)
                    // Step 5 (symlink twin): still 1 (resolved-path collapse).
                    XCTAssertEqual(sessionCount(dumps[4]), 1,
                        "symlink twin must collapse onto existing session", file: file, line: line)
                    // Step 7 (force-new): now 2 over the same realpath.
                    guard let last = dumps.last else { return }
                    XCTAssertEqual(sessionCount(last), 2,
                        "forceNew must create a second pill over same realpath", file: file, line: line)
                    let roots = sessionRoots(last)
                    XCTAssertEqual(roots.count, 2, file: file, line: line)
                    XCTAssertEqual(roots[0], roots[1],
                        "forceNew twin must share the SAME resolved root", file: file, line: line)
                })
        ])
    }

    // MARK: - SESS-04 — LRU re-activation on close (the headline guard)

    /// SESS-04 — closing the active session re-activates the MOST-RECENTLY-USED
    /// remaining session, not the list-adjacent neighbour; closing the last
    /// leaves an empty strip with `activeID` cleared.
    ///
    /// This is fully value-layer (`SessionsCoordinator.close` sorts survivors
    /// by `lastActiveAt`), so it IS observable under the nil-lifecycle harness.
    func test_SESS04_lruReactivationOnClose() throws {
        let projA = try harness.makeDir("projA")
        let projB = try harness.makeDir("projB")
        let projC = try harness.makeDir("projC")
        let arg = try harness.writeFile("arg.txt", "scratch\n")
        // Open A,B,C (C active). Activate B,C,A → LRU A,C,B. Close A → C active.
        // Close C → B active. Close B → empty.
        let script = """
        session-open-folder \(projA.path)
        delay 0.2
        session-open-folder \(projB.path)
        delay 0.2
        session-open-folder \(projC.path)
        delay 0.2
        session-activate 2
        delay 0.15
        session-activate 3
        delay 0.15
        session-activate 1
        delay 0.15
        session-close-active
        delay 0.25
        session-close-active
        delay 0.25
        session-close-active
        delay 0.25
        """
        try runScenarios([
            Scenario(
                name: "lru-close",
                argFile: arg,
                script: script,
                assert: { [self] dumps, file, line in
                    // Labels in order; find the dumps by their close labels.
                    // dumps indices: 0 openA,1 d,2 openB,3 d,4 openC,5 d,
                    // 6 act2,7 d,8 act3,9 d,10 act1,11 d,12 closeA,13 d,
                    // 14 closeC,15 d,16 closeB,17 d
                    XCTAssertGreaterThanOrEqual(dumps.count, 18,
                        "expected full close sequence dumps", file: file, line: line)
                    // After open A,B,C: 3 sessions, C active.
                    XCTAssertEqual(sessionNames(dumps[4]), ["projA", "projB", "projC"],
                        file: file, line: line)
                    XCTAssertEqual(activeName(dumps[4]), "projC", file: file, line: line)
                    // After activate 1 (projA): A active. (LRU now A,C,B.)
                    XCTAssertEqual(activeName(dumps[10]), "projA", file: file, line: line)
                    // Close A → projC re-activates (MRU), NOT projB (adjacent).
                    XCTAssertEqual(sessionCount(dumps[12]), 2, file: file, line: line)
                    XCTAssertEqual(activeName(dumps[12]), "projC",
                        "close-active must re-activate MRU (projC), not adjacent projB",
                        file: file, line: line)
                    XCTAssertFalse(sessionNames(dumps[12]).contains("projA"),
                        "projA pill must be gone after close", file: file, line: line)
                    // Close C → projB (only one left).
                    XCTAssertEqual(activeName(dumps[14]), "projB", file: file, line: line)
                    // Close B → empty strip, activeID cleared.
                    XCTAssertEqual(sessionCount(dumps[16]), 0,
                        "closing the last session leaves an empty strip", file: file, line: line)
                    XCTAssertEqual(activeID(dumps[16]), "",
                        "activeID must clear when last session closes", file: file, line: line)
                })
        ])
    }

    // MARK: - SESS-11 — next / prev wrap + ⌃-jump activation semantics

    /// SESS-11 (observable half) — `session-next` / `session-prev` cycle in
    /// list order and WRAP at the ends; `session-activate N` is 1-based and
    /// independent of the per-file `select-tab` (no ⌃/⌘ cross-fire at the
    /// model level — they call distinct coordinator vs model methods).
    func test_SESS11_nextPrevWrapAndActivate() throws {
        let projA = try harness.makeDir("projA")
        let projB = try harness.makeDir("projB")
        let projC = try harness.makeDir("projC")
        let arg = try harness.writeFile("arg.txt", "scratch\n")
        // Open A,B,C (C active). activate 2 → B. next → C. next → A (wrap).
        // prev → C (wrap back).
        let script = """
        session-open-folder \(projA.path)
        delay 0.15
        session-open-folder \(projB.path)
        delay 0.15
        session-open-folder \(projC.path)
        delay 0.15
        session-activate 2
        delay 0.15
        session-next
        delay 0.15
        session-next
        delay 0.15
        session-prev
        delay 0.15
        """
        try runScenarios([
            Scenario(
                name: "next-prev-wrap",
                argFile: arg,
                script: script,
                assert: { [self] dumps, file, line in
                    // 0 openA..4 openC(C active),6 act2(B),8 next(C),
                    // 10 next(A wrap),12 prev(C wrap)
                    XCTAssertGreaterThanOrEqual(dumps.count, 13, file: file, line: line)
                    XCTAssertEqual(activeName(dumps[6]), "projB",
                        "activate 2 → projB", file: file, line: line)
                    XCTAssertEqual(activeName(dumps[8]), "projC",
                        "next from B → projC", file: file, line: line)
                    XCTAssertEqual(activeName(dumps[10]), "projA",
                        "next from C → projA (wrap)", file: file, line: line)
                    XCTAssertEqual(activeName(dumps[12]), "projC",
                        "prev from A → projC (wrap back)", file: file, line: line)
                })
        ])
    }

    // MARK: - SESS-03 — rename guards (value-layer, no relaunch)

    /// SESS-03 (observable half) — `session-rename <name>` renames the active
    /// session; whitespace-trim + empty/whitespace-only + no-op guards reject a
    /// clobber. The relaunch-survives-restore step (SESS-03 step 4) is NOT
    /// observable here (clean-room flag + no store redirect) — see run log.
    func test_SESS03_renameGuards() throws {
        let projA = try harness.makeDir("projA")
        let arg = try harness.writeFile("arg.txt", "scratch\n")
        let script = """
        session-open-folder \(projA.path)
        delay 0.2
        session-rename Backend API
        delay 0.2
        session-rename
        delay 0.2
        session-rename Backend API
        delay 0.2
        """
        try runScenarios([
            Scenario(
                name: "rename-guards",
                argFile: arg,
                script: script,
                assert: { [self] dumps, file, line in
                    // 0 open(projA),2 rename "Backend API",4 rename "   " (whitespace),
                    // 6 rename "Backend API" again (no-op)
                    XCTAssertGreaterThanOrEqual(dumps.count, 7, file: file, line: line)
                    XCTAssertEqual(activeName(dumps[0]), "projA",
                        "fresh session label = folder leaf", file: file, line: line)
                    XCTAssertEqual(activeName(dumps[2]), "Backend API",
                        "rename should commit the trimmed name", file: file, line: line)
                    // Whitespace-only rename is rejected by the guard → name unchanged.
                    XCTAssertEqual(activeName(dumps[4]), "Backend API",
                        "whitespace-only rename must NOT clobber the name",
                        file: file, line: line)
                    // Re-applying the same name is a no-op equality guard → unchanged.
                    XCTAssertEqual(activeName(dumps[6]), "Backend API",
                        "no-op rename keeps the name", file: file, line: line)
                })
        ])
    }

    // MARK: - SESS-12 — strip presence scaling with session count

    /// SESS-12 (observable half) — the session list grows from 0 → 1 → 2 as
    /// folders are opened; the empty / single / multi states are reflected in
    /// the session-count projection (the actual strip-chrome rendering — pill
    /// styling, divider, context-menu enable rules — is not in the dump).
    func test_SESS12_stripScalesWithCount() throws {
        let projA = try harness.makeDir("projA")
        let projB = try harness.makeDir("projB")
        let arg = try harness.writeFile("arg.txt", "scratch\n")
        let script = """
        delay 0.3
        session-open-folder \(projA.path)
        delay 0.25
        session-open-folder \(projB.path)
        delay 0.25
        """
        try runScenarios([
            Scenario(
                name: "strip-scales",
                argFile: arg,
                script: script,
                assert: { [self] dumps, file, line in
                    // 0 delay (zero sessions — empty strip), 1 open A (1),
                    // 3 open B (2)
                    XCTAssertEqual(sessionCount(dumps[0]), 0,
                        "launch with clean-room flag → empty session strip",
                        file: file, line: line)
                    XCTAssertEqual(activeID(dumps[0]), "",
                        "empty strip → no active session", file: file, line: line)
                    XCTAssertEqual(sessionCount(dumps[1]), 1,
                        "one folder → one pill", file: file, line: line)
                    guard let last = dumps.last else { return }
                    XCTAssertEqual(sessionCount(last), 2,
                        "two folders → two pills", file: file, line: line)
                })
        ])
    }

    // MARK: - F-SESS-1 — façade-swap NON-observability probe (the headline)

    /// OBSERVATION PROBE (non-fatal logging via assertions that PIN the
    /// CURRENT scripted-run behaviour): demonstrates that under the harness's
    /// clean-room flag the session list/active pointer update, but the per-
    /// session FAÇADE (tabs, sidebar root) does NOT swap on session change —
    /// because the lifecycle bridge is nil (see suite doc + F-SESS-1 in the run
    /// log). This is the un-observability proof, NOT a product bug assertion:
    /// the live UI (foreground, restore enabled) DOES swap. We pin the scripted
    /// behaviour so a future change that DOES wire the bridge under the flag
    /// trips this test and prompts moving SESS-01/05/06/08/09 to hard asserts.
    func test_SESS01_tabAndSidebar_doNotSwitch_probe() throws {
        let projA = try harness.makeDir("projA")
        let projB = try harness.makeDir("projB")
        let a1 = try harness.writeFile("projA/a1.md", "# a1\n")
        let a2 = try harness.writeFile("projA/a2.txt", "a2\n")
        _ = try harness.writeFile("projB/b1.json", "{}\n")
        let arg = try harness.writeFile("arg.txt", "scratch\n")
        let script = """
        session-open-folder \(projA.path)
        delay 0.4
        open \(a1.path)
        delay 0.3
        open \(a2.path)
        delay 0.4
        session-open-folder \(projB.path)
        delay 0.5
        session-activate 1
        delay 0.5
        """
        try runScenarios([
            Scenario(
                name: "facade-noswap-probe",
                argFile: arg,
                script: script,
                assert: { [self] dumps, file, line in
                    // 0 openA,2 open a1,4 open a2,6 openB(switch),8 activate 1
                    XCTAssertGreaterThanOrEqual(dumps.count, 9, file: file, line: line)
                    let afterTwoTabs = dumps[4]
                    let afterSwitchToB = dumps[6]
                    let afterBackToA = dumps[8]
                    // Sanity: opening files appended tabs to the shared model
                    // (argv arg.txt + a1 + a2 = 3).
                    XCTAssertEqual(tabCount(afterTwoTabs), 3,
                        "opening a1+a2 (plus argv) → 3 tabs in the shared model",
                        file: file, line: line)
                    // PROBE: switching to projB does NOT empty/swap the tab list
                    // (façade nil-lifecycle). Pin the current behaviour.
                    XCTAssertEqual(tabCount(afterSwitchToB), tabCount(afterTwoTabs),
                        "F-SESS-1: scripted session switch does NOT reset tabs "
                        + "(lifecycle bridge nil under clean-room flag)",
                        file: file, line: line)
                    XCTAssertEqual(activeName(afterSwitchToB), "projB",
                        "but the active-session POINTER does flip (value layer ok)",
                        file: file, line: line)
                    // PROBE: switching back to projA does NOT restore projA's
                    // tabs either — tab list is unchanged.
                    XCTAssertEqual(tabCount(afterBackToA), tabCount(afterTwoTabs),
                        "F-SESS-1: switch back does NOT restore per-session tabs",
                        file: file, line: line)
                    XCTAssertEqual(activeName(afterBackToA), "projA",
                        "active pointer flips back to projA", file: file, line: line)
                    // PROBE: the sidebar never re-roots off the argv file's
                    // parent (the temp scratch dir) on a session change.
                    let rootB = sidebarRoot(afterSwitchToB)
                    XCTAssertFalse(rootB.hasSuffix("/projB") || rootB.hasSuffix("/projB/"),
                        "F-SESS-1: sidebar does NOT re-root to projB on switch "
                        + "(stays at argv parent: \(rootB))",
                        file: file, line: line)
                })
        ])
    }

    // MARK: - dump helpers (operate on the `model` sub-dict)

    private func model(_ dump: [String: Any]) -> [String: Any] {
        (dump["model"] as? [String: Any]) ?? [:]
    }
    private func sessionDicts(_ dump: [String: Any]) -> [[String: Any]] {
        (model(dump)["sessions"] as? [[String: Any]]) ?? []
    }
    private func sessionCount(_ dump: [String: Any]) -> Int { sessionDicts(dump).count }
    private func sessionNames(_ dump: [String: Any]) -> [String] {
        sessionDicts(dump).map { ($0["displayName"] as? String) ?? "" }
    }
    private func sessionRoots(_ dump: [String: Any]) -> [String] {
        sessionDicts(dump).map { ($0["sidebarRootPath"] as? String) ?? "" }
    }
    private func activeID(_ dump: [String: Any]) -> String {
        (model(dump)["activeSessionID"] as? String) ?? ""
    }
    private func activeName(_ dump: [String: Any]) -> String {
        let id = activeID(dump)
        guard !id.isEmpty else { return "" }
        return sessionDicts(dump)
            .first { ($0["id"] as? String) == id }?["displayName"] as? String ?? ""
    }
    private func tabCount(_ dump: [String: Any]) -> Int {
        (model(dump)["tabCount"] as? Int) ?? -1
    }
    private func sidebarRoot(_ dump: [String: Any]) -> String {
        let sb = (model(dump)["sidebar"] as? [String: Any]) ?? [:]
        return (sb["rootURL"] as? String) ?? ""
    }
}
