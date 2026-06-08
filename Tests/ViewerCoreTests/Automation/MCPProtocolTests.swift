import XCTest
@testable import ViewerCore

final class MCPProtocolTests: XCTestCase {

    // MARK: - Value codable

    func test_value_intDecode_keepsIntegerNotDouble() throws {
        // The decoder must try Int before Double — otherwise {"line": 42}
        // round-trips as 42.0 and downstream Int args break.
        let data = Data(#"{"line": 42}"#.utf8)
        let v = try JSONDecoder().decode(MCP.Value.self, from: data)
        guard case .object(let o) = v,
              case .int(let n)? = o["line"] else {
            return XCTFail("expected int")
        }
        XCTAssertEqual(n, 42)
    }

    func test_value_floatDecode() throws {
        let data = Data(#"{"zoom": 1.25}"#.utf8)
        let v = try JSONDecoder().decode(MCP.Value.self, from: data)
        guard case .object(let o) = v,
              case .double(let d)? = o["zoom"] else {
            return XCTFail()
        }
        XCTAssertEqual(d, 1.25, accuracy: 0.0001)
    }

    func test_value_roundTrip() throws {
        let v: MCP.Value = .object([
            "a": .int(1),
            "b": .string("hi"),
            "c": .array([.bool(true), .null, .double(3.14)]),
        ])
        let data = try JSONEncoder().encode(v)
        let back = try JSONDecoder().decode(MCP.Value.self, from: data)
        XCTAssertEqual(back, v)
    }

    // MARK: - Request envelope

    func test_request_decode_initialize() throws {
        let raw = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8)
        let req = try JSONDecoder().decode(MCP.Request.self, from: raw)
        XCTAssertEqual(req.jsonrpc, "2.0")
        XCTAssertEqual(req.method, "initialize")
        XCTAssertEqual(req.id, .int(1))
    }

    func test_request_decode_stringId() throws {
        let raw = Data(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#.utf8)
        let req = try JSONDecoder().decode(MCP.Request.self, from: raw)
        XCTAssertEqual(req.id, .string("abc"))
    }

    func test_request_decode_noIdMeansNotification() throws {
        let raw = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        let req = try JSONDecoder().decode(MCP.Request.self, from: raw)
        XCTAssertNil(req.id)
    }

    // MARK: - Response envelope

    func test_response_encode_result() throws {
        let resp = MCP.Response(id: .int(7), result: .object(["ok": .bool(true)]))
        let data = try JSONEncoder().encode(resp)
        let s = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains(#""jsonrpc":"2.0""#))
        XCTAssertTrue(s.contains(#""id":7"#))
        XCTAssertTrue(s.contains(#""result""#))
        XCTAssertFalse(s.contains(#""error""#))
    }

    func test_response_encode_error() throws {
        let resp = MCP.Response(id: .int(7), error: .init(
            code: MCP.ErrorCode.methodNotFound, message: "nope"))
        let data = try JSONEncoder().encode(resp)
        let s = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains(#""error""#))
        XCTAssertTrue(s.contains(#""code":-32601"#))
    }

    // MARK: - Arg accessors

    func test_argAccessors_extractTypedFields() throws {
        let v: MCP.Value = .object([
            "path": .string("/tmp/x"),
            "newTab": .bool(false),
            "n": .int(5),
        ])
        XCTAssertEqual(try v.string("path"), "/tmp/x")
        XCTAssertEqual(try v.bool("newTab"), false)
        XCTAssertEqual(try v.int("n"), 5)
        XCTAssertNil(v.optionalString("missing"))
        XCTAssertNil(v.optionalInt("missing"))
    }

    func test_argAccessor_missingRequiredField_throws() {
        let v: MCP.Value = .object([:])
        XCTAssertThrowsError(try v.string("path")) { error in
            guard case .invalidParams = error as? MCPError else {
                XCTFail("expected invalidParams, got \(error)"); return
            }
        }
    }

    // TSK-145: a JSON number outside Int's range (e.g. 1e19) or with a
    // fraction arrives as `.double`. `int(_:)` must NOT use the trapping
    // `Int(d)` — that aborts the whole host from a single malformed
    // tools/call. It must convert non-trappingly (`Int(exactly:)`) and
    // throw `.invalidParams` instead. If this regresses to `Int(d)` the
    // out-of-range case TRAPS, failing this test by crashing the run.
    func test_int_outOfRangeDouble_throwsInsteadOfTrapping() {
        let v: MCP.Value = .object(["big": .double(1e19)])
        XCTAssertThrowsError(try v.int("big")) { error in
            guard case .invalidParams = error as? MCPError else {
                XCTFail("expected invalidParams for 1e19, got \(error)"); return
            }
        }
    }

    func test_int_fractionalDouble_throws() {
        let v: MCP.Value = .object(["frac": .double(1.5)])
        XCTAssertThrowsError(try v.int("frac")) { error in
            guard case .invalidParams = error as? MCPError else {
                XCTFail("expected invalidParams for 1.5, got \(error)"); return
            }
        }
    }

    func test_optionalInt_outOfRangeOrFractionalDouble_isNilNotTrap() {
        // Same non-trapping contract on the optional path: unusable values
        // map to nil (its "absent / unusable" signal), never a crash.
        let v: MCP.Value = .object(["big": .double(1e19), "frac": .double(2.7)])
        XCTAssertNil(v.optionalInt("big"))
        XCTAssertNil(v.optionalInt("frac"))
    }

    func test_int_inRangeWholeDouble_isAccepted() {
        // A whole-valued double within range is a legal integer (42.0 → 42).
        let v: MCP.Value = .object(["n": .double(42)])
        XCTAssertEqual(try v.int("n"), 42)
        XCTAssertEqual(v.optionalInt("n"), 42)
    }
}
