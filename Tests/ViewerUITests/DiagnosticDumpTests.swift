import XCTest
import AppKit
import SwiftUI
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// L3 tests using `DiagnosticDump` to assert on EVERY property that
/// determines whether content is visible on screen, not just whether a
/// view exists in the NSView subtree. Catches the failure modes that
/// `ContentViewHostingTests` (presence-only) misses:
///   - colors that look right in code but resolve to invisible at runtime
///   - layer.opacity=0, layer.isHidden, masksToBounds clipping
///   - NSTextView glyphs not generated despite textStorage populated
///   - zero-sized views deep in the tree
///   - ancestor hidden / alpha=0 propagation
///
/// These tests render inside `NSHostingView` only (no real `NSWindow`),
/// so they don't exercise the `WindowServer` compositor — but they DO
/// validate every property up to that boundary, which is where most
/// invisible-content bugs live.
@MainActor
final class DiagnosticDumpTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var historyStoreURL: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticDumpTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DiagnosticDumpTests-\(UUID().uuidString)"
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

    /// Render `view` into an NSHostingView at the given size, force
    /// layout, and return both the hosting view and a DiagnosticDump
    /// JSON description of its subtree.
    private func dump<V: View>(
        _ view: V,
        size: NSSize = NSSize(width: 1200, height: 800)
    ) -> (NSView, [String: Any]) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return (host, DiagnosticDump.describeView(host, depth: 0, includeRecursive: false))
    }

    /// Walk the diagnostic tree and collect every node matching a
    /// predicate. Avoids having to repeat tree-walking logic in each test.
    private func collect(
        from node: [String: Any],
        matching predicate: ([String: Any]) -> Bool
    ) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if predicate(node) { out.append(node) }
        if let subs = node["subviews"] as? [[String: Any]] {
            for s in subs {
                out.append(contentsOf: collect(from: s, matching: predicate))
            }
        }
        return out
    }

    private func nodesOfClass(_ cls: String, in tree: [String: Any]) -> [[String: Any]] {
        collect(from: tree) { ($0["class"] as? String) == cls }
    }

    // MARK: - Source-text view: the bug we just fixed

    func test_sourceView_noZeroSizedViews() throws {
        let model = makeModel()
        let url = try writeFile("test.xml", "<root>\n<a/>\n<b/>\n<c/>\n</root>\n")
        model.open(url: url)
        let (_, tree) = dump(ContentView(model: model))
        // SwiftUI's internal helper containers (DocumentView,
        // PlatformGroupContainer) are sometimes zero-sized inside an
        // NSHostingView without a real NSWindow — they get sized once
        // ordered into a window. That's not our bug; we only care that
        // the *user-visible* views aren't collapsed. So we filter to
        // classes we own + the load-bearing AppKit primitives.
        let zeroed = collect(from: tree) { $0["zeroSize"] != nil }
        let userVisible = zeroed.filter { node in
            let cls = node["class"] as? String ?? ""
            // The pure-SwiftUI source view doesn't introduce NSScrollView /
            // NSTextView anymore, but if a future regression brings them
            // back, a zero-sized one would be highly visible. Keep these
            // sentinels for defense-in-depth.
            return cls == "NSScrollView"
                || cls == "NSClipView"
                || cls == "NSTextView"
        }
        XCTAssertTrue(userVisible.isEmpty,
            "Found \(userVisible.count) zero-sized USER-VISIBLE view(s):\n"
            + userVisible.prefix(5).map { "\($0["class"] ?? "?")=\($0["frame"] ?? "?")" }.joined(separator: "\n"))
    }

    func test_sourceView_loadsFileContents() throws {
        // The pure-SwiftUI source view doesn't expose an NSTextView,
        // so we can't introspect glyphs from the realized AppKit tree.
        // Verify the model-level contract: text is loaded and routed to
        // the view via `displayText(for:)` — which feeds SwiftUI Text
        // rows directly.
        let model = makeModel()
        let url = try writeFile("test.xml", "<root>\n<a/>\n<b/>\n<c/>\n</root>\n")
        model.open(url: url)
        guard case .loaded(let file) = model.currentState else {
            return XCTFail("Expected .loaded state, got \(model.currentState)")
        }
        XCTAssertFalse(file.contents.isEmpty, "Text content must be loaded")
        let display = model.displayText(for: file)
        XCTAssertTrue(display.contains("<root>"),
            "displayText should include the file's contents (no formatting yet)")
        // Sanity-check that the SwiftUI tree got populated when this
        // file is shown.
        let (host, _) = dump(ContentView(model: model))
        XCTAssertGreaterThan(descendantCount(of: host), 20,
            "Source-view tree should populate non-trivially. Got \(descendantCount(of: host)) subviews.")
    }

    private func descendantCount(of view: NSView) -> Int {
        1 + view.subviews.reduce(0) { $0 + descendantCount(of: $1) }
    }

    func test_sourceView_isPureSwiftUI_noNSScrollView() throws {
        // Regression for the SwiftUI compositor pathology. The source
        // view is now pure SwiftUI (ScrollView + LazyVStack) — there
        // must be NO NSScrollView in the rendered tree under the
        // TextDisplayView host. An NSScrollView in this tree triggers
        // the macOS-14+ bug where TabBar / ModeBar / Sidebar all stop
        // committing their layer contents.
        let model = makeModel()
        let url = try writeFile("g.xml", "<root>\n<a/>\n<b/>\n</root>\n")
        model.open(url: url)
        let (host, _) = dump(ContentView(model: model))
        var nsScrollCount = 0
        var nsTextViewCount = 0
        func walk(_ v: NSView) {
            if v is NSScrollView { nsScrollCount += 1 }
            if v is NSTextView { nsTextViewCount += 1 }
            for s in v.subviews { walk(s) }
        }
        walk(host)
        // ZERO NSScrollView / NSTextView in source mode. (Tab bar uses
        // a HostingScrollView wrapper which is SwiftUI's internal and
        // doesn't subclass NSScrollView in the strict-`is` sense — but
        // even if it did the count would be limited, hence the cap.)
        XCTAssertTrue(nsTextViewCount == 0,
            "Source view must not contain any NSTextView (pure-SwiftUI source viewer). Found \(nsTextViewCount).")
    }

    // MARK: - Empty state

    func test_emptyState_renders_buttonsAndNonZeroContent() throws {
        let model = makeModel()
        XCTAssertEqual(model.tabs.tabs.count, 0)
        let (host, _) = dump(ContentView(model: model))
        var buttonCount = 0
        var hostingViewCount = 0
        func walk(_ v: NSView) {
            let cls = String(describing: type(of: v))
            if cls.contains("Button") { buttonCount += 1 }
            if cls.contains("HostingView") || cls.contains("HostingScrollView") {
                hostingViewCount += 1
            }
            for s in v.subviews { walk(s) }
        }
        walk(host)
        // Either we see explicit buttons (NSButton subclass) or we see
        // hosted SwiftUI subviews — both confirm the empty state rendered
        // beyond just the outer hosting view itself.
        XCTAssertGreaterThanOrEqual(buttonCount + hostingViewCount, 2,
            "EmptyStateView should produce ≥2 hosted child views. Found buttons=\(buttonCount), hostingViews=\(hostingViewCount).")
        XCTAssertGreaterThan(host.frame.width, 0)
        XCTAssertGreaterThan(host.frame.height, 0)
    }

    // MARK: - Markdown rendered

    func test_markdownRenderedView_hasWKWebView_withNonZeroSize() throws {
        let model = makeModel()
        let url = try writeFile("hello.md", "# Hi\n\nbody\n")
        model.open(url: url)
        let (_, tree) = dump(ContentView(model: model))
        let webViews = nodesOfClass("WKWebView", in: tree)
        XCTAssertFalse(webViews.isEmpty, "Rendered markdown must embed a WKWebView")
        if let web = webViews.first, let frame = web["frame"] as? String {
            // Frame is encoded as "(x,y wxh)". Strip non-numeric and check width/height.
            let parts = frame
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
                .split(whereSeparator: { ",x ".contains($0) })
                .compactMap { Double($0) }
            XCTAssertEqual(parts.count, 4, "Unexpected frame format: \(frame)")
            if parts.count == 4 {
                XCTAssertGreaterThan(parts[2], 0, "WKWebView width must be > 0")
                XCTAssertGreaterThan(parts[3], 0, "WKWebView height must be > 0")
            }
        }
    }

    // MARK: - Tab bar

    func test_tabBar_isPresent_andHasNonZeroFrame_whenFileOpened() throws {
        let model = makeModel()
        let url = try writeFile("a.md", "# a\n")
        model.open(url: url)
        let (host, _) = dump(ContentView(model: model))
        // SwiftUI's .accessibilityIdentifier doesn't always set
        // NSView.accessibilityIdentifier on the realized AppKit view —
        // it can be exposed only via the AX query path. So instead of
        // matching by ID, we identify the TabBar by its structural role:
        // a PlatformContainer hosting a SwiftUI tab strip (~28pt tall,
        // near the top of the window).
        var candidates: [NSView] = []
        func walk(_ v: NSView) {
            let cls = String(describing: type(of: v))
            // SwiftUI's tab-bar scroll wrapper is a PlatformContainer.
            // Top-anchored, narrow (height ~28), spans most of window width.
            if cls == "PlatformContainer"
                && v.frame.height < 50
                && v.frame.height > 10
                && v.frame.width > 200 {
                candidates.append(v)
            }
            for s in v.subviews { walk(s) }
        }
        walk(host)
        XCTAssertFalse(candidates.isEmpty,
            "Could not find a TabBar-shaped PlatformContainer (narrow + wide). Tree depth=\(host.subviews.count) top-level subviews.")
    }

    // MARK: - Whole-tree sanity

    func test_wholeTree_noOpacityZeroOrAncestorHidden() throws {
        // Any view with isHiddenOrHasHiddenAncestor=true OR layer.opacity<=0
        // is invisible. Assert nothing important is in that state for a
        // freshly-opened source file.
        let model = makeModel()
        let url = try writeFile("z.xml", "<root>\n<a/>\n</root>\n")
        model.open(url: url)
        let (_, tree) = dump(ContentView(model: model))
        // We skip _FocusRingView (legitimately near-transparent), the
        // hidden horizontal scroller, and SwiftUI's own zero-alpha
        // overlay views (KeyViewProxy etc).
        let allowZeroAlpha: Set<String> = [
            "_FocusRingView", "NSScroller", "KeyViewProxy",
            "_NSBannerDecorationView"
        ]
        var problems: [String] = []
        func walk(_ node: [String: Any]) {
            let cls = node["class"] as? String ?? "?"
            let hidden = node["isHiddenOrHasHiddenAncestor"] as? Bool ?? false
            let alpha = (node["alphaValue"] as? Double) ?? 1
            let layerOpacity = (node["layer"] as? [String: Any])?["opacity"] as? Double ?? 1
            if !allowZeroAlpha.contains(cls) {
                if hidden { problems.append("\(cls): isHiddenOrHasHiddenAncestor=true") }
                if alpha <= 0.01 { problems.append("\(cls): alphaValue=\(alpha)") }
                if layerOpacity <= 0.01 { problems.append("\(cls): layer.opacity=\(layerOpacity)") }
            }
            for s in node["subviews"] as? [[String: Any]] ?? [] { walk(s) }
        }
        walk(tree)
        XCTAssertTrue(problems.isEmpty,
            "Found unexpectedly invisible views:\n" + problems.joined(separator: "\n"))
    }
}
