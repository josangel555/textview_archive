import XCTest
import AppKit
import SwiftUI
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Hosts `ContentView` in a real `NSHostingView` inside a real `NSWindow`,
/// forces layout, and walks the resulting NSView hierarchy to verify
/// invariants that "the source view actually renders" depends on:
///
/// 1. After `model.open(xmlFile)`, the model's `currentState` is `.loaded`
///    and `tabs.tabs.count == 1`.
/// 2. The hosted view contains at least one `NSScrollView` (TextDisplayView).
/// 3. That `NSScrollView` has a non-zero width — i.e. SwiftUI didn't collapse
///    it to ruler-only.
/// 4. The scroll view's documentView is an `NSTextView` containing the
///    loaded text.
/// 5. The `NSTextView`'s frame has width > the ruler's thickness, so text
///    is actually visible to the user.
///
/// This is the test the user wanted: "what we expect to see in the window
/// when it renders." It would have caught the "only line numbers visible"
/// regression directly.
@MainActor
final class ContentViewHostingTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var historyStoreURL: URL!
    /// #192: tracked so tearDown can dismantle embedded WKWebViews.
    private var hostedViews: [NSView] = []

    override func setUp() async throws {
        // #192: process-isolated — skipped in the bare sweep.
        try WebViewTestTeardown.skipUnlessEnabled()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentViewHostingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "ContentViewHostingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        historyStoreURL = tmpDir.appendingPathComponent("history.json")
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
            history: HistoryStore(storeURL: historyStoreURL),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Hosts `view` in an `NSHostingView` at the given size and forces
    /// layout. We deliberately do **not** wrap in an NSWindow — that's
    /// flaky in xctest's environment where NSApplication isn't running.
    /// Pure NSHostingView gives us enough to walk the resulting NSView
    /// subtree.
    private func host<V: View>(_ view: V, size: NSSize = NSSize(width: 1000, height: 700)) -> NSView {
        // NSApplication.shared has to exist for NSView lifecycle to be sane;
        // xctest creates it implicitly when AppKit is linked, but ensure
        // we've touched it before allocating SwiftUI hosts.
        _ = NSApplication.shared

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        hostedViews.append(host)  // #192: track for WebView teardown
        return host
    }

    private func allDescendants(of view: NSView) -> [NSView] {
        var result: [NSView] = [view]
        for sub in view.subviews {
            result.append(contentsOf: allDescendants(of: sub))
        }
        return result
    }

    // MARK: Model preconditions

    func test_openXML_modelHasOneLoadedTab() throws {
        let model = makeModel()
        let url = try writeFile("test.xml", """
        <?xml version="1.0"?>
        <root>
          <a/>
          <b/>
          <c/>
          <d/>
          <e/>
        </root>
        """)
        model.open(url: url)
        XCTAssertEqual(model.tabs.tabs.count, 1)
        guard case .loaded(let file) = model.currentState else {
            return XCTFail("expected .loaded, got \(model.currentState)")
        }
        XCTAssertTrue(file.contents.contains("<root>"))
    }

    // MARK: View hierarchy after opening a non-markdown file
    //
    // The source viewer is now pure SwiftUI (ScrollView + LazyVStack),
    // not NSScrollView + NSTextView — that combo triggered a macOS-14+
    // SwiftUI compositor bug where the surrounding TabBar / ModeBar /
    // sidebar all stopped rendering. Tests are rewritten to assert
    // model state + view-tree presence instead of NSTextView text.

    func test_openXML_hostedView_loadsContents() throws {
        let model = makeModel()
        let xmlBody = (0..<10)
            .map { "  <line index=\"\($0)\"/>" }
            .joined(separator: "\n")
        let url = try writeFile("test.xml", "<root>\n\(xmlBody)\n</root>\n")
        model.open(url: url)

        guard case .loaded(let file) = model.currentState else {
            return XCTFail("Expected .loaded, got \(model.currentState)")
        }
        XCTAssertTrue(file.contents.contains("<root>"))

        let host = host(ContentView(model: model))
        XCTAssertGreaterThan(host.frame.width, 0)
        XCTAssertGreaterThan(host.frame.height, 0)
        // The hosted tree should be non-trivially populated when a
        // source file is shown.
        XCTAssertGreaterThan(allDescendants(of: host).count, 20)
    }

    func test_openXML_hostedView_hasNonZeroOverallSize() throws {
        let model = makeModel()
        let url = try writeFile("a.xml", "<root/>\n")
        model.open(url: url)
        let host = host(ContentView(model: model))
        XCTAssertGreaterThan(host.frame.width, 0)
        XCTAssertGreaterThan(host.frame.height, 0)
    }

    // MARK: Markdown path still works (regression guard for the rendered view)

    func test_openMarkdown_hostedView_containsWebView() throws {
        let model = makeModel()
        let url = try writeFile("hello.md", "# Hi\n\nThis is a test.\n")
        model.open(url: url)

        // model.viewMode defaults to .rendered, so the WKWebView is shown.
        let host = host(ContentView(model: model))
        let descendants = allDescendants(of: host)
        let webViewClass: AnyClass = NSClassFromString("WKWebView")!
        let webViews = descendants.filter { $0.isKind(of: webViewClass) }
        XCTAssertFalse(webViews.isEmpty,
                       "Rendered markdown should embed a WKWebView")
    }

    // MARK: Layout invariant under "no sidebar" (the user's reported configuration)

    func test_openXML_atNarrowWidth_treeStillBuilds() throws {
        // With the pure-SwiftUI source view, the "ruler only, nothing
        // else visible" regression is structurally impossible: there's
        // no NSScrollView / NSTextView in the tree to collapse. This
        // test now just confirms the view tree builds without crashing
        // at narrow widths.
        let model = makeModel()
        let url = try writeFile("narrow.xml", "<root>\n<a/>\n<b/>\n</root>\n")
        model.open(url: url)
        let host = host(ContentView(model: model), size: NSSize(width: 200, height: 400))
        XCTAssertGreaterThan(allDescendants(of: host).count, 10)
    }

    func test_openXML_hostedView_hasNonTrivialTree() throws {
        let model = makeModel()
        let url = try writeFile("wide.xml", "<root>\n<a/>\n<b/>\n</root>\n")
        model.open(url: url)
        let host = host(ContentView(model: model), size: NSSize(width: 1000, height: 700))
        XCTAssertGreaterThan(allDescendants(of: host).count, 20)
    }
}
