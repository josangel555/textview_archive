import XCTest
@testable import RustCore
import ViewerCore

/// A/B parity: the Rust core's `mdvcore_hex_render` (via `mdvCoreHexRender`) vs
/// the SHIPPING Swift `HexDumpBuilder.buildAll`, over a corpus spanning every
/// width preset, short final rows (padding), non-printable bytes, all-256 byte
/// values, truncation headers, and empty input. The rendered dump must be
/// byte-identical. Forces the Rust path directly (no gate) — exercises the FFI
/// pointer-in / raw-UTF-8-out path end-to-end.
final class HexRenderABTests: XCTestCase {

    private func file(_ bytes: [UInt8], total: Int? = nil, truncated: Bool = false) -> BinaryFile {
        BinaryFile(
            url: URL(fileURLWithPath: "/tmp/hex-ab"),
            data: Data(bytes),
            totalByteCount: total ?? bytes.count,
            isTruncated: truncated)
    }

    /// Each case: a byte buffer + the width to render at + truncation metadata.
    private func cases() -> [(bytes: [UInt8], width: Int, total: Int, truncated: Bool)] {
        let allBytes = (0...255).map { UInt8($0) }
        let ascii = Array("Hello, HEX viewer! 0123456789".utf8)
        return [
            ([], 16, 0, false),                              // empty
            ([], 16, 4096, true),                            // empty but truncated → header only
            ([0x41], 16, 1, false),                          // single byte, short row
            ([0x41, 0x42, 0x43], 4, 3, false),               // short final row, width 4
            (ascii, 16, ascii.count, false),                 // printable mix, width 16
            (ascii, 32, ascii.count, false),                 // width 32
            (ascii, 64, ascii.count, false),                 // width 64
            (allBytes, 16, 256, false),                      // all byte values (printable/dot)
            (allBytes, 16, 1_000_000, true),                 // truncated header + all bytes
            (Array(repeating: 0x00, count: 40), 16, 40, false), // all-NUL → dots
            (Array(0..<17).map { UInt8($0) }, 16, 17, false),   // exactly width+1 → 2 rows
            (Array(0..<16).map { UInt8($0) }, 16, 16, false),   // exactly one full row
        ]
    }

    func test_rust_matches_swift_across_corpus() throws {
        for c in cases() {
            let f = file(c.bytes, total: c.total, truncated: c.truncated)
            let swift = HexDumpBuilder.buildAll(file: f, width: c.width)
            let rust = try mdvCoreHexRender(
                bytes: f.data, width: c.width,
                totalByteCount: c.total, isTruncated: c.truncated)
            XCTAssertEqual(rust, swift,
                           "parity mismatch for \(c.bytes.count) bytes @ width \(c.width), truncated=\(c.truncated)")
        }
    }

    func test_gate_off_uses_swift_and_matches() {
        let f = file(Array("abc".utf8))
        let o = RustHexAdapter.outcome(file: f, width: 16)
        XCTAssertEqual(o.source, .swiftBecauseGateOff)
        XCTAssertEqual(o.value, HexDumpBuilder.buildAll(file: f, width: 16))
    }
}
