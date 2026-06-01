import XCTest
import Foundation

/// `XCTestCase` subclass that runs a list of `Scenario`s against a
/// shared `LaunchHarness`.
///
/// Each scenario is wrapped in an `XCTContext.runActivity` so Xcode
/// (and `xcodebuild`) attaches failures to the scenario name. The
/// harness skips the whole method when the `.app` bundle isn't built,
/// matching the original per-method `XCTSkip` guard.
///
/// Subclasses typically expose one method per "shape" of test (e.g.
/// `test_tabFlows`, `test_zoomFlows`) and call `runScenarios([...])`
/// from inside, listing N scenarios that share fixture files written
/// in `setUp`.
///
/// TIER-JUSTIFY: T4 — spawns `dist/TextView.app` via `--script`, so the
/// observable is the real cross-process AppDelegate↔coordinator launch
/// wiring + on-disk dump round-trip that only exists in a real process.
/// Subclasses whose assertions read ONLY `model.*` scalars should move to
/// `HeadlessHarness` + `HeadlessUITestCase` instead (that's the §3.2
/// move-down list).
@MainActor
class MultiScenarioTestCase: LiveAppTestCase {

    /// Shared harness for the current test method. Re-created in
    /// `setUp` so each method gets a clean tmpdir.
    var harness: LaunchHarness!

    /// Per-class label used when constructing the harness's scratch
    /// directory name. Override to keep `/var/folders/...` listings
    /// human-readable when triaging stale fixtures.
    open class var harnessLabel: String { String(describing: self) }

    /// Default per-scenario timeout when the scenario itself doesn't
    /// override. Override per-class for long flows.
    open class var defaultScenarioTimeout: TimeInterval { 30 }

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            harness = LaunchHarness(label: Self.harnessLabel)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            harness?.cleanup()
            harness = nil
        }
        try await super.tearDown()
    }

    /// Execute each scenario sequentially. Failures within a scenario
    /// are attributed to that scenario's name via `runActivity`.
    ///
    /// Skips the whole method (`XCTSkip`) when `dist/TextView.app`
    /// isn't built — matches the historical guard in every L4/L5
    /// test method.
    func runScenarios(
        _ scenarios: [Scenario],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard harness.isAppBuilt else {
            throw XCTSkip("Build .app first (e.g. bash scripts/build-app.sh debug)")
        }
        for scenario in scenarios {
            XCTContext.runActivity(named: "scenario: \(scenario.name)") { _ in
                do {
                    let dumps = try harness.runScript(
                        scenario.script,
                        with: scenario.argFile,
                        timeout: scenario.timeout ?? Self.defaultScenarioTimeout,
                        scriptFileName: "script-\(safeFilename(scenario.name)).txt"
                    )
                    scenario.assert(dumps, file, line)
                } catch {
                    XCTFail(
                        "[scenario: \(scenario.name)] launcher threw: \(error)",
                        file: file, line: line)
                }
            }
        }
    }

    // MARK: - private

    private func safeFilename(_ s: String) -> String {
        s.unicodeScalars.map { sc -> Character in
            (CharacterSet.alphanumerics.contains(sc) || sc == "-" || sc == "_")
                ? Character(sc) : "_"
        }.reduce(into: "") { $0.append($1) }
    }
}
