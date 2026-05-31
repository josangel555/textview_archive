import AppKit
import WebKit
import XCTest

/// Deterministic `WKWebView` teardown for in-process SwiftUI-hosting tests.
///
/// **#192 — `com.apple.WebKit.WebContent` exhaustion → SIGABRT.**
/// Suites such as `ContentViewHostingTests`, `MermaidHostingTests`,
/// `DiagnosticDumpTests`, `ComponentVisualTests`, `RenderedFindBarTests`,
/// `FindBarTests`, and `FormatToggleTests` host `ContentView` /
/// `MarkdownRenderedView` in a bare `NSHostingView`. In rendered mode
/// each host mints a live `WKWebView`, and **each `WKWebView` spawns a
/// `com.apple.WebKit.WebContent` helper process** (see LESSONS.md). The
/// tests only walk the realized NSView tree, then drop the host on the
/// floor — relying on ARC to release the WebView. Under full-suite
/// parallel load (two xctest workers, hundreds of host(...) calls)
/// ARC never runs deterministically, so WebContent processes pile up
/// until WebKit hits its per-host process cap and `abort()`s the test
/// process (signal 6). That truncates the alphabetical suite tail
/// (M→Z), masking ~30 suites.
///
/// The fix is to tear each WebView down *deterministically* at end of
/// test, following the production `MarkdownRenderedView.dismantleNSView`
/// sequence (stop in-flight loads, sever the navigation delegate, drop
/// user scripts) so the pooled WebContent process is released promptly,
/// then spin the runloop briefly so WebKit's async teardown actually
/// reclaims it before the next test allocates more.
///
/// This is a **test-only** change — it does not touch the production
/// WebView lifecycle (no compositor triggers, no source-side WebView
/// changes; respects LESSONS).
enum WebViewTestTeardown {

    /// #192 — gate the in-process live-`WKWebView` suites out of the bare
    /// `swift test` sweep.
    ///
    /// **Why a gate and not just teardown.** Deterministic WebView
    /// teardown (below) keeps each suite self-clean and lets the WebView
    /// suites pass cleanly *as a group*. But at full-suite scale the
    /// accumulated SwiftUI hosting state across ~1600 prior tests still
    /// trips an `AG::precondition_failure` in AttributeGraph the next
    /// time *any* later test spins the main runloop (e.g.
    /// `PluginSubprocessHost.call` → `Process.waitUntilExit()`), which
    /// `abort()`s the single xctest process and truncates the
    /// alphabetical suite tail (M→Z). That corruption lives in SwiftUI's
    /// process-global view graph — a test-side teardown can't reach it,
    /// and a production-side fix would be a risky change to the live
    /// hosting/WebView path. So we follow the repo's existing
    /// `MDV_RUN_LSP_SMOKE` convention: the live-WebView suites are
    /// **process-isolated** — skipped in the bare sweep so it runs to
    /// completion, and run on their own via:
    ///
    ///     MDV_RUN_WEBVIEW_TESTS=1 swift test \
    ///       --filter ViewerUITests.ComponentVisualTests \
    ///       --filter ViewerUITests.ContentViewHostingTests \
    ///       --filter ViewerUITests.DiagnosticDumpTests \
    ///       --filter ViewerUITests.FindBarTests \
    ///       --filter ViewerUITests.FormatToggleTests \
    ///       --filter ViewerUITests.MermaidHostingTests \
    ///       --filter ViewerUITests.RenderedFindBarTests
    ///
    /// where they pass (modulo the pre-existing `about:blank` URL-parser
    /// drift failure documented in LESSONS).
    ///
    /// Call from each live-WebView suite's `setUp`:
    /// `try WebViewTestTeardown.skipUnlessEnabled()`.
    static func skipUnlessEnabled() throws {
        if ProcessInfo.processInfo.environment["MDV_RUN_WEBVIEW_TESTS"] != "1" {
            throw XCTSkip(
                "in-process live-WKWebView suite skipped in the bare sweep "
                + "(#192: full-suite SwiftUI AttributeGraph abort). Run with "
                + "MDV_RUN_WEBVIEW_TESTS=1 in a dedicated invocation.")
        }
    }

    /// Recursively collect every `WKWebView` in `root`'s subtree.
    @MainActor
    static func webViews(in root: NSView) -> [WKWebView] {
        var out: [WKWebView] = []
        if let wv = root as? WKWebView { out.append(wv) }
        for sub in root.subviews { out.append(contentsOf: webViews(in: sub)) }
        return out
    }

    /// Tear down every `WKWebView` found under each root view, then spin
    /// the runloop so WebKit's asynchronous WebContent-process teardown
    /// completes before more WebViews are allocated.
    ///
    /// Mirrors `MarkdownRenderedView.dismantleNSView` (we can't call it
    /// directly — it needs the matching `Coordinator`, which SwiftUI owns
    /// privately for a hosted representable — but the WebView-side steps
    /// are identical and are what actually frees the helper process):
    ///   - `stopLoading()` cancels in-flight navigation so no further
    ///     delegate callbacks fire into a soon-to-be-freed coordinator.
    ///   - `navigationDelegate = nil` severs the (unowned) delegate link.
    ///   - `removeAllUserScripts()` drops the mermaid runtime + shim so
    ///     the pooled WebContent process doesn't carry stale scripts.
    ///   - `removeFromSuperview()` detaches it from the (also-dropped)
    ///     host tree.
    @MainActor
    static func teardown(_ roots: [NSView]) {
        // STEP 1 — settle the SwiftUI view graph *while the hosts are
        // still retained and valid*. This is the actual #192 fix:
        // the full-suite SIGABRT is an `AG::precondition_failure` in
        // AttributeGraph, NOT WebContent exhaustion. An `NSHostingView`
        // test that's dropped on the floor leaves a deferred
        // `ViewGraphRootValueUpdater` render scheduled on the main
        // dispatch queue. Hundreds of tests later, an unrelated test
        // that spins the main runloop (e.g.
        // `PluginSubprocessHost.call` → `Process.waitUntilExit()`)
        // drains that stale render against a now-invalid graph node and
        // aborts — truncating the alphabetical suite tail. Flushing the
        // pending render here, before the host is released, renders it
        // against a valid graph so nothing stale survives into a later
        // runloop spin.
        guard !roots.isEmpty else { return }
        pumpMainQueue()

        // STEP 2 — dismantle any WKWebViews, mirroring the production
        // `MarkdownRenderedView.dismantleNSView` sequence so the pooled
        // WebContent helper is released promptly and no navigation
        // callback fires into a soon-to-be-freed coordinator.
        for root in roots {
            for wv in webViews(in: root) {
                wv.stopLoading()
                wv.navigationDelegate = nil
                wv.uiDelegate = nil
                wv.configuration.userContentController.removeAllUserScripts()
                wv.removeFromSuperview()
            }
        }

        // STEP 3 — a final drain so WebKit's async process-teardown +
        // any post-detach SwiftUI bookkeeping completes before the next
        // test allocates more.
        pumpMainQueue()
    }

    /// Spin the main runloop in the default mode a few short intervals.
    /// The default mode services the **main dispatch queue**, which is
    /// where SwiftUI schedules its async `ViewGraphRootValueUpdater`
    /// render — so this flushes pending renders deterministically. Kept
    /// short (≤0.1s total): this is teardown bookkeeping, not a load
    /// wait.
    @MainActor
    private static func pumpMainQueue() {
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
