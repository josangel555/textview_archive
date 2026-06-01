import XCTest
import Foundation

/// The single T4 launch-smoke (§3.4): the one scenario that genuinely
/// needs a real process — the AppDelegate↔coordinator launch wiring that
/// only exists when `dist/TextView.app` actually boots.
///
/// TIER-JUSTIFY: T4 — the observable is "the real `.app` boots, mounts its
/// window, loads a file, dispatches a representative verb, and exits 0
/// WITHOUT crashing." That wiring (AppDelegate `applicationDidFinishLaunch`
/// → `main.swift` window/menu setup → `SessionsAppCoordinator.bootstrap` →
/// `--script` runner → `captureStepArtifacts`) lives only in the spawned
/// process. The in-process `HeadlessHarness` constructs the model/coordinator
/// directly, so it CANNOT exercise the launch path or catch a regression
/// that crashes it (a bad menu wiring, an AppDelegate init order bug, a
/// missing resource). T1m proves the verbs apply correctly; only this proves
/// the app survives launching and running one. VM lane.
///
/// Deliberately ONE scenario, ONE representative verb: this is a smoke
/// signal, not coverage. The behavioural coverage (what each verb does to
/// the model) is the migrated T1m suites' job.
final class LaunchSmokeTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "LaunchSmoke" }
    override class var defaultScenarioTimeout: TimeInterval { 30 }

    func test_launch_opensFile_dispatchesVerb_exitsClean() throws {
        let md = try harness.writeFile("smoke.md", "# Smoke\n\nbody\n")
        try runScenarios([
            // Boot the app on a real markdown file, dispatch one
            // representative verb (toggle-view), and confirm we got a dump
            // back (i.e. the launch → script-run → artifact-capture →
            // exit(0) chain completed without crashing). The assertion is
            // intentionally minimal: a non-empty dump with the model
            // sub-dict present is sufficient proof the wiring is intact.
            Scenario(name: "launch-open-toggle-exit",
                     argFile: md,
                     script: "toggle-view\n") { dumps, file, line in
                XCTAssertEqual(dumps.count, 1,
                    "Expected one step dump from a clean launch+verb+exit",
                    file: file, line: line)
                let pages = Pages(dump: dumps[0])
                XCTAssertFalse(pages.generic.model.isEmpty,
                    "Launch dump must carry a model sub-dictionary — proves the "
                    + "AppDelegate↔coordinator wiring booted and ScriptVerb ran",
                    file: file, line: line)
                // The verb actually took effect in the real process
                // (markdown opens rendered; toggle flips to source).
                pages.modeBar.assertMode("source", file: file, line: line)
            }
        ])
    }
}
