import XCTest
@testable import ViewerCore

final class CSVFilterTests: XCTestCase {

    private let sample = CSVParser.Result(
        delimiter: ",",
        header: ["name", "status", "score", "city"],
        rows: [
            ["Alice",   "active",   "42",  "Paris"],
            ["Bob",     "inactive", "7",   "Lyon"],
            ["Charlie", "active",   "100", "Paris"],
            ["Dora",    "pending",  "12",  "Marseille"],
            ["alice",   "active",   "3",   "Nice"]
        ]
    )

    // MARK: - Global substring

    func test_emptyFilter_returnsAllRows() {
        let f = CSVFilter()
        let r = f.apply(to: sample)
        XCTAssertEqual(r.rows.count, sample.rows.count)
        XCTAssertEqual(r.indices, Array(0..<sample.rows.count))
    }

    func test_globalSubstring_acrossAllColumns_caseInsensitive() {
        let f = CSVFilter(globalQuery: "ALICE")
        let r = f.apply(to: sample)
        XCTAssertEqual(r.rows.map { $0[0] }, ["Alice", "alice"])
    }

    func test_globalSubstring_matchesAnyColumn() {
        // "Paris" lives only in the city column.
        let f = CSVFilter(globalQuery: "paris")
        let r = f.apply(to: sample)
        XCTAssertEqual(Set(r.rows.map { $0[0] }), ["Alice", "Charlie"])
    }

    // MARK: - Column-scoped global

    func test_globalSubstring_scopedToColumn() {
        // "active" is a substring of "inactive", so Bob matches too —
        // this exercises the case-insensitive substring contract.
        let f = CSVFilter(globalQuery: "active", globalScope: .column(1))
        let r = f.apply(to: sample)
        XCTAssertEqual(Set(r.rows.map { $0[0] }),
                       ["Alice", "Bob", "Charlie", "alice"])
    }

    func test_globalSubstring_scopedToColumn_misses() {
        let f = CSVFilter(globalQuery: "active", globalScope: .column(0))
        let r = f.apply(to: sample)
        // "active" doesn't appear in the name column.
        XCTAssertTrue(r.rows.isEmpty)
    }

    // MARK: - Per-column expressions

    func test_perColumn_contains_isDefault() {
        let f = CSVFilter(perColumn: [3: "par"])
        let r = f.apply(to: sample)
        XCTAssertEqual(Set(r.rows.map { $0[0] }), ["Alice", "Charlie"])
    }

    func test_perColumn_equals_numeric() {
        let f = CSVFilter(perColumn: [2: "=42"])
        let r = f.apply(to: sample)
        XCTAssertEqual(r.rows.map { $0[0] }, ["Alice"])
    }

    func test_perColumn_equals_numeric_acceptsWhitespaceAndFloats() {
        let local = CSVParser.Result(
            delimiter: ",", header: ["v"],
            rows: [["42"], ["42.0"], [" 42 "], ["43"]]
        )
        let f = CSVFilter(perColumn: [0: "=42"])
        let r = f.apply(to: local)
        XCTAssertEqual(r.rows.count, 3)
    }

    func test_perColumn_notEquals_numeric() {
        let f = CSVFilter(perColumn: [2: "!=42"])
        let r = f.apply(to: sample)
        XCTAssertEqual(Set(r.rows.map { $0[0] }), ["Bob", "Charlie", "Dora", "alice"])
    }

    func test_perColumn_greaterThan_numeric() {
        let f = CSVFilter(perColumn: [2: ">10"])
        let r = f.apply(to: sample)
        XCTAssertEqual(Set(r.rows.map { $0[0] }), ["Alice", "Charlie", "Dora"])
    }

    func test_perColumn_lessOrEqual_numeric() {
        let f = CSVFilter(perColumn: [2: "<=12"])
        let r = f.apply(to: sample)
        XCTAssertEqual(Set(r.rows.map { $0[0] }), ["Bob", "Dora", "alice"])
    }

    func test_perColumn_greaterThan_string_fallback() {
        // "Lyon" > "Bobsville" lexically.
        let f = CSVFilter(perColumn: [3: ">Lyon"])
        let r = f.apply(to: sample)
        XCTAssertTrue(r.rows.contains { $0[0] == "Dora" })  // Marseille > Lyon
        XCTAssertTrue(r.rows.contains { $0[0] == "alice" }) // Nice > Lyon
        XCTAssertFalse(r.rows.contains { $0[0] == "Bob" })  // Lyon == Lyon, not strict >
    }

    func test_perColumn_equals_caseInsensitiveString() {
        let f = CSVFilter(perColumn: [0: "=alice"])
        let r = f.apply(to: sample)
        XCTAssertEqual(r.rows.count, 2)
    }

    // MARK: - Composition

    func test_globalAndPerColumn_compose_AND() {
        // Global must match (any col), AND per-column expressions must match.
        let f = CSVFilter(
            globalQuery: "active",
            perColumn: [2: ">10"]
        )
        let r = f.apply(to: sample)
        XCTAssertEqual(Set(r.rows.map { $0[0] }), ["Alice", "Charlie"])
    }

    func test_multiplePerColumn_compose_AND() {
        let f = CSVFilter(perColumn: [1: "active", 3: "Paris"])
        let r = f.apply(to: sample)
        XCTAssertEqual(Set(r.rows.map { $0[0] }), ["Alice", "Charlie"])
    }

    // MARK: - Indices are original positions

    func test_returnedIndicesArePositionsInOriginalRows() {
        let f = CSVFilter(perColumn: [3: "Paris"])
        let r = f.apply(to: sample)
        XCTAssertEqual(r.indices, [0, 2])
    }

    // MARK: - Out-of-bounds column index is ignored

    func test_perColumn_outOfBoundsIndex_dropsRow() {
        let f = CSVFilter(perColumn: [42: "anything"])
        let r = f.apply(to: sample)
        XCTAssertTrue(r.rows.isEmpty)
    }

    // MARK: - Empty per-column entries are no-ops

    func test_perColumn_emptyExpression_treatedAsNoFilter() {
        let f = CSVFilter(perColumn: [0: "", 1: "   "])
        let r = f.apply(to: sample)
        XCTAssertEqual(r.rows.count, sample.rows.count)
    }

    // MARK: - ColumnExpression parsing

    func test_columnExpression_parses_allOperators() {
        XCTAssertEqual(ColumnExpression.parse(">=10"), .greaterOrEqual("10"))
        XCTAssertEqual(ColumnExpression.parse("<=10"), .lessOrEqual("10"))
        XCTAssertEqual(ColumnExpression.parse(">10"),  .greaterThan("10"))
        XCTAssertEqual(ColumnExpression.parse("<10"),  .lessThan("10"))
        XCTAssertEqual(ColumnExpression.parse("=foo"), .equals("foo"))
        XCTAssertEqual(ColumnExpression.parse("!=x"),  .notEquals("x"))
        XCTAssertEqual(ColumnExpression.parse("plain"),.contains("plain"))
    }

    func test_columnExpression_trimsOperandWhitespace() {
        XCTAssertEqual(ColumnExpression.parse(">  10"), .greaterThan("10"))
    }
}
