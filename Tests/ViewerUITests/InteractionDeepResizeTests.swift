import XCTest
import Foundation

/// T4 residue split out of `InteractionDeepTests` by the testing-pyramid
/// migration (§3.4).
///
/// TIER-JUSTIFY: T4 — the observable is the real `NSWindow.frame` AFTER
/// `setFrame`, INCLUDING the OS's own clamping to the available screen
/// geometry. The `resize WxH` verb is window-coupled (`ScriptVerb.apply`
/// returns `false` for it — there is no window to size in-process), and the
/// assertion reads back `dump["window"]["frame"]`. A hermetic
/// `DocumentModel` has no `NSWindow`, so this CANNOT be demoted to T1m.
/// Stays in the VM lane.
final class InteractionDeepResizeTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "InteractionDeepResize" }
    override class var defaultScenarioTimeout: TimeInterval { 30 }

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
}
