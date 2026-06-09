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
/// Both the session **value layer** (list, active pointer, dedup, LRU, rename
/// guards, close pipeline) AND the session **mount/façade layer** (per-session
/// tab capture & restore, sidebar re-root on switch) are now fully observable
/// from a scripted run and are asserted hard below.
///
/// **History (F-SESS-1, RESOLVED 2026-06-03 by commit 5b9d82e / SFB-10):** the
/// façade layer used to be un-observable here because the lifecycle bridge
/// (`SessionsCoordinator.setLifecycle` → tab reset + `hydrate` + sidebar
/// re-root) was wired EXCLUSIVELY inside `SessionsAppCoordinator.bootstrap()`,
/// which is gated behind `MDV_SKIP_WORKSPACE_RESTORE != "1"` — and the harness
/// (`AppLauncher.runScript`) always sets `MDV_SKIP_WORKSPACE_RESTORE=1`. So the
/// coordinator's `lifecycle` stayed `nil` and `openFolder`/`activate`'s
/// `lifecycle?.mount(snap)` was a no-op (tabs didn't swap, sidebar didn't
/// re-root). SFB-10 hoisted `wireLifecycle()` OUT of `bootstrap()` and calls it
/// UNCONDITIONALLY at `main.swift:238`; only the disk-restore (`bootstrap()`)
/// stays behind the flag. Net: scripted session switches now perform the real
/// per-session façade swap, and `test_SESS01_facadeSwapsPerSession_onSwitch`
/// pins it with positive hard asserts (observed on the VM disclaim lane, TSK-518).
///
/// Still VM-lane / manual (not reachable from this model-state dump): SESS-05
/// (per-session split/expansion/hidden), SESS-06 (global-vs-per-session zoom),
/// SESS-08 (watcher pause), SESS-09 (panel layout), and the relaunch-restore
/// halves (SESS-03 step 4, SESS-07, SESS-10) — those need a foreground VM
/// session WITHOUT the skip flag (real disk restore) or surfaces this projection
/// doesn't carry (split state, zoom-per-session, watcher status).
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

    // MARK: - SESS-01 — per-session façade swap on switch (the headline)

    /// SESS-01 façade-swap HARD ASSERT. With the lifecycle bridge wired
    /// unconditionally (SFB-10, `main.swift:238` — see suite doc), a scripted
    /// session switch performs the real per-session façade swap: the tab list
    /// and sidebar root are CAPTURED for the leaving session and RESTORED for
    /// the entering one. Pinned against values observed on the VM disclaim lane
    /// (TSK-518). Supersedes the old F-SESS-1 non-observability probe, which
    /// asserted the inverse (no swap) under the now-retired nil-bridge regime.
    ///
    /// Script timeline (even indices = verbs, odd = settle delays):
    ///   0 open-folder projA → 1 tab (argv arg.txt), sidebar=projA
    ///   2 open a1           → 2 tabs
    ///   4 open a2           → 3 tabs, active file a2.txt
    ///   6 open-folder projB → SWAP: fresh projB session, 0 tabs, sidebar=projB
    ///   8 activate 1        → SWAP BACK: projA restored — 3 tabs, a2.txt, sidebar=projA
    func test_SESS01_facadeSwapsPerSession_onSwitch() throws {
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
                name: "facade-swap",
                argFile: arg,
                script: script,
                assert: { [self] dumps, file, line in
                    // 0 openA,2 open a1,4 open a2,6 openB(switch),8 activate 1
                    XCTAssertGreaterThanOrEqual(dumps.count, 9, file: file, line: line)
                    let afterThreeTabs = dumps[4]
                    let afterSwitchToB = dumps[6]
                    let afterBackToA = dumps[8]

                    // In projA: argv arg.txt + a1 + a2 accumulate to 3 tabs,
                    // a2.txt is the active file, sidebar rooted at projA.
                    XCTAssertEqual(tabCount(afterThreeTabs), 3,
                        "opening a1+a2 (plus argv) → 3 tabs in projA's façade",
                        file: file, line: line)
                    XCTAssertEqual(activeName(afterThreeTabs), "projA",
                        "active session is projA before the switch",
                        file: file, line: line)
                    XCTAssertTrue(sidebarRoot(afterThreeTabs).hasSuffix("/projA/"),
                        "sidebar rooted at projA (got \(sidebarRoot(afterThreeTabs)))",
                        file: file, line: line)

                    // SWAP to projB: a FRESH session → façade resets to 0 tabs,
                    // active pointer flips to projB, sidebar re-roots to projB.
                    XCTAssertEqual(tabCount(afterSwitchToB), 0,
                        "SESS-01: switching to fresh projB swaps the façade to 0 tabs "
                        + "(projA's 3 tabs captured, not carried over)",
                        file: file, line: line)
                    XCTAssertEqual(activeName(afterSwitchToB), "projB",
                        "active session flips to projB on switch", file: file, line: line)
                    XCTAssertTrue(sidebarRoot(afterSwitchToB).hasSuffix("/projB/"),
                        "SESS-01: sidebar re-roots to projB on switch "
                        + "(got \(sidebarRoot(afterSwitchToB)))",
                        file: file, line: line)

                    // SWAP BACK to projA (1-based activate 1): projA's façade is
                    // RESTORED — 3 tabs return, a2.txt is active again, sidebar
                    // re-roots back to projA. This is per-session persistence.
                    XCTAssertEqual(tabCount(afterBackToA), 3,
                        "SESS-01: switching back to projA RESTORES its 3 tabs "
                        + "(per-session tab persistence)",
                        file: file, line: line)
                    XCTAssertEqual(activeName(afterBackToA), "projA",
                        "active session flips back to projA", file: file, line: line)
                    XCTAssertTrue(sidebarRoot(afterBackToA).hasSuffix("/projA/"),
                        "SESS-01: sidebar re-roots back to projA "
                        + "(got \(sidebarRoot(afterBackToA)))",
                        file: file, line: line)
                    XCTAssertTrue(
                        ((model(afterBackToA)["currentURL"] as? String) ?? "")
                            .hasSuffix("a2.txt"),
                        "SESS-01: the active file (a2.txt) is restored on switch-back",
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
