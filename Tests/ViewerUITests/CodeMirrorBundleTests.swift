import XCTest
@testable import ViewerUI

/// Pure-logic tests that don't need a window or WKWebView. Cover:
///
/// 1. The CM6 bundle's three files (HTML host, JS, CSS) ship inside
///    `Bundle.module` so a future rebuild that drops one of them
///    surfaces here instead of as a blank webview at runtime.
/// 2. The JS→Swift bridge `CodeMirrorBridge.decode` correctly maps
///    every payload shape we care about to its action enum, and
///    rejects unknown / malformed payloads instead of crashing.
final class CodeMirrorBundleTests: XCTestCase {

    func testHostHTMLResourceExists() {
        let url = CodeMirrorResources.hostHTMLURL
        XCTAssertNotNil(url, "codemirror.html missing from ViewerUI resources")
        if let url = url {
            let size = (try? Data(contentsOf: url).count) ?? 0
            XCTAssertGreaterThan(size, 1000, "codemirror.html shrunk suspiciously to \(size) bytes")
        }
    }

    func testJSBundleResourceExists() {
        let url = CodeMirrorResources.jsBundleURL
        XCTAssertNotNil(url, "codemirror.js bundle missing — re-run scripts/codemirror-build/npm run build")
        if let url = url {
            let size = (try? Data(contentsOf: url).count) ?? 0
            // Sanity: minified CM6 bundle is ~570 KB. Floor at 100 KB
            // catches an empty / esbuild-failed output without locking
            // us to a specific byte count on every rebuild.
            XCTAssertGreaterThan(size, 100_000, "codemirror.js suspiciously small: \(size) bytes")
            XCTAssertLessThan(size, 5_000_000, "codemirror.js suspiciously large: \(size) bytes — added too many languages?")
        }
    }

    func testHostCSSResourceExists() {
        let url = CodeMirrorResources.hostCSSURL
        XCTAssertNotNil(url, "codemirror.css missing from ViewerUI resources")
    }

    // MARK: - Bridge action decoding

    func testBridgeDecodesReady() {
        XCTAssertEqual(
            CodeMirrorBridge.decode(["type": "ready"]),
            .ready
        )
    }

    func testBridgeDecodesChangeWithText() {
        XCTAssertEqual(
            CodeMirrorBridge.decode(["type": "change", "text": "hello world"]),
            .change(text: "hello world")
        )
    }

    func testBridgeDecodesChangeWithEmptyText() {
        // JS always sends text but we don't trust the wire — missing
        // key must decode to empty string, not nil-crash.
        XCTAssertEqual(
            CodeMirrorBridge.decode(["type": "change"]),
            .change(text: "")
        )
    }

    func testBridgeDecodesSaveRequested() {
        XCTAssertEqual(
            CodeMirrorBridge.decode(["type": "saveRequested"]),
            .saveRequested
        )
    }

    func testBridgeRejectsUnknownType() {
        XCTAssertNil(CodeMirrorBridge.decode(["type": "totallyMadeUp"]))
    }

    func testBridgeRejectsNonDictionary() {
        XCTAssertNil(CodeMirrorBridge.decode("not a dictionary"))
        XCTAssertNil(CodeMirrorBridge.decode(42))
        XCTAssertNil(CodeMirrorBridge.decode(NSNull()))
    }

    func testBridgeRejectsMissingType() {
        XCTAssertNil(CodeMirrorBridge.decode(["text": "no type field"]))
    }

    // MARK: - Language mapping

    func testLanguageMappingCoversCommonCases() {
        XCTAssertEqual(jsLanguageName(for: .markdown),   "markdown")
        XCTAssertEqual(jsLanguageName(for: .javascript), "javascript")
        XCTAssertEqual(jsLanguageName(for: .typescript), "typescript")
        XCTAssertEqual(jsLanguageName(for: .python),     "python")
        XCTAssertEqual(jsLanguageName(for: .json),       "json")
    }

    func testLanguageMappingFallsBackToPlain() {
        XCTAssertEqual(jsLanguageName(for: .ruby),     "plain")
        XCTAssertEqual(jsLanguageName(for: .go),       "plain")
        XCTAssertEqual(jsLanguageName(for: .plainText),"plain")
    }
}
