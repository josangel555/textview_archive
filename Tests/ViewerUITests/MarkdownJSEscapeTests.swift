import XCTest
@testable import ViewerUI

/// Coverage for `MarkdownRenderedView.Coordinator.jsEscape(_:)` — the
/// escaper that turns an arbitrary search string into a safe JS string
/// literal for the rendered-markdown find injection (`evaluateJavaScript`).
/// Was untested. Two contracts matter:
///   1. the output is a quoted JS/JSON string literal that decodes back to
///      the exact input (no corruption, quotes/backslashes/newlines escaped);
///   2. the JS line terminators U+2028 / U+2029 — which are legal in JSON
///      but break a JS string literal — are escaped away, never emitted raw.
@MainActor
final class MarkdownJSEscapeTests: XCTestCase {

    private func esc(_ s: String) -> String {
        MarkdownRenderedView.Coordinator.jsEscape(s)
    }

    /// Decode a produced JS string literal back to its Swift value by
    /// re-wrapping it as a one-element JSON array.
    private func decodeBack(_ literal: String) -> String? {
        guard let d = "[\(literal)]".data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [String]
        else { return nil }
        return arr.first
    }

    func test_output_isQuotedLiteral() {
        let out = esc("hello")
        XCTAssertTrue(out.hasPrefix("\"") && out.hasSuffix("\""),
                      "must be a quoted string literal, got \(out)")
    }

    func test_roundTrips_throughTrickyInputs() {
        for input in [
            "hello",
            "a\"b",            // embedded double quote
            "a\\b",            // embedded backslash
            "line1\nline2",    // newline
            "tab\there",       // tab
            "emoji 😀 and ünïcødé",
            "",                // empty
            "</script>",       // not special for evaluateJavaScript, must survive intact
        ] {
            XCTAssertEqual(decodeBack(esc(input)), input,
                           "jsEscape must round-trip \(input.debugDescription)")
        }
    }

    func test_empty_isEmptyLiteral() {
        XCTAssertEqual(esc(""), "\"\"")
    }

    func test_jsLineTerminators_areEscaped_notRaw() {
        // U+2028 LINE SEPARATOR / U+2029 PARAGRAPH SEPARATOR are valid in
        // JSON but terminate a JS string literal — the sanitize step must
        // escape them so the injected script doesn't SyntaxError.
        let input = "before\u{2028}mid\u{2029}after"
        let out = esc(input)
        XCTAssertFalse(out.unicodeScalars.contains(Unicode.Scalar(0x2028)!),
                       "raw U+2028 must not appear in the JS literal")
        XCTAssertFalse(out.unicodeScalars.contains(Unicode.Scalar(0x2029)!),
                       "raw U+2029 must not appear in the JS literal")
        XCTAssertTrue(out.contains("2028") && out.contains("2029"),
                      "the separators must be emitted as \\u escapes")
        // Still round-trips to the original despite the escaping.
        XCTAssertEqual(decodeBack(out), input)
    }
}
