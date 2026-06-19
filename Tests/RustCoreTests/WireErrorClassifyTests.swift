import XCTest
@testable import RustCore

/// TSK-995: an error-path out-buffer that isn't a decodable WireError must be
/// CLASSIFIED as `.undecodable` so `logWireErrorIfPresent` surfaces it, rather
/// than the old bare `guard let … else { return }` silently dropping it.
final class WireErrorClassifyTests: XCTestCase {

    func test_emptyBuffer_isEmpty() {
        XCTAssertEqual(CsvSession.classifyErrorBuffer([]), .empty)
    }

    func test_nonEmptyUndecodable_isSurfaced() {
        // Non-empty bytes that aren't a valid framed WireError map.
        let cls = CsvSession.classifyErrorBuffer([1, 2, 3, 4, 5])
        XCTAssertEqual(cls, .undecodable(bytes: 5),
                       "a non-empty undecodable error buffer must be surfaced, not dropped")
    }
}
