import XCTest
@testable import ViewerCore

/// TSK-723 — the structural-query DSL parser (user query string → StructuralQuery,
/// the input to the already-built StructuralSearchEngine matcher). Pins each grammar
/// construct, the error cases, and that the parser is TOTAL (never panics on
/// arbitrary/untrusted input).
final class StructuralQueryParserTests: XCTestCase {

    private func parse(_ s: String) throws -> StructuralQuery { try StructuralQueryParser.parse(s) }

    func test_singleKind() throws {
        XCTAssertEqual(try parse("function_declaration"), StructuralQuery(kind: "function_declaration"))
    }

    func test_orKinds() throws {
        XCTAssertEqual(try parse("if_statement|guard_statement"),
                       StructuralQuery(kinds: ["if_statement", "guard_statement"]))
    }

    func test_wildcard_emptyKinds() throws {
        XCTAssertEqual(try parse("* (call_expression)"),
                       StructuralQuery(kinds: [], childPatterns: [StructuralQuery(kind: "call_expression")]))
    }

    func test_rootCapture() throws {
        XCTAssertEqual(try parse("function_declaration @func"),
                       StructuralQuery(kind: "function_declaration", captureAs: "func"))
    }

    func test_fieldEquals_quotedAndBare() throws {
        XCTAssertEqual(try parse("call_expression name=\"print\""),
                       StructuralQuery(kind: "call_expression", fieldConstraints: [.equals("name", "print")]))
        XCTAssertEqual(try parse("call_expression name=print"),
                       StructuralQuery(kind: "call_expression", fieldConstraints: [.equals("name", "print")]))
    }

    func test_fieldCapture() throws {
        XCTAssertEqual(try parse("function_declaration name=$X"),
                       StructuralQuery(kind: "function_declaration", fieldConstraints: [.capture("name", as: "X")]))
    }

    func test_fieldContains_andKind() throws {
        XCTAssertEqual(try parse("function_declaration name~test"),
                       StructuralQuery(kind: "function_declaration", fieldConstraints: [.contains("name", "test")]))
        XCTAssertEqual(try parse("assignment value:integer_literal"),
                       StructuralQuery(kind: "assignment", fieldConstraints: [.kind("value", is: "integer_literal")]))
    }

    func test_childContainment() throws {
        XCTAssertEqual(try parse("function_declaration (return_statement)"),
                       StructuralQuery(kind: "function_declaration",
                                       childPatterns: [StructuralQuery(kind: "return_statement")]))
    }

    func test_combined() throws {
        let q = try parse("function_declaration @f name=$X (return_statement)")
        XCTAssertEqual(q, StructuralQuery(
            kind: "function_declaration",
            fieldConstraints: [.capture("name", as: "X")],
            childPatterns: [StructuralQuery(kind: "return_statement")],
            captureAs: "f"))
    }

    func test_errors() {
        XCTAssertThrowsError(try parse(""))                              // empty
        XCTAssertThrowsError(try parse("call_expression name="))         // no value
        XCTAssertThrowsError(try parse("|foo"))                          // leading pipe
        XCTAssertThrowsError(try parse("function_declaration ("))        // unclosed child
        XCTAssertThrowsError(try parse("call_expression name"))          // field w/o operator
    }

    func test_arbitraryInput_neverPanics() {
        let alphabet = Array("abc_|@=~:$() \"123 function name return")
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func rnd() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) & 0x7FFF)
        }
        for _ in 0..<3000 {
            let len = rnd() % 60
            var s = ""
            for _ in 0..<len { s.append(alphabet[rnd() % alphabet.count]) }
            _ = try? StructuralQueryParser.parse(s)   // must throw-or-return, never trap
        }
        for s in ["@", "$", "(((", ")))", "a|", "a:", "a~", "a=$", "\"unterminated", "* * *"] {
            _ = try? StructuralQueryParser.parse(s)
        }
    }
}
