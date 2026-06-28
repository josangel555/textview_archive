import XCTest
@testable import RustCore

/// Recursion-depth-cap coverage for the Swift-side wire decoder (TSK-965, the
/// C1 critical). `MsgPackReader.decode()` recurses one native stack frame per
/// `array`/`map` container level. The live remote path (`RemoteTransport`)
/// admits an envelope of up to 16 MiB and hands it straight to `decode()`; a
/// sub-16 MiB body of repeated `0x91` (fixarray-of-1) tags is ~8M containers
/// deep, which BEFORE the fix overflowed the native stack -> signal 139
/// (SIGSEGV), an UNCATCHABLE remote DoS. The cap turns that into a typed,
/// catchable `MsgPackError.tooDeep`.
///
/// Pure logic, host-safe (no VM, no window) — exactly the slice the directive
/// wants regression-guarded on the merge gate.
final class MsgPackDecoderDepthCapTests: XCTestCase {

    /// Build a frame of `count` nested `0x91` (fixarray length-1) tags wrapping
    /// a single `0xc0` (nil) terminator: `0x91 0x91 ... 0x91 0xc0`. This is a
    /// fully VALID MessagePack value — `count` levels of single-element arrays
    /// around a nil — so the ONLY reason to reject it is the depth cap, mirroring
    /// the Rust core's `deeply_nested_input_is_bounded_not_overflowed` test.
    private func nestedFixarrays(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0x91, count: count)
        bytes.append(0xc0) // innermost element: nil
        return bytes
    }

    // MARK: - RED-then-GREEN teeth: overflow becomes a typed throw

    func test_decode_nestingFarBeyondCap_throwsTooDeep_notSIGSEGV() {
        // Well past the cap but a tiny buffer — the whole point is that depth,
        // not byte count, is what's bounded. On UNFIXED code this same input
        // SIGSEGVs the test process at ~8M; here we use a count comfortably
        // over the cap so the throw fires deterministically and instantly.
        let bytes = nestedFixarrays(MsgPackReader.maxDepth + 5_000)
        var reader = MsgPackReader(bytes)
        XCTAssertThrowsError(try reader.decode()) { err in
            XCTAssertEqual(err as? MsgPackError, .tooDeep,
                           "deeply-nested frame must throw .tooDeep, not crash")
        }
    }

    func test_decode_oneOverCap_throwsTooDeep() {
        // The exact failing boundary: maxDepth + 1 containers must be rejected.
        let bytes = nestedFixarrays(MsgPackReader.maxDepth + 1)
        var reader = MsgPackReader(bytes)
        XCTAssertThrowsError(try reader.decode()) { err in
            XCTAssertEqual(err as? MsgPackError, .tooDeep)
        }
    }

    func test_decode_pathologicalRemoteSizedFrame_throwsTooDeep_doesNotCrash() {
        // A realistic attack shape: a large run of container tags such as could
        // ride inside the admitted 16 MiB envelope. If the cap were absent this
        // would recurse 200k frames deep and blow the stack; with it, the very
        // first over-cap level throws before any deep descent, so the buffer
        // size is irrelevant. Reaching this assertion at all proves no crash.
        let bytes = nestedFixarrays(200_000)
        var reader = MsgPackReader(bytes)
        XCTAssertThrowsError(try reader.decode()) { err in
            XCTAssertEqual(err as? MsgPackError, .tooDeep)
        }
    }

    // MARK: - Boundary: nesting exactly AT the cap still decodes

    func test_decode_nestingExactlyAtCap_decodesSuccessfully() {
        // `maxDepth` nested single-element arrays around a nil is the deepest
        // legal value; it must round-trip to the fully-nested structure, proving
        // the cap rejects only what's strictly deeper than the limit.
        let bytes = nestedFixarrays(MsgPackReader.maxDepth)
        var reader = MsgPackReader(bytes)
        let decoded = try? reader.decode()
        XCTAssertNotNil(decoded, "nesting at exactly maxDepth must decode")

        // Walk the result: each level is a 1-element array; the floor is nil.
        var level = 0
        var cursor = decoded
        while case let .array(inner)? = cursor {
            XCTAssertEqual(inner.count, 1, "each level is a single-element array")
            cursor = inner.first
            level += 1
        }
        XCTAssertEqual(level, MsgPackReader.maxDepth,
                       "must have unwound exactly maxDepth array levels")
        XCTAssertEqual(cursor, .nilValue, "innermost element is nil")
    }

    func test_decode_maps_nestingExactlyAtCap_decodesSuccessfully() {
        // Same boundary via the map recursion path: maxDepth nested fixmaps
        // {nil: <child>}, innermost value nil. 0x81 = fixmap len 1, key 0xc0.
        var bytes: [UInt8] = []
        for _ in 0..<MsgPackReader.maxDepth {
            bytes.append(0x81) // fixmap, 1 pair
            bytes.append(0xc0) // key: nil
        }
        bytes.append(0xc0) // innermost value: nil
        var reader = MsgPackReader(bytes)
        XCTAssertNotNil(try? reader.decode(),
                        "map nesting at exactly maxDepth must decode")
    }

    func test_decode_maps_oneOverCap_throwsTooDeep() {
        var bytes: [UInt8] = []
        for _ in 0..<(MsgPackReader.maxDepth + 1) {
            bytes.append(0x81)
            bytes.append(0xc0)
        }
        bytes.append(0xc0)
        var reader = MsgPackReader(bytes)
        XCTAssertThrowsError(try reader.decode()) { err in
            XCTAssertEqual(err as? MsgPackError, .tooDeep)
        }
    }

    // MARK: - Shallow real-shaped responses are unaffected

    func test_decode_typicalShallowEnvelope_unaffectedByCap() {
        // A realistic envelope shape (map with a nested array-of-arrays body)
        // is only ~depth 3 — far under the cap — and must decode untouched, so
        // the guard never penalizes legitimate core responses.
        let v = MsgPackValue.map([
            MsgPackPair(.string("t"), .string("r")),
            MsgPackPair(.string("rows"), .array([
                .array([.string("a"), .string("b")]),
                .array([.string("c"), .string("d")]),
            ])),
        ])
        var reader = MsgPackReader(v.encode())
        XCTAssertEqual(try? reader.decode(), v)
    }
}
