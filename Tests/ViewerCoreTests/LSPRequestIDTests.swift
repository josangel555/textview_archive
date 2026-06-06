import XCTest
@testable import ViewerCore

/// Coverage for `LSPRequestID` — the JSON-RPC request-id union
/// (`number(Int64) | string`) with a hand-rolled `Codable`. It was
/// untested. The load-bearing behaviours: a JSON number decodes to
/// `.number`, a JSON string to `.string`, a *numeric string* stays
/// `.string` (no silent coercion — the `try?` int probe must not eat a
/// quoted "5"), both cases round-trip through JSON unchanged, and the two
/// arms are distinct under `Hashable`/`Equatable`.
final class LSPRequestIDTests: XCTestCase {

    /// Wrapper so we decode/encode an object field rather than a bare
    /// top-level JSON fragment (robust across Foundation versions).
    private struct Box: Codable, Equatable { let id: LSPRequestID }

    private func decode(_ json: String) throws -> LSPRequestID {
        try JSONDecoder().decode(Box.self, from: Data(json.utf8)).id
    }

    // MARK: - decode

    func test_decode_jsonNumber_isNumber() throws {
        XCTAssertEqual(try decode(#"{"id":42}"#), .number(42))
        XCTAssertEqual(try decode(#"{"id":0}"#), .number(0))
        XCTAssertEqual(try decode(#"{"id":-7}"#), .number(-7))
    }

    func test_decode_jsonString_isString() throws {
        XCTAssertEqual(try decode(#"{"id":"req-1"}"#), .string("req-1"))
        XCTAssertEqual(try decode(#"{"id":""}"#), .string(""))
    }

    /// The disambiguation that matters: a JSON *string* that happens to
    /// look numeric must remain `.string`. `JSONDecoder` does not coerce a
    /// quoted value to `Int64`, so the `try?` number probe fails and the
    /// string arm wins — a future refactor adding string→int coercion
    /// would break id round-tripping against a server that issued `"5"`.
    func test_decode_numericString_staysString() throws {
        XCTAssertEqual(try decode(#"{"id":"5"}"#), .string("5"))
        XCTAssertNotEqual(try decode(#"{"id":"5"}"#), .number(5))
    }

    func test_decode_largeInt64_preserved() throws {
        let big = Int64.max
        XCTAssertEqual(try decode(#"{"id":\#(big)}"#), .number(big))
    }

    // MARK: - round-trip (encode → decode)

    func test_roundTrip_number() throws {
        let original = Box(id: .number(123))
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(Box.self, from: data), original)
    }

    func test_roundTrip_string() throws {
        let original = Box(id: .string("abc-def"))
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(Box.self, from: data), original)
    }

    /// `.number` must encode as a bare JSON number (no quotes); `.string`
    /// as a quoted value. Pins the wire shape the server parses.
    func test_encode_numberIsUnquoted_stringIsQuoted() throws {
        let n = String(data: try JSONEncoder().encode(Box(id: .number(9))), encoding: .utf8)!
        XCTAssertTrue(n.contains("\"id\":9"), "number arm must encode unquoted: \(n)")
        let s = String(data: try JSONEncoder().encode(Box(id: .string("9"))), encoding: .utf8)!
        XCTAssertTrue(s.contains("\"id\":\"9\""), "string arm must encode quoted: \(s)")
    }

    // MARK: - Hashable / Equatable

    func test_numberAndStringArmsAreDistinct() {
        XCTAssertNotEqual(LSPRequestID.number(5), .string("5"))
        var set: Set<LSPRequestID> = [.number(5), .string("5")]
        XCTAssertEqual(set.count, 2, "the two arms must hash distinctly")
        set.insert(.number(5))
        XCTAssertEqual(set.count, 2, "re-inserting an equal value is a no-op")
    }
}
