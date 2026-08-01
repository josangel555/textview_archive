import WebKit
import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1596 — validates `diffweb.html` END-TO-END against a live WKWebView:
/// the real payload pipeline (generate → rust parse → DiffWebPayload JSON) →
/// `mdvDiffRender` → the page's DOM must hold the expected rows, and the
/// Line|Word|Char granularity switch must add/remove intra-line `<mark>`s
/// (backed by the vendored @codemirror/merge diff engine). Exercises the SAME
/// page + JS contract `DiffWebView` drives in production.
///
/// `#192`-gated (`MDV_RUN_WEBVIEW_TESTS=1` — the VM/nightly WebView lane).
@MainActor
final class DiffWebPageTests: WebViewTestCase {

    private var webView: WKWebView!

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
    }

    override func tearDown() async throws {
        webView = nil
        try await super.tearDown()
    }

    private func loadPage() async throws {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 600), configuration: config)
        let htmlURL = try XCTUnwrap(
            Bundle.viewerUIResources.url(forResource: "diffweb", withExtension: "html"),
            "diffweb.html must ship in the ViewerUI resource bundle")
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        let deadline = Date().addingTimeInterval(10)
        while webView.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        _ = await evalUntil("typeof window.mdvDiffRender === 'function' && typeof window.CM === 'object'", deadline: 5)
    }

    // Completion-handler bridged (the TSK-1047 pattern — the async
    // evaluateJavaScript overload intermittently throws WKError-5).
    private func evalInt(_ js: String) async -> Int {
        await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
            webView.evaluateJavaScript(js) { v, _ in
                cont.resume(returning: (v as? NSNumber)?.intValue ?? Int.min)
            }
        }
    }
    private func evalBool(_ js: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            webView.evaluateJavaScript(js) { v, _ in
                cont.resume(returning: ((v as? NSNumber)?.boolValue) ?? false)
            }
        }
    }
    @discardableResult
    private func evalUntil(_ expr: String, deadline seconds: TimeInterval) async -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if await evalBool("Boolean(\(expr))") { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// The production payload pipeline for a one-line change fixture.
    private func fixturePayload() -> String {
        let diffText = UnifiedDiffGenerator.generate(
            old: "alpha\nthe quick brown fox\nomega\n",
            new: "alpha\nthe slow brown fox\nomega\n",
            path: "sample.txt")
        return DiffWebPayload.json(RustDiffAdapter.parse(diffText))
    }

    func test_render_producesRows_andFileHeader() async throws {
        try await loadPage()
        let count = await evalInt("window.mdvDiffRender(\(fixturePayload()), \"word\")")
        XCTAssertGreaterThan(count, 0, "render must report its row count (verified-apply contract)")
        let domRows = await evalInt("document.querySelectorAll('.row').length")
        XCTAssertEqual(domRows, count, "reported count must match the DOM")
        let headerOK = await evalBool(
            "document.querySelector('.file-header').textContent.indexOf('sample.txt') === 0")
        XCTAssertTrue(headerOK, "file header shows the path")
    }

    func test_granularity_word_vs_char_vs_line_marks() async throws {
        try await loadPage()
        _ = await evalInt("window.mdvDiffRender(\(fixturePayload()), \"word\")")
        let wordMarks = await evalInt("document.querySelectorAll('.txt mark').length")
        XCTAssertGreaterThan(wordMarks, 0, "word granularity marks the changed word")
        let wordMarkIsQuick = await evalBool(
            "Array.from(document.querySelectorAll('.row.del mark')).some(m => m.textContent.includes('quick'))")
        XCTAssertTrue(wordMarkIsQuick, "word mode marks the whole changed word")

        _ = await evalInt("window.mdvDiffSetGranularity(\"line\")")
        let lineMarks = await evalInt("document.querySelectorAll('.txt mark').length")
        XCTAssertEqual(lineMarks, 0, "line granularity draws NO intra-line marks")

        _ = await evalInt("window.mdvDiffSetGranularity(\"char\")")
        let charMarks = await evalInt("document.querySelectorAll('.txt mark').length")
        XCTAssertGreaterThan(charMarks, 0, "char granularity restores intra-line marks")
    }

    /// I-05c (owner 2026-08-01): changed rows must be FINDABLE at a glance —
    /// a real full-line wash (not transparent) plus the inset colored edge
    /// bar, on BOTH the add and del sides, in light AND dark themes.
    func test_changedRows_haveVisibleWash_andEdgeBar() async throws {
        try await loadPage()
        _ = await evalInt("window.mdvDiffRender(\(fixturePayload()), \"word\")")

        for cls in ["add", "del"] {
            let bgVisible = await evalBool("""
                (() => {
                  const r = document.querySelector('.row.\(cls)');
                  if (!r) return false;
                  const m = getComputedStyle(r).backgroundColor
                      .match(/rgba\\([^,]+,[^,]+,[^,]+,\\s*([0-9.]+)\\)/);
                  return !!m && parseFloat(m[1]) >= 0.15;
                })()
                """)
            XCTAssertTrue(bgVisible,
                ".\(cls) rows need a perceptible full-line wash (alpha ≥ 0.15)")
            let edgeBar = await evalBool("""
                getComputedStyle(document.querySelector('.row.\(cls)'))
                    .boxShadow.includes('inset')
                """)
            XCTAssertTrue(edgeBar, ".\(cls) rows need the inset colored edge bar")
        }

        // Dark theme keeps both affordances (the variables are re-declared).
        _ = await evalInt("(window.mdvDiffSetTheme(true), 1)")
        let darkStillVisible = await evalBool("""
            (() => {
              const m = getComputedStyle(document.querySelector('.row.add'))
                  .backgroundColor.match(/rgba\\([^,]+,[^,]+,[^,]+,\\s*([0-9.]+)\\)/);
              return !!m && parseFloat(m[1]) >= 0.15
                  && getComputedStyle(document.querySelector('.row.del'))
                      .boxShadow.includes('inset');
            })()
            """)
        XCTAssertTrue(darkStillVisible, "dark theme keeps the wash + edge bar")
    }

    func test_hostileContent_staysText_neverInjects() async throws {
        try await loadPage()
        let diffText = UnifiedDiffGenerator.generate(
            old: "safe\n", new: "<img id=\"pwned\" src=x onerror=\"window.__pwned=1\">\n",
            path: "evil.txt")
        let payload = DiffWebPayload.json(RustDiffAdapter.parse(diffText))
        let count = await evalInt("window.mdvDiffRender(\(payload), \"word\")")
        XCTAssertGreaterThan(count, 0)
        let injected = await evalBool("Boolean(document.getElementById('pwned')) || Boolean(window.__pwned)")
        XCTAssertFalse(injected, "diff content must enter the DOM as TEXT, never as markup")
    }

    func test_emptyDiff_showsEmptyState_returnsZero() async throws {
        try await loadPage()
        let count = await evalInt("window.mdvDiffRender([], \"word\")")
        XCTAssertEqual(count, 0)
        let emptyShown = await evalBool("Boolean(document.getElementById('empty'))")
        XCTAssertTrue(emptyShown, "empty payload renders the No-differences state")
    }

    // MARK: - TSK-1598: wrap mode + changed-files nav

    /// A two-file fixture (nested path + long line) for the nav/wrap tests.
    private func twoFilePayload(longLine: String) -> String {
        let d1 = UnifiedDiffGenerator.generate(
            old: "a\n", new: "a\n\(longLine)\n", path: "src/deep/dir/alpha.txt")
        let d2 = UnifiedDiffGenerator.generate(
            old: "x\n", new: "y\n", path: "beta.txt")
        return DiffWebPayload.json(RustDiffAdapter.parse(d1 + d2))
    }

    func test_wrapMode_fillsWindowWidth_noHorizontalOverflow() async throws {
        try await loadPage()
        let long = String(repeating: "wraps ", count: 120)   // ≫ 900px viewport
        _ = await evalInt("window.mdvDiffRender(\(twoFilePayload(longLine: long)), \"line\")")

        // Wrap OFF: the content is WIDER than the window (h-scroll range).
        _ = await evalInt("window.mdvDiffSetWrap(false) || 1")
        let unwrapped = await evalBool(
            "document.documentElement.scrollWidth > window.innerWidth + 10")
        XCTAssertTrue(unwrapped, "unwrapped long lines extend past the window (h-scroll)")

        // Wrap ON: content fits EXACTLY the window — no h-overflow, and rows
        // are never narrower than the window (the TSK-1595 class).
        _ = await evalInt("window.mdvDiffSetWrap(true) || 1")
        let fits = await evalBool(
            "document.documentElement.scrollWidth <= window.innerWidth + 1")
        XCTAssertTrue(fits, "wrap mode must eliminate horizontal overflow")
        let rowFillsWindow = await evalBool(
            "document.querySelector('.row').getBoundingClientRect().width >= window.innerWidth - 240")
        XCTAssertTrue(rowFillsWindow, "rows span the full content width in wrap mode")
    }

    func test_fileNav_treeRendersAndJumps() async throws {
        try await loadPage()
        _ = await evalInt("window.mdvDiffRender(\(twoFilePayload(longLine: "z")), \"word\")")

        // Hidden until enabled.
        let hidden = await evalBool(
            "getComputedStyle(document.getElementById('nav')).display === 'none'")
        XCTAssertTrue(hidden, "nav is hidden until the toggle enables it")

        _ = await evalInt("window.mdvDiffSetNav(true) || 1")
        let fileRows = await evalInt("document.querySelectorAll('.nav-file').length")
        XCTAssertEqual(fileRows, 2, "one nav row per changed file")
        let dirRows = await evalInt("document.querySelectorAll('.nav-dir').length")
        XCTAssertGreaterThanOrEqual(dirRows, 1, "nested path renders a directory row")
        let compressed = await evalBool(
            "Array.from(document.querySelectorAll('.nav-dir')).some(d => d.textContent.endsWith('src/deep/dir/'))")
        XCTAssertTrue(compressed, "single-child directory chains compress onto one row")
        // PATCH ORDER: the fixture's patch lists src/deep/dir/alpha.txt (idx 0)
        // BEFORE beta.txt (idx 1); the nav must present the same top-to-bottom
        // order as the diff blocks, not alphabetical (owner 2026-07-24).
        let orderMatchesPatch = await evalBool(
            "Array.from(document.querySelectorAll('.nav-file')).map(r => r.dataset.fileIndex).join(',') === '0,1'")
        XCTAssertTrue(orderMatchesPatch, "nav order must match the diff's file order")

        // EXPAND/COLLAPSE: clicking the dir row hides its subtree, click again restores.
        _ = await evalBool("(document.querySelector('.nav-dir').click(), true)")
        let visibleAfterCollapse = await evalInt(
            "Array.from(document.querySelectorAll('.nav-file')).filter(r => r.offsetParent !== null).length")
        XCTAssertEqual(visibleAfterCollapse, 1, "collapsing the dir hides its files")
        let triFlipped = await evalBool(
            "document.querySelector('.nav-dir .tri').textContent === '▸'")
        XCTAssertTrue(triFlipped, "the disclosure triangle reflects the collapsed state")
        _ = await evalBool("(document.querySelector('.nav-dir').click(), true)")
        let visibleAfterExpand = await evalInt(
            "Array.from(document.querySelectorAll('.nav-file')).filter(r => r.offsetParent !== null).length")
        XCTAssertEqual(visibleAfterExpand, 2, "expanding restores the subtree")

        // Jump: clicking the nav row scrolls the file block to the top.
        _ = await evalBool("window.mdvDiffJumpToFile(1)")
        let jumped = await evalBool(
            "Math.abs(window.scrollY - document.getElementById('file-1').offsetTop) < 4")
        XCTAssertTrue(jumped, "jump pins the target file's header to the top")
        let active = await evalBool(
            "document.querySelector('.nav-file.active').dataset.fileIndex === '1'")
        XCTAssertTrue(active, "the jumped file is marked active in the nav")

        _ = await evalInt("window.mdvDiffSetNav(false) || 1")
        let reHidden = await evalBool(
            "getComputedStyle(document.getElementById('nav')).display === 'none'")
        XCTAssertTrue(reHidden, "the toggle hides the nav again")
    }

    func test_deletedFile_showsRealPath_withDStatus() async throws {
        // A git-style deletion (`+++ /dev/null`): the nav + file header must
        // show the file's REAL (old) path with the D status — never dev/null.
        try await loadPage()
        let deletePatch = """
        diff --git a/docs/gone.txt b/docs/gone.txt
        deleted file mode 100644
        index 1111111..0000000
        --- a/docs/gone.txt
        +++ /dev/null
        @@ -1,1 +0,0 @@
        -bye
        """
        let payload = DiffWebPayload.json(RustDiffAdapter.parse(deletePatch))
        let count = await evalInt("window.mdvDiffRender(\(payload), \"word\")")
        XCTAssertGreaterThan(count, 0)
        _ = await evalInt("window.mdvDiffSetNav(true) || 1")
        let status = await evalBool(
            "document.querySelector('.nav-file .st').textContent === 'D'")
        XCTAssertTrue(status, "deleted file carries the D status in the nav")
        let name = await evalBool(
            "document.querySelector('.nav-file .nm').textContent === 'gone.txt'")
        XCTAssertTrue(name, "the nav shows the real filename, not dev/null")
        let header = await evalBool(
            "document.querySelector('.file-header').textContent.indexOf('docs/gone.txt') === 0")
        XCTAssertTrue(header, "the diff block header shows the real path")
    }

    // MARK: - TSK-1599: summary, syntax highlighting, version buttons, scrollspy

    func test_summaryBlock_showsPreambleAndTotals() async throws {
        try await loadPage()
        let text = """
        abc1234def
        Tester <t@example.com>
        Mon Jul 20 12:00:00 2026

        fix: the thing

        diff --git a/f.txt b/f.txt
        index aaaa111..bbbb222 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1 +1 @@
        -old line
        +new line
        """
        _ = await evalInt("window.mdvDiffRender(\(DiffWebPayload.json(diffText: text)), \"word\")")
        let hasPre = await evalBool(
            "document.querySelector('#summary .pre').textContent.includes('fix: the thing')")
        XCTAssertTrue(hasPre, "the commit preamble renders in the summary")
        let hasStat = await evalBool(
            "document.querySelector('#summary .stat').textContent === '1 file changed, +1 −1'")
        XCTAssertTrue(hasStat, "the totals line renders")
    }

    func test_syntaxHighlighting_tokensInBothLanguageFamilies() async throws {
        try await loadPage()
        let js = UnifiedDiffGenerator.generate(
            old: "let a = 1;\n", new: "const b = \"str\";\n", path: "code.js")
        let swift = UnifiedDiffGenerator.generate(
            old: "var x = 1\n", new: "let y = 2\n", path: "code.swift")
        _ = await evalInt("window.mdvDiffRender(\(DiffWebPayload.json(diffText: js + swift)), \"line\")")
        let jsKeyword = await evalBool(
            "Array.from(document.querySelectorAll('#file-0 .tok-keyword')).some(s => s.textContent === 'const')")
        XCTAssertTrue(jsKeyword, "Lezer pack highlights the js keyword")
        let swiftKeyword = await evalBool(
            "Array.from(document.querySelectorAll('#file-1 .tok-keyword')).some(s => s.textContent === 'let')")
        XCTAssertTrue(swiftKeyword, "stream-language pack highlights the swift keyword")
        let stringTok = await evalBool(
            "document.querySelectorAll('#file-0 .tok-string, #file-0 .tok-string2').length > 0")
        XCTAssertTrue(stringTok, "string literals tokenize")
    }

    func test_versionButtons_postBridgeMessages() async throws {
        try await loadPage()
        let text = """
        diff --git a/lib/f.txt b/lib/f.txt
        index aaaa111..bbbb222 100644
        --- a/lib/f.txt
        +++ b/lib/f.txt
        @@ -1 +1 @@
        -x
        +y
        """
        _ = await evalInt("window.mdvDiffRender(\(DiffWebPayload.json(diffText: text)), \"word\")")
        let buttons = await evalInt("document.querySelectorAll('.fh-btn').length")
        XCTAssertEqual(buttons, 3, "Old + New + Current for a modified file with both blobs")
        // No Swift handler in this harness → posts land in the page's test sink.
        _ = await evalBool(
            "(Array.from(document.querySelectorAll('.fh-btn')).find(b => b.textContent === 'Old').click(), true)")
        _ = await evalBool(
            "(Array.from(document.querySelectorAll('.fh-btn')).find(b => b.textContent === 'Current').click(), true)")
        let oldMsg = await evalBool(
            "window.__mdvDiffBridgeSink[0].version === 'old' && window.__mdvDiffBridgeSink[0].blob === 'aaaa111' && window.__mdvDiffBridgeSink[0].path === 'lib/f.txt'")
        XCTAssertTrue(oldMsg, "Old button posts {version:'old', blob, path}")
        let curMsg = await evalBool(
            "window.__mdvDiffBridgeSink[1].version === 'current' && !('blob' in window.__mdvDiffBridgeSink[1])")
        XCTAssertTrue(curMsg, "Current button posts {version:'current'} without a blob")
    }

    func test_scrollspy_tracksVisibleFile() async throws {
        try await loadPage()
        // Two files, the first tall enough to scroll within.
        let filler = (0..<120).map { "line \($0)" }.joined(separator: "\n")
        let d1 = UnifiedDiffGenerator.generate(old: "a\n", new: filler + "\n", path: "tall.txt")
        let d2 = UnifiedDiffGenerator.generate(old: "x\n", new: "y\n", path: "short.txt")
        _ = await evalInt("window.mdvDiffRender(\(DiffWebPayload.json(diffText: d1 + d2)), \"line\")")
        _ = await evalInt("window.mdvDiffSetNav(true) || 1")
        // Scroll to the SECOND file's block and let the rAF spy run.
        _ = await evalBool(
            "(window.scrollTo(0, document.getElementById('file-1').offsetTop + 30), window.dispatchEvent(new Event('scroll')), true)")
        let tracked = await evalUntil(
            "document.querySelector('.nav-file.active') && document.querySelector('.nav-file.active').dataset.fileIndex === '1'",
            deadline: 3)
        XCTAssertTrue(tracked, "scrolling into file-1 marks its nav row active")
    }

    func test_navWidth_scalesWithFontSize() async throws {
        // TSK-1598 follow-up (owner): the tree's size must track the UI text
        // size — width ≈ 18em of the pushed font, row fonts em-based.
        try await loadPage()
        _ = await evalInt("window.mdvDiffRender(\(twoFilePayload(longLine: "z")), \"word\")")
        _ = await evalInt("window.mdvDiffSetNav(true) || 1")
        _ = await evalBool("(window.mdvDiffSetFontSize(12), true)")
        let w12 = await evalInt("document.getElementById('nav').getBoundingClientRect().width")
        _ = await evalBool("(window.mdvDiffSetFontSize(18), true)")
        let w18 = await evalInt("document.getElementById('nav').getBoundingClientRect().width")
        XCTAssertEqual(w12, 12 * 18, "nav width is 18em of the content font")
        XCTAssertEqual(w18, 18 * 18, "nav width scales with the font size")
    }
}
