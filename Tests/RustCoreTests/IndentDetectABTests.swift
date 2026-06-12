import XCTest
@testable import RustCore
import ViewerCore

/// A/B parity: the Rust core's `mdvcore_indent_detect` (via `mdvCoreIndentDetect`)
/// vs the SHIPPING Swift `IndentDetector.detect`, over a corpus spanning tabs,
/// each space width, mixed, none, blank-only, single-space (no divisor), and the
/// sample-window bound. The result string must match exactly (incl. the em-dash
/// sentinel). Forces the Rust path directly (no gate).
final class IndentDetectABTests: XCTestCase {

    /// Each case: source text + the sample-lines window to use.
    private func cases() -> [(text: String, sample: Int)] {
        [
            ("abc\ndef\n", 50),                 // no indent → "—"
            ("", 50),                           // empty → "—"
            ("\n\n\n", 50),                      // blank only → "—"
            ("\tfoo\n\tbar\n", 50),             // tabs
            ("  a\n  b\n", 50),                  // 2-space
            ("    a\n    b\n", 50),              // 4-space
            ("        a\n", 50),                 // 8-space
            ("\tfoo\n  bar\n", 50),             // mixed
            (" a\n b\n", 50),                    // 1-space → "Spaces" (no divisor)
            ("   a\n   b\n", 50),                // 3-space
            ("\tx\n    y\n", 1),                 // window=1 → first indented line (tab) → "Tabs"
            ("func f() {\n    return 1\n}\n", 50), // realistic 4-space code
            ("def f():\n\treturn 1\n", 50),     // realistic tab code
            // CRLF parity (the gap that let the Rust-port trailing-CR bug slip):
            ("    a\r\n    b\r\n", 50),          // 4-space CRLF
            ("\tfoo\r\n\tbar\r\n", 50),         // tab CRLF
            ("\tfoo\r\n  \r\n\tbar\r\n", 50),   // tab file w/ a whitespace-only CRLF line → must stay "Tabs"
            ("    a\r\n  \r\n    b\r\n  \r\n    c\r\n", 50), // 4-space + blank "  \r" lines → must stay "Spaces (4)"
        ]
    }

    func test_rust_matches_swift_across_corpus() throws {
        for c in cases() {
            let swift = IndentDetector.detect(in: c.text, sampleLines: c.sample)
            let rust = try mdvCoreIndentDetect(text: c.text, sampleLines: c.sample)
            XCTAssertEqual(rust, swift,
                           "parity mismatch for text=\(c.text.debugDescription) sample=\(c.sample)")
        }
    }

    func test_gate_off_uses_swift_and_matches() {
        // Env-pinned OFF (the shipped default is ON since TSK-649 stage A).
        let text = "    a\n    b\n"
        let o = RustIndentAdapter.outcome(in: text, environment: ["MDV_RUST_INDENT": "0"])
        XCTAssertEqual(o.source, .swiftBecauseGateOff)
        XCTAssertEqual(o.value, IndentDetector.detect(in: text))
    }

    func test_shippedDefault_routesRust_andMatchesSwift() {
        // TSK-649 stage A: indent is in the soak set — an UNTOUCHED process
        // default must route rust, with output equal to the Swift engine.
        let text = "    a\n    b\n"
        let o = RustIndentAdapter.outcome(in: text, environment: [:])
        XCTAssertEqual(o.source, .rust, "indent ships default-ON (soak set)")
        XCTAssertEqual(o.value, IndentDetector.detect(in: text))
    }
}
