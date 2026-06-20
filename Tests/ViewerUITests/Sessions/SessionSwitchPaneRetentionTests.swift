import XCTest
import AppKit
import SwiftUI
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Perf P1 (TSK-1042) VIEW-LAYER proof: a session switch AWAY from a session
/// whose focused tab is a rendered-Markdown WebView, then BACK to it, must NOT
/// rebuild that WebView (`MountProbe.webViewMakes` stays 0 across the round
/// trip). Before the warm-WebView cache, the switch drained every tab →
/// `MountedPanesLRU` dropped every pane → the incoming tab (fresh `Tab.id`)
/// rebuilt its WKWebView from scratch, re-paying ~94% of a rendered-MD open
/// (TSK-598). With the cache, `dismantleNSView` parks the WebView by file path
/// and `makeNSView` re-attaches it — zero rebuild.
///
/// This is the audit's host-testable-via-VM teeth point. It needs real
/// WebContent processes (MountProbe only bumps in real make/dismantle), so it
/// `#192`-gates itself out of the bare host sweep and runs in the
/// `MDV_RUN_WEBVIEW_TESTS` / VM lane:
///   MDV_RUN_WEBVIEW_TESTS=1 swift test --filter SessionSwitchPaneRetentionTests
///
/// TEETH: on today's code WITHOUT the cache (`dismantleNSView` tearing down +
/// `makeNSView` rebuilding) this FAILS — webViewMakes increments on the
/// switch-back. With the cache it passes.
@MainActor
final class SessionSwitchPaneRetentionTests: XCTestCase {

    private var tmpRoot: URL!
    private var hostedViews: [NSView] = []

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()   // #192
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitchPaneRetention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        // Process-singleton cache — start each test from a clean slate so a
        // prior test's parked WebViews can't satisfy (or pollute) this one.
        WarmWebViewCache.shared.removeAll()
        #if DEBUG
        WarmWebViewCache.shared.resetProbes()
        #endif
    }

    override func tearDown() async throws {
        WebViewTestTeardown.teardown(hostedViews)
        hostedViews.removeAll()
        WarmWebViewCache.shared.removeAll()
        if let tmpRoot { try? FileManager.default.removeItem(at: tmpRoot) }
    }

    private func makeWorkspace(named: String, files: [String: String]) -> URL {
        let folder = tmpRoot.appendingPathComponent(named, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, body) in files {
            try? Data(body.utf8).write(to: folder.appendingPathComponent(name))
        }
        return folder
    }

    private func makeCoordinator() -> SessionsAppCoordinator {
        let sessionsDir = tmpRoot.appendingPathComponent("Sessions-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let coord = SessionsAppCoordinator(
            model: DocumentModel(), store: SessionStore(directory: sessionsDir), initialRoot: nil)
        coord.bootstrap()
        return coord
    }

    private func host<V: View>(_ view: V) -> NSHostingView<V> {
        _ = NSApplication.shared
        let h = NSHostingView(rootView: view)
        h.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        h.layoutSubtreeIfNeeded()
        hostedViews.append(h)
        return h
    }

    private func settle(_ host: NSView) {
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
    }

    func test_switchAwayAndBack_doesNotRebuildTheRenderedMarkdownWebView() throws {
        let coord = makeCoordinator()
        // Bind the live ContentView to the coordinator's shared model so real
        // WKWebViews mount for the focused rendered-MD tab.
        let host = host(ContentView(model: coord.model))

        let folderA = makeWorkspace(named: "A", files: ["a.md": "# Alpha\n\nBody of A.\n"])
        let folderB = makeWorkspace(named: "B", files: ["b.md": "# Bravo\n\nBody of B.\n"])

        // Session A: open + focus the rendered-MD tab → realize its WebView.
        coord.openFolder(folderA, forceNew: true)
        coord.model.open(url: folderA.appendingPathComponent("a.md"))
        settle(host)
        let aSessionID = coord.core.activeID!

        // Session B: open + focus its rendered-MD tab. This switch drains A
        // (A's WebView dismantles → PARKED by path), then builds B's.
        coord.openFolder(folderB, forceNew: true)
        coord.model.open(url: folderB.appendingPathComponent("b.md"))
        settle(host)

        // Baseline established — now measure ONLY the switch BACK to A.
        MountProbe.reset()
        coord.activate(id: aSessionID)
        settle(host)

        XCTAssertEqual(MountProbe.webViewMakes, 0,
            "switching BACK to session A rebuilt its rendered-MD WKWebView (\(MountProbe.webViewMakes) makes) — "
            + "the warm-WebView cache failed to re-attach the parked pane (the ~94% WebKit-open cost regressed)")
    }
}
