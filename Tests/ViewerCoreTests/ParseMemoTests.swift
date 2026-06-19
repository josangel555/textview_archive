import XCTest
@testable import ViewerCore

/// TSK-887 — the memoizer that stops per-keystroke re-parsing. Pure, host-safe.
final class ParseMemoTests: XCTestCase {

    func test_recomputesOnlyWhenKeyChanges() {
        var computeCount = 0
        let memo = ParseMemo<Int>(-1)

        // First resolve for a key computes.
        XCTAssertEqual(memo.resolve("a") { computeCount += 1; return $0.count }, 1)
        XCTAssertEqual(computeCount, 1)

        // Same key → cached, no recompute (the per-keystroke win).
        XCTAssertEqual(memo.resolve("a") { computeCount += 1; return $0.count }, 1)
        XCTAssertEqual(memo.resolve("a") { computeCount += 1; return $0.count }, 1)
        XCTAssertEqual(computeCount, 1, "same key must not recompute")

        // New key → recompute.
        XCTAssertEqual(memo.resolve("bbb") { computeCount += 1; return $0.count }, 3)
        XCTAssertEqual(computeCount, 2)

        // Back to the first key → recompute (single-slot, not a full cache).
        XCTAssertEqual(memo.resolve("a") { computeCount += 1; return $0.count }, 1)
        XCTAssertEqual(computeCount, 3)
    }

    func test_emptyKeyIsAValidCachedKey() {
        var computeCount = 0
        let memo = ParseMemo<[String]>([])
        _ = memo.resolve("") { _ in computeCount += 1; return ["x"] }
        let again = memo.resolve("") { _ in computeCount += 1; return ["y"] }
        XCTAssertEqual(again, ["x"], "empty string is a real key — second call is cached")
        XCTAssertEqual(computeCount, 1)
    }
}
