import XCTest
import Foundation

/// T1m long user-flow tests. Realistic multi-step user sessions
/// composed of 10-25 interactions. Each test asserts INVARIANTS that
/// must hold across the whole session — no crashes, state coherent.
///
/// They're a different shape of test than the granular ones: they catch
/// interaction bugs that only show after a stretch of mixed use.
///
/// (History: this spawned `dist/TextView.app` per scenario, ~300ms/step
/// → 30-90s each. The per-step invariants assert on `model.zoom` and the
/// window title (a pure `model.windowTitle` projection), so the migration
/// (§3.2) demoted them to in-process T1m — microseconds, no VM. The ONE
/// scenario that depended on cross-*process* `PreferencesStore`
/// persistence across a relaunch (zoom-prime → relaunch → read-back) was
/// split to `LongFlowRelaunchTests` (T4, §3.4 residue): a fresh hermetic
/// model can't observe state persisted by a *previous process*. The old
/// per-step "window has a non-nil frame" smoke check was dropped — there
/// is no window at T1m, and frame-present is not a `model.*` observable;
/// the resize/geometry observable lives in `InteractionDeepResizeTests`.)
final class LongFlowTests: HeadlessMultiScenarioTestCase {

    override class var harnessLabel: String { "LongFlow" }

    // MARK: - Scenario: day-in-the-life

    func test_dayInTheLife_15Interactions_noBrokenStates() throws {
        // Fixture: a folder with several files of different types.
        for i in 0..<5 {
            _ = try harness.writeFile(
                "doc\(i).md",
                "# Doc \(i)\nBody for document \(i).\n- item one\n- item two\n")
        }
        let xml = harness.tmpDir.appendingPathComponent("config.xml")
        try "<?xml version=\"1.0\"?>\n<root>\n  <a>1</a>\n  <b>2</b>\n</root>\n"
            .write(to: xml, atomically: true, encoding: .utf8)
        let first = harness.tmpDir.appendingPathComponent("doc0.md")

        try runScenarios([
            Scenario(name: "day-in-life-16-steps",
                     argFile: first,
                     script: """
                        # Open a folder, open a few files, swap modes, zoom, switch tabs,
                        # close some, zoom-reset.
                        sidebar-set-root \(harness.tmpDir.path)
                        toggle-sidebar
                        open \(harness.tmpDir.path)/doc1.md
                        open \(harness.tmpDir.path)/doc2.md
                        open \(xml.path)
                        toggle-view
                        select-tab 1
                        zoom-in
                        zoom-in
                        next-tab
                        next-tab
                        toggle-view
                        zoom-reset
                        prev-tab
                        close-tab
                        close-tab
                        """) { dumps, file, line in
                XCTAssertEqual(dumps.count, 16,
                    "Day-in-life flow should execute 16 distinct steps",
                    file: file, line: line)

                // Invariants across all steps (all `model.*` observables;
                // the dropped "non-nil window frame" check was a T4-only
                // geometry probe — see InteractionDeepResizeTests):
                // 1. Every step has a non-empty window title
                //    (`model.windowTitle` is never empty — defaults to
                //    "TextView" with no tab).
                // 2. model.zoom (when present) is in a sane range.
                for (i, d) in dumps.enumerated() {
                    let p = Pages(dump: d).generic
                    let title = p.windowTitle ?? ""
                    XCTAssertFalse(title.isEmpty,
                        "Step \(i+1): window title should never be empty mid-flow",
                        file: file, line: line)
                    if let zoom = p.zoom {
                        XCTAssertGreaterThan(zoom, 0,
                            "Step \(i+1): model.zoom must be positive",
                            file: file, line: line)
                        XCTAssertLessThan(zoom, 100,
                            "Step \(i+1): model.zoom looks corrupted",
                            file: file, line: line)
                    }
                }
            }
        ])
    }

    // MARK: - Scenario: heavy tab churn
    //
    // (The zoom-across-relaunch scenarios that used to live here moved to
    // `LongFlowRelaunchTests` — they assert cross-*process* PreferencesStore
    // persistence, which a per-scenario hermetic model can't observe.)

    func test_tabChurn() throws {
        // Heavy-tab-churn fixtures.
        var urls: [URL] = []
        for i in 0..<8 {
            urls.append(try harness.writeFile("h\(i).md", "# H\(i)\n"))
        }
        var lines: [String] = []
        for u in urls.dropFirst() { lines.append("open \(u.path)") }
        for _ in 0..<6 { lines.append("next-tab") }
        for _ in 0..<3 { lines.append("close-tab") }
        let churnScript = lines.joined(separator: "\n")
        let churnExpectedSteps = lines.count

        try runScenarios([
            Scenario(name: "heavy-tab-churn",
                     argFile: urls[0],
                     script: churnScript) { dumps, file, line in
                XCTAssertEqual(dumps.count, churnExpectedSteps,
                    "Each step should produce one dump",
                    file: file, line: line)
                XCTAssertNotNil(dumps.last,
                    "Last step should have produced a dump",
                    file: file, line: line)

                // Invariant: tab count should never decrease unexpectedly
                // during the open-many phase. Sample via window title
                // changes (a11y-id-based tab counting is unreliable —
                // see InteractionScriptTests for the historical context).
                let openPhaseTitles = dumps.prefix(7).map {
                    Pages(dump: $0).generic.windowTitle ?? ""
                }
                XCTAssertGreaterThanOrEqual(Set(openPhaseTitles).count, 5,
                    "Opening 7 different files should change the title ≥5 times. Titles: \(openPhaseTitles)",
                    file: file, line: line)
            }
        ])
    }
}
