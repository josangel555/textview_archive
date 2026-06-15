import XCTest
@testable import ViewerCore

/// TSK-925 — type-aware CSV column sort + the header-click toggle transition.
final class CsvSortTests: XCTestCase {

    func test_numericColumn_sortsNumerically_notLexically() {
        let rows = [["9"], ["10"], ["2"]]
        XCTAssertEqual(
            CsvSort.sorted(rows: rows, column: 0, ascending: true),
            [["2"], ["9"], ["10"]],
            "numeric column must sort 2<9<10, not the lexical 10<2<9")
    }

    func test_numericDescending() {
        let rows = [["9"], ["10"], ["2"]]
        XCTAssertEqual(
            CsvSort.sorted(rows: rows, column: 0, ascending: false),
            [["10"], ["9"], ["2"]])
    }

    func test_stringColumn_caseInsensitive() {
        let rows = [["banana"], ["Apple"], ["cherry"]]
        XCTAssertEqual(
            CsvSort.sorted(rows: rows, column: 0, ascending: true),
            [["Apple"], ["banana"], ["cherry"]])
    }

    func test_emptyCells_sortLast_inBothDirections() {
        let rows = [["b"], [""], ["a"]]
        XCTAssertEqual(
            CsvSort.sorted(rows: rows, column: 0, ascending: true),
            [["a"], ["b"], [""]])
        XCTAssertEqual(
            CsvSort.sorted(rows: rows, column: 0, ascending: false),
            [["b"], ["a"], [""]], "empties stay last even descending")
    }

    func test_stable_forEqualValues() {
        // Two rows with equal key keep original order (tie-break on index).
        let rows = [["x", "first"], ["x", "second"], ["a", "third"]]
        XCTAssertEqual(
            CsvSort.sorted(rows: rows, column: 0, ascending: true),
            [["a", "third"], ["x", "first"], ["x", "second"]])
    }

    func test_sortBySecondColumn() {
        let rows = [["a", "3"], ["b", "1"], ["c", "2"]]
        XCTAssertEqual(
            CsvSort.sorted(rows: rows, column: 1, ascending: true),
            [["b", "1"], ["c", "2"], ["a", "3"]])
    }

    func test_shortRow_missingColumn_treatedAsEmpty_sortsLast() {
        let rows = [["a", "2"], ["b"], ["c", "1"]]
        XCTAssertEqual(
            CsvSort.sorted(rows: rows, column: 1, ascending: true),
            [["c", "1"], ["a", "2"], ["b"]])
    }

    func test_columnOutOfRange_returnsUnchanged() {
        let rows = [["a"], ["b"]]
        XCTAssertEqual(CsvSort.sorted(rows: rows, column: -1, ascending: true), rows)
    }

    // Toggle transition (header click).

    func test_nextState_newColumn_isAscending() {
        let s = CsvSort.nextState(current: nil, tapped: 2)
        XCTAssertEqual(s.column, 2); XCTAssertTrue(s.ascending)
    }

    func test_nextState_sameColumn_flipsDirection() {
        let s = CsvSort.nextState(current: (column: 2, ascending: true), tapped: 2)
        XCTAssertEqual(s.column, 2); XCTAssertFalse(s.ascending)
    }

    func test_nextState_differentColumn_resetsToAscending() {
        let s = CsvSort.nextState(current: (column: 2, ascending: false), tapped: 0)
        XCTAssertEqual(s.column, 0); XCTAssertTrue(s.ascending)
    }
}
