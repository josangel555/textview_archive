import XCTest
import Foundation

/// T1m scenario tests: longer composed flows that exercise multiple
/// components in sequence. These verify that interactions chain
/// correctly — that toggling source mode while a search is active
/// doesn't break, that opening multiple files updates the tabs AND
/// the title, etc.
///
/// Each scenario is one `--script` run with N steps. We assert on
/// invariants that span steps, not just the final state — that's what
/// a chain test is for.
///
/// (History: this spawned `dist/TextView.app` per scenario. The cross-step
/// invariants assert on `model.currentViewMode`, `model.zoom`, and the
/// window title — a pure `model.windowTitle` projection — so the migration
/// (§3.2) demoted it to in-process T1m. The "rendered mode minted a
/// WKWebView" checks moved to the T2' `ContentViewHostingTests`; here we
/// assert the model-mode transition that drives it.)
final class ScenarioTests: HeadlessMultiScenarioTestCase {

    override class var harnessLabel: String { "Scenario" }

    // MARK: - Tab + view-mode scenarios share a fixture

    func test_tabAndModeScenarios() throws {
        let a = try harness.writeFile("a.md", "# A\n")
        let b = try harness.writeFile("b.md", "# B\n")
        let c = try harness.writeFile("c.md", "# C\n")
        let rt = try harness.writeFile("rt.md", """
            # Heading

            This is a paragraph with **bold** and *italic*.

            - first
            - second
            - third
            """)

        try runScenarios([
            // Scenario 1: open multiple files via script, tabs accumulate.
            Scenario(name: "open-multiple-files-builds-tabs",
                     argFile: a,
                     script: """
                        open \(b.path)
                        open \(c.path)
                        prev-tab
                        close-tab
                        """) { dumps, file, line in
                XCTAssertEqual(dumps.count, 4, file: file, line: line)
                let titles = dumps.map { Pages(dump: $0).generic.windowTitle ?? "" }
                let uniqueTitles = Set(titles)
                XCTAssertGreaterThanOrEqual(uniqueTitles.count, 2,
                    "Window title should change as we open/close files. Titles: \(titles)",
                    file: file, line: line)
            },

            // Scenario 2: source/rendered roundtrip preserves content + mode.
            Scenario(name: "rendered-source-roundtrip-keeps-content",
                     argFile: rt,
                     script: """
                        toggle-view
                        toggle-view
                        toggle-view
                        """) { dumps, file, line in
                XCTAssertEqual(dumps.count, 3, file: file, line: line)
                let p = dumps.map { Pages(dump: $0) }
                p[0].modeBar.assertMode("source", file: file, line: line)
                p[1].modeBar.assertMode("rendered", file: file, line: line)
                p[2].modeBar.assertMode("source", file: file, line: line)
                // (Middle-step "rendered mode minted a WKWebView" check
                // moved to T2' ContentViewHostingTests; the model-mode
                // assertion above is the authoritative T1m signal.)
            }
        ])
    }

    // MARK: - Zoom scenario stays in its own method (it asserts
    //         cross-toggle invariants on a single file).

    func test_zoomPersistsAcrossViewToggle() throws {
        let md = try harness.writeFile("z.md", "# Hello\n\nsome text\n")
        try runScenarios([
            Scenario(name: "zoom-persists-across-toggle",
                     argFile: md,
                     script: """
                        toggle-view
                        zoom-in
                        zoom-in
                        toggle-view
                        toggle-view
                        """) { dumps, file, line in
                XCTAssertEqual(dumps.count, 5, file: file, line: line)
                let p = dumps.map { Pages(dump: $0) }
                guard let baseline = p[0].generic.zoom,
                      let zoomedTwoSteps = p[2].generic.zoom,
                      let returnedToSource = p[4].generic.zoom else {
                    return XCTFail("model.zoom missing from one of the dumps",
                                   file: file, line: line)
                }
                XCTAssertGreaterThan(zoomedTwoSteps, baseline,
                    "two zoom-in steps must enlarge model.zoom",
                    file: file, line: line)
                XCTAssertEqual(returnedToSource, zoomedTwoSteps, accuracy: 0.001,
                    "after rendered round-trip, model.zoom should be unchanged",
                    file: file, line: line)
            }
        ])
    }

    // MARK: - Folder open scenario

    func test_openFolder_doesNotBreakContent() throws {
        let md = try harness.writeFile("a.md", "# inline\n")
        try runScenarios([
            Scenario(name: "open-folder-keeps-content",
                     argFile: md,
                     script: """
                        open \(harness.tmpDir.path)
                        zoom-in
                        zoom-reset
                        """) { dumps, file, line in
                XCTAssertEqual(dumps.count, 3, file: file, line: line)
                // The original assertion ("WKWebView present at every step")
                // proved folder-open doesn't collapse the rendered content.
                // The authoritative model signal is that the active document
                // stays in `.rendered` mode (markdown a.md) across the
                // open-folder + zoom steps — the WKWebView follows from that,
                // and its realization is guarded at T2'
                // (ContentViewHostingTests).
                for (i, d) in dumps.enumerated() {
                    Pages(dump: d).modeBar.assertMode(
                        "rendered",
                        file: file, line: line)
                    _ = i
                }
            }
        ])
    }
}
