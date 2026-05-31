import XCTest
@testable import ViewerCore

/// Pure-logic tests for `SidebarDataPresence.evaluate(_:)`.
///
/// Pins that the extracted predicate reproduces the exact output of the
/// inline predicates that previously lived in `SidebarView.panelVisibility`
/// for representative input combinations.
final class SidebarDataPresenceTests: XCTestCase {

    private func presence(_ i: SidebarDataPresence.Inputs) -> [SidebarPanelKind: Bool] {
        SidebarDataPresence.evaluate(i)
    }

    // MARK: - always-present panels (independent of inputs)

    func test_bookmarksAndPlugins_alwaysPresent() {
        for inputs in [
            SidebarDataPresence.Inputs(),
            SidebarDataPresence.Inputs(hasRoot: true, hasRepo: true,
                                       hasLSPLanguage: true, claudeHasTranscripts: true),
        ] {
            let p = presence(inputs)
            XCTAssertEqual(p[.bookmarks], true)
            XCTAssertEqual(p[.pluginSections], true)
        }
    }

    // MARK: - no root open

    func test_noRoot_onlyAlwaysOnPanelsPresent() {
        let p = presence(SidebarDataPresence.Inputs())   // all false
        XCTAssertEqual(p[.files], false)
        XCTAssertEqual(p[.searchAnywhere], false)
        XCTAssertEqual(p[.git], false)
        XCTAssertEqual(p[.claudeTimeline], false)
        XCTAssertEqual(p[.lspOutline], false)
        XCTAssertEqual(p[.lspNavigation], false)
        XCTAssertEqual(p[.lspProblems], false)
        // Always-on regardless of root:
        XCTAssertEqual(p[.bookmarks], true)
        XCTAssertEqual(p[.pluginSections], true)
    }

    // MARK: - root only (no repo, no LSP, no claude)

    func test_rootOnly_filesSearchNavProblemsPresent() {
        let p = presence(SidebarDataPresence.Inputs(hasRoot: true))
        XCTAssertEqual(p[.files], true)
        XCTAssertEqual(p[.searchAnywhere], true)
        XCTAssertEqual(p[.lspNavigation], true)   // root-gated only
        XCTAssertEqual(p[.lspProblems], true)     // root-gated only
        // Still gated off — their specific data condition is false.
        XCTAssertEqual(p[.git], false)
        XCTAssertEqual(p[.claudeTimeline], false)
        XCTAssertEqual(p[.lspOutline], false)
    }

    // MARK: - root + repo

    func test_rootAndRepo_gitPresent() {
        let p = presence(SidebarDataPresence.Inputs(hasRoot: true, hasRepo: true))
        XCTAssertEqual(p[.git], true)
        // Repo without LSP/claude leaves those off.
        XCTAssertEqual(p[.lspOutline], false)
        XCTAssertEqual(p[.claudeTimeline], false)
    }

    /// A repo flag without a root must NOT surface git — the original
    /// predicate was `hasRoot && hasRepo`.
    func test_repoWithoutRoot_gitAbsent() {
        let p = presence(SidebarDataPresence.Inputs(hasRoot: false, hasRepo: true))
        XCTAssertEqual(p[.git], false)
    }

    // MARK: - root + LSP language

    func test_rootAndLSP_outlinePresent() {
        let p = presence(SidebarDataPresence.Inputs(hasRoot: true, hasLSPLanguage: true))
        XCTAssertEqual(p[.lspOutline], true)
        XCTAssertEqual(p[.lspNavigation], true)
        XCTAssertEqual(p[.lspProblems], true)
    }

    func test_lspWithoutRoot_outlineAbsent() {
        let p = presence(SidebarDataPresence.Inputs(hasRoot: false, hasLSPLanguage: true))
        XCTAssertEqual(p[.lspOutline], false)
    }

    // MARK: - root + claude transcripts

    func test_rootAndClaude_timelinePresent() {
        let p = presence(SidebarDataPresence.Inputs(hasRoot: true, claudeHasTranscripts: true))
        XCTAssertEqual(p[.claudeTimeline], true)
    }

    func test_claudeWithoutRoot_timelineAbsent() {
        let p = presence(SidebarDataPresence.Inputs(hasRoot: false, claudeHasTranscripts: true))
        XCTAssertEqual(p[.claudeTimeline], false)
    }

    // MARK: - full coverage + isPresent convenience

    func test_evaluate_coversEveryPanelKind() {
        let p = presence(SidebarDataPresence.Inputs())
        XCTAssertEqual(Set(p.keys), Set(SidebarPanelKind.allCases),
                       "evaluate(...) must return an entry for every panel kind")
    }

    func test_isPresent_matchesEvaluate() {
        let inputs = SidebarDataPresence.Inputs(hasRoot: true, hasRepo: true)
        let map = presence(inputs)
        for kind in SidebarPanelKind.allCases {
            XCTAssertEqual(SidebarDataPresence.isPresent(kind, inputs), map[kind])
        }
    }
}
