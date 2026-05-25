import XCTest
@testable import ViewerCore

/// S1-C: JSONSerialization leaves U+2028 / U+2029 unescaped — both
/// are JavaScript line terminators. Embedding raw into JS source via
/// `evaluateJavaScript("foo(\(json));")` breaks the surrounding
/// script. `JSStringEmbedding.sanitize` post-processes the encoder
/// output to escape both.
final class JSStringEmbeddingTests: XCTestCase {

    func test_sanitize_escapesLineSeparator() {
        let raw = "\"a\u{2028}b\""
        XCTAssertEqual(JSStringEmbedding.sanitize(raw), "\"a\\u2028b\"")
    }

    func test_sanitize_escapesParagraphSeparator() {
        let raw = "\"a\u{2029}b\""
        XCTAssertEqual(JSStringEmbedding.sanitize(raw), "\"a\\u2029b\"")
    }

    func test_sanitize_idempotent() {
        let once = JSStringEmbedding.sanitize("\"a\u{2028}b\"")
        let twice = JSStringEmbedding.sanitize(once)
        XCTAssertEqual(once, twice)
    }

    func test_sanitize_asciiUnchanged() {
        let raw = "{\"v\":1,\"text\":\"plain ascii\"}"
        XCTAssertEqual(JSStringEmbedding.sanitize(raw), raw)
    }

    func test_sanitize_otherUnicodeUnchanged() {
        // Only U+2028 / U+2029 are problematic. Other supplementary
        // chars (emoji, CJK, combining marks) ride through unchanged.
        let raw = "{\"x\":\"déjà 🦀 vu\"}"
        XCTAssertEqual(JSStringEmbedding.sanitize(raw), raw)
    }

    func test_sanitize_handlesBothInOneString() {
        let raw = "abc\u{2028}def\u{2029}ghi"
        XCTAssertEqual(
            JSStringEmbedding.sanitize(raw),
            "abc\\u2028def\\u2029ghi"
        )
    }

    /// Concrete regression: the CM bridge's `encodeOutboundJSON`
    /// must produce a JS-embed-safe string for any payload.
    func test_cmBridgeEncoder_escapesLineSeparatorInSetText() {
        let msg = CMOutboundMessage.setText(
            text: "line one\u{2028}line two",
            resetHistory: false, preserveSelection: false
        )
        let json = CMBridgeCodec.encodeOutboundJSON(msg)
        XCTAssertFalse(
            json.contains("\u{2028}"),
            "encoder output must not contain raw U+2028: \(json)"
        )
        XCTAssertTrue(
            json.contains("\\u2028"),
            "encoder output should escape U+2028 to \\u2028: \(json)"
        )
    }

    func test_cmBridgeEncoder_escapesParagraphSeparatorInSetText() {
        let msg = CMOutboundMessage.setText(
            text: "para1\u{2029}para2",
            resetHistory: false, preserveSelection: false
        )
        let json = CMBridgeCodec.encodeOutboundJSON(msg)
        XCTAssertFalse(json.contains("\u{2029}"))
        XCTAssertTrue(json.contains("\\u2029"))
    }
}
