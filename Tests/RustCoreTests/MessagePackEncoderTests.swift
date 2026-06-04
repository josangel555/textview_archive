import XCTest
@testable import RustCore

/// Round-trip coverage for the Swift→Rust MessagePack encoder (the write path
/// added for Phase-B command dispatch). The invariant: for every supported
/// value, `MsgPackReader(v.encode()).decode() == v` — the encoder is the exact
/// inverse of the shipped reader over the shared subset, across every tag-size
/// boundary.
final class MessagePackEncoderTests: XCTestCase {

    private func roundTrip(_ v: MsgPackValue, file: StaticString = #filePath, line: UInt = #line) {
        var reader = MsgPackReader(v.encode())
        do {
            let decoded = try reader.decode()
            XCTAssertEqual(decoded, v, "round-trip mismatch", file: file, line: line)
        } catch {
            XCTFail("decode threw on encoded value: \(error)", file: file, line: line)
        }
    }

    func test_scalars() {
        roundTrip(.nilValue)
        roundTrip(.bool(true)); roundTrip(.bool(false))
    }

    func test_uint_acrossTagBoundaries() {
        for u: UInt64 in [0, 1, 0x7f, 0x80, 0xff, 0x100, 0xffff, 0x1_0000,
                          0xffff_ffff, 0x1_0000_0000, UInt64.max] {
            roundTrip(.uint(u))
        }
    }

    func test_int_acrossTagBoundaries_caseAndValuePreserved() {
        for i: Int64 in [0, 5, 127, -1, -32, -33, -128, -129, -32768, -32769,
                         -2_147_483_648, -2_147_483_649, Int64.min, Int64.max] {
            roundTrip(.int(i))
        }
    }

    func test_int_vs_uint_casesStayDistinct() {
        // .int(5) and .uint(5) must NOT collapse into each other on round-trip.
        var ri = MsgPackReader(MsgPackValue.int(5).encode())
        var ru = MsgPackReader(MsgPackValue.uint(5).encode())
        XCTAssertEqual(try? ri.decode(), .int(5))
        XCTAssertEqual(try? ru.decode(), .uint(5))
    }

    func test_strings_acrossTagBoundaries() {
        for n in [0, 1, 31, 32, 255, 256, 70000] {
            roundTrip(.string(String(repeating: "x", count: n)))
        }
        roundTrip(.string("héllo · 日本語 · 🧠"))  // multi-byte UTF-8
    }

    func test_array_acrossTagBoundaries() {
        roundTrip(.array([]))
        roundTrip(.array([.uint(1), .string("a"), .bool(true), .nilValue]))
        roundTrip(.array((0..<20).map { .uint(UInt64($0)) }))        // > fixarray(15)
    }

    func test_namedMap_thePhaseB_commandShape() {
        // The shape a Phase-B command serializes to: a named map (string keys),
        // matching the Rust side's to_vec_named.
        let cmd = MsgPackValue.map([
            (.string("op"), .string("setFilter")),
            (.string("scope"), .int(-1)),
            (.string("query"), .string("needle")),
            (.string("limit"), .uint(40)),
            (.string("flags"), .array([.bool(true), .bool(false)])),
        ])
        roundTrip(cmd)
    }

    func test_map_largerThanFixmap() {
        let pairs = (0..<20).map { (MsgPackValue.string("k\($0)"), MsgPackValue.uint(UInt64($0))) }
        roundTrip(.map(pairs))
    }

    func test_nested() {
        roundTrip(.array([
            .map([(.string("rows"), .array([.array([.string("a"), .string("b")])]))]),
            .uint(0xdead_beef),
            .int(-70000),
        ]))
    }

    func test_frame_isU32LELengthPrefixed() {
        let v = MsgPackValue.string("hello")
        let body = v.encode()
        let frame = v.frame()
        XCTAssertEqual(Array(frame.prefix(4)),
                       [UInt8(body.count & 0xff), 0, 0, 0], "u32-LE length prefix")
        XCTAssertEqual(Array(frame.dropFirst(4)), body, "body follows the prefix")
        // And the body still round-trips.
        var reader = MsgPackReader(Array(frame.dropFirst(4)))
        XCTAssertEqual(try? reader.decode(), v)
    }
}
