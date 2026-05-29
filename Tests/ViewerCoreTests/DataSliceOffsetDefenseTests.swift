import XCTest
@testable import ViewerCore

/// Regression tests for the macOS 26 `Data.subdata(in:)` slice-offset
/// bug. After `Data.removeFirst(n)` (and most slice operations), the
/// resulting `Data` value carries an internal `startIndex > 0`. On
/// macOS 26 some byte-level accessors interpret the requested range in
/// the *parent's* index space rather than the slice's 0-based view,
/// returning shifted bytes (or trapping). Framing decoders and any
/// JSONL-style line splitter that takes a `Data` parameter must be
/// robust to either shape.
///
/// These tests don't need macOS 26 to be meaningful: they simply
/// confirm that the production code returns the byte-identical result
/// when fed a slice with a non-zero `startIndex` as when fed a freshly
/// allocated `Data`. If a future regression drops the defensive
/// `Data(_:)` rebase, the slice case will diverge here. The fix
/// pattern is documented in `LSPFraming.decode` and replicated by
/// `MCPFraming.DataReader`, `MCPFraming.FileHandleReader`, and
/// `ClaudeLogParser.parse`.
final class DataSliceOffsetDefenseTests: XCTestCase {

    // MARK: - helpers

    /// Build a `Data` value whose internal `startIndex` is non-zero by
    /// dropping `prefix` bytes from a synthetic prefix. This is the
    /// canonical reproducer for the symptom — both `dropFirst` and
    /// `removeFirst` produce offset slices.
    private func offsetSlice(of payload: Data, prefix: Int = 7) -> Data {
        var raw = Data(repeating: 0xAB, count: prefix)
        raw.append(payload)
        raw.removeFirst(prefix)
        // Sanity: a real offset slice still has count == payload.count
        // but does NOT necessarily start at index 0 internally. We don't
        // assert on the offset directly (it's an implementation detail)
        // — instead we exercise the decoders below and assert they
        // return the canonical payload bytes regardless.
        XCTAssertEqual(raw.count, payload.count)
        return raw
    }

    // MARK: - LSPFraming

    func test_lspFraming_decode_handlesOffsetSliceBuffer() throws {
        let body = Data(#"{"jsonrpc":"2.0","id":42,"result":{"value":1}}"#.utf8)
        let framed = LSPFraming.frame(body)
        let sliced = offsetSlice(of: framed)

        let step = try LSPFraming.decode(sliced)
        guard case .message(let got, let consumed) = step else {
            return XCTFail("expected .message, got \(step)")
        }
        XCTAssertEqual(got, body, "body bytes must match regardless of slice offset")
        XCTAssertEqual(consumed, framed.count)
    }

    func test_lspFraming_decode_drainPattern_matchesFreshBuffer() throws {
        // The real-world LSPClient pattern: append a chunk, decode,
        // `removeFirst(consumed)`, decode again. Each `removeFirst`
        // shifts the buffer's internal startIndex. The decoder must
        // remain correct across the iteration.
        let a = Data(#"{"id":1}"#.utf8)
        let b = Data(#"{"id":2,"x":"hello"}"#.utf8)
        let c = Data(#"{"id":3,"nested":{"k":[1,2,3]}}"#.utf8)

        var buf = Data()
        buf.append(LSPFraming.frame(a))
        buf.append(LSPFraming.frame(b))
        buf.append(LSPFraming.frame(c))

        var collected: [Data] = []
        var step = try LSPFraming.decode(buf)
        while case .message(let body, let consumed) = step {
            collected.append(body)
            buf.removeFirst(consumed)
            step = try LSPFraming.decode(buf)
        }
        XCTAssertEqual(collected, [a, b, c])
        XCTAssertEqual(buf.count, 0)
    }

    // MARK: - MCPFraming.DataReader

    func test_mcpFraming_dataReader_handlesOffsetSliceInput() throws {
        let body = Data(#"{"jsonrpc":"2.0","method":"ping","params":{}}"#.utf8)
        let framed = MCPFraming.encode(body: body)
        let sliced = offsetSlice(of: framed)

        var reader = MCPFraming.DataReader(sliced)
        let decoded = try MCPFraming.decode(from: &reader)
        XCTAssertEqual(decoded, body)
    }

    func test_mcpFraming_dataReader_handlesOffsetSliceMultipleMessages() throws {
        let a = Data(#"{"a":1}"#.utf8)
        let b = Data(#"{"b":[true,false,null]}"#.utf8)
        let c = Data(#"{"c":"a string with \"quotes\""}"#.utf8)
        var combined = Data()
        combined.append(MCPFraming.encode(body: a))
        combined.append(MCPFraming.encode(body: b))
        combined.append(MCPFraming.encode(body: c))

        let sliced = offsetSlice(of: combined, prefix: 13)
        var reader = MCPFraming.DataReader(sliced)
        XCTAssertEqual(try MCPFraming.decode(from: &reader), a)
        XCTAssertEqual(try MCPFraming.decode(from: &reader), b)
        XCTAssertEqual(try MCPFraming.decode(from: &reader), c)
        XCTAssertNil(try MCPFraming.decode(from: &reader),
                     "fourth read on drained reader must be clean EOF")
    }

    func test_mcpFraming_dataReader_readByteAndReadExactly_consistentAcrossOffset() throws {
        // Mix `readByte` (used for headers) and `read(exactly:)` (used
        // for bodies). Both must agree on the byte sequence whether
        // fed a fresh buffer or an offset slice.
        let payload = Data((0..<128).map { UInt8($0) })
        let sliced = offsetSlice(of: payload)

        var freshReader = MCPFraming.DataReader(payload)
        var slicedReader = MCPFraming.DataReader(sliced)

        // Peel off a few bytes via readByte, then read the rest in bulk.
        for _ in 0..<5 {
            let fb = try freshReader.readByte()
            let sb = try slicedReader.readByte()
            XCTAssertEqual(fb, sb)
        }
        let freshRest = try freshReader.read(exactly: payload.count - 5)
        let slicedRest = try slicedReader.read(exactly: payload.count - 5)
        XCTAssertEqual(freshRest, slicedRest)
        XCTAssertEqual(freshRest, payload.suffix(from: 5))
    }

    // MARK: - ClaudeLogParser

    func test_claudeLogParser_parse_handlesOffsetSliceData() {
        let line1 = #"{"type":"user","timestamp":"2026-05-29T12:00:00Z","message":{"role":"user","content":"hello"}}"#
        let line2 = #"{"type":"assistant","timestamp":"2026-05-29T12:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"world"}]}}"#
        let jsonl = (line1 + "\n" + line2 + "\n").data(using: .utf8)!
        let sliced = offsetSlice(of: jsonl, prefix: 11)

        let parser = ClaudeLogParser()
        let fresh = parser.parse(jsonl)
        let offset = parser.parse(sliced)

        XCTAssertEqual(fresh.count, 2)
        XCTAssertEqual(offset.count, fresh.count,
                       "parser must yield the same event count for an offset slice")
        for (l, r) in zip(fresh, offset) {
            // Event IDs from `uuid`/`id` fields are stable; comparing
            // the kind directly is the load-bearing assertion — if the
            // slice-offset bug were triggering, the slice case would
            // see corrupt JSON bytes and yield zero events (or wrong
            // text payloads).
            XCTAssertEqual(l.kind, r.kind)
        }
    }

    func test_claudeLogParser_parse_trailingLineWithoutNewline_handlesOffsetSlice() {
        // The trailing-line branch of `parse` is a separate
        // `data.subdata(in:)` call; cover it explicitly.
        let only = #"{"type":"user","message":{"role":"user","content":"trailing"}}"#
        let jsonl = only.data(using: .utf8)!
        let sliced = offsetSlice(of: jsonl, prefix: 3)

        let parser = ClaudeLogParser()
        let fresh = parser.parse(jsonl)
        let offset = parser.parse(sliced)

        XCTAssertEqual(fresh.count, 1)
        XCTAssertEqual(offset.count, fresh.count)
        XCTAssertEqual(offset.first?.kind, fresh.first?.kind)
    }
}
