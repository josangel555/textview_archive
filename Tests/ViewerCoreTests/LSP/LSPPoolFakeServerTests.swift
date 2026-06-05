import XCTest
@testable import ViewerCore

/// Behavior tests for `LSPPool` driven against `MDVFakeLSPServer`.
/// Mirrors the pattern in `LSPClientFakeServerTests`: we own the
/// language-registry injection so each test wires the fake binary as
/// the server-launcher and supplies an `MDV_FAKE_LSP_*` scenario.
///
/// Scope: state-machine paths inside `LSPPool` itself —
///   * lazy spawn + reuse
///   * `closeAll()` rejects further acquires
///   * `fail_initialize` cycles through `restartBackoff` and ends in
///     `dead(until:)` after `maxRestartAttempts`
///   * `deadCooldown` expiry path (the entry is dropped + re-attempted)
///   * `recordCrash` demotes `.live` → `.cold`; next acquire respawns
///   * `crash_after_init` round-trips through the request-side catch
///     and gets demoted, then respawns on the next call
///   * `reapIdle()` shuts down stale live entries
///   * concurrent `ensureLive` races land both callers on live clients
///   * `workspaceSymbol` fans out across multiple live keys
///   * `didChange` is a no-op when the file isn't opened, otherwise OK
///
/// We deliberately *don't* exercise the reaper `Task` (the wall-clock
/// `Task.sleep(for: tick)` loop) — instead we call `reapIdle()`
/// directly. That keeps the test deterministic and avoids relying on
/// the cooperative scheduler waking up within an arbitrary tick window.
///
/// Skipped (not failed) when the fake-server binary can't be located.
final class LSPPoolFakeServerTests: XCTestCase {

    // MARK: - Test scaffolding

    /// Build a single-language registry routing the file extension to
    /// the fake server binary. `rootFinder` returns the file's parent
    /// directory so each tmpdir spawns its own pool key. The env
    /// overlay carries the requested fake-server scenario.
    private func makeRegistry(
        binary: URL,
        scenario: String? = nil,
        hoverDelayMs: Int? = nil,
        publishDiagnostics: Bool = false
    ) -> LSPLanguageRegistry {
        var mutableEnv: [String: String] = ProcessInfo.processInfo.environment
        if let s = scenario { mutableEnv["MDV_FAKE_LSP_SCENARIO"] = s }
        if let d = hoverDelayMs { mutableEnv["MDV_FAKE_LSP_HOVER_DELAY_MS"] = "\(d)" }
        if publishDiagnostics { mutableEnv["MDV_FAKE_LSP_PUBLISH_DIAGNOSTICS"] = "1" }
        // Capture as immutable so the @Sendable serverLauncher closure
        // can reference it under Swift 6 strict concurrency.
        let env = mutableEnv
        // We reuse `LSPLanguage.swift` as the registered language and
        // claim the synthetic extension `.fakelsp` so we never collide
        // with any real Swift LSP behavior in the rest of the suite.
        let entry = LSPLanguageEntry(
            language: .swift,
            fileExtensions: ["fakelsp"],
            rootFinder: { fileURL in fileURL.deletingLastPathComponent() },
            serverLauncher: { workspaceRoot in
                LSPClient.Config(
                    executable: binary,
                    arguments: [],
                    workspaceRoot: workspaceRoot,
                    environment: env)
            }
        )
        return LSPLanguageRegistry(entries: [entry])
    }

    /// Build a fresh tmpdir + a single fake file inside it. Returns the
    /// directory (workspace root) and the file URL.
    private func makeTempFile(named: String = "sample.fakelsp") throws -> (root: URL, file: URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LSPPool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent(named)
        try Data("// fake".utf8).write(to: file)
        return (tmp, file)
    }

    /// Tight `Config` for pool tests:
    ///   * Tiny `restartBackoff` (1 ms each) so failing tests don't
    ///     compound seconds of real sleep.
    ///   * Short `idleTimeout` / `deadCooldown` so timing-sensitive
    ///     tests stay deterministic in CI.
    ///   * Long `reaperTick` — the background reaper task is started
    ///     but won't fire during a test; we drive `reapIdle()` directly.
    private func tightConfig(
        idleTimeout: Duration = .milliseconds(50),
        deadCooldown: Duration = .milliseconds(50),
        maxRestartAttempts: Int = 3
    ) -> LSPPool.Config {
        return LSPPool.Config(
            idleTimeout: idleTimeout,
            restartBackoff: [.milliseconds(1), .milliseconds(1), .milliseconds(1)],
            maxRestartAttempts: maxRestartAttempts,
            deadCooldown: deadCooldown,
            reaperTick: .seconds(60)
        )
    }

    // MARK: - Lazy spawn + reuse

    func test_ensureLive_caches_clientAcrossAcquires() async throws {
        let binary = try FakeLSPServerHelper.locate()
        let (root, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: root) }

        let pool = LSPPool(
            registry: makeRegistry(binary: binary), config: tightConfig())
        self.addTeardownBlock { await pool.closeAll() }

        let canHandle = await pool.canHandle(file)
        XCTAssertTrue(canHandle,
            "canHandle should succeed for a registered extension + present binary")
        let key = await pool.key(for: file)
        XCTAssertNotNil(key)
        XCTAssertEqual(key?.workspaceRoot.standardizedFileURL, root.standardizedFileURL)

        let c1 = try await pool.client(for: file)
        let c2 = try await pool.client(for: file)
        // Actor identity preserved across acquires.
        XCTAssertTrue(c1 === c2,
            "second client(for:) must reuse the cached live client")
        let snap = await pool.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertTrue(snap.first?.isLive == true,
            "post-acquire snapshot should report the entry as live")

        await pool.closeAll()
    }

    // MARK: - closeAll() rejects further acquires

    func test_closeAll_shutsDown_andRejectsSubsequentAcquires() async throws {
        let binary = try FakeLSPServerHelper.locate()
        let (root, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: root) }

        let pool = LSPPool(
            registry: makeRegistry(binary: binary), config: tightConfig())
        _ = try await pool.client(for: file)
        await pool.closeAll()
        let postCloseSnap = await pool.snapshot()
        XCTAssertEqual(postCloseSnap.count, 0,
            "closeAll should drop all entries")

        do {
            _ = try await pool.client(for: file)
            XCTFail("client(for:) after closeAll should throw transportClosed")
        } catch LSPError.transportClosed {
            // expected
        } catch {
            XCTFail("expected LSPError.transportClosed, got \(error)")
        }
    }

    // MARK: - fail_initialize: backoff + dead cooldown

    func test_failInitialize_backsOff_thenMarksDead_thenRejectsDuringCooldown() async throws {
        let binary = try FakeLSPServerHelper.locate()
        let (root, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: root) }

        let pool = LSPPool(
            registry: makeRegistry(binary: binary, scenario: "fail_initialize"),
            config: tightConfig(deadCooldown: .seconds(60), maxRestartAttempts: 3))
        self.addTeardownBlock { await pool.closeAll() }

        // 1st & 2nd attempts: rethrow the server error after backoff;
        // 3rd attempt crosses `maxRestartAttempts` and marks the entry
        // dead. Each throws — the surface error from `LSPClient.initialize`
        // is `.serverError`.
        for i in 1...3 {
            do {
                _ = try await pool.client(for: file)
                XCTFail("attempt \(i): expected client(for:) to throw")
            } catch LSPError.serverError {
                // expected for each of the maxRestartAttempts
            } catch {
                XCTFail("attempt \(i): expected serverError, got \(error)")
            }
        }

        // After threshold the entry is in `dead(until:)`. The next call
        // must short-circuit with `serverBinaryNotFound("...cooldown...")`.
        do {
            _ = try await pool.client(for: file)
            XCTFail("post-threshold acquire should throw cooldown error")
        } catch LSPError.serverBinaryNotFound(let msg) {
            XCTAssertTrue(msg.lowercased().contains("cooldown"),
                "cooldown branch should mention cooldown, got: \(msg)")
        } catch {
            XCTFail("expected serverBinaryNotFound(cooldown), got \(error)")
        }

        let snap = await pool.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertTrue(snap.first?.isDead == true,
            "snapshot should report the entry as dead after max attempts")
        XCTAssertGreaterThanOrEqual(snap.first?.status.crashCount ?? 0, 3,
            "crashCount should reflect each failed spawn (>=3)")
        XCTAssertNotNil(snap.first?.status.lastError,
            "lastError should be populated after a failed spawn")
    }

    func test_deadCooldown_expiry_allowsRespawnAttempt() async throws {
        let binary = try FakeLSPServerHelper.locate()
        let (root, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: root) }

        // Tiny cooldown so the test doesn't block waiting for it.
        let pool = LSPPool(
            registry: makeRegistry(binary: binary, scenario: "fail_initialize"),
            config: tightConfig(deadCooldown: .milliseconds(30), maxRestartAttempts: 2))
        self.addTeardownBlock { await pool.closeAll() }

        // Exhaust attempts → entry becomes dead.
        for _ in 0..<2 {
            _ = try? await pool.client(for: file)
        }
        let preCool = await pool.snapshot()
        XCTAssertTrue(preCool.first?.isDead == true,
            "preconditon: entry should be dead after exhausting attempts")

        // During cooldown, the next acquire must short-circuit with the
        // cooldown error (no fresh spawn).
        do {
            _ = try await pool.client(for: file)
            XCTFail("during cooldown the acquire should short-circuit")
        } catch LSPError.serverBinaryNotFound(let msg) {
            XCTAssertTrue(msg.lowercased().contains("cooldown"),
                "during cooldown branch should mention cooldown, got: \(msg)")
        } catch {
            XCTFail("during cooldown expected serverBinaryNotFound, got \(error)")
        }

        // Wait past the cooldown deadline. Cooldown is 30 ms — sleep
        // 150 ms to leave plenty of slack on a busy CI host.
        try await Task.sleep(for: .milliseconds(150))

        // Next acquire must take the "cooldown elapsed → fall through"
        // branch: the existing dead entry is dropped, a fresh Entry is
        // constructed (resetting the status counter), and the spawn is
        // re-attempted. Spawn still fails since scenario=fail_initialize,
        // so restartAttempts climbs from 0 again. We detect the path by
        // confirming the entry is no longer reported as dead AND a new
        // crash has been recorded against the freshly-constructed entry.
        do {
            _ = try await pool.client(for: file)
            XCTFail("post-cooldown spawn still fails for fail_initialize scenario")
        } catch LSPError.serverError {
            // expected — the freshly-respawned client fails to initialize
        } catch LSPError.serverBinaryNotFound(let msg) where msg.lowercased().contains("cooldown") {
            XCTFail("post-cooldown acquire should NOT still be in cooldown — clock did not advance enough")
        } catch {
            XCTFail("post-cooldown expected serverError, got \(error)")
        }
        let postCool = await pool.snapshot()
        XCTAssertFalse(postCool.first?.isDead == true,
            "after cooldown expiry + fresh attempt, the dead state must be dropped")
        XCTAssertGreaterThanOrEqual(postCool.first?.status.crashCount ?? 0, 1,
            "post-cooldown spawn attempt should record at least one fresh crash")
    }

    // MARK: - recordCrash demotes + respawn

    func test_recordCrash_demotesEntry_andNextAcquireRespawns() async throws {
        let binary = try FakeLSPServerHelper.locate()
        let (root, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: root) }

        let pool = LSPPool(
            registry: makeRegistry(binary: binary),
            config: tightConfig())
        self.addTeardownBlock { await pool.closeAll() }

        let c1 = try await pool.client(for: file)
        guard let key = await pool.key(for: file) else {
            return XCTFail("expected key for opened file")
        }

        await pool.recordCrash(key: key, error: "test-induced crash")
        let mid = await pool.snapshot()
        XCTAssertFalse(mid.first?.isLive == true,
            "after recordCrash, snapshot must not report the entry as live")
        XCTAssertFalse(mid.first?.isDead == true,
            "after recordCrash, state is .cold — neither live nor dead")
        XCTAssertGreaterThanOrEqual(mid.first?.status.crashCount ?? 0, 1)
        XCTAssertEqual(mid.first?.status.lastError, "test-induced crash")

        let c2 = try await pool.client(for: file)
        XCTAssertFalse(c1 === c2,
            "after a recorded crash, ensureLive must spawn a fresh client")
        let post = await pool.snapshot()
        XCTAssertTrue(post.first?.isLive == true,
            "after respawn, snapshot should report live again")
    }

    // MARK: - crash_after_init: request-side recordCrash path

    func test_crashAfterInit_subsequentRequest_demotesAndCanRespawn() async throws {
        let binary = try FakeLSPServerHelper.locate()
        let (root, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: root) }

        // 2 attempts is enough to see "1st request after crash bounces;
        // pool demotes; 2nd ensureLive attempts a respawn (which itself
        // crashes after init)". A long cooldown so we don't accidentally
        // hit cooldown expiry inside the test.
        let pool = LSPPool(
            registry: makeRegistry(binary: binary, scenario: "crash_after_init"),
            config: tightConfig(deadCooldown: .seconds(60), maxRestartAttempts: 5))
        self.addTeardownBlock { await pool.closeAll() }

        _ = try await pool.client(for: file)

        // Poll for the request path to register a crash. We don't know
        // exactly when the stdout EOF lands on the actor, so retry the
        // routed `hover` call until a crash is recorded (or the deadline
        // expires). Each call either:
        //   * routes successfully then hover throws notInitialized → catch
        //     calls recordCrash → snapshot.crashCount climbs;
        //   * routes through `ensureLive` which respawns (which crashes
        //     again) and the catch records that crash too.
        let deadline = Date().addingTimeInterval(5.0)
        var crashCount = 0
        while Date() < deadline {
            _ = try? await pool.hover(
                fileURL: file, line: 0, character: 0)
            let snap = await pool.snapshot()
            crashCount = snap.first?.status.crashCount ?? 0
            if crashCount >= 1 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThanOrEqual(crashCount, 1,
            "request-side error path must call recordCrash at least once")
    }

    // MARK: - Idle reaper

    func test_reapIdle_shutsDown_staleLiveEntries() async throws {
        let binary = try FakeLSPServerHelper.locate()
        let (root, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: root) }

        let pool = LSPPool(
            registry: makeRegistry(binary: binary),
            // Aggressive idle timeout — the live entry becomes reapable
            // after 20 ms with no traffic.
            config: tightConfig(idleTimeout: .milliseconds(20)))
        self.addTeardownBlock { await pool.closeAll() }

        _ = try await pool.client(for: file)
        let preReapCount = await pool.snapshot().count
        XCTAssertEqual(preReapCount, 1)

        // Wait past the idle window, then drive the reaper directly so
        // we don't depend on the background ticker.
        try await Task.sleep(for: .milliseconds(100))
        await pool.reapIdle()

        let postReapCount = await pool.snapshot().count
        XCTAssertEqual(postReapCount, 0,
            "reapIdle must drop entries whose lastUsed is older than idleTimeout")
    }

    func test_reapIdle_keepsBusyEntries() async throws {
        let binary = try FakeLSPServerHelper.locate()
        let (root, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: root) }

        let pool = LSPPool(
            registry: makeRegistry(binary: binary),
            // Long enough that a single acquire stays within the window
            // even on a slow CI box.
            config: tightConfig(idleTimeout: .seconds(60)))
        self.addTeardownBlock { await pool.closeAll() }

        _ = try await pool.client(for: file)
        await pool.reapIdle()
        let count = await pool.snapshot().count
        XCTAssertEqual(count, 1,
            "reapIdle must not touch entries whose lastUsed is within idleTimeout")
    }

    // MARK: - Concurrent ensureLive races

    func test_concurrent_acquires_allReturnLiveClients() async throws {
        let binary = try FakeLSPServerHelper.locate()
        let (root, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: root) }

        let pool = LSPPool(
            registry: makeRegistry(binary: binary),
            config: tightConfig())
        self.addTeardownBlock { await pool.closeAll() }

        // N parallel acquires. The pool's state machine intentionally
        // permits two near-simultaneous spawns (the second falls
        // through `.starting`); the public contract is "every caller
        // gets a live LSPClient back". We assert that, and that the
        // pool settles on a single live entry.
        let n = 6
        try await withThrowingTaskGroup(of: ObjectIdentifier.self) { group in
            for _ in 0..<n {
                group.addTask {
                    let c = try await pool.client(for: file)
                    return ObjectIdentifier(c)
                }
            }
            var ids = Set<ObjectIdentifier>()
            for try await id in group {
                ids.insert(id)
            }
            XCTAssertFalse(ids.isEmpty,
                "every concurrent acquire must return a non-nil client")
            // Race tolerated: at most a small handful of distinct
            // client instances (we don't enforce 1 here because the
            // pool documents the fall-through behavior). What we *do*
            // enforce is none of them came back nil.
        }
        let snap = await pool.snapshot()
        XCTAssertEqual(snap.count, 1, "pool ends with exactly one entry")
        XCTAssertTrue(snap.first?.isLive == true,
            "the surviving entry must be live")
    }

    // MARK: - workspace/symbol fan-out

    func test_workspaceSymbol_fansOut_acrossLiveKeys_and_dedupes() async throws {
        let binary = try FakeLSPServerHelper.locate()
        // Two distinct roots → two pool keys → two live clients.
        let (rootA, fileA) = try makeTempFile()
        let (rootB, fileB) = try makeTempFile()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }

        let pool = LSPPool(
            registry: makeRegistry(binary: binary),
            config: tightConfig())
        self.addTeardownBlock { await pool.closeAll() }

        _ = try await pool.client(for: fileA)
        _ = try await pool.client(for: fileB)
        let twoCount = await pool.snapshot().count
        XCTAssertEqual(twoCount, 2)

        let merged = try await pool.workspaceSymbol(query: "MyQuery")
        // Fake server echoes the query as the symbol name. Both clients
        // return a Location with the SAME URI (`file:///fake/sym.swift`),
        // so the dedupe must collapse to exactly one entry.
        XCTAssertEqual(merged.count, 1,
            "fan-out merge should dedupe by (uri, range.start) — got \(merged.map(\.name))")
        XCTAssertEqual(merged.first?.name, "MyQuery")
    }

    func test_workspaceSymbol_returnsEmpty_whenNoLiveClients() async throws {
        let binary = try FakeLSPServerHelper.locate()
        let pool = LSPPool(
            registry: makeRegistry(binary: binary),
            config: tightConfig())
        self.addTeardownBlock { await pool.closeAll() }

        let result = try await pool.workspaceSymbol(query: "anything")
        XCTAssertTrue(result.isEmpty,
            "workspace/symbol must return [] with no live clients")
    }

    // MARK: - didChange / ensureOpened paths

    func test_ensureOpened_then_didChange_doesNotThrow() async throws {
        let binary = try FakeLSPServerHelper.locate()
        let (root, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: root) }

        let pool = LSPPool(
            registry: makeRegistry(binary: binary),
            config: tightConfig())
        self.addTeardownBlock { await pool.closeAll() }

        try await pool.ensureOpened(fileURL: file, text: "// v1")
        try await pool.didChange(fileURL: file, text: "// v2")
        try await pool.didChange(fileURL: file, text: "// v3")
        // Fake server silently drops both notifications — we're proving
        // the pool's per-file version counter and `live` mutation paths
        // don't trip Swift 6 isolation or state-machine invariants.
        let snap = await pool.snapshot()
        XCTAssertTrue(snap.first?.isLive == true)
    }

    func test_didChange_isNoop_whenFileNotOpened() async throws {
        let binary = try FakeLSPServerHelper.locate()
        let (root, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: root) }

        let pool = LSPPool(
            registry: makeRegistry(binary: binary),
            config: tightConfig())
        self.addTeardownBlock { await pool.closeAll() }

        // No prior `ensureOpened` — `didChange` must short-circuit
        // before ever touching the LSPClient.
        try await pool.didChange(fileURL: file, text: "ghost edit")
        let count = await pool.snapshot().count
        XCTAssertEqual(count, 0,
            "didChange without a live entry must not spawn a server")
    }

    // MARK: - PERF-01: didChange content-hash gate

    func test_didChange_skipsVersionBump_whenTextUnchanged() async throws {
        let binary = try FakeLSPServerHelper.locate()
        let (root, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: root) }

        let pool = LSPPool(
            registry: makeRegistry(binary: binary),
            config: tightConfig())
        self.addTeardownBlock { await pool.closeAll() }

        // didOpen sets version = 1, hash = H("v1").
        try await pool.ensureOpened(fileURL: file, text: "let a = 1")
        let v0 = await pool._testFileVersion(for: file)
        XCTAssertEqual(v0, 1, "ensureOpened should set the initial version to 1")

        // didChange with byte-identical text — the PERF-01 gate must
        // short-circuit: no notification, no version bump. This is the
        // tab-switch hot path (outline re-runs ensureOpened + didChange
        // on the same unchanged buffer).
        try await pool.didChange(fileURL: file, text: "let a = 1")
        let v1 = await pool._testFileVersion(for: file)
        XCTAssertEqual(v1, 1,
            "didChange with unchanged text must NOT bump the version (PERF-01 gate)")

        // Repeat — still gated.
        try await pool.didChange(fileURL: file, text: "let a = 1")
        let v2 = await pool._testFileVersion(for: file)
        XCTAssertEqual(v2, 1, "repeated unchanged didChange stays gated")

        // A real edit MUST bump the version.
        try await pool.didChange(fileURL: file, text: "let a = 2")
        let v3 = await pool._testFileVersion(for: file)
        XCTAssertEqual(v3, 2,
            "a genuine text change must bump the version past the gate")

        // Re-sending the previous text bumps again (it differs from the
        // current server-known text "let a = 2").
        try await pool.didChange(fileURL: file, text: "let a = 1")
        let v4 = await pool._testFileVersion(for: file)
        XCTAssertEqual(v4, 3, "changing back to old text is still a change")
    }

    // MARK: - CONC-002 / RC-3: idle crash callback demotes + reclaims

    func test_idleServerCrash_firesPoolCrashCallback_andDemotes() async throws {
        let binary = try FakeLSPServerHelper.locate()
        let (root, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: root) }

        // crash_after_init: the server EOFs right after `initialized`.
        // CONC-002 wires `client.setOnCrash` so the reader-thread's
        // failAllPending → onCrash demotes the entry WITHOUT any
        // in-flight request to carry the error. The entry must flip off
        // `.live` purely from the idle-crash callback.
        let pool = LSPPool(
            registry: makeRegistry(binary: binary, scenario: "crash_after_init"),
            config: tightConfig(deadCooldown: .seconds(60), maxRestartAttempts: 5))
        self.addTeardownBlock { await pool.closeAll() }

        _ = try await pool.client(for: file)

        // Do NOT issue any further request. Poll the snapshot: the idle
        // crash callback alone must demote the live entry (crashCount
        // climbs, isLive flips false). Pre-fix (dead setOnCrash) the
        // entry would stay `.live` forever absent a request.
        var demoted = false
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            let snap = await pool.snapshot()
            if let s = snap.first,
               !s.isLive, s.status.crashCount >= 1 {
                demoted = true
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(demoted,
            "idle server crash must fire the wired onCrash → recordCrash demote (CONC-002)")
    }

    func test_recordCrash_afterLive_shutsDownPriorClient_noLeak() async throws {
        let binary = try FakeLSPServerHelper.locate()
        let (root, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: root) }

        let pool = LSPPool(
            registry: makeRegistry(binary: binary),
            config: tightConfig())
        self.addTeardownBlock { await pool.closeAll() }

        let c1 = try await pool.client(for: file)
        let pid1 = await c1.debugProcessIdentifier
        guard let key = await pool.key(for: file) else {
            return XCTFail("expected key")
        }

        // recordCrash on a live entry: RC-3 captures the prior client
        // and shuts it down (terminate + reap) before demoting to cold.
        await pool.recordCrash(key: key, error: "induced")

        // The prior client's subprocess must be reaped — poll until it
        // is no longer running (shutdown happens on a detached task).
        var reaped = false
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            let running = await c1.debugIsRunning
            if !running { reaped = true; break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(reaped,
            "recordCrash on a live entry must shut down the prior client (RC-3) — pid \(pid1) still running")

        // Next acquire respawns a fresh, distinct client.
        let c2 = try await pool.client(for: file)
        XCTAssertFalse(c1 === c2, "post-crash acquire must spawn a fresh client")
    }

    // MARK: - Routed-request bookkeeping

    func test_routedRequest_recordsResponseTime_andRequestCount() async throws {
        let binary = try FakeLSPServerHelper.locate()
        let (root, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: root) }

        let pool = LSPPool(
            registry: makeRegistry(binary: binary),
            config: tightConfig())
        self.addTeardownBlock { await pool.closeAll() }

        try await pool.ensureOpened(fileURL: file, text: "// x")
        _ = try await pool.hover(fileURL: file, line: 1, character: 2)
        _ = try await pool.documentSymbol(fileURL: file)

        let snap = await pool.snapshot()
        guard let s = snap.first?.status else {
            return XCTFail("expected one snapshot entry")
        }
        XCTAssertGreaterThanOrEqual(s.requestCount, 2,
            "each routed request should bump requestCount via recordRequest")
        XCTAssertNotNil(s.lastResponseMillis,
            "lastResponseMillis should be populated after a successful routed call")
    }
}
