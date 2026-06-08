import XCTest
@testable import ViewerCore

/// Teeth for `CSVFind` (TSK-303) — the pure find-in-table matcher behind the
/// CSV grid's Cmd-F. Distinct from `CSVFilterTests` (row removal): these pin
/// the CELL-coordinate matching, reading order, scope, header inclusion, and
/// the next/prev navigation cursor. Pure value logic — no UI.
final class CSVFindTests: XCTestCase {

    private func table(header: [String], rows: [[String]]) -> CSVParser.Result {
        CSVParser.Result(delimiter: ",", header: header, rows: rows)
    }

    private let sample = CSVParser.Result(
        delimiter: ",",
        header: ["Name", "City"],
        rows: [
            ["Alice", "NYC"],
            ["Bob", "LA"],
            ["Carol", "Austin"],
        ]
    )

    // MARK: - Matching

    func test_emptyQuery_returnsNoMatches() {
        let f = CSVFind(query: "")
        XCTAssertTrue(f.isEmpty)
        XCTAssertEqual(f.matches(in: sample), [])
        XCTAssertEqual(f.count(in: sample), 0)
    }

    func test_caseInsensitiveSubstring_acrossAllCells_inReadingOrder() {
        // "a" (case-insensitive) hits: header "Name"(0); rows: Alice(0,0),
        // LA(1,1), Carol(2,0), Austin(2,1). Header "City" has no 'a'.
        let f = CSVFind(query: "a")
        let m = f.matches(in: sample)
        XCTAssertEqual(m, [
            CSVFind.Match(row: CSVFind.headerRow, column: 0), // "Name"
            CSVFind.Match(row: 0, column: 0),                 // "Alice"
            CSVFind.Match(row: 1, column: 1),                 // "LA"
            CSVFind.Match(row: 2, column: 0),                 // "Carol"
            CSVFind.Match(row: 2, column: 1),                 // "Austin"
        ], "header first, then rows top-to-bottom, each left-to-right")
    }

    func test_isHeaderFlag_distinguishesHeaderMatch() {
        let m = CSVFind(query: "Name").matches(in: sample)
        XCTAssertEqual(m.count, 1)
        XCTAssertTrue(m.first?.isHeader == true)
        XCTAssertFalse(CSVFind.Match(row: 0, column: 0).isHeader)
    }

    func test_includeHeaderFalse_skipsHeaderCells() {
        let f = CSVFind(query: "Name", includeHeader: false)
        XCTAssertEqual(f.matches(in: sample), [], "header excluded → no 'Name' hit")
        // A data-cell hit still works with header excluded.
        let g = CSVFind(query: "alice", includeHeader: false)
        XCTAssertEqual(g.matches(in: sample), [CSVFind.Match(row: 0, column: 0)])
    }

    func test_columnScope_restrictsToThatColumn() {
        // "a" restricted to column 1 (City): only LA(1,1), Austin(2,1).
        let f = CSVFind(query: "a", scope: .column(1))
        XCTAssertEqual(f.matches(in: sample), [
            CSVFind.Match(row: 1, column: 1),
            CSVFind.Match(row: 2, column: 1),
        ])
    }

    func test_outOfRangeColumnScope_yieldsNoMatches() {
        let f = CSVFind(query: "a", scope: .column(99))
        XCTAssertEqual(f.matches(in: sample), [])
        let neg = CSVFind(query: "a", scope: .column(-1))
        XCTAssertEqual(neg.matches(in: sample), [])
    }

    func test_noMatch_returnsEmpty() {
        XCTAssertEqual(CSVFind(query: "zzz").matches(in: sample), [])
    }

    func test_multipleMatchesInSameRow_areLeftToRight() {
        let t = table(header: ["x", "y"], rows: [["foo", "food"]])
        // "o" hits header? "x"/"y" no. row0: "foo"(0,0), "food"(0,1).
        let m = CSVFind(query: "o").matches(in: t)
        XCTAssertEqual(m, [CSVFind.Match(row: 0, column: 0),
                           CSVFind.Match(row: 0, column: 1)])
    }

    func test_whitespaceQuery_isLiteralNotTreatedAsEmpty() {
        let t = table(header: ["a b", "c"], rows: [["d", "e f"]])
        let f = CSVFind(query: " ")
        XCTAssertFalse(f.isEmpty, "a space is a real literal search, unlike CSVFilter")
        XCTAssertEqual(f.matches(in: t), [
            CSVFind.Match(row: CSVFind.headerRow, column: 0), // "a b"
            CSVFind.Match(row: 0, column: 1),                 // "e f"
        ])
    }

    func test_emptyTable_isNoMatchNoCrash() {
        let empty = table(header: [], rows: [])
        XCTAssertEqual(CSVFind(query: "x").matches(in: empty), [])
    }

    // MARK: - Navigation cursor (step)

    func test_step_emptyMatches_isNil() {
        XCTAssertNil(CSVFind.step(count: 0, from: nil, forward: true))
        XCTAssertNil(CSVFind.step(count: 0, from: 3, forward: false))
    }

    func test_step_fromNil_forwardStartsFirst_backwardStartsLast() {
        XCTAssertEqual(CSVFind.step(count: 5, from: nil, forward: true), 0)
        XCTAssertEqual(CSVFind.step(count: 5, from: nil, forward: false), 4)
    }

    func test_step_forwardWrapsAround() {
        XCTAssertEqual(CSVFind.step(count: 3, from: 0, forward: true), 1)
        XCTAssertEqual(CSVFind.step(count: 3, from: 1, forward: true), 2)
        XCTAssertEqual(CSVFind.step(count: 3, from: 2, forward: true), 0, "wraps to first")
    }

    func test_step_backwardWrapsAround() {
        XCTAssertEqual(CSVFind.step(count: 3, from: 2, forward: false), 1)
        XCTAssertEqual(CSVFind.step(count: 3, from: 0, forward: false), 2, "wraps to last")
    }

    func test_step_clampsOutOfRangeCurrent() {
        // A stale cursor (e.g. matches shrank) is clamped into range first.
        XCTAssertEqual(CSVFind.step(count: 3, from: 99, forward: true), 0)
        XCTAssertEqual(CSVFind.step(count: 3, from: 99, forward: false), 1)
        XCTAssertEqual(CSVFind.step(count: 3, from: -5, forward: false), 2)
    }
}
