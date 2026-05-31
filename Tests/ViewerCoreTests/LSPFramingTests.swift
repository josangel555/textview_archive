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

    // MARK: PARSE-01 — Content-Length cap (OOM guard)

    func test_decode_rejectsOversizeContentLength_beforeAllocating() {
        // Content-Length one past the cap must throw a framing error
        // *without* waiting for / allocating the body. We send only the
        // header (no body bytes) — a correct cap-check rejects here; a
        // missing one would return `.needMore` and start buffering.
        let oversize = LSPFraming.maxBodyBytes + 1
        let header = Data("Content-Length: \(oversize)\r\n\r\n".utf8)
        XCTAssertThrowsError(try LSPFraming.decode(header)) { err in
            guard case LSPError.framingError(let m) = err else {
                return XCTFail("expected framingError, got \(err)")
            }
            XCTAssertTrue(m.contains("exceeds cap"),
                "cap rejection should name the cap, got: \(m)")
        }
    }

    func test_decode_acceptsContentLengthAtCapBoundary() throws {
        // Exactly at the cap is allowed (boundary is inclusive). We
        // don't supply the body, so the result is `.needMore` — the
        // point is it must NOT throw.
        let atCap = LSPFraming.maxBodyBytes
        let header = Data("Content-Length: \(atCap)\r\n\r\n".utf8)
        let step = try LSPFraming.decode(header)
        XCTAssertEqual(step, .needMore,
            "a Content-Length at the cap must be accepted (awaiting body)")
    }

    // MARK: PARSE-01 — header cap (unterminated header guard)

    func test_decode_rejectsUnterminatedHeaderPastCap() {
        // A stream that never emits `\r\n\r\n` must not let us buffer
        // without bound. Feed > maxHeaderBytes with no terminator.
        let junk = Data(repeating: 0x41 /* 'A' */, count: LSPFraming.maxHeaderBytes + 16)
        XCTAssertThrowsError(try LSPFraming.decode(junk)) { err in
            guard case LSPError.framingError(let m) = err else {
                return XCTFail("expected framingError, got \(err)")
            }
            XCTAssertTrue(m.lowercased().contains("header"),
                "unterminated-header rejection should mention header, got: \(m)")
        }
    }

    // MARK: PARSE-01 — O(n) header scan via resume cursor

    func test_decode_resumeCursor_findsTerminatorSplitAcrossChunks() throws {
        // Simulate a header arriving in two reads where the `\r\n\r\n`
        // straddles the chunk boundary. The resume cursor backs up 3
        // bytes, so the split terminator must still be found.
        var cursor = 0
        // First chunk ends mid-terminator: "...\r\n\r" (3 of 4 bytes).
        var buf = Data("Content-Length: 2\r\n\r".utf8)
        let step1 = try LSPFraming.decode(buf, headerScanStart: &cursor)
        XCTAssertEqual(step1, .needMore)
        XCTAssertGreaterThan(cursor, 0, "cursor should advance on needMore")
        // Cursor must be backed up enough to re-find the split terminator.
        XCTAssertLessThanOrEqual(cursor, buf.count - 1)

        // Second chunk completes the terminator + body.
        buf.append(Data("\n{}".utf8)) // now "...\r\n\r\n{}"
        let step2 = try LSPFraming.decode(buf, headerScanStart: &cursor)
        guard case .message(let body, let consumed) = step2 else {
            return XCTFail("expected message after completing the split terminator, got \(step2)")
        }
        XCTAssertEqual(body, Data("{}".utf8))
        XCTAssertEqual(consumed, buf.count)
        XCTAssertEqual(cursor, 0, "cursor resets to 0 once a terminator is found")
    }

    func test_decode_resumeCursor_matchesPlainDecode_onBackToBack() throws {
        // The resume-cursor variant must agree with the plain `decode`
        // on a realistic back-to-back drain.
        let a = Data(#"{"id":1}"#.utf8)
        let b = Data(#"{"id":2}"#.utf8)
        var buf = LSPFraming.frame(a)
        buf.append(LSPFraming.frame(b))

        var cursor = 0
        var collected: [Data] = []
        while true {
            let step = try LSPFraming.decode(buf, headerScanStart: &cursor)
            switch step {
            case .needMore: break
            case .message(let body, let consumed):
                collected.append(body)
                buf.removeFirst(consumed)
                cursor = 0
                continue
            }
            break
        }
        XCTAssertEqual(collected, [a, b])
        XCTAssertEqual(buf.count, 0)
    }
}
