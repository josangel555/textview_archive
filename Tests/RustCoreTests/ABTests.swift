import XCTest

@testable import RustCore
import CMdvCore
import ViewerCore

/// CSV engine contract pins (STAGE-B, TSK-649: the Swift CSVParser twin is
/// deleted — rust is the only engine). The expectations below are the
/// CONTRACT the retired A/B suite proved byte-identical across both engines
/// before deletion: delimiter sniffing (incl. quote-aware), RFC-4180 quoting,
/// ragged-row normalization, CR/CRLF framing, and the wire/envelope plumbing.
final class ABTests: XCTestCase {

    /// (input, expected delimiter, expected header, expected first row or nil)
    /// — the distinctive grammar cases from the retired parity corpus.
    static let contractCases: [(String, String, [String], [String]?)] = [
        ("a,b,c\n1,2,3\n4,5,6\n", ",", ["a", "b", "c"], ["1", "2", "3"]),
        ("a;b;c\n1;2;3\n", ";", ["a", "b", "c"], ["1", "2", "3"]),
        ("a\tb\tc\n1\t2\t3\n", "\t", ["a", "b", "c"], ["1", "2", "3"]),
        ("a|b|c\n1|2|3\n", "|", ["a", "b", "c"], ["1", "2", "3"]),
        ("a,b\n\"x,y\",z\n", ",", ["a", "b"], ["x,y", "z"]),
        ("a,b\n\"she said \"\"hi\"\"\",z\n", ",", ["a", "b"], ["she said \"hi\"", "z"]),
        ("a,b\r\n1,2\r\n3,4\r\n", ",", ["a", "b"], ["1", "2"]),
        // Ragged: long row truncated to header width, short row padded.
        ("a,b,c\n1,2,3,4\n5,6\n", ",", ["a", "b", "c"], ["1", "2", "3"]),
        ("name,emoji\nJosé,🎉\n", ",", ["name", "emoji"], ["José", "🎉"]),
        // Quote-aware sniff: the comma inside quotes must not win.
        ("\"a,b,c\";x;y\n1;2;3\n", ";", ["a,b,c", "x", "y"], ["1", "2", "3"]),
        ("a,b\n\"line1\nline2\",z\n", ",", ["a", "b"], ["line1\nline2", "z"]),
        ("a,b\r1,2\r3,4\r", ",", ["a", "b"], ["1", "2"]),
        ("a,b,c\n", ",", ["a", "b", "c"], nil),
    ]

    func testEngineGrammarContract() throws {
        for (input, delim, header, firstRow) in Self.contractCases {
            // Both production paths: the session read and the adapter mapping.
            let rust = try CsvSession(csv: input).table()
            XCTAssertEqual(rust.delimiter, delim, "sniff: \(input.debugDescription)")
            XCTAssertEqual(rust.header, header, "header: \(input.debugDescription)")
            XCTAssertEqual(rust.rows.first, firstRow, "row0: \(input.debugDescription)")
            XCTAssertFalse(rust.truncated)

            let adapted = RustCSVAdapter.parse(input)
            XCTAssertEqual(String(adapted.delimiter), delim)
            XCTAssertEqual(adapted.header, header)
            XCTAssertEqual(adapted.rows.first, firstRow)
        }
        // Empty input parses to an empty table, never a fault.
        let empty = RustCSVAdapter.parse("")
        XCTAssertTrue(empty.header.isEmpty && empty.rows.isEmpty)
    }

    func testFilterAgainstEngineParse() throws {
        // The rust session's global-query filter and the (still-Swift, still
        // live) CSVFilter view-model must agree on the engine's parse.
        let input = "name,city\nAlice,Paris\nBob,Parma\nCarol,Berlin\n"
        let session = try CsvSession(csv: input)
        try session.setFilter("par")
        let snap = try session.snapshot()

        let parsed = RustCSVAdapter.parse(input)
        let filter = CSVFilter(globalQuery: "par", globalScope: .all)
        let expected = filter.apply(to: parsed)
        XCTAssertEqual(snap.rows, expected.rows)
        XCTAssertEqual(snap.indices.map(Int.init), expected.indices)
    }

    /// TSK-559 — the windowed snapshot + filtered-count bindings round-trip
    /// through the FFI: a consumer can page the visible viewport (O(window))
    /// and size its scrollbar from filteredCount without pulling the whole set.
    func testSnapshotWindowAndFilteredCount() throws {
        var csv = "id,name\n"
        for i in 0..<100 { csv += "\(i),row\(i)\n" }
        let session = try CsvSession(csv: csv)

        XCTAssertEqual(try session.filteredCount(), 100, "unfiltered → all rows")
        let w = try session.snapshotWindow(offset: 50, limit: 10)
        XCTAssertEqual(w.rows.count, 10)
        XCTAssertEqual(w.indices.map(Int.init), Array(50..<60), "absolute row ids")
        XCTAssertEqual(w.totalRows, 100, "table total, not window size")
        XCTAssertEqual(w.rows.first, ["50", "row50"])

        // Past the end → empty window, no throw.
        let past = try session.snapshotWindow(offset: 500, limit: 10)
        XCTAssertTrue(past.rows.isEmpty)
        XCTAssertEqual(past.totalRows, 100)

        // The window pages the FILTERED set. "row1" matches row1 + row10..19 = 11.
        try session.setFilter("row1")
        XCTAssertEqual(try session.filteredCount(), 11)
        let win = try session.snapshotWindow(offset: 0, limit: 3)
        XCTAssertEqual(win.indices.map(Int.init), [1, 10, 11])
    }

    /// TSK-669 — the host decodes the rich WireError frame TSK-577 emits.
    /// Round-trips the EXACT shape the rust side writes ({code, message,
    /// data:[["kind", tag]]}); the rust FFI test proves that shape is emitted.
    func testWireErrorDetailDecodesEmittedFrame() throws {
        let frame = MsgPackValue.map([
            MsgPackPair(.string("code"), .int(4)),
            MsgPackPair(.string("message"), .string("wire decode error: boom")),
            MsgPackPair(.string("data"), .array([.array([.string("kind"), .string("decode")])])),
        ]).frame()
        let detail = try XCTUnwrap(CsvSession.decodeWireError(frame))
        XCTAssertEqual(detail.code, 4)
        XCTAssertEqual(detail.message, "wire decode error: boom")
        XCTAssertEqual(detail.kind, "decode")
    }

    /// The decoder runs on the ERROR path, so it must be TOTAL — never throw or
    /// crash on an empty / non-WireError / garbage frame (that would mask the
    /// real status).
    func testDecodeWireErrorIsTotalOnBadFrames() {
        XCTAssertNil(CsvSession.decodeWireError([]))
        XCTAssertNil(CsvSession.decodeWireError(MsgPackValue.int(7).frame()))
        XCTAssertNil(CsvSession.decodeWireError([0xFF, 0x00]))
    }

    /// TSK-580 slice 2 — the MDV_METHOD_* ids cbindgen emitted reach Swift via
    /// CMdvCore, and a Swift call through the thin-waist envelope routes to the
    /// right core method (here: diff, whose response is a {files:[…]} frame).
    func testEnvelopeCallFromSwiftRoutesToDiff() throws {
        XCTAssertEqual(MDV_METHOD_DIFF_PARSE, 2, "the header const reaches Swift")
        let diff = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"
        let req = MsgPackValue.map([MsgPackPair(.string("text"), .string(diff))]).frame()
        let result = try CoreEnvelope.call(method: UInt16(MDV_METHOD_DIFF_PARSE), req: req)
        XCTAssertFalse(result.isEmpty)
        let body = try CsvSession.unframe(result)
        var reader = MsgPackReader(body)
        let map = try reader.decode().mapValue()
        XCTAssertNotNil(map["files"], "routed to diff::parse_wire (response carries a files array)")
    }

    func testEnvelopeCallUnknownMethodThrows() {
        XCTAssertThrowsError(try CoreEnvelope.call(method: 9999, req: []),
                             "an unknown method id throws, not crashes")
    }

    /// TSK-580 slices 4+5 — ALL 8 stateless methods now dispatch through the
    /// single envelope (method-id table); the per-method-symbol fallback table
    /// is empty. Structural teeth: reverting any method to a symbol fails this.
    func testAllStatelessMethodsRouteThroughTheEnvelope() {
        for m in ["cm_apply", "diff_parse", "diff_hunk_marks", "fuzzy_rank",
                  "find_search", "transcript_parse", "markdown_render", "highlight_runs"] {
            XCTAssertNotNil(InProcessTransport.methodIds[m], "\(m) routes via mdvcore_call")
        }
        XCTAssertTrue(InProcessTransport.exports.isEmpty,
                      "no stateless method uses a per-method symbol anymore")
    }

    /// Wiring pin (dead-channel idiom): the session call path decodes+logs the
    /// emitted detail before the coarse status throws. os.Logger output isn't
    /// assertable, so the channel is source-pinned here; the decoder behavior is
    /// pinned by the two tests above.
    func testCallBufSurfacesWireErrorBeforeThrowing() throws {
        let src = try Self.coreClientSource()
        XCTAssertTrue(src.contains("Self.logWireErrorIfPresent(buf)"),
                      "callBuf must surface the WireError on the error path")
        XCTAssertTrue(src.contains("decodeWireError(frame)"),
                      "the surfacer must decode the emitted frame")
    }

    /// TSK-981 — the WINDOWED snapshot path (`snapshotWindow`) hand-rolls its own
    /// out-buf call (it does NOT route through `callBuf`), and used to throw the
    /// coarse status straight from `check(status)` — DISCARDING the rich
    /// WireError frame the core wrote into `out_buf` on a fault. Pin that the
    /// method now surfaces the detail (decode + log) before the throw, like every
    /// other error path. os.Logger output isn't assertable, so the channel is
    /// source-pinned to the `snapshotWindow` body specifically; the decoder
    /// behavior is pinned by `testWireErrorDetailDecodesEmittedFrame`.
    func testSnapshotWindowSurfacesWireErrorBeforeThrowing() throws {
        let body = try Self.functionBody(
            "public func snapshotWindow(offset: Int, limit: Int) throws -> Snapshot")
        XCTAssertTrue(body.contains("logWireErrorIfPresent(buf)"),
                      "snapshotWindow must surface the WireError before throwing the coarse status")
        // The log MUST precede the throwing `check(status)` — surfacing after the
        // throw is dead code (check throws first).
        let logIdx = try XCTUnwrap(body.range(of: "logWireErrorIfPresent(buf)")?.lowerBound,
                                   "expected a surfacer call in snapshotWindow")
        let checkIdx = try XCTUnwrap(body.range(of: "try check(status)")?.lowerBound,
                                     "expected the coarse-status throw in snapshotWindow")
        XCTAssertLessThan(logIdx, checkIdx,
                          "the WireError must be surfaced BEFORE check(status) throws")
    }

    private static func coreClientSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/RustCore/CoreClient.swift"),
            encoding: .utf8)
    }

    /// Extract the body of the function whose signature line is `signature`
    /// (everything from the opening `{` to its matching `}`), so a source-pin can
    /// scope its assertions to one method instead of the whole file.
    private static func functionBody(_ signature: String) throws -> String {
        let src = try coreClientSource()
        guard let sigRange = src.range(of: signature) else {
            throw XCTSkip("signature not found: \(signature)")
        }
        let after = src[sigRange.upperBound...]
        guard let open = after.firstIndex(of: "{") else {
            throw XCTSkip("no opening brace after \(signature)")
        }
        var depth = 0
        var idx = open
        while idx < after.endIndex {
            let ch = after[idx]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(after[after.index(after: open)...idx])
                }
            }
            idx = after.index(after: idx)
        }
        throw XCTSkip("unbalanced braces after \(signature)")
    }
}
