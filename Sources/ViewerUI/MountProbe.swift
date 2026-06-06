#if DEBUG
import Foundation

/// Perf Fix#1 (TSK-108) mount-count probe — DEBUG-only, not compiled into
/// release builds.
///
/// The two WKWebView-backed representables (`MarkdownRenderedView`,
/// `CodeMirrorEditorView`) bump these counters in `makeNSView` /
/// `dismantleNSView`. A test (or the live-smoke) resets, drives an A→B→A tab
/// switch, and asserts ZERO additional makes/dismantles — proving the
/// retained inactive pane was NOT torn down + reloaded (the ~1s freeze). LRU
/// tail eviction is the ONE controlled `dismantle`.
///
/// The view-layer 0-remount proof needs real WKWebViews, so it lives in the
/// `MDV_RUN_WEBVIEW_TESTS` / VM lane (not the bare headless gate). The
/// retention-SET correctness (which ids stay mounted) is proven separately,
/// WKWebView-free, in `MountedPanesWiringTests` on the bare gate.
@MainActor
public enum MountProbe {
    /// Total `makeNSView` calls across both WKWebView representables.
    public static var webViewMakes = 0
    /// Total `dismantleNSView` calls across both WKWebView representables.
    public static var webViewDismantles = 0

    public static func reset() {
        webViewMakes = 0
        webViewDismantles = 0
    }
}
#endif
