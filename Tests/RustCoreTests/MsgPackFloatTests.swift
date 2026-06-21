import XCTest
@testable import RustCore

/// TSK-1213 — MessagePack float decode/encode. Added for the formula evaluator's
/// numeric values (the first wire type with non-integer numbers); the reader was
/// integer-only before.
final class MsgPackFloatTests: XCTestCase {

    func test_float64_encode_decode_roundtrip() throws {
        for d in [0.0, 1.0, -3.5, 0.15, 1234.5678, 1e10, -1e-10] {
            let bytes = MsgPackValue.double(d).encode()
            var reader = MsgPackReader(bytes)
            let v = try reader.decode()
            try reader.finish()
            XCTAssertEqual(v, .double(d))
            XCTAssertEqual(try v.doubleValue(), d)
        }
    }

    func test_float64_decode_known_bytes() throws {
        // 0xcb + IEEE-754 big-endian bits of 1.5 (0x3FF8000000000000)
        let bytes: [UInt8] = [0xcb, 0x3F, 0xF8, 0, 0, 0, 0, 0, 0]
        var reader = MsgPackReader(bytes)
        XCTAssertEqual(try reader.decode(), .double(1.5))
    }

    func test_float32_decode() throws {
        // 0xca + IEEE-754 big-endian float32 bits of 1.5 (0x3FC00000)
        let bytes: [UInt8] = [0xca, 0x3F, 0xC0, 0, 0]
        var reader = MsgPackReader(bytes)
        XCTAssertEqual(try reader.decode(), .double(1.5))
    }

    func test_doubleValue_accepts_int_forms() throws {
        XCTAssertEqual(try MsgPackValue.uint(7).doubleValue(), 7.0)
        XCTAssertEqual(try MsgPackValue.int(-3).doubleValue(), -3.0)
        XCTAssertEqual(try MsgPackValue.double(2.5).doubleValue(), 2.5)
    }
}
