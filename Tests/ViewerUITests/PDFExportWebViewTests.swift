import WebKit
import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-638 — the live-WKWebView half of Export-as-PDF: our rendered page
/// (HTMLRenderer output + the bundled stylesheet, including the new
/// `@media print` block) loads into a real WebView and `createPDF`
/// produces genuine PDF bytes. `#192`-gated (`MDV_RUN_WEBVIEW_TESTS=1`,
/// the VM/nightly WebView lane) — listed in `test-in-vm.sh`
/// `run_webview_tests` AND `nightly-vm.yml` (a gated suite in no lane
/// list runs nowhere).
@MainActor
final class PDFExportWebViewTests: WebViewTestCase {

    private var webView: WKWebView!

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
    }

    override func tearDown() async throws {
        webView = nil
        try await super.tearDown()
    }

    /// Load `html` and wait for didFinish (poll `isLoading` — no delegate
    /// needed for a local string load).
    private func loadPage(_ html: String) async {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        webView.loadHTMLString(html, baseURL: nil)
        let deadline = Date().addingTimeInterval(10)
        while (webView.isLoading || webView.url == nil), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func test_renderedMarkdownPage_exportsRealPDFBytes() async throws {
        let page = HTMLRenderer().renderPage(
            "# PDF Title\n\nBody text with `code`.\n\n```swift\nlet x = 1\n```\n",
            stylesheet: MarkdownStylesheet.load())
        await loadPage(page)

        let data: Data = try await withCheckedThrowingContinuation { cont in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                cont.resume(with: result)
            }
        }
        // %PDF magic + a non-trivial body — the regression guard the
        // ticket asked for (a blank/failed export yields no magic).
        XCTAssertGreaterThan(data.count, 1024, "a one-page PDF is > 1 KB")
        XCTAssertEqual(Array(data.prefix(5)), Array("%PDF-".utf8),
                       "createPDF must yield real PDF bytes")
    }

    func test_atomicWritePath_roundTrips() async throws {
        await loadPage("<html><body><p>tiny</p></body></html>")
        let data: Data = try await withCheckedThrowingContinuation { cont in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                cont.resume(with: result)
            }
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-pdf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: dest) }
        try data.write(to: dest, options: .atomic)
        let back = try Data(contentsOf: dest)
        XCTAssertEqual(Array(back.prefix(5)), Array("%PDF-".utf8))
    }
}
