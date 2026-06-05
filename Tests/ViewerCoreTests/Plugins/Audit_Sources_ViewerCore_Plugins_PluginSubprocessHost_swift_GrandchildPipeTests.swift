import XCTest
@testable import ViewerCore

/// Regression coverage for F-PMA-LEAK-1 (audit S2/leak):
/// `PluginSubprocessHost.call()` must not hang — and must not leak its
/// reader threads / pipe fds — when a plugin forks a GRANDCHILD that
/// inherits the stdout/stderr pipe write-ends and outlives the direct
/// child. The pre-existing `hang.sh` test only covers a single process
/// that closes its own pipes on death, so the grandchild-holds-the-pipe
/// path (the actual leak class) was untested.
///
/// These spawn real subprocesses (host-safe per CLAUDE.md — no UI), and
/// are deliberately kept in a separate file so they don't collide with
/// the shared `PluginSubprocessHostTests`.
final class Audit_Sources_ViewerCore_Plugins_PluginSubprocessHost_swift_GrandchildPipeTests: XCTestCase {

    private var pluginDir: URL!
    private var auditURL: URL!
    private var host: PluginSubprocessHost!

    override func setUp() {
        super.setUp()
        let tmp = FileManager.default.temporaryDirectory
        pluginDir = tmp.appendingPathComponent("MDVPluginGrandchildTest-\(UUID().uuidString)")
        auditURL = tmp.appendingPathComponent("MDVAuditGrandchild-\(UUID().uuidString).log")
        try? FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        host = PluginSubprocessHost(auditURLOverride: auditURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: pluginDir)
        try? FileManager.default.removeItem(at: auditURL)
        super.tearDown()
    }

    @discardableResult
    private func writeScript(_ name: String, body: String) throws -> String {
        let url = pluginDir.appendingPathComponent(name)
        try body.data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: url.path
        )
        return name
    }

    /// The direct child exits immediately, but it has backgrounded a
    /// grandchild that keeps stdout AND stderr open (`sleep`) for far
    /// longer than the host's bounded drain window. With the old code the
    /// reader threads would block on `availableData` until the grandchild
    /// died ~30s later; `call()` must instead return promptly because the
    /// timeout path kills the whole process group and/or force-closes the
    /// read handles after the 500ms join.
    ///
    /// We don't assert a specific `Outcome` (it may surface as `.timedOut`
    /// or — if the direct child's own `exit 0` wins the race — `.ok`/a
    /// decode result); the load-bearing assertion is that `call()` does
    /// NOT hang for the grandchild's full lifetime.
    func test_grandchild_holding_pipe_does_not_hang_call() throws {
        // The grandchild inherits fds 1 (stdout) and 2 (stderr) from the
        // shell. It sleeps 30s, holding both pipe write-ends open the
        // whole time, while the direct shell exits right away.
        let bin = try writeScript("grandchild.sh", body: """
        #!/bin/sh
        cat >/dev/null
        # Background a grandchild that keeps stdout+stderr open for 30s.
        sleep 30 &
        # Direct child exits immediately, leaving the grandchild holding
        # the inherited pipe write-ends.
        exit 0
        """)
        let started = Date()
        let result = host.call(
            pluginID: "test.grandchild", pluginFolder: pluginDir,
            bin: bin, args: [], timeoutMs: 500,
            request: .init(kind: "listRows")
        )
        let elapsed = Date().timeIntervalSince(started)
        // Must return well under the 30s grandchild lifetime. Budget:
        // up to 500ms timeout + 200ms SIGTERM grace + 500ms drain join +
        // 200ms post-close settle, plus slack for a loaded CI host.
        XCTAssertLessThan(elapsed, 5.0,
                          "call() hung on a grandchild holding the pipe (got \(result.outcome) after \(elapsed)s)")
    }

    /// A plugin that itself never exits AND has spawned a grandchild
    /// holding the pipes: the wall-clock timeout must fire, the group
    /// kill + force-close must unwind everything, and `call()` must
    /// return `.timedOut` promptly.
    func test_runaway_plugin_with_grandchild_times_out_promptly() throws {
        let bin = try writeScript("runaway_grandchild.sh", body: """
        #!/bin/sh
        cat >/dev/null
        # Grandchild keeps the pipes open...
        sleep 30 &
        # ...and the direct child also refuses to die on its own.
        sleep 30
        echo '{"rows":[]}'
        """)
        let started = Date()
        let result = host.call(
            pluginID: "test.runaway.grandchild", pluginFolder: pluginDir,
            bin: bin, args: [], timeoutMs: 300,
            request: .init(kind: "listRows")
        )
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 5.0,
                          "timeout path hung on a grandchild holding the pipe (after \(elapsed)s)")
        if case .timedOut = result.outcome {} else {
            XCTFail("expected .timedOut, got \(result.outcome)")
        }
    }

    /// Run the grandchild scenario several times back-to-back and assert
    /// the host process's open file-descriptor count does not climb
    /// monotonically — i.e. each timed-out call releases its pipe fds
    /// (the leak the audit finding describes compounds across the
    /// sidebar provider's repeated invocations).
    func test_repeated_grandchild_calls_do_not_leak_fds() throws {
        let bin = try writeScript("grandchild_leak.sh", body: """
        #!/bin/sh
        cat >/dev/null
        sleep 30 &
        exit 0
        """)

        func openFDCount() -> Int {
            // /dev/fd lists the calling process's open descriptors on
            // Darwin. Counting its entries is a cheap proxy for our fd
            // footprint without pulling in libproc.
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
            return entries.count
        }

        // Warm up once so any one-time allocations (audit dir, etc.)
        // don't skew the baseline.
        _ = host.call(pluginID: "warmup", pluginFolder: pluginDir,
                      bin: bin, args: [], timeoutMs: 400,
                      request: .init(kind: "listRows"))

        let baseline = openFDCount()
        for _ in 0..<5 {
            _ = host.call(pluginID: "test.fdleak", pluginFolder: pluginDir,
                          bin: bin, args: [], timeoutMs: 400,
                          request: .init(kind: "listRows"))
        }
        let after = openFDCount()

        // Each leaked call would retain up to ~3 pipe fds; 5 iterations
        // would push well past a small slack. Allow generous headroom for
        // transient fds still settling, but a true per-call leak (15+)
        // trips this.
        XCTAssertLessThan(after - baseline, 8,
                          "fd count grew \(baseline) -> \(after) across 5 grandchild calls — pipes leaking")
    }
}
