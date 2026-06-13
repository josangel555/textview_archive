import XCTest
import AppKit
@testable import ViewerUI
import ViewerCore
import ViewerKit

/// TSK-736 — `SourceTextController.applyFindHighlights` skips its O(document)
/// remove-all + O(matches) repaint on an apply() where nothing find-related
/// changed. A mouse hover line-crossing re-bodies the source view →
/// `updateNSViewController` → apply(), so on a big log with Find active that
/// per-mouse-move temp-attr churn was the felt lag. `findHighlightsLive` tracks
/// whether the find wash (a layout-manager temp-attr) is currently painted and
/// is cleared whenever the storage's characters are replaced.
///
/// Technique: paint the wash, then MANUALLY strip it; a re-apply that REPAINTS
/// re-adds it, one that SKIPS leaves it stripped — distinguishing the two with
/// no production counter. TEETH: delete the early-out in `applyFindHighlights`
/// → `test_unchangedFindApply_skipsRepaint` goes red (the re-apply repaints).
@MainActor
final class TextSearchRepaintGuardTests: XCTestCase {

    private func find(_ q: String, next: Int = 0, prev: Int = 0) -> TextDisplayView.FindState {
        TextDisplayView.FindState(query: q, caseSensitive: false, isRegex: false,
                                  nextNonce: next, prevNonce: prev)
    }
    private func apply(_ c: SourceTextController, text: String,
                       runs: [HighlightRun] = [], theme: SyntaxTheme = .xcodeLight,
                       find: TextDisplayView.FindState) {
        c.apply(text: text, fontSize: 13, theme: theme, runs: runs,
                wordWrap: false, showInvisibles: false,
                scrollLineRequest: TextDisplayView.ScrollLineRequest(line: nil, nonce: 0),
                findState: find, onFindSummary: nil, onScrollChange: nil, onSelectionChange: nil)
    }

    /// Is the find wash (a `.backgroundColor` temporary attribute) painted at `index`?
    private func washed(_ c: SourceTextController, at index: Int) -> Bool {
        c.textView.layoutManager?.temporaryAttribute(
            .backgroundColor, atCharacterIndex: index, effectiveRange: nil) != nil
    }
    private func stripWash(_ c: SourceTextController, _ text: String) {
        c.textView.layoutManager?.removeTemporaryAttribute(
            .backgroundColor, forCharacterRange: NSRange(location: 0, length: (text as NSString).length))
    }

    func test_unchangedFindApply_skipsRepaint() {
        let text = "axbxc\n"   // "x" at offsets 1 and 3
        let c = SourceTextController(text: text, fontSize: 13, theme: .xcodeLight, wordWrap: false)
        apply(c, text: text, find: find("x"))
        XCTAssertTrue(washed(c, at: 1), "precondition: the find wash is painted at a match")

        stripWash(c, text)
        // A hover-driven re-apply with IDENTICAL find state must NOT repaint.
        apply(c, text: text, find: find("x"))
        XCTAssertFalse(washed(c, at: 1),
                       "an unchanged find apply re-painted the wash — the TSK-736 early-out is defeated")
    }

    func test_nextMatchNav_repaints() {
        let text = "axbxc\n"
        let c = SourceTextController(text: text, fontSize: 13, theme: .xcodeLight, wordWrap: false)
        apply(c, text: text, find: find("x"))
        stripWash(c, text)
        // A next-match navigation (nonce bump) MUST repaint (current match moves).
        apply(c, text: text, find: find("x", next: 1))
        XCTAssertTrue(washed(c, at: 1), "a next-match navigation must repaint the wash")
    }

    func test_queryChange_repaints() {
        let text = "axbyc\n"   // x@1, y@3
        let c = SourceTextController(text: text, fontSize: 13, theme: .xcodeLight, wordWrap: false)
        apply(c, text: text, find: find("x"))
        stripWash(c, text)
        // Different query → different lastFindKey → must repaint at the new match.
        apply(c, text: text, find: find("y"))
        XCTAssertTrue(washed(c, at: 3), "a query change must repaint at the new match")
    }

    func test_storageRebuild_clearsLive_soFindRepaints() throws {
        // A theme change WITH highlight runs rebuilds the storage
        // (setAttributedString), wiping the find temp-attrs. `findHighlightsLive`
        // must go false so the next applyFindHighlights repaints, not skips.
        let text = "func x() {}\n"
        let runs = TreeSitterEngine.shared.tokenize(text, language: .swift)
        XCTAssertFalse(runs.isEmpty, "fixture should produce highlight runs")
        let xIndex = (text as NSString).range(of: "x").location

        let c = SourceTextController(text: text, fontSize: 13, theme: .xcodeLight, wordWrap: false)
        apply(c, text: text, runs: runs, theme: .xcodeLight, find: find("x"))
        XCTAssertTrue(washed(c, at: xIndex), "precondition: wash painted")

        // Theme change → storage rebuild wipes temp-attrs; find MUST repaint.
        apply(c, text: text, runs: runs, theme: .xcodeDark, find: find("x"))
        XCTAssertTrue(washed(c, at: xIndex),
                      "after a storage-rebuilding theme change the find wash must be repainted, not skipped")
    }
}
