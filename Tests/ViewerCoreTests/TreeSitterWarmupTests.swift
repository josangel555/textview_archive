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
}
