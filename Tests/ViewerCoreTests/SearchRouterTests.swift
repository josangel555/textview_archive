import XCTest
@testable import ViewerCore

/// TSK-677 — the unified search-routing model behind the single palette front
/// door. Pins the query → SearchSource + SubmitAction routing so the palette
/// wiring (the view tail) builds on a host-verified model. This is the
/// regression guard the change ships with: a routing change that broke any of
/// the three unified search types (recents / commands / global cross-file) — or
/// the in-file modes it wraps — fails here on the host gate.
final class SearchRouterTests: XCTestCase {

    // MARK: - Source routing (which engine a query targets)

    func testBareQueryRoutesToRecents() {
        let r = SearchRouter.route("ReadMe")
        XCTAssertEqual(r.source, .recents)
        XCTAssertEqual(r.term, "ReadMe", "recents keeps the whole input as the term")
    }

    func testEmptyQueryRoutesToRecents() {
        let r = SearchRouter.route("")
        XCTAssertEqual(r.source, .recents)
        XCTAssertEqual(r.term, "")
        // Files mode always resolves to `.openFile` (it opens whatever the list
        // has selected); the view dismisses when the filtered list is empty —
        // emptiness is a view concern, not a routing one.
        XCTAssertEqual(r.submit, .openFile)
    }

    func testCommandOperatorRoutesToCommands() {
        let r = SearchRouter.route(">Open Settings")
        XCTAssertEqual(r.source, .commands)
        XCTAssertEqual(r.term, "Open Settings", "the leading > is consumed")
    }

    func testGlobalSearchOperatorRoutesToGlobalText() {
        let r = SearchRouter.route("?TODO")
        XCTAssertEqual(r.source, .globalText)
        XCTAssertEqual(r.term, "TODO", "the leading ? is consumed")
    }

    func testInFileOperatorRoutesToInFileText() {
        let r = SearchRouter.route("#needle")
        XCTAssertEqual(r.source, .inFileText)
        XCTAssertEqual(r.term, "needle")
    }

    func testSymbolOperatorRoutesToSymbol() {
        let r = SearchRouter.route("@Heading")
        XCTAssertEqual(r.source, .symbol)
        XCTAssertEqual(r.term, "Heading")
    }

    func testLineOperatorRoutesToLine() {
        let r = SearchRouter.route(":42")
        XCTAssertEqual(r.source, .line)
        XCTAssertEqual(r.goto.line, 42, "line/column still parsed via the wrapped GotoQuery")
    }

    // MARK: - `?` global-search semantics

    func testGlobalSearchSubmitCarriesTrimmedTerm() {
        let r = SearchRouter.route("?  foo bar  ")
        XCTAssertEqual(r.source, .globalText)
        XCTAssertEqual(r.submit, .runGlobalSearch("foo bar"),
                       "the submit payload is trimmed so the view doesn't re-trim; internal spaces kept")
    }

    func testBareGlobalSearchOperatorIsNotActionable() {
        // Typing just "?" or "?   " is mid-entry — global mode, but nothing to
        // search yet, so Return dismisses rather than opening an empty grep.
        XCTAssertEqual(SearchRouter.route("?").submit, .none)
        XCTAssertEqual(SearchRouter.route("?   ").submit, .none)
        XCTAssertEqual(SearchRouter.route("?").source, .globalText,
                       "still global mode while the term is empty (icon/hint reflect it)")
    }

    func testLeadingWhitespaceDisablesGlobalOperator() {
        // A space before `?` → plain recents search (matches the parser's rule
        // for the other operators), so " ?foo" is a filename search.
        let r = SearchRouter.route(" ?foo")
        XCTAssertEqual(r.source, .recents)
        XCTAssertEqual(r.term, " ?foo")
    }

    func testGlobalOperatorOnlyInFirstPosition() {
        // A `?` later in the string is part of the term, not a mode switch.
        let r = SearchRouter.route("foo?bar")
        XCTAssertEqual(r.source, .recents)
        XCTAssertEqual(r.term, "foo?bar")
    }

    // MARK: - Submit-action routing for the wrapped modes

    func testRecentsSubmitOpensFile() {
        XCTAssertEqual(SearchRouter.route("readme").submit, .openFile)
    }

    func testCommandSubmitRunsCommand() {
        XCTAssertEqual(SearchRouter.route(">build").submit, .runCommand)
    }

    func testLineSubmitGoesToLine() {
        XCTAssertEqual(SearchRouter.route(":42").submit, .goToLine(42))
        XCTAssertEqual(SearchRouter.route(":42:10").submit, .goToLine(42))
    }

    func testBareColonIsNone() {
        XCTAssertEqual(SearchRouter.route(":").submit, .none)
        XCTAssertEqual(SearchRouter.route(":abc").submit, .none)
    }

    func testInFileAndSymbolSubmitJumpInFile() {
        // The view owns the selected row for `#`/`@`, so the router resolves
        // these to a payload-free jump rather than re-deriving "open file".
        XCTAssertEqual(SearchRouter.route("#text").submit, .jumpInFile)
        XCTAssertEqual(SearchRouter.route("@sym").submit, .jumpInFile)
    }

    // MARK: - Coverage guards

    func testEverySourceReachable() {
        // A new SearchSource without a route would fail this guard — the whole
        // point of the unified model is that every search type has ONE route.
        let reached = Set([
            SearchRouter.route("x").source,    // recents
            SearchRouter.route(">x").source,   // commands
            SearchRouter.route("?x").source,   // globalText
            SearchRouter.route("#x").source,   // inFileText
            SearchRouter.route("@x").source,   // symbol
            SearchRouter.route(":1").source,   // line
        ])
        XCTAssertEqual(reached, Set(SearchRouter.SearchSource.allCases))
    }

    func testRouteStaysInLockStepWithGotoParserForLegacyModes() {
        // The router must not diverge from the parser for the modes it delegates
        // (everything except `?`): same term, same line/column.
        for raw in [">cmd", "@sym", "#txt", ":12:3", "plainfile", ""] {
            let r = SearchRouter.route(raw)
            let g = GotoQueryParser.parse(raw)
            XCTAssertEqual(r.goto, g, "router should expose the parser's GotoQuery verbatim for \(raw)")
        }
    }
}
