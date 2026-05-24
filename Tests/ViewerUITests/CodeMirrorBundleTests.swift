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

    // MARK: - Phase 2: bundle contract for new dispatch surface
    //
    // We can't execute the JS here, but we can grep the HTML host's
    // dispatch switch and the JS bundle's exports to confirm Phase 2
    // wiring made it through the build.

    func testHostHTMLExposesNewDispatchTypes() throws {
        let url = try XCTUnwrap(CodeMirrorResources.hostHTMLURL)
        let html = try String(contentsOf: url, encoding: .utf8)
        for needle in [
            "case \"setDiagnostics\"",
            "case \"setShowInvisibles\"",
            "case \"setSearchQuery\"",
            "findResultChanged",
            "applySetDiagnostics",
            "applySetShowInvisibles",
            "applySetSearchQuery",
        ] {
            XCTAssertTrue(html.contains(needle),
                          "codemirror.html missing Phase 2 wiring: \(needle)")
        }
    }

    func testJSBundleExportsLintAndSearchAPIs() throws {
        let url = try XCTUnwrap(CodeMirrorResources.jsBundleURL)
        let data = try Data(contentsOf: url)
        let js = String(data: data, encoding: .utf8) ?? ""
        // The IIFE bundle attaches every re-exported symbol off `window.CM`.
        // Just confirm string presence — the bundle is minified so name-
        // mangling on locals is fine but the export names survive.
        for needle in ["lintGutter", "setDiagnostics", "setSearchQuery", "SearchQuery"] {
            XCTAssertTrue(js.contains(needle),
                          "codemirror.js missing expected export: \(needle)")
        }
    }

    func testJSBundleSizeWithinPhase2Budget() throws {
        let url = try XCTUnwrap(CodeMirrorResources.jsBundleURL)
        let size = try Data(contentsOf: url).count
        // Phase 2 plan: bundle stays below ~1.5 MB through Phase 4 even
        // with vim + extra languages. Today (Phase 2 with lint added)
        // we're at ~650 KB. Lock the upper bound at 1.5 MB so a slip
        // (e.g. accidentally bundling a non-minified build) trips here.
        XCTAssertLessThan(size, 1_500_000,
                          "codemirror.js bundle exceeded 1.5 MB Phase-2 budget: \(size) bytes")
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

    // MARK: - Phase 3: hover / Cmd-click / context-menu wiring

    func testHostHTMLExposesPhase3DispatchSurface() throws {
        let url = try XCTUnwrap(CodeMirrorResources.hostHTMLURL)
        let html = try String(contentsOf: url, encoding: .utf8)
        for needle in [
            // JS → Swift outbound shapes
            "requestHover",
            "requestDefinition",
            "contextMenuRequested",
            // Swift → JS inbound dispatch handlers
            "case \"hoverResponse\"",
            "case \"setSaveOnBlur\"",
            // CM6 hoverTooltip + custom CSS class for our popover
            "cm-tooltip-hover-lsp",
            "buildHoverExtension",
        ] {
            XCTAssertTrue(html.contains(needle),
                          "codemirror.html missing Phase 3 wiring: \(needle)")
        }
    }

    func testJSBundleExportsHoverTooltip() throws {
        let url = try XCTUnwrap(CodeMirrorResources.jsBundleURL)
        let data = try Data(contentsOf: url)
        let js = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(js.contains("hoverTooltip"),
                      "codemirror.js missing hoverTooltip export — re-run scripts/codemirror-build/npm run build")
    }
}
