import XCTest
import AppKit
import SwiftUI
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// L3 tests for the source-view find bar. NSTextView's `usesFindBar`
/// and `isIncrementalSearchingEnabled` flags control whether the bar
/// is available; we assert those flags propagate correctly.
///
/// Find behavior itself (next/prev, regex, case) is provided by
/// AppKit's NSTextFinder; we don't re-test that — we only verify the
/// wiring (NSTextView is configured to use the find bar).
@MainActor
final class FindBarTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    /// #192: tracked so tearDown can dismantle embedded WKWebViews.
    private var hostedViews: [NSView] = []

    override func setUp() async throws {
        // #192: process-isolated — skipped in the bare sweep.
        try WebViewTestTeardown.skipUnlessEnabled()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FindBar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "FindBar-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        WebViewTestTeardown.teardown(hostedViews)  // #192
        hostedViews.removeAll()
        // tmpDir/defaults are nil when setUp early-skipped (#192 gate).
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    private func renderHost<V: View>(_ view: V) -> NSView {
        _ = NSApplication.shared
        let h = NSHostingView(rootView: view)
        h.frame = NSRect(origin: .zero, size: NSSize(width: 1200, height: 800))
        h.layoutSubtreeIfNeeded()
        hostedViews.append(h)  // #192: track for WebView teardown
        return h
    }

    private func descendants(of view: NSView) -> [NSView] {
        var out: [NSView] = [view]
        for s in view.subviews { out.append(contentsOf: descendants(of: s)) }
        return out
    }

    // The source view is now pure SwiftUI — there's no NSTextView to
    // host AppKit's native find bar. Cmd+F now routes to our SwiftUI
    // MarkdownFindBar (works in both rendered and source mode), which
    // is covered by RenderedFindBarTests.
    //
    // These two tests previously asserted on NSTextView.usesFindBar
    // and NSTextView.performFindPanelAction responder availability —
    // both gone with the pure-SwiftUI source view. The contract they
    // covered ("Cmd+F does something useful in source mode") is now
    // covered indirectly: source mode uses the same SwiftUI find bar
    // as rendered mode, gated by isRenderedFindBarPresented.
    func test_findBar_modelStateUpdatesForSourceView() throws {
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("find.xml")
        try "<root>\n<a>findme</a>\n</root>\n".write(to: url, atomically: true, encoding: .utf8)
        model.open(url: url)
        XCTAssertFalse(model.isRenderedFindBarPresented)
        model.showRenderedFindBar()
        XCTAssertTrue(model.isRenderedFindBarPresented)
        model.renderedFindQuery = "findme"
        XCTAssertEqual(model.renderedFindQuery, "findme")
        model.dismissRenderedFindBar()
        XCTAssertFalse(model.isRenderedFindBarPresented)
        XCTAssertEqual(model.renderedFindQuery, "")
    }
}
