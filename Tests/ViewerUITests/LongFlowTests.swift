import XCTest
import Foundation

/// L5 long user-flow tests. Realistic multi-step user sessions
/// composed of 10-25 interactions. Each test asserts INVARIANTS that
/// must hold across the whole session — no crashes, content always
/// rendered when expected, state coherent.
///
/// These take 30s-90s each (each step ~300ms). They're a different
/// shape of test than the granular L4 ones: they catch interaction
/// bugs that only show after a stretch of mixed use.
///
/// Refactored onto `MultiScenarioTestCase`. The day-in-life scenario
/// stays in its own test method because its invariants span 16 steps
/// and don't share fixtures with the others.
final class LongFlowTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "LongFlow" }
    override class var defaultScenarioTimeout: TimeInterval { 90 }

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

                // Invariants across all steps:
                // 1. Every step has a non-empty window frame.
                // 2. Every step has a non-nil window title.
                // 3. model.zoom (when present) is in a sane range.
                for (i, d) in dumps.enumerated() {
                    let p = Pages(dump: d).generic
                    XCTAssertNotNil(p.windowSize,
                        "Step \(i+1): no window frame",
                        file: file, line: line)
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

    // MARK: - Scenarios: heavy tab churn + zoom persistence across launch

    func test_tabChurnAndZoomPersistence() throws {
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

        // Zoom-persistence fixtures.
        let md = try harness.writeFile("p.md", "# pers\nbody\n")

        try runScenarios([
            // 1. Heavy tab churn.
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
            },

            // 2. Persistence across launch: prime the preferences store.
            Scenario(name: "zoom-prime-preferences",
                     argFile: md,
                     script: """
                        zoom-reset
                        zoom-in
                        zoom-in
                        """) { dumps, _, _ in
                _ = dumps  // primer; assertions live in the next scenario.
            },

            // 3. Persistence across launch: read back model.zoom after a
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

            // 4. Clean up preferences so unrelated tests run from a known
            //    baseline.
            Scenario(name: "zoom-cleanup-reset",
                     argFile: md,
                     script: "zoom-reset\n") { _, _, _ in
                // intentionally no assertion — cleanup-only step.
            }
        ])
    }
}
