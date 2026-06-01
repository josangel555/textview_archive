import XCTest
import Foundation

/// Machine-checkable enforcement of the headless-first CI gate
/// (TierBaseCases.swift §"CI gating").
///
/// The merge/PR gate runs the bare `swift test` sweep on a host with **no
/// `dist/TextView.app` and no WindowServer-grade GUI session**. Under those
/// conditions the heavy tiers self-skip:
///
///   - `LiveAppTestCase` (T4) descendants skip because `LaunchHarness.isAppBuilt`
///     is false (no bundle on the CI runner).
///   - `PixelTestCase` (T5) descendants skip because the app isn't built and/or
///     Screen-Recording isn't granted.
///
/// That self-skip is *load-bearing* for "the gate is headless", yet nothing
/// asserts it: a future heavy test that forgets its `isAppBuilt` / screencapture
/// guard — or a `// TIER-JUSTIFY:` test mis-filed under the wrong base — would
/// silently start spawning the app (or needing the WindowServer) inside the
/// gate, and the gate would either hang/flake on the CI runner or, worse, pass
/// while having quietly become non-headless. This observer closes that hole.
///
/// **Mechanism (tier = the type, checked at runtime).** When the gate sets
/// `MDV_HEADLESS_GATE=1`, this observer watches every test that runs in the
/// process and, for any `LiveAppTestCase` / `PixelTestCase` subclass, asserts
/// the test **did not execute its body** — i.e. it was skipped, not run. A
/// heavy-tier test that actually runs assertions in the gate is a guard
/// regression. The observer records each such violation to a **sentinel file**
/// (`MDV_HEADLESS_GATE_SENTINEL`, default `$TMPDIR/mdv-headless-gate-violations.txt`)
/// and the gate step in CI fails the build if that file exists after the sweep.
///
/// **Why a sentinel file, not `XCTIssue`.** XCTest's `record(_:)` recording
/// path is only valid *while a test is executing*; calling it from
/// `testCaseDidFinish` (after the run has ended) trips an internal precondition
/// and `abort()`s the worker (SIGABRT/signal 6) under `swift test --parallel`.
/// And there is no "fail the whole bundle" primitive reachable from
/// `testBundleDidFinish`. A sentinel file is the robust, parallel-safe channel:
/// each worker process appends atomically, and the orchestrating script makes
/// the verdict. (`swift test` spawns one or more `xctest` workers; the sentinel
/// path is shared across them.)
///
/// This is the class-membership query the design called for: CI selects
/// "headless-safe" without a hand-maintained `--filter` list, and "headless"
/// can't silently regress because the type hierarchy is checked at runtime.
///
/// Outside the gate (`MDV_HEADLESS_GATE` unset, e.g. the VM/nightly lane where
/// the bundle *is* built) the observer is inert — heavy tiers are expected to
/// run there.
final class TierGateObserver: NSObject, XCTestObservation {

    /// Env var the gate sets to arm enforcement. Matches the `MDV_RUN_*`
    /// convention used elsewhere (`MDV_RUN_WEBVIEW_TESTS`, `MDV_RUN_LSP_SMOKE`).
    static let gateEnvVar = "MDV_HEADLESS_GATE"

    /// Env var overriding the sentinel-file path. The gate script sets this to
    /// a fresh temp file it has just removed, then checks the file's existence
    /// after `swift test` returns. Defaults under `$TMPDIR` when unset so a
    /// developer running `MDV_HEADLESS_GATE=1 swift test` locally still gets a
    /// sentinel (and a visible stderr banner).
    static let sentinelEnvVar = "MDV_HEADLESS_GATE_SENTINEL"

    /// Registered exactly once per process, regardless of how many test
    /// classes touch `register()`. `nonisolated(unsafe)` is sound: the lock
    /// guarantees a single writer and all reads happen-after.
    nonisolated(unsafe) private static var didRegister = false
    private static let registerLock = NSLock()

    /// Serialises sentinel-file appends within a worker process (multiple test
    /// classes can finish concurrently under `--parallel` *within* a worker).
    private let writeLock = NSLock()

    private var gateArmed: Bool {
        ProcessInfo.processInfo.environment[Self.gateEnvVar] == "1"
    }

    private var sentinelURL: URL {
        if let custom = ProcessInfo.processInfo.environment[Self.sentinelEnvVar],
           !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-headless-gate-violations.txt")
    }

    /// Idempotent registration. Called from the tier base classes' class-level
    /// `setUp` so the observer is live before any test method runs. Registering
    /// from `HeadlessUITestCase` (which always runs in the gate) guarantees the
    /// observer is armed even if a heavy-tier class is the very first to start.
    static func register() {
        registerLock.lock()
        defer { registerLock.unlock() }
        guard !didRegister else { return }
        didRegister = true
        XCTestObservationCenter.shared.addTestObserver(TierGateObserver())
    }

    // MARK: - XCTestObservation

    func testCaseDidFinish(_ testCase: XCTestCase) {
        guard gateArmed else { return }
        guard Self.isHeavyTier(type(of: testCase)) else { return }

        // A correctly-guarded heavy test throws `XCTSkip` before doing any
        // real work: skipCount == 1, the assertions never ran. That is the
        // expected, headless-clean outcome in the gate. Anything else — the
        // body actually executed (a pass / fail / error was recorded) — means
        // the headless guard regressed and the test ran where it shouldn't.
        let run = testCase.testRun
        let wasSkipped = (run?.skipCount ?? 0) > 0
        guard !wasSkipped else { return }

        recordViolation(testCase.name)
    }

    // MARK: - violation recording

    private func recordViolation(_ name: String) {
        let banner = """
        HEADLESS GATE VIOLATION — \(name) is a heavy-tier \
        (LiveAppTestCase/PixelTestCase) test that RAN its body inside the \
        headless merge gate (\(Self.gateEnvVar)=1) instead of skipping. Heavy \
        tiers need the app bundle / WindowServer and belong in the VM / nightly \
        lane. Either a headless guard regressed (lost its isAppBuilt / \
        screencapture skip) or the test is mis-filed under the wrong tier base.
        """
        FileHandle.standardError.write(Data(("\n" + banner + "\n").utf8))

        writeLock.lock()
        defer { writeLock.unlock() }
        let line = name + "\n"
        let url = sentinelURL
        let fm = FileManager.default
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            handle.write(Data(line.utf8))
        } else {
            // File doesn't exist yet — create it (with this first line).
            try? fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? line.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    // MARK: - tier membership

    /// True iff `cls` is `LiveAppTestCase`, `PixelTestCase`, or any subclass
    /// (e.g. `MultiScenarioTestCase`, `SourceViewVisualRegressionTests`). The
    /// `is *.Type` check walks the superclass chain, so the check is "tier is
    /// the type", not a name match — adding a new heavy subclass is
    /// automatically covered.
    static func isHeavyTier(_ cls: AnyClass) -> Bool {
        cls is LiveAppTestCase.Type || cls is PixelTestCase.Type
    }
}
