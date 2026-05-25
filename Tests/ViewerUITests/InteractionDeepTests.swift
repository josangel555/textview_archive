import XCTest
import Foundation

/// L4 deep interaction tests — exercise tab cycling, sidebar nav,
/// palette show/dismiss, find invocation, window resize, zoom across
/// many small interactions. Driven by the `--script` runner so we don't
/// depend on AppleScript focus stealing.
///
/// Refactored onto `MultiScenarioTestCase`: related checks now share a
/// test method and a fixture set instead of each one rebuilding tmpdir
/// fixtures from scratch.
final class InteractionDeepTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "InteractionDeep" }
    override class var defaultScenarioTimeout: TimeInterval { 30 }

    // MARK: - Tab cycling (two scenarios share a/b/c.md)

    func test_tabCyclingAndClose() throws {
        let a = try harness.writeFile("a.md", "# A\n")
        let b = try harness.writeFile("b.md", "# B\n")
        let c = try harness.writeFile("c.md", "# C\n")
        let aa = try harness.writeFile("aa.md")
        let bb = try harness.writeFile("bb.md")
        let cc = try harness.writeFile("cc.md")

        try runScenarios([
            // Open three tabs, then cycle through them.
            Scenario(name: "tab-cycling-nextprev-and-select-by-index",
                     argFile: a,
                     script: """
                        open \(b.path)
                        open \(c.path)
                        select-tab 1
                        next-tab
                        next-tab
                        prev-tab
                        """) { dumps, file, line in
                XCTAssertEqual(dumps.count, 6, file: file, line: line)
                let titles = dumps.map { Pages(dump: $0).generic.windowTitle ?? "" }
                XCTAssertGreaterThanOrEqual(Set(titles).count, 2,
                    "Tab cycling should produce ≥2 distinct window titles. Got: \(titles)",
                    file: file, line: line)
            },

            // Close the middle tab; final title shouldn't reference bb.md.
            Scenario(name: "close-middle-tab-keeps-others",
                     argFile: aa,
                     script: """
                        open \(bb.path)
                        open \(cc.path)
                        select-tab 2
                        close-tab
                        """) { dumps, file, line in
                XCTAssertEqual(dumps.count, 4, file: file, line: line)
                guard let last = dumps.last else {
                    return XCTFail("no final dump", file: file, line: line)
                }
                TabBarPage(dump: last).assertActiveTabNotNamed(
                    "bb.md", file: file, line: line)
            }
        ])
    }

    // MARK: - Palette show / dismiss

    func test_palette_showAndDismiss_modelStateUpdates() throws {
        let md = try harness.writeFile("a.md")
        try runScenarios([
            Scenario(name: "palette-show-dismiss-show",
                     argFile: md,
                     script: """
                        show-palette
                        dismiss-palette
                        show-palette
                        """) { dumps, file, line in
                XCTAssertEqual(dumps.count, 3, file: file, line: line)
                // Read `model.isPalettePresented` directly from each
                // dump. Earlier this test compared `totalNodeCount`
                // deltas — any unrelated tree change (focus ring, stale
                // @State, tooltip) would also perturb that, so the
                // test gave false positives. The model bool is the
                // authoritative wire.
                let flags = dumps.map { d -> Bool in
                    (Pages(dump: d).generic.model["isPalettePresented"] as? Bool) ?? false
                }
                XCTAssertEqual(flags, [true, false, true],
                    "Expected isPalettePresented to toggle show→dismiss→show; got \(flags)",
                    file: file, line: line)
            }
        ])
    }

    // MARK: - Window resize

    func test_resize_changesWindowGeometry() throws {
        let md = try harness.writeFile("a.md")
        try runScenarios([
            // Resize targets sized to fit even modest displays (the
            // 1440x900 UTM VM). 1400x900 + titlebar overflowed and
            // macOS clamped — these targets are well inside any modern
            // viewport.
            Scenario(name: "resize-grows-window",
                     argFile: md,
                     script: """
                        resize 800x500
                        resize 1100x650
                        """) { dumps, file, line in
                XCTAssertEqual(dumps.count, 2, file: file, line: line)
                let p1 = Pages(dump: dumps[0]).generic
                let p2 = Pages(dump: dumps[1]).generic
                guard let (w1, h1) = p1.windowSize,
                      let (w2, h2) = p2.windowSize else {
                    return XCTFail("could not parse window size",
                                   file: file, line: line)
                }
                XCTAssertEqual(w1, 800, "First resize width should be 800",
                               file: file, line: line)
                XCTAssertGreaterThan(h1, 500 - 5, file: file, line: line)
                XCTAssertEqual(w2, 1100, "Second resize width should be 1100",
                               file: file, line: line)
                XCTAssertGreaterThan(w2, w1, "Second resize widened the window",
                                     file: file, line: line)
                XCTAssertGreaterThan(h2, h1, "Second resize heightened the window",
                                     file: file, line: line)
            }
        ])
    }

    // MARK: - Zoom persistence

    func test_zoom_persistsAcrossNewTab() throws {
        let a = try harness.writeFile("a.md", "# A\nbody\n")
        let b = try harness.writeFile("b.md", "# B\nbody\n")
        try runScenarios([
            // model.zoom is a single value applied across tabs; two
            // zoom-ins should persist when we open b.md.
            Scenario(name: "zoom-persists-across-new-tab",
                     argFile: a,
                     script: """
                        zoom-reset
                        toggle-view
                        zoom-in
                        zoom-in
                        open \(b.path)
                        """) { dumps, file, line in
                // Regression observed post mode-normalization (commit
                // 169a4de): sometimes only 1 dump comes back instead of
                // 5. Bail safely so a crash doesn't mask other results.
                guard dumps.count == 5 else {
                    return XCTFail(
                        "expected 5 step dumps, got \(dumps.count) — script-runner regression?",
                        file: file, line: line)
                }
                let p = dumps.map { Pages(dump: $0).generic }
                guard let zoomedA = p[3].zoom,
                      let zoomedB = p[4].zoom else {
                    return XCTFail("model.zoom missing", file: file, line: line)
                }
                XCTAssertEqual(zoomedA, zoomedB, accuracy: 0.001,
                    "Zoom should persist across tabs. a=\(zoomedA) b=\(zoomedB)",
                    file: file, line: line)
                XCTAssertGreaterThan(zoomedA, 1.0,
                    "After 2 zoom-ins, zoom should be >1.0",
                    file: file, line: line)
            }
        ])
    }

    // MARK: - Sidebar navigation

    func test_sidebar_setRoot_andWalkUp() throws {
        let sub = try harness.makeDir("sub")
        _ = try harness.writeFile("sub/inner.md", "# inner\n")
        let outer = try harness.writeFile("a.md")
        try runScenarios([
            // Set root to subfolder, then walk up. Walk-up only moves
            // *selection* if there's a selection inside the root — here
            // there's none, so sidebar root stays put. We assert that
            // sidebar-set-root actually flipped `model.sidebar.rootURL`
            // to the requested path (regression guard for a silent
            // no-op in the command dispatcher).
            Scenario(name: "sidebar-set-root-then-walk-up",
                     argFile: outer,
                     script: """
                        sidebar-set-root \(sub.path)
                        sidebar-walk-up
                        sidebar-select-next
                        sidebar-select-prev
                        """) { dumps, file, line in
                XCTAssertEqual(dumps.count, 4, file: file, line: line)
                // After `sidebar-set-root <sub>` the sidebar root must
                // point at the requested directory. URLs round-trip via
                // `URL.absoluteString` in the dump, so we compare the
                // trailing path component.
                let afterSetRoot = Pages(dump: dumps[0]).sidebar
                XCTAssertNotNil(afterSetRoot.rootURLString,
                    "sidebar-set-root should populate model.sidebar.rootURL",
                    file: file, line: line)
                afterSetRoot.assertRoot(endsWith: "sub/", file: file, line: line)

                // After `sidebar-walk-up` with no selection inside the
                // root, the rootURL is unchanged — same expectation.
                let afterWalkUp = Pages(dump: dumps[1]).sidebar
                afterWalkUp.assertRoot(endsWith: "sub/", file: file, line: line)
            }
        ])
    }
}
