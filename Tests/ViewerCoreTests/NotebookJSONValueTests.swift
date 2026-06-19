import XCTest
@testable import ViewerCore

/// Host tests for the order-preserving `JSONValue` that backs notebook
/// round-trip (TSK-717). The key guarantees: object member order is retained,
/// number tokens are preserved verbatim (no `1.0` → `1` reformat), and
/// serialize ∘ parse is idempotent.
final class NotebookJSONValueTests: XCTestCase {

    func testPreservesObjectKeyOrder() throws {
        // Deliberately non-alphabetical so the order can't be confused with a
        // sorted re-emit.
        let json = "{\"zebra\":1,\"apple\":2,\"mango\":3}"
        let value = try JSONValue.parse(json)
        let keys = value.objectMembers?.map(\.0)
        XCTAssertEqual(keys, ["zebra", "apple", "mango"])
    }

    func testPreservesNumberFormatting() throws {
        let json = "{\"int\":1,\"float\":1.0,\"exp\":1e10,\"neg\":-0,\"big\":12345678901234567890}"
        let value = try JSONValue.parse(json)
        XCTAssertEqual(value["int"], .number(raw: "1"))
        XCTAssertEqual(value["float"], .number(raw: "1.0"))
        XCTAssertEqual(value["exp"], .number(raw: "1e10"))
        XCTAssertEqual(value["neg"], .number(raw: "-0"))
        // A number beyond Int64/Double precision survives as its token.
        XCTAssertEqual(value["big"], .number(raw: "12345678901234567890"))
    }

    func testParsesNestedAndScalars() throws {
        let json = "{\"a\":[true,false,null,\"s\"],\"b\":{\"c\":42}}"
        let value = try JSONValue.parse(json)
        let arr = value["a"]?.arrayElements
        XCTAssertEqual(arr, [.bool(true), .bool(false), .null, .string("s")])
        XCTAssertEqual(value["b"]?["c"], .number(raw: "42"))
    }

    func testRoundTripIdempotent() throws {
        let json = "{\"zebra\":1,\"apple\":[1.0,2,3],\"mango\":{\"x\":null}}"
        let value = try JSONValue.parse(json)
        let once = value.serialized()
        let twice = try JSONValue.parse(once).serialized()
        XCTAssertEqual(once, twice)
    }

    func testStringEscaping() throws {
        let json = "{\"s\":\"tab\\tnewline\\nquote\\\"backslash\\\\\"}"
        let value = try JSONValue.parse(json)
        XCTAssertEqual(value["s"]?.stringValue, "tab\tnewline\nquote\"backslash\\")
        // Re-serialize and re-parse: the string is preserved.
        let reparsed = try JSONValue.parse(value.serialized())
        XCTAssertEqual(reparsed["s"]?.stringValue, "tab\tnewline\nquote\"backslash\\")
    }

    func testUnicodeEscapeAndSurrogatePair() throws {
        // U+00E9 (é) and a surrogate pair for U+1F600 (😀).
        let json = "{\"a\":\"\\u00e9\",\"b\":\"\\ud83d\\ude00\"}"
        let value = try JSONValue.parse(json)
        XCTAssertEqual(value["a"]?.stringValue, "é")
        XCTAssertEqual(value["b"]?.stringValue, "😀")
    }

    func testEmptyContainers() throws {
        let value = try JSONValue.parse("{\"obj\":{},\"arr\":[]}")
        XCTAssertEqual(value["obj"], .object([]))
        XCTAssertEqual(value["arr"], .array([]))
        // Empty containers serialize compactly.
        XCTAssertEqual(JSONValue.object([]).serialized(), "{}")
        XCTAssertEqual(JSONValue.array([]).serialized(), "[]")
    }

    func testSubscriptSetReplacesAndAppendsInOrder() throws {
        var value = try JSONValue.parse("{\"a\":1,\"b\":2}")
        value["a"] = .number(raw: "99")          // replace in place
        value["c"] = .string("new")              // append at end
        XCTAssertEqual(value.objectMembers?.map(\.0), ["a", "b", "c"])
        XCTAssertEqual(value["a"], .number(raw: "99"))
        value["b"] = nil                          // remove
        XCTAssertEqual(value.objectMembers?.map(\.0), ["a", "c"])
    }

    func testRejectsMalformed() {
        XCTAssertThrowsError(try JSONValue.parse("{\"a\":}"))
        XCTAssertThrowsError(try JSONValue.parse("{\"a\":1,}}"))
        XCTAssertThrowsError(try JSONValue.parse("trailing garbage {}"))
        XCTAssertThrowsError(try JSONValue.parse(""))
    }
}

/// Tests for the notebook feature gate (default OFF; env + UserDefaults opt-in).
final class NotebookGateTests: XCTestCase {

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "NotebookGateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultOff() {
        let defaults = ephemeralDefaults()
        XCTAssertFalse(NotebookGate.isEnabled(defaults: defaults, environment: [:]))
    }

    func testEnvOverrideOn() {
        let defaults = ephemeralDefaults()
        XCTAssertTrue(NotebookGate.isEnabled(defaults: defaults, environment: ["MDV_NOTEBOOKS": "1"]))
        XCTAssertTrue(NotebookGate.isEnabled(defaults: defaults, environment: ["MDV_NOTEBOOKS": "true"]))
        XCTAssertFalse(NotebookGate.isEnabled(defaults: defaults, environment: ["MDV_NOTEBOOKS": "0"]))
    }

    func testPersistedToggleOn() {
        let defaults = ephemeralDefaults()
        defaults.set(true, forKey: NotebookGate.defaultsKey)
        XCTAssertTrue(NotebookGate.isEnabled(defaults: defaults, environment: [:]))
    }

    func testEnvOverridesPersisted() {
        let defaults = ephemeralDefaults()
        defaults.set(true, forKey: NotebookGate.defaultsKey)
        // env "0" wins over a persisted true.
        XCTAssertFalse(NotebookGate.isEnabled(defaults: defaults, environment: ["MDV_NOTEBOOKS": "0"]))
    }
}
