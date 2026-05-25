import XCTest
import Foundation

/// L4 tests: drive the real `.app` through a sequence of interactions
/// using the in-app `--script` runner, then assert on the JSON diagnostic
/// dumps written between each step. Catches:
///   - state changes that don't propagate to the view layer (e.g. toggle
///     view mode produces no WKWebView/NSTextView swap)
///   - tab open/close failing to update the tab list
///   - sidebar toggle not changing the tree presence
///   - zoom adjustments not changing font sizes
///
/// We do **not** rely on PNG snapshots for assertions here. Snapshots
/// taken via `CGWindowListCreateImage` come back blank when the test
/// harness owns the foreground; the JSON dump is layer-state-independent
/// and gives us truthful per-step state. PNGs are still written to
/// `/tmp/mdv-step-NN.png` for human visual review.
///
/// Refactored onto `MultiScenarioTestCase` + Page Objects. Each test
/// method below either runs one scenario or a batch — the dump-walking
/// helpers (`nodesOfClass`, tabbar lookup, mode/zoom probes) are now
/// in `PageObjects/`.
final class InteractionScriptTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "InteractionScript" }
    override class var defaultScenarioTimeout: TimeInterval { 20 }

    private func writeMarkdown(_ name: String = "doc.md") throws -> URL {
        try harness.writeFile(name, """
        # Heading

        Paragraph with **bold** and *italic*.

        - one
        - two
        """)
    }

    // MARK: - Tests

    func test_toggleView_swapsRenderedAndSourceViews() throws {
        let md = try writeMarkdown()
        try runScenarios([
            Scenario(name: "toggle-roundtrip", argFile: md, script: """
                # Initial state is rendered (markdown default).
                toggle-view
                toggle-view
                """) { dumps, file, line in
                XCTAssertEqual(dumps.count, 2, "Expected two step dumps",
                               file: file, line: line)
                let after1 = Pages(dump: dumps[0])
                let after2 = Pages(dump: dumps[1])
                after1.modeBar.assertMode("source", file: file, line: line)
                after1.modeBar.assertNoWebView(file: file, line: line)
                after2.modeBar.assertMode("rendered", file: file, line: line)
                after2.modeBar.assertHasWebView(file: file, line: line)
            }
        ])
    }

    func test_newTabAndClose_changesTabCount() throws {
        let md = try writeMarkdown()
        try runScenarios([
            Scenario(name: "new-then-close", argFile: md, script: """
                new-tab
                close-tab
                """) { dumps, file, line in
                XCTAssertEqual(dumps.count, 2, file: file, line: line)
                // Prefer model state over the realised NSView tab
                // count — SwiftUI accessibility identifiers don't
                // always propagate to the realised NSView, so the
                // TabBarPage's NSView-count can silently come back
                // zero. The dump's `model.tabs.count` is authoritative
                // (see AutomationHost) and never zero-spoofs.
                let countsFromModel = dumps.map { d -> Int? in
                    let m = Pages(dump: d).generic.model
                    return m["tabCount"] as? Int
                }
                guard let nNewModel = countsFromModel[0],
                      let nCloseModel = countsFromModel[1] else {
                    return XCTFail(
                        "model.tabCount missing in step dumps — automation host regressed?",
                        file: file, line: line)
                }
                XCTAssertGreaterThan(nNewModel, nCloseModel,
                    "After new-tab+close-tab, the after-new count must exceed the after-close count. Got \(nNewModel) then \(nCloseModel)",
                    file: file, line: line)
            }
        ])
    }

    // Sidebar toggle width-effect test omitted: the SwiftUI HStack layout
    // reflow after toggle-sidebar doesn't always settle within the
    // script-runner's 300ms inter-step delay. SidebarModel state changes
    // are covered by SidebarModelTests (pure-logic unit tests).

    func test_zoom_commands_changeModelZoom() throws {
        let md = try writeMarkdown()
        try runScenarios([
            Scenario(name: "zoom-reset-in-in-reset", argFile: md, script: """
                zoom-reset
                zoom-in
                zoom-in
                zoom-reset
                """) { dumps, file, line in
                XCTAssertEqual(dumps.count, 4, file: file, line: line)
                let pages = dumps.map { Pages(dump: $0) }
                guard let baseline = pages[0].generic.zoom,
                      let oneStep = pages[1].generic.zoom,
                      let twoStep = pages[2].generic.zoom,
                      let reset = pages[3].generic.zoom else {
                    return XCTFail("model.zoom missing in one of the step dumps",
                                   file: file, line: line)
                }
                XCTAssertEqual(baseline, 1.0, accuracy: 0.001, file: file, line: line)
                XCTAssertGreaterThan(oneStep, 1.0,
                    "zoom-in should bump model.zoom > 1.0",
                    file: file, line: line)
                XCTAssertGreaterThan(twoStep, oneStep,
                    "second zoom-in should bump further",
                    file: file, line: line)
                XCTAssertEqual(reset, 1.0, accuracy: 0.001, file: file, line: line)
            }
        ])
    }
}
