import XCTest
@testable import ViewerCore

/// Pure-logic tests for LSP `Content-Length` framing. No subprocess.
final class LSPFramingTests: XCTestCase {

    private func frame(_ json: String) -> Data {
        LSPFraming.frame(Data(json.utf8))
    }

    // MARK: encode

    func test_frame_addsContentLengthHeaderCRLF() {
        let out = frame(#"{"x":1}"#)
        let s = String(data: out, encoding: .utf8)!
        XCTAssertTrue(s.hasPrefix("Content-Length: 7\r\n\r\n"))
        XCTAssertTrue(s.hasSuffix(#"{"x":1}"#))
    }

    func test_frame_lengthIsByteCount_notCharCount() {
        // 4-byte emoji "🚀" in UTF-8 is 4 bytes; quoted JSON string is 6.
        let json = "\"🚀\""
        let out = LSPFraming.frame(Data(json.utf8))
        // Find the \r\n\r\n boundary in bytes, then decode the header
        // section as ASCII (the body has non-ASCII bytes — emoji).
        let bytes = [UInt8](out)
        var headerEnd = 0
        for i in 0..<(bytes.count - 3) {
            if bytes[i] == 0x0D && bytes[i+1] == 0x0A
                && bytes[i+2] == 0x0D && bytes[i+3] == 0x0A {
                headerEnd = i; break
            }
        }
        let header = String(data: out.prefix(headerEnd), encoding: .ascii) ?? ""
        XCTAssertEqual(header, "Content-Length: 6")
    }

    // MARK: decode — happy path

    func test_decode_singleMessage() throws {
        let body = Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8)
        let buf = LSPFraming.frame(body)
        let step = try LSPFraming.decode(buf)
        guard case .message(let got, let consumed) = step else {
            return XCTFail("expected message, got \(step)")
        }
        XCTAssertEqual(got, body)
        XCTAssertEqual(consumed, buf.count)
    }

    func test_decode_handlesEmbeddedCRLFInBody() throws {
        // hover.contents markdown often contains literal CRLFs inside
        // a JSON string. The decoder must not treat them as a header
        // terminator — that was the original `\r\n`-based-split bug.
        let body = Data(#"{"contents":"line1\r\nline2"}"#.utf8)
        let buf = LSPFraming.frame(body)
        let step = try LSPFraming.decode(buf)
        guard case .message(let got, _) = step else {
            return XCTFail("expected message")
        }
        XCTAssertEqual(got, body)
    }

    // MARK: decode — partial / needMore

    func test_decode_needMoreOnIncompleteHeader() throws {
        let partial = Data("Content-Length: 10\r\n".utf8) // no terminator yet
        let step = try LSPFraming.decode(partial)
        XCTAssertEqual(step, .needMore)
    }

    func test_decode_needMoreOnIncompleteBody() throws {
        let body = Data(#"{"x":1}"#.utf8)
        var buf = LSPFraming.frame(body)
        buf = buf.dropLast(2) // chop the last 2 bytes of the body
        let step = try LSPFraming.decode(buf)
        XCTAssertEqual(step, .needMore)
    }

    // MARK: decode — back-to-back

    func test_decode_drainsBackToBackMessages() throws {
        let a = Data(#"{"id":1}"#.utf8)
        let b = Data(#"{"id":2}"#.utf8)
        var buf = LSPFraming.frame(a)
        buf.append(LSPFraming.frame(b))

        var collected: [Data] = []
        while true {
            let step = try LSPFraming.decode(buf)
            switch step {
            case .needMore: break
            case .message(let body, let consumed):
                collected.append(body)
                buf.removeFirst(consumed)
                continue
            }
            break
        }
        XCTAssertEqual(collected, [a, b])
        XCTAssertEqual(buf.count, 0)
    }

    // MARK: decode — errors

    func test_decode_throwsOnMissingContentLength() {
        let bogus = Data("X-Other: 1\r\n\r\nbody".utf8)
        XCTAssertThrowsError(try LSPFraming.decode(bogus)) { err in
            guard case LSPError.framingError = err else {
                return XCTFail("expected framingError, got \(err)")
            }
        }
    }

    func test_decode_acceptsCaseInsensitiveHeaderName() throws {
        let body = Data(#"{}"#.utf8)
        var raw = Data("content-length: 2\r\n\r\n".utf8)
        raw.append(body)
        let step = try LSPFraming.decode(raw)
        guard case .message(let got, _) = step else {
            return XCTFail("expected message")
        }
        XCTAssertEqual(got, body)
    }
}
