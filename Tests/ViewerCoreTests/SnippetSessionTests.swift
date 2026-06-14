import XCTest
@testable import ViewerCore

/// TSK-705 (slice 5) — the tab-stop navigation model. Pure: given a parsed
/// snippet + the insertion offset, it yields absolute caret targets in visit
/// order ($1→$2→…→$0) and walks forward/back. The CM6 Tab-key wiring that
/// applies the selections is the editor/VM tail.
final class SnippetSessionTests: XCTestCase {

    private func session(_ body: String, at base: Int) -> SnippetSession? {
        SnippetSession(snippet: SnippetExpansion.parse(body), insertedAt: base)
    }

    func test_noTabStops_returnsNil() {
        XCTAssertNil(session("just literal text", at: 0))
    }

    func test_absoluteOffsets_addBaseAndVisitOrder() {
        // "a${1:X}b$2c$0" → plainText "aXbc"; stops (relative): 1@1(1), 2@3(0), 0@4(0).
        var s = session("a${1:X}b$2c$0", at: 10)!
        XCTAssertEqual(s.stops.map(\.index), [1, 2, 0], "visit order, $0 last")
        XCTAssertEqual(s.current, .init(index: 1, offset: 11, length: 1))
        XCTAssertEqual(s.advance(), .init(index: 2, offset: 13, length: 0))
        XCTAssertEqual(s.advance(), .init(index: 0, offset: 14, length: 0))
        XCTAssertNil(s.advance(), "past the final stop → finished")
        XCTAssertTrue(s.isFinished)
    }

    func test_retreat_walksBack_clampedAtStart() {
        var s = session("$1$2$0", at: 0)!
        s.advance(); s.advance()                 // at $0
        XCTAssertEqual(s.retreat()?.index, 2)
        XCTAssertEqual(s.retreat()?.index, 1)
        XCTAssertEqual(s.retreat()?.index, 1, "clamped at the first stop")
    }

    func test_repeatedIndex_firstOccurrenceIsTarget() {
        // "$1 then $1 again" → one navigable stop (index 1), at the FIRST $1.
        let s = session("$1 then $1 again", at: 100)!
        XCTAssertEqual(s.stops.map(\.index), [1])
        XCTAssertEqual(s.current?.offset, 100, "first $1 is at the insertion point")
    }

    func test_finishedSession_currentIsNil() {
        var s = session("$1$0", at: 0)!
        s.advance(); s.advance()
        XCTAssertTrue(s.isFinished)
        XCTAssertNil(s.current)
    }
}
