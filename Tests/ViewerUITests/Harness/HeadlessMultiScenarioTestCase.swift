import XCTest
import Foundation

/// Headless (T1m) counterpart to `MultiScenarioTestCase`.
///
/// `MultiScenarioTestCase` runs each `Scenario` against a `LaunchHarness`
/// that spawns `dist/TextView.app`, drives the `--script` runner, and
/// reads per-step JSON dumps back off disk. The §3.2 migration found that
/// the suites built on it assert ONLY on `model.*` scalars (zoom, view
/// mode, tab count, session list, goto error, sidebar root, palette /
/// find-bar flags) — observables a hermetic `DocumentModel` produces
/// faithfully in-process. The spawn + disk round-trip is pure ceremony for
/// those.
///
/// This base swaps the producer: it runs the SAME `Scenario` list (same
/// `--script` body, same assert closures) against an in-process
/// `HeadlessHarness` via `ScriptVerb.apply`, then feeds the SAME
/// `Pages(dump:)` Page Objects the SAME `model` dump dict. The migrated
/// suites change only their base class + a handful of view-tree assertions
/// that needed a realized `NSView` tree (those move to a dedicated T2'
/// suite per §3.2). Everything else carries over byte-for-byte.
///
/// ## Behavioural parity notes
///
///   - **No `isAppBuilt` skip.** Headless runs need no bundle, so the
///     whole class runs on every host (and is part of the merge gate),
///     not just the VM.
///   - **`argFile` is opened before the first script line**, matching the
///     live app's "open this file on launch" argv (see
///     `HeadlessHarness.runScript(_:with:)`).
///   - **One harness per scenario, not per method.** The live harness
///     shares `PreferencesStore` state across scenarios in a method
///     (zoom/sidebar width persist via a real on-disk store). Headless
///     scenarios are independent by design — each gets a fresh hermetic
///     model so cross-scenario coupling can't leak. The migrated suites
///     that relied on cross-*process* persistence (zoom-across-relaunch)
///     stayed at T4 deliberately (§3.4); nothing here depends on the
///     carry-over.
///   - **Window-coupled verbs are no-ops.** `resize` / `find` return
///     `false` from `ScriptVerb.apply` (no window to size, no responder
///     chain) and leave the model unchanged. A suite asserting on window
///     geometry belongs at T4 — keep it there.
///
/// No `// TIER-JUSTIFY:` — this is the headless floor (`HeadlessUITestCase`).
@MainActor
class HeadlessMultiScenarioTestCase: HeadlessUITestCase {

    /// Method-level harness. Its `tmpDir` / `writeFile` / `makeDir` give
    /// migrated suites the SAME fixture-authoring surface
    /// `MultiScenarioTestCase` exposed (`harness.writeFile("a.md", ...)`),
    /// so the test bodies that pre-write fixtures and pass absolute paths
    /// into a `Scenario` script carry over unchanged. Re-created per method
    /// in `setUp`. Each scenario runs its script against its OWN fresh
    /// harness (see `runScenarios`); the absolute fixture paths resolve
    /// across harness instances.
    var harness: HeadlessHarness!

    /// Per-class label for the harness scratch directory name. Override to
    /// keep `/var/folders/...` listings human-readable when triaging.
    open class var harnessLabel: String { String(describing: self) }

    override func setUp() async throws {
        try await super.setUp()
        harness = HeadlessHarness(label: Self.harnessLabel)
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    /// Run each scenario sequentially against a FRESH `HeadlessHarness`.
    /// Failures within a scenario are attributed to its name via
    /// `runActivity`, matching the live runner's reporting.
    ///
    /// Throws nothing today (no bundle pre-flight), but keeps the `throws`
    /// signature so a suite's `try runScenarios(...)` call site doesn't
    /// have to change when it migrates off `MultiScenarioTestCase`.
    func runScenarios(
        _ scenarios: [Scenario],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for scenario in scenarios {
            XCTContext.runActivity(named: "scenario: \(scenario.name)") { _ in
                let scenarioHarness = HeadlessHarness(label: Self.harnessLabel)
                defer { scenarioHarness.cleanup() }
                let dumps = scenarioHarness.runScript(
                    scenario.script, with: scenario.argFile)
                scenario.assert(dumps, file, line)
            }
        }
    }
}
