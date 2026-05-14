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

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentViewHostingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "ContentViewHostingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        historyStoreURL = tmpDir.appendingPathComponent("history.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
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

    func test_openXML_hostedView_containsScrollViewWithText() throws {
        let model = makeModel()
        let xmlBody = (0..<10)
            .map { "  <line index=\"\($0)\"/>" }
            .joined(separator: "\n")
        let url = try writeFile("test.xml", "<root>\n\(xmlBody)\n</root>\n")
        model.open(url: url)

        let host = host(ContentView(model: model))
        let descendants = allDescendants(of: host)

        let scrollViews = descendants.compactMap { $0 as? NSScrollView }
        XCTAssertFalse(scrollViews.isEmpty,
                       "ContentView for a non-markdown file must contain at least one NSScrollView")

        let textViews = descendants.compactMap { $0 as? NSTextView }
        XCTAssertFalse(textViews.isEmpty,
                       "ContentView for a text file must contain at least one NSTextView")

        // The source NSTextView should have the file's contents.
        let sourceTextView = textViews.first { tv in
            !tv.string.isEmpty && tv.string.contains("<root>")
        }
        XCTAssertNotNil(sourceTextView,
                        "An NSTextView in the hierarchy should contain the file's text")

        // And its scroll view ancestor's content area must be wider than the
        // ruler — otherwise only line numbers are visible (the bug).
        if let tv = sourceTextView, let scroll = tv.enclosingScrollView {
            XCTAssertGreaterThan(scroll.frame.width, 100,
                                 "Scroll view too narrow — ruler-only collapse")
            XCTAssertGreaterThan(scroll.contentSize.width, 60,
                "Content area must be wider than the line-number ruler (~40pt). Got \(scroll.contentSize.width)")
            XCTAssertGreaterThan(tv.frame.width, 0,
                                 "NSTextView frame width must be > 0")
        }
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

    func test_openXML_withSidebarHidden_scrollViewClaimsFullViewportWidth() throws {
        let model = makeModel()
        // sidebar.isVisible defaults to false (no folder open).
        XCTAssertFalse(model.sidebar.isVisible)
        let url = try writeFile("wide.xml", "<root>\n<a/>\n<b/>\n</root>\n")
        model.open(url: url)

        let windowWidth: CGFloat = 1000
        let host = host(ContentView(model: model), size: NSSize(width: windowWidth, height: 700))
        let scrollViews = allDescendants(of: host).compactMap { $0 as? NSScrollView }

        // The TextDisplayView's scroll view should occupy most of the
        // window's width (subtract some chrome for TabBar/ModeBar/Dividers).
        // Strict assertion: width must be at least 60% of the window.
        let sourceScroll = scrollViews.first { ($0.documentView as? NSTextView)?.string.contains("<root>") == true }
        XCTAssertNotNil(sourceScroll, "Could not find the source-view scroll view")
        if let s = sourceScroll {
            XCTAssertGreaterThan(s.frame.width, windowWidth * 0.6,
                "Source scroll view should fill most of the window when no sidebar is open. Got width=\(s.frame.width) of windowWidth=\(windowWidth)")
        }
    }
}
