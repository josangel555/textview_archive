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
