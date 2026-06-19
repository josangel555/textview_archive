import XCTest
@testable import RustCore

/// TSK-826: the FFI receive path used to copy every response frame TWICE —
/// once into `Array(UnsafeBufferPointer(...))` (the whole framed buffer), then
/// again via `unframe`'s `Array(frame[4...])` to strip the 4-byte length
/// prefix. `CsvSession.copyFrameBody` collapses that to ONE copy off the raw
/// FFI buffer: it validates the LE length prefix in place and copies only the
/// body subrange `[4..<len]`.
///
/// These pin: (1) the copied body is byte-identical to the framed body;
/// (2) the prefix is still validated (corrupt / short frames throw, never
/// mis-offset); (3) the decode path accepts a non-zero base offset (the
/// `MsgPackReader(_, startingAt:)` in-place twin used by the aux path); and
/// (4) a >1 MB frame round-trips through the single-copy helper unchanged.
final class FrameBodySingleCopyTests: XCTestCase {

    /// Frame a body and run it through the single-copy unframe the FFI path uses.
    private func bodyViaCopyFrameBody(_ frame: [UInt8]) throws -> [UInt8] {
        try frame.withUnsafeBufferPointer { p in
            try CsvSession.copyFrameBody(p.baseAddress!, p.count)
        }
    }

    // MARK: - Byte-identity

    func test_copyFrameBody_returnsBodyByteIdentical() throws {
        let body: [UInt8] = [0x93, 0x01, 0x02, 0x03]  // fixarray [1,2,3]
        let frame = MsgPackFraming.frame(body)
        let copied = try bodyViaCopyFrameBody(frame)
        XCTAssertEqual(copied, body, "the single copy must reproduce the body exactly")
    }

    func test_copyFrameBody_matchesLegacyUnframe() throws {
        // The new single-copy path and the legacy double-copy `unframe` must
        // agree on the body bytes for an arbitrary payload.
        let body = (0..<512).map { UInt8($0 & 0xff) }
        let frame = MsgPackFraming.frame(body)
        let viaCopy = try bodyViaCopyFrameBody(frame)
        let viaUnframe = try CsvSession.unframe(frame)
        XCTAssertEqual(viaCopy, viaUnframe)
        XCTAssertEqual(viaCopy, body)
    }

    func test_copyFrameBody_emptyBody_returnsEmpty() throws {
        // A length-0 body (declared 0, frame is just the 4-byte prefix).
        let frame = MsgPackFraming.frame([])
        XCTAssertEqual(frame.count, 4)
        XCTAssertEqual(try bodyViaCopyFrameBody(frame), [])
    }

    // MARK: - Prefix validation (teeth: must not silently mis-offset)

    func test_copyFrameBody_rejectsCorruptLengthPrefix() throws {
        var bad = MsgPackFraming.frame([0x01, 0x02, 0x03])
        bad[0] = bad[0] &+ 1  // declared length no longer matches the body
        XCTAssertThrowsError(try bodyViaCopyFrameBody(bad)) { err in
            guard case CoreError.decode = err else {
                return XCTFail("expected a decode fault, got \(err)")
            }
        }
    }

    func test_copyFrameBody_rejectsShortFrame() throws {
        let short: [UInt8] = [0x00, 0x00, 0x00]  // fewer than 4 prefix bytes
        XCTAssertThrowsError(
            try short.withUnsafeBufferPointer { p in
                try CsvSession.copyFrameBody(p.baseAddress!, p.count)
            }
        ) { err in
            guard case CoreError.decode = err else {
                return XCTFail("expected a decode fault, got \(err)")
            }
        }
    }

    // MARK: - Non-zero base offset decode (MsgPackReader startingAt)

    func test_msgPackReader_decodesFromNonZeroOffset() throws {
        // The aux path (hex search) and the table/snapshot decoders read the
        // body IN PLACE from offset 4, never re-materializing `frame[4...]`.
        let value = MsgPackValue.map([
            (.string("offsets"), .array([.uint(10), .uint(20), .uint(30)])),
        ])
        let frame = value.frame()
        let offset = try CsvSession.frameBodyStart(frame)
        XCTAssertEqual(offset, 4)
        var reader = MsgPackReader(frame, startingAt: offset)
        let map = try reader.decode().mapValue()
        XCTAssertEqual(try map.require("offsets").u32Array(), [10, 20, 30])
        try reader.finish()  // body fully consumed from the offset to frame end
    }

    func test_offsetDecode_equalsZeroBasedDecodeOfBody() throws {
        // Decoding the whole frame from offset 4 yields the same value tree as
        // decoding the copied body from offset 0.
        let value = MsgPackValue.map([
            (.string("a"), .string("hello")),
            (.string("b"), .array([.int(-1), .int(-2)])),
        ])
        let frame = value.frame()
        let body = try bodyViaCopyFrameBody(frame)

        var offsetReader = MsgPackReader(frame, startingAt: try CsvSession.frameBodyStart(frame))
        let fromOffset = try offsetReader.decode()

        var bodyReader = MsgPackReader(body)
        let fromBody = try bodyReader.decode()

        XCTAssertEqual(fromOffset, fromBody)
        XCTAssertEqual(fromOffset, value)
    }

    // MARK: - Large frame (>1 MB) single-copy round trip

    func test_copyFrameBody_largeFrame_overOneMiB_roundTrips() throws {
        // A body well past 1 MiB exercises the path the double copy was most
        // wasteful on (a >1 MB markdown/find/transcript response). The helper
        // copies it exactly once; assert the body survives byte-for-byte.
        let n = 1_500_000
        let body = (0..<n).map { UInt8(($0 * 31 + 7) & 0xff) }
        XCTAssertGreaterThan(body.count, 1 << 20)
        let frame = MsgPackFraming.frame(body)
        XCTAssertEqual(frame.count, body.count + 4)

        let copied = try bodyViaCopyFrameBody(frame)
        XCTAssertEqual(copied.count, body.count)
        XCTAssertEqual(copied, body)
        // The legacy double-copy path must agree (no behavior drift on size).
        XCTAssertEqual(copied, try CsvSession.unframe(frame))
    }

    func test_largeFrame_msgPackPayload_decodesIdentically_fromOffsetAndBody() throws {
        // A large structural payload (a big string array) — the realistic
        // shape of a snapshot/find response — must decode to the same tree via
        // the in-place offset reader and via the single-copied body.
        let rows = (0..<50_000).map { MsgPackValue.string("row-\($0)-payload-padding-bytes") }
        let value = MsgPackValue.map([(.string("rows"), .array(rows))])
        let frame = value.frame()
        XCTAssertGreaterThan(frame.count, 1 << 20)

        var offsetReader = MsgPackReader(frame, startingAt: try CsvSession.frameBodyStart(frame))
        let fromOffset = try offsetReader.decode()

        let body = try bodyViaCopyFrameBody(frame)
        var bodyReader = MsgPackReader(body)
        let fromBody = try bodyReader.decode()

        XCTAssertEqual(fromOffset, fromBody)
        XCTAssertEqual(try fromBody.mapValue().require("rows").arrayValue().count, rows.count)
    }
}
