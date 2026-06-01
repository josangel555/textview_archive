import XCTest
import Foundation

/// T4 residue split out of `LongFlowTests` by the testing-pyramid
/// migration (§3.4).
///
/// TIER-JUSTIFY: T4 — the observable is cross-*process* `PreferencesStore`
/// persistence: zoom set in one app launch must be read back by a SEPARATE
/// later launch. `MultiScenarioTestCase` runs each scenario as its own
/// `dist/TextView.app` launch sharing the real on-disk preferences store,
/// so scenario 1 ("prime": zoom-in × 2) persists zoom that scenario 2
/// ("relaunch": fresh process) reads back. A hermetic in-process
/// `DocumentModel` gets a throwaway `UserDefaults` suite per construction —
/// it CANNOT observe state a previous process wrote — so this cannot be
/// demoted to T1m. Stays in the VM lane.
final class LongFlowRelaunchTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "LongFlowRelaunch" }
    override class var defaultScenarioTimeout: TimeInterval { 90 }

    func test_zoomPersistsAcrossRelaunch() throws {
        let md = try harness.writeFile("p.md", "# pers\nbody\n")

        try runScenarios([
            // 1. Persistence across launch: prime the preferences store.
            Scenario(name: "zoom-prime-preferences",
                     argFile: md,
                     script: """
                        zoom-reset
                        zoom-in
                        zoom-in
                        """) { dumps, _, _ in
                _ = dumps  // primer; assertions live in the next scenario.
            },

            // 2. Persistence across launch: read back model.zoom after a
            //    fresh launch (PreferencesStore persists across runs).
            Scenario(name: "zoom-persists-after-relaunch",
                     argFile: md,
                     script: "toggle-view\n") { dumps, file, line in
                XCTAssertEqual(dumps.count, 1, file: file, line: line)
                let zoom = Pages(dump: dumps[0]).generic.zoom ?? -1
                XCTAssertGreaterThan(zoom, 1.0,
                    "After zoom-in × 2 + relaunch, model.zoom should be > 1.0. Got \(zoom)",
                    file: file, line: line)
            },

            // 3. Clean up preferences so unrelated tests run from a known
            //    baseline.
            Scenario(name: "zoom-cleanup-reset",
                     argFile: md,
                     script: "zoom-reset\n") { _, _, _ in
                // intentionally no assertion — cleanup-only step.
            }
        ])
    }
}
