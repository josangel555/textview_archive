import XCTest
@testable import ViewerCore

final class MCPFramingTests: XCTestCase {

    // MARK: - Encode

    func test_encode_simpleBody() {
        let body = Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8)
        let framed = MCPFraming.encode(body: body)
        let header = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        // Use UTF-8 byte length, not String.count — CRLF is one
        // Character but two bytes.
        XCTAssertEqual(framed.prefix(header.count), header)
        XCTAssertEqual(framed.suffix(body.count), body)
    }

    func test_encode_emptyBody() {
        let framed = MCPFraming.encode(body: Data())
        XCTAssertEqual(framed, Data("Content-Length: 0\r\n\r\n".utf8))
    }

    // MARK: - Decode (round-trip)

    func test_roundTrip_singleMessage() throws {
        let body = Data(#"{"hello":"world","n":42}"#.utf8)
        let framed = MCPFraming.encode(body: body)
        var reader = MCPFraming.DataReader(framed)
        let decoded = try MCPFraming.decode(from: &reader)
        XCTAssertEqual(decoded, body)
    }

    func test_roundTrip_multipleMessages() throws {
        let a = Data(#"{"a":1}"#.utf8)
        let b = Data(#"{"b":2}"#.utf8)
        let c = Data(#"{"c":3}"#.utf8)
        var combined = Data()
        combined.append(MCPFraming.encode(body: a))
        combined.append(MCPFraming.encode(body: b))
        combined.append(MCPFraming.encode(body: c))
        var reader = MCPFraming.DataReader(combined)
        XCTAssertEqual(try MCPFraming.decode(from: &reader), a)
        XCTAssertEqual(try MCPFraming.decode(from: &reader), b)
        XCTAssertEqual(try MCPFraming.decode(from: &reader), c)
        // Fourth read = clean EOF → nil
        XCTAssertNil(try MCPFraming.decode(from: &reader))
    }

    func test_roundTrip_bodyWithEmbeddedNewlines() throws {
        // Content-Length framing exists precisely so bodies can contain
        // newlines without escaping. Make sure we handle it.
        let body = Data("""
            {
              "method": "tools/call",
              "params": {"text": "line1\\nline2"}
            }
            """.utf8)
        let framed = MCPFraming.encode(body: body)
        var reader = MCPFraming.DataReader(framed)
        XCTAssertEqual(try MCPFraming.decode(from: &reader), body)
    }

    func test_decode_acceptsLFOnlyLineEndings() throws {
        // Tolerant header parser accepts bare LF (hand-written client).
        var raw = Data("Content-Length: 4\n\n".utf8)
        raw.append(Data("abcd".utf8))
        var reader = MCPFraming.DataReader(raw)
        XCTAssertEqual(try MCPFraming.decode(from: &reader), Data("abcd".utf8))
    }

    // MARK: - Decode errors

    func test_decode_emptyStream_returnsNil() throws {
        var reader = MCPFraming.DataReader(Data())
        XCTAssertNil(try MCPFraming.decode(from: &reader))
    }

    func test_decode_midHeaderEOF_throwsUnexpectedEOF() {
        var reader = MCPFraming.DataReader(Data("Content-Length: 4".utf8))
        XCTAssertThrowsError(try MCPFraming.decode(from: &reader)) { error in
            XCTAssertEqual(error as? MCPFraming.DecodeError, .unexpectedEOF)
        }
    }

    func test_decode_missingContentLength_throws() {
        let raw = Data("Content-Type: application/json\r\n\r\nabc".utf8)
        var reader = MCPFraming.DataReader(raw)
        XCTAssertThrowsError(try MCPFraming.decode(from: &reader)) { error in
            XCTAssertEqual(error as? MCPFraming.DecodeError, .missingContentLength)
        }
    }

    func test_decode_bodyTooLarge_throws() {
        // Advertise a body well past the 16 MiB cap.
        let raw = Data("Content-Length: 999999999\r\n\r\n".utf8)
        var reader = MCPFraming.DataReader(raw)
        XCTAssertThrowsError(try MCPFraming.decode(from: &reader)) { error in
            if case .bodyTooLarge = error as? MCPFraming.DecodeError {
                // expected
            } else {
                XCTFail("expected .bodyTooLarge, got \(error)")
            }
        }
    }

    func test_decode_truncatedBody_returnsNilForEOF() throws {
        // Advertise 10 but only ship 3 bytes — EOF before length is met.
        var raw = Data("Content-Length: 10\r\n\r\n".utf8)
        raw.append(Data("abc".utf8))
        var reader = MCPFraming.DataReader(raw)
        XCTAssertThrowsError(try MCPFraming.decode(from: &reader)) { error in
            XCTAssertEqual(error as? MCPFraming.DecodeError, .unexpectedEOF)
        }
    }

    // MARK: - Header tolerance

    func test_decode_caseInsensitiveHeaderName() throws {
        var raw = Data("content-length: 3\r\n\r\n".utf8)
        raw.append(Data("xyz".utf8))
        var reader = MCPFraming.DataReader(raw)
        XCTAssertEqual(try MCPFraming.decode(from: &reader), Data("xyz".utf8))
    }

    func test_decode_extraHeaderIgnored() throws {
        var raw = Data("Content-Type: application/json\r\nContent-Length: 3\r\n\r\n".utf8)
        raw.append(Data("xyz".utf8))
        var reader = MCPFraming.DataReader(raw)
        XCTAssertEqual(try MCPFraming.decode(from: &reader), Data("xyz".utf8))
    }
}

// MARK: - TSK-1545: NDJSON (the real MCP stdio spec) + mode detection

/// Real MCP clients (Claude Code) delimit messages by newlines, not
/// Content-Length — the framing must accept both and REPORT which one
/// arrived so the server can reply in kind. The owner hit a 30 s connect
/// timeout against the Content-Length-only decode; these pin the fix.
final class MCPFramingNDJSONTests: XCTestCase {

    func test_decodeDetecting_ndjsonLine() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#
        var r = MCPFraming.DataReader(Data((json + "\n").utf8))
        let m = try XCTUnwrap(MCPFraming.decodeDetecting(from: &r))
        XCTAssertEqual(m.mode, .ndjson)
        XCTAssertEqual(String(decoding: m.body, as: UTF8.self), json)
    }

    func test_decodeDetecting_multipleNdjsonMessages_andBlankLines() throws {
        let a = #"{"id":1}"#, b = #"{"id":2}"#
        var r = MCPFraming.DataReader(Data((a + "\n\n" + b + "\r\n").utf8))
        let m1 = try XCTUnwrap(MCPFraming.decodeDetecting(from: &r))
        let m2 = try XCTUnwrap(MCPFraming.decodeDetecting(from: &r))
        XCTAssertEqual(String(decoding: m1.body, as: UTF8.self), a)
        XCTAssertEqual(String(decoding: m2.body, as: UTF8.self), b,
                       "CRLF line ending must be tolerated")
        XCTAssertNil(try MCPFraming.decodeDetecting(from: &r), "clean EOF after last message")
    }

    func test_decodeDetecting_unterminatedFinalLine_isDelivered() throws {
        let json = #"{"id":9}"#
        var r = MCPFraming.DataReader(Data(json.utf8))   // no trailing \n
        let m = try XCTUnwrap(MCPFraming.decodeDetecting(from: &r))
        XCTAssertEqual(String(decoding: m.body, as: UTF8.self), json)
    }

    func test_decodeDetecting_contentLength_reportsMode() throws {
        let body = #"{"id":3}"#
        var r = MCPFraming.DataReader(MCPFraming.encode(body: Data(body.utf8)))
        let m = try XCTUnwrap(MCPFraming.decodeDetecting(from: &r))
        XCTAssertEqual(m.mode, .contentLength)
        XCTAssertEqual(String(decoding: m.body, as: UTF8.self), body)
    }

    func test_encode_ndjson_appendsExactlyOneNewline() {
        let out = MCPFraming.encode(body: Data(#"{"a":1}"#.utf8), mode: .ndjson)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "{\"a\":1}\n")
    }

    func test_ndjson_oversizeLine_throwsBodyTooLarge() {
        var big = Data([UInt8(ascii: "{")])
        big.append(Data(repeating: UInt8(ascii: "x"), count: MCPFraming.maxBodyBytes + 2))
        var r = MCPFraming.DataReader(big)
        XCTAssertThrowsError(try MCPFraming.decodeDetecting(from: &r)) { err in
            guard case MCPFraming.DecodeError.bodyTooLarge = err as! MCPFraming.DecodeError else {
                return XCTFail("expected bodyTooLarge, got \(err)")
            }
        }
    }
}
