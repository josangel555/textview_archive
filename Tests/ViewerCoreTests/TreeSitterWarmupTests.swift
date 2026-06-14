import XCTest
@testable import ViewerCore
import ViewerKit

/// TSK-619 — the launch-time grammar warm-up contract. The first
/// `Query(language:data:)` compile for a grammar costs hundreds of ms and
/// the HTMLRenderer fence path tokenizes synchronously on the main actor,
/// so `warm(_:)` exists to move that compile off the user's first open.
/// These pin the warm/isWarm semantics on a FRESH engine (not .shared,
/// which other suites may have already warmed in-process).
final class TreeSitterWarmupTests: XCTestCase {

    func test_warm_compilesBundles_andIsWarmFlips() {
        let engine = TreeSitterEngine()
        XCTAssertFalse(engine.isWarm(.json), "fresh engine must start cold")
        XCTAssertFalse(engine.isWarm(.swift))

        engine.warm([.json, .swift])

        XCTAssertTrue(engine.isWarm(.json), "warm() must compile the bundle")
        XCTAssertTrue(engine.isWarm(.swift))
        // The warm cache must serve real tokenization (not a sentinel).
        let runs = engine.tokenize(#"{"key": 1}"#, language: .json)
        XCTAssertFalse(runs.isEmpty, "warm bundle must tokenize normally")
    }

    func test_warm_skipsPlainText() {
        let engine = TreeSitterEngine()
        engine.warm([.plainText])
        XCTAssertFalse(engine.isWarm(.plainText),
            "plainText has no grammar — warm must skip it, not cache a failure")
    }

    func test_warm_fromBackgroundThread_isSafe_andVisibleToCaller() {
        let engine = TreeSitterEngine()
        let done = expectation(description: "warm finished off-main")
        DispatchQueue.global(qos: .utility).async {
            engine.warm([.markdown])
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        XCTAssertTrue(engine.isWarm(.markdown),
            "a background warm must be visible to subsequent callers")
        XCTAssertFalse(engine.tokenize("# h\n`x`", language: .markdown).isEmpty)
    }

    // TSK-840 — the launch warm became two-phase + concurrent. These pin the
    // contract (the wall-clock win itself is machine-load-flaky, so unasserted).

    /// The concurrent phase-2 sweep (the default `prioritizing: []` path over
    /// many languages) must leave EXACTLY the cache a serial warm would: every
    /// statically-linked keeplist grammar warm and serving real tokenization,
    /// with no dropped/duplicated bundle from the parallel `bundle(for:)` race.
    /// (Lazy grammars may be unavailable in the host test env — isWarm stays
    /// false for those by design, which is not a failure; we assert on the
    /// always-present keeplist: swift/json/markdown.)
    func test_warm_concurrentPhase_warmsAllKeeplist_noRace() {
        let engine = TreeSitterEngine()
        engine.warm(HighlightLanguage.allCases)   // phase-2 concurrent over all
        XCTAssertTrue(engine.isWarm(.json), "concurrent warm must compile json")
        XCTAssertTrue(engine.isWarm(.swift), "concurrent warm must compile swift")
        XCTAssertTrue(engine.isWarm(.markdown), "concurrent warm must compile markdown")
        // Each warmed bundle must serve real tokenization, not a sentinel.
        XCTAssertFalse(engine.tokenize(#"{"k":1}"#, language: .json).isEmpty)
        XCTAssertFalse(engine.tokenize("let x = 1", language: .swift).isEmpty)
    }

    /// `prioritizing:` languages compile in phase 1 (serial, before the
    /// concurrent phase 2) and must be warm when the call returns — alongside
    /// the phase-2 remainder. A first open racing the warm thus blocks on at
    /// most the priority compiles.
    func test_warm_prioritizing_warmsPriorityAndRemainder() {
        let engine = TreeSitterEngine()
        engine.warm(HighlightLanguage.allCases, prioritizing: [.markdown, .json])
        XCTAssertTrue(engine.isWarm(.markdown), "priority language must be warm")
        XCTAssertTrue(engine.isWarm(.json), "priority language must be warm")
        XCTAssertTrue(engine.isWarm(.swift), "phase-2 remainder must also be warm")
    }

    /// A priority language NOT in the `languages` list is still warmed (phase 1
    /// is additive), and plainText is skipped in both phases.
    func test_warm_prioritizing_isAdditive_andSkipsPlainText() {
        let engine = TreeSitterEngine()
        engine.warm([.json], prioritizing: [.markdown, .plainText])
        XCTAssertTrue(engine.isWarm(.markdown),
            "a priority language outside `languages` must still warm")
        XCTAssertTrue(engine.isWarm(.json))
        XCTAssertFalse(engine.isWarm(.plainText),
            "plainText has no grammar — skipped in the priority phase too")
    }
}
