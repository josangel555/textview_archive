import XCTest
@testable import ViewerCore

/// TSK-317 — the deeplink verb routing, extracted from the AppDelegate so
/// it's finally testable (the path POLICY had tests; the dispatch didn't).
/// Containment runs through the real `URLSchemePolicy`, so the S1.1
/// rejections are exercised end-to-end here too.
final class URLSchemeRouterTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    /// A real path inside $HOME for containment-accepting cases.
    private var homePath: String {
        NSHomeDirectory() + "/mdv-router-test.md"
    }

    func test_textviewScheme_routes_andMarkdownviewerAliasStillWorks() {
        // TSK-928: textview:// is the current scheme; markdownviewer:// is a
        // back-compat alias. Both must route identically.
        guard case .open(let a)? = URLSchemeRouter.route(
            url("textview://open?path=\(homePath)")) else {
            return XCTFail("textview:// must route")
        }
        XCTAssertEqual(a.lastPathComponent, "mdv-router-test.md")
        guard case .open(let b)? = URLSchemeRouter.route(
            url("markdownviewer://open?path=\(homePath)")) else {
            return XCTFail("markdownviewer:// alias must still route")
        }
        XCTAssertEqual(b.lastPathComponent, "mdv-router-test.md")
    }

    func test_unknownScheme_doesNotRoute() {
        XCTAssertNil(URLSchemeRouter.route(url("https://open?path=\(homePath)")),
            "a non-app scheme must never route")
        XCTAssertNil(URLSchemeRouter.route(url("evil://open?path=\(homePath)")))
    }

    func test_openVerb_routesContainedPaths_only() {
        let route = URLSchemeRouter.route(
            url("markdownviewer://open?path=\(homePath)"))
        guard case .open(let target)? = route else {
            return XCTFail("expected .open, got \(String(describing: route))")
        }
        XCTAssertEqual(target.lastPathComponent, "mdv-router-test.md")
        // The S1.1 rejection: outside home/temp drops at the boundary.
        XCTAssertNil(URLSchemeRouter.route(
            url("markdownviewer://open?path=/etc/passwd")),
            "out-of-home paths must never route")
        XCTAssertNil(URLSchemeRouter.route(url("markdownviewer://open")),
                     "open without a path is meaningless")
    }

    func test_searchVerb_partsAreOptional_butNotBothAbsent() {
        guard case .search(let root, let query)? = URLSchemeRouter.route(
            url("markdownviewer://search?q=hello")) else {
            return XCTFail("query-only search must route")
        }
        XCTAssertNil(root)
        XCTAssertEqual(query, "hello")
        XCTAssertNil(URLSchemeRouter.route(url("markdownviewer://search")),
                     "search with neither part routes nowhere")
        // A rejected root with a live query still searches (root dropped).
        guard case .search(let badRoot, "x")? = URLSchemeRouter.route(
            url("markdownviewer://search?root=/etc&q=x")) else {
            return XCTFail("rejected root must not kill the query half")
        }
        XCTAssertNil(badRoot)
    }

    func test_walkthroughVerb_routesContained_rejectsOutside() {
        let route = URLSchemeRouter.route(
            url("markdownviewer://walkthrough?path=\(homePath)"))
        guard case .walkthrough? = route else {
            return XCTFail("expected .walkthrough, got \(String(describing: route))")
        }
        XCTAssertNil(URLSchemeRouter.route(
            url("markdownviewer://walkthrough?path=/etc/passwd")),
            "the automation verb gets the SAME containment wall")
    }

    func test_unknownHosts_andForeignSchemes_routeNowhere() {
        XCTAssertNil(URLSchemeRouter.route(url("markdownviewer://format?x=1")))
        XCTAssertNil(URLSchemeRouter.route(url("https://example.com/open?path=~/x")))
    }

    /// The confirmation gate: a walkthrough deeplink EXECUTES UI
    /// automation, so the delegate must prompt before starting — pinned
    /// at the source (the route enum documents the contract; this pins
    /// the dispatch honors it).
    func test_walkthroughDeeplink_hasTheConfirmationGate() throws {
        let main = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/MarkdownViewer/main.swift"),
            encoding: .utf8)
        XCTAssertTrue(main.contains("Start walkthrough?"),
                      "the URL route must prompt before running automation")
        XCTAssertTrue(main.contains("alert.runModal() == .alertFirstButtonReturn else { return }"),
                      "cancel must abort the start")
    }
}
