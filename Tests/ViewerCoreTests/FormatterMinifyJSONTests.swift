import XCTest
@testable import ViewerCore

/// Teeth for `Formatter.minifyJSON` — a whitespace-strip minify that PRESERVES
/// key order and exact value text (unlike a JSONSerialization round-trip).
final class FormatterMinifyJSONTests: XCTestCase {

    func test_stripsInsignificantWhitespace() {
        XCTAssertEqual(
            Formatter.minifyJSON("{ \"a\" : 1, \"b\" : [1, 2, 3] }"),
            "{\"a\":1,\"b\":[1,2,3]}")
    }

    func test_preservesWhitespaceInsideStrings() {
        XCTAssertEqual(
            Formatter.minifyJSON("{\n  \"k\": \"hello   world\"\n}"),
            "{\"k\":\"hello   world\"}")
    }

    func test_preservesEscapedQuotesInStrings() {
        XCTAssertEqual(
            Formatter.minifyJSON("{ \"k\": \"a\\\"b c\" }"),
            "{\"k\":\"a\\\"b c\"}")
    }

    func test_preservesKeyOrder_notSorted() {
        // A JSONSerialization round-trip would reorder; the char-walk doesn't.
        XCTAssertEqual(
            Formatter.minifyJSON("{ \"b\": 1, \"a\": 2 }"),
            "{\"b\":1,\"a\":2}")
    }

    func test_preservesExactNumberText() {
        // 1.50 / 1e3 would be renormalised by JSONSerialization; preserved here.
        XCTAssertEqual(
            Formatter.minifyJSON("{ \"x\": 1.50, \"y\": 1e3 }"),
            "{\"x\":1.50,\"y\":1e3}")
    }

    func test_invalidJSON_returnedUnchanged() {
        XCTAssertEqual(Formatter.minifyJSON("not json { , }"), "not json { , }")
        XCTAssertEqual(Formatter.minifyJSON("{ \"unterminated\": "), "{ \"unterminated\": ")
    }

    func test_fragment_minifies() {
        // .fragmentsAllowed → a bare array/scalar is valid JSON to minify.
        XCTAssertEqual(Formatter.minifyJSON("[ 1 , 2 ,\n 3 ]"), "[1,2,3]")
    }

    func test_alreadyMinified_isStable() {
        let m = "{\"a\":[1,2],\"b\":\"x y\"}"
        XCTAssertEqual(Formatter.minifyJSON(m), m)
    }
}
