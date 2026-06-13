import XCTest
@testable import RustCore
import ViewerCore

/// TSK-580 slice 3 close-out: the three raw/aux production wrappers
/// (`mdvCoreHexRender`, `mdvCoreHexSearch`, `mdvCoreIndentDetect`) were the last
/// direct callers of their dedicated per-method C symbols; they now route through
/// the thin-waist envelope `mdvcore_call(MDV_METHOD_*, req, aux, out)` via the
/// `mdvEnvelopeCallAux` helper (bulk input rides `aux`, small scalars ride the
/// `req` frame, raw/forme output disambiguated by `MdvStatus`).
///
/// These pin the Swift boundary to the SAME fixed outputs the Rust
/// `envelope_routes_*` A/B tests assert (`crates/ffi/src/tests.rs`) — independent
/// ground truth that each wrapper builds `req`/`aux` correctly and reaches the
/// right dispatch arm. The broader `HexRenderABTests` / `HexSearchABTests` /
/// `IndentDetectABTests` corpora re-verify byte-for-byte parity vs the Swift
/// engines THROUGH this migrated path. TEETH: dropping `aux` in
/// `mdvEnvelopeCallAux` (or a wrong method id / req key) makes the assertions
/// below diverge.
final class EnvelopeRawAuxRoutingTests: XCTestCase {

    func test_indentDetect_routesEnvelope_toKnownStyle() throws {
        // Mirrors envelope_routes_indent_detect_raw_output: text rides aux,
        // {sample_lines} rides req, RAW string out (not a frame).
        XCTAssertEqual(try mdvCoreIndentDetect(text: "    a\n    b\n"), "Spaces (4)")
    }

    func test_hexSearch_routesEnvelope_toKnownOffsets() throws {
        // Mirrors envelope_routes_hex_search_over_the_aux_channel: data rides aux,
        // {query, mode} ride req, a {offsets:[u32]} FRAME out (unframed by the
        // wrapper). 0xDEAD at offsets 0 and 3.
        let data = Data([0xDE, 0xAD, 0x00, 0xDE, 0xAD])
        XCTAssertEqual(try mdvCoreHexSearch(data: data, query: "dead", mode: .hex), [0, 3])
        // No match → empty (the wrapper's nil-buf contract), not a throw.
        XCTAssertEqual(try mdvCoreHexSearch(data: data, query: "beef", mode: .hex), [])
    }

    func test_hexRender_routesEnvelope_toRawBulkDump() throws {
        // Mirrors envelope_routes_hex_render_raw_bulk_output: bytes ride aux,
        // {width, total_byte_count, is_truncated} ride req, RAW dump out. Pin it
        // to the shipping Swift renderer for a concrete input (independent of the
        // dump format) — dropping aux would yield an empty dump that diverges.
        let bytes = Data([0x00, 0x41, 0x7f, 0xff, 0x42])
        let file = BinaryFile(
            url: URL(fileURLWithPath: "/tmp/env-aux-routing"),
            data: bytes, totalByteCount: bytes.count, isTruncated: false)
        let rust = try mdvCoreHexRender(
            bytes: bytes, width: 4, totalByteCount: bytes.count, isTruncated: false)
        XCTAssertFalse(rust.isEmpty, "a non-empty buffer renders a non-empty dump")
        XCTAssertEqual(rust, HexDumpBuilder.buildAll(file: file, width: 4),
                       "envelope-routed render is byte-identical to the Swift engine")
        // Empty input → empty dump, not a throw.
        XCTAssertEqual(
            try mdvCoreHexRender(bytes: Data(), width: 16, totalByteCount: 0, isTruncated: false),
            "")
    }
}
