import XCTest
@testable import RustCore

/// Negative / fuzz coverage for the Swift-side wire decoder — the explicitly
/// flagged "protocol version skew" attack surface on the FFI boundary
/// (`MsgPackReader` + `CsvSession.unframe`). Every other Swift test exercises
/// only happy-path round-trips; this suite hand-crafts malformed byte arrays
/// per failure mode and asserts each throws the SPECIFIC error in the
/// `MsgPackError` / `CoreError` taxonomy, so a future wire-format bump or
/// corrupt buffer surfaces as a typed `throw`, never a crash or silent-wrong.
///
/// Filed for audit findings on `Sources/RustCore/MessagePack.swift`
/// (S3 test-gap, S3 contract OOM-guard, S3 perf no-Array decode, S4 finish()).
final class MsgPackDecoderNegativeAuditTests: XCTestCase {

    // MARK: - decode() helper that always closes over a throw

    private func expectDecodeThrows(
        _ bytes: [UInt8],
        _ expected: MsgPackError,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var reader = MsgPackReader(bytes)
        XCTAssertThrowsError(try reader.decode(), file: file, line: line) { err in
            XCTAssertEqual(err as? MsgPackError, expected,
                           "wrong error for \(bytes)", file: file, line: line)
        }
    }

    // MARK: - Frame layer (CsvSession.unframe)

    func test_unframe_shorterThanLengthPrefix_throwsDecode() {
        // 3 bytes < the mandatory 4-byte u32-LE length prefix.
        XCTAssertThrowsError(try CsvSession.unframe([0x00, 0x00, 0x00])) { err in
            XCTAssertEqual(err as? CoreError, .decode("frame shorter than length prefix"))
        }
    }

    func test_unframe_declaredLengthDisagreesWithBody_throwsDecode() {
        // Prefix declares 4 body bytes; only 1 follows.
        let frame: [UInt8] = [0x04, 0x00, 0x00, 0x00, 0xc0]
        XCTAssertThrowsError(try CsvSession.unframe(frame)) { err in
            guard case let .decode(msg)? = err as? CoreError else {
                return XCTFail("expected CoreError.decode, got \(err)")
            }
            XCTAssertTrue(msg.contains("frame length"), "msg was: \(msg)")
        }
    }

    func test_unframe_emptyDeclaredEmptyBody_roundTripsToEmptyBody() {
        // Boundary: a 4-byte frame declaring a zero-length body is valid and
        // yields an empty body (the legitimate "no payload" frame).
        XCTAssertEqual(try CsvSession.unframe([0x00, 0x00, 0x00, 0x00]), [])
    }

    // MARK: - Truncation (str / map / array running past EOF)

    func test_str8_tagPastEOF_throwsTruncated() {
        // 0xd9 = str8, declares 5 bytes, body provides only 2.
        expectDecodeThrows([0xd9, 0x05, 0x61, 0x62], .truncated)
    }

    func test_fixstr_pastEOF_throwsTruncated() {
        // 0xa3 = fixstr len 3, but only 1 byte follows.
        expectDecodeThrows([0xa3, 0x61], .truncated)
    }

    func test_fixmap_claimingPairWithEmptyBody_throwsTruncated() {
        // 0x81 = fixmap with 1 pair, but nothing follows -> key read truncates.
        expectDecodeThrows([0x81], .truncated)
    }

    func test_fixmap_pairWithKeyButNoValue_throwsTruncated() {
        // 0x81 key="a" (0xa1 0x61) then nothing -> value read truncates.
        expectDecodeThrows([0x81, 0xa1, 0x61], .truncated)
    }

    func test_fixarray_claimingElementWithEmptyBody_throwsTruncated() {
        // 0x91 = fixarray of 1, no element follows.
        expectDecodeThrows([0x91], .truncated)
    }

    func test_uint16_payloadTruncated_throwsTruncated() {
        // 0xcd = uint16, needs 2 payload bytes, only 1 present.
        expectDecodeThrows([0xcd, 0x00], .truncated)
    }

    func test_uint64_payloadTruncated_throwsTruncated() {
        // 0xcf = uint64, needs 8, gives 3.
        expectDecodeThrows([0xcf, 0x00, 0x00, 0x00], .truncated)
    }

    func test_emptyBuffer_throwsTruncated() {
        expectDecodeThrows([], .truncated)
    }

    // MARK: - Unsupported / reserved tag

    func test_reservedTag_0xc1_throwsUnsupportedTag() {
        // 0xc1 is the single never-used MessagePack byte — the canonical
        // "this is not valid msgpack" sentinel.
        expectDecodeThrows([0xc1], .unsupportedTag(0xc1))
    }

    // MARK: - OOM-abort guard (S3 contract): the clamp must keep a huge
    // declared count from aborting; the read loop then fails cleanly.

    func test_array32_hugeDeclaredCount_shortBody_throwsTruncated_doesNotAbort() {
        // 0xdd = array32 declaring 0xFFFFFFFF (~4.29e9) elements; only one real
        // element follows. Pre-fix this drove reserveCapacity(4.29e9) -> ~34 GB
        // alloc -> host abort BEFORE any element read. With the clamp it must
        // instead throw .truncated once the body is exhausted.
        let bytes: [UInt8] = [0xdd, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
        expectDecodeThrows(bytes, .truncated)
    }

    func test_map32_hugeDeclaredCount_shortBody_throwsTruncated_doesNotAbort() {
        // 0xdf = map32 declaring 0xFFFFFFFF pairs; empty body.
        let bytes: [UInt8] = [0xdf, 0xFF, 0xFF, 0xFF, 0xFF]
        expectDecodeThrows(bytes, .truncated)
    }

    // MARK: - Typed-accessor contract (mapValue / require / *Value)

    func test_missingRequiredKey_throwsMissingKey() {
        // A valid 1-pair map {"a": nil} that lacks the required key "delimiter".
        let v = MsgPackValue.map([MsgPackPair(.string("a"), .nilValue)])
        var reader = MsgPackReader(v.encode())
        XCTAssertThrowsError(try reader.decode().mapValue().require("delimiter")) { err in
            XCTAssertEqual(err as? MsgPackError, .missingKey("delimiter"))
        }
    }

    func test_typeMismatch_mapValueOnNonMap_throwsTypeMismatch() {
        var reader = MsgPackReader(MsgPackValue.string("not a map").encode())
        XCTAssertThrowsError(try reader.decode().mapValue()) { err in
            XCTAssertEqual(err as? MsgPackError, .typeMismatch("expected map"))
        }
    }

    func test_typeMismatch_stringValueOnInt_throwsTypeMismatch() {
        var reader = MsgPackReader(MsgPackValue.uint(7).encode())
        XCTAssertThrowsError(try reader.decode().stringValue()) { err in
            XCTAssertEqual(err as? MsgPackError, .typeMismatch("expected string"))
        }
    }

    func test_typeMismatch_negativeWhereU64Expected_throwsTypeMismatch() {
        var reader = MsgPackReader(MsgPackValue.int(-1).encode())
        XCTAssertThrowsError(try reader.decode().u64Value()) { err in
            XCTAssertEqual(err as? MsgPackError, .typeMismatch("expected non-negative int"))
        }
    }

    // MARK: - finish() end-of-stream check (S4 quality)

    func test_finish_afterFullConsumption_succeeds() {
        let body = MsgPackValue.map([MsgPackPair(.string("k"), .uint(1))]).encode()
        var reader = MsgPackReader(body)
        XCTAssertNoThrow(try reader.decode())
        XCTAssertNoThrow(try reader.finish(), "fully-consumed body must pass finish()")
    }

    func test_finish_withTrailingBytes_throwsTypeMismatch() {
        // One valid value (nil) followed by an extra stray byte. decode()
        // consumes only the nil; finish() must reject the trailing byte.
        var reader = MsgPackReader([0xc0, 0x2a])
        XCTAssertNoThrow(try reader.decode())
        XCTAssertThrowsError(try reader.finish()) { err in
            XCTAssertEqual(err as? MsgPackError, .typeMismatch("trailing bytes"))
        }
    }

    func test_finish_onEmptyBeforeDecode_throwsForNonEmptyBody() {
        // Calling finish() without consuming a non-empty body must throw.
        var reader = MsgPackReader([0xc0])
        XCTAssertThrowsError(try reader.finish()) { err in
            XCTAssertEqual(err as? MsgPackError, .typeMismatch("trailing bytes"))
        }
    }

    // MARK: - Perf path still decodes correctly (no-Array str/int rewrite)

    func test_str_withMultiByteUTF8_decodesCorrectly_afterNoArrayRewrite() {
        // Guards the String(decoding:as:) + direct-index rewrite: a multi-byte
        // UTF-8 fixstr must still decode to the exact string.
        let v = MsgPackValue.string("é日🧠")
        var reader = MsgPackReader(v.encode())
        XCTAssertEqual(try? reader.decode(), v)
    }

    func test_multiByteInts_decodeCorrectly_afterInlineLoopRewrite() {
        // Guards the uintN/intN inline-index rewrite across widths.
        for v: MsgPackValue in [.uint(0xff), .uint(0xffff), .uint(0xffff_ffff),
                                .uint(UInt64.max), .int(-128), .int(-32768),
                                .int(-2_147_483_648), .int(Int64.min)] {
            var reader = MsgPackReader(v.encode())
            XCTAssertEqual(try? reader.decode(), v, "round-trip failed for \(v)")
        }
    }
}
