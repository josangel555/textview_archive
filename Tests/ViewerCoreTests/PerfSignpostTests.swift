import XCTest
@testable import ViewerCore

/// `PerfSignpost` is an Instruments-facing facility; the behaviour we can
/// assert headlessly (without an attached trace) is the contract that
/// matters for correctness/cost:
///
///   1. It is OFF by default (no `MDV_SIGNPOSTS=1` in the test env), so the
///      hot path pays nothing in normal runs / the gate.
///   2. Every entry point is total + crash-free whether enabled or not —
///      a disabled `Token` round-trips through `end` as a no-op, and
///      `withInterval` returns the body's value / propagates throws.
///
/// We deliberately do NOT try to assert that signposts were *emitted* —
/// that needs a live os_signpost consumer (Instruments), which is the
/// VM/manual lane. The point of these tests is "the facility never costs
/// or crashes the hot path", which is host-checkable.
final class PerfSignpostTests: XCTestCase {

    func testDisabledByDefaultInTestEnv() {
        // The gate / bare sweep never sets MDV_SIGNPOSTS=1, so the facility
        // must report disabled. (If a developer exports it in their shell
        // this would flip — acceptable; the assertion documents the default
        // contract for CI where the env is clean.)
        if ProcessInfo.processInfo.environment["MDV_SIGNPOSTS"] == "1" {
            XCTAssertTrue(PerfSignpost.isEnabled)
        } else {
            XCTAssertFalse(PerfSignpost.isEnabled,
                           "PerfSignpost must be OFF without MDV_SIGNPOSTS=1")
        }
    }

    func testBeginEndIsTotalAndCrashFree() {
        // A begin/end pair over every stage must not crash regardless of
        // the enabled state.
        for stage in PerfSignpost.Stage.allCases {
            let token = PerfSignpost.begin(stage, "unit-test-interval")
            PerfSignpost.end(token)
            // Double-end is benign (no-op).
            PerfSignpost.end(token)
            PerfSignpost.event(stage, "unit-test-event")
        }
    }

    func testWithIntervalReturnsBodyValue() {
        let result = PerfSignpost.withInterval(.highlight, "compute") { 7 * 6 }
        XCTAssertEqual(result, 42)
    }

    func testWithIntervalPropagatesThrows() {
        struct Boom: Error {}
        XCTAssertThrowsError(
            try PerfSignpost.withInterval(.load, "throwing") { throw Boom() }
        ) { error in
            XCTAssertTrue(error is Boom)
        }
    }

    func testStageRawValuesAreStableContract() {
        // These category strings are an Instruments-facing contract
        // (docs/PERFORMANCE_PROFILING.md). Pin them so a rename can't slip
        // through silently and desync the profiling doc.
        XCTAssertEqual(PerfSignpost.Stage.open.rawValue, "open")
        XCTAssertEqual(PerfSignpost.Stage.categorize.rawValue, "categorize")
        XCTAssertEqual(PerfSignpost.Stage.load.rawValue, "load")
        XCTAssertEqual(PerfSignpost.Stage.materialize.rawValue, "materialize")
        XCTAssertEqual(PerfSignpost.Stage.highlight.rawValue, "highlight")
        XCTAssertEqual(PerfSignpost.Stage.render.rawValue, "render")
        XCTAssertEqual(PerfSignpost.subsystem, "com.markdownviewer.MarkdownViewer")
    }
}
