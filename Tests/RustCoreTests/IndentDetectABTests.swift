import XCTest
@testable import RustCore

/// GOLDEN suite for the Rust core's `mdvcore_indent_detect` (via
/// `mdvCoreIndentDetect`). Was an A/B parity suite against the Swift
/// `IndentDetector`; that twin was DELETED in TSK-649 Stage B #1, so the
/// expected values are now FROZEN from the (already parity-proven) outputs —
/// the oracle changed from "compute via Swift" to these literal goldens. The
/// cross-language behavior pins survive intact, including the CRLF / trailing-CR
/// cases (the gap that once let a Rust-port trailing-CR bug slip — TSK-127).
final class IndentDetectABTests: XCTestCase {

    /// Each case: source text, sample-lines window, and the FROZEN expected
    /// result string (incl. the em-dash "no indent" sentinel).
    private func cases() -> [(text: String, sample: Int, expect: String)] {
        [
            ("abc\ndef\n", 50, "—"),                          // no indent
            ("", 50, "—"),                                     // empty
            ("\n\n\n", 50, "—"),                                // blank only
            ("\tfoo\n\tbar\n", 50, "Tabs"),                    // tabs
            ("  a\n  b\n", 50, "Spaces (2)"),                  // 2-space
            ("    a\n    b\n", 50, "Spaces (4)"),              // 4-space
            ("        a\n", 50, "Spaces (8)"),                 // 8-space
            ("\tfoo\n  bar\n", 50, "Mixed"),                   // mixed
            (" a\n b\n", 50, "Spaces"),                         // 1-space → no divisor
            ("   a\n   b\n", 50, "Spaces (3)"),                // 3-space
            ("\tx\n    y\n", 1, "Tabs"),                       // window=1 → first indented (tab)
            ("func f() {\n    return 1\n}\n", 50, "Spaces (4)"), // realistic 4-space code
            ("def f():\n\treturn 1\n", 50, "Tabs"),           // realistic tab code
            // CRLF goldens (the gap that let the Rust-port trailing-CR bug slip):
            ("    a\r\n    b\r\n", 50, "Spaces (4)"),          // 4-space CRLF
            ("\tfoo\r\n\tbar\r\n", 50, "Tabs"),               // tab CRLF
            ("\tfoo\r\n  \r\n\tbar\r\n", 50, "Tabs"),         // tab file w/ a whitespace-only CRLF line → stays Tabs
            ("    a\r\n  \r\n    b\r\n  \r\n    c\r\n", 50, "Spaces (4)"), // 4-space + blank "  \r" lines → stays Spaces (4)
        ]
    }

    func test_rust_matches_frozen_goldens() throws {
        for c in cases() {
            let rust = try mdvCoreIndentDetect(text: c.text, sampleLines: c.sample)
            XCTAssertEqual(rust, c.expect,
                           "golden mismatch for text=\(c.text.debugDescription) sample=\(c.sample)")
        }
    }
}
