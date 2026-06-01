import XCTest
import AppKit
@testable import ViewerUI
import ViewerCore
import ViewerKit

/// Correctness + structural guarantees for the plain → highlighted in-place
/// recolor in `SourceTextController.applyAttributedString` (PERF source-slow,
/// 2026-06-01).
///
/// The source-open sequence paints TWICE: a plain first paint (highlight
/// cache cold) then a highlighted second paint once tokenize lands. The
/// optimization re-fixes the foreground colors over the EXISTING text storage
/// when only the runs changed (byte-identical text, same font + theme),
/// instead of `setAttributedString(NSMutableAttributedString(string:))` which
/// throws away the storage and the glyph layout (a second full O(document)
/// AppKit layout on the main thread — the dominant cost, esp. with word-wrap
/// on, per the diagnosis).
///
/// Headless NSTextView can't surface the live-WindowServer layout cost (that's
/// VM-owed), so these tests assert the two things that ARE host-checkable and
/// load-bearing for correctness:
///   1. The structural guarantee: the second (highlighted) paint does NOT
///      replace the textStorage object — same instance before/after — which
///      is exactly what preserves the glyph layout in the live app.
///   2. The output is correct: text intact, colors applied at run positions.
@MainActor
final class SourceApplyRecolorTests: XCTestCase {

    private func emptyFind() -> TextDisplayView.FindState {
        TextDisplayView.FindState(query: "", caseSensitive: false, isRegex: false, nextNonce: 0, prevNonce: 0)
    }
    private func noScroll() -> TextDisplayView.ScrollLineRequest {
        TextDisplayView.ScrollLineRequest(line: nil, nonce: 0)
    }

    private func apply(_ c: SourceTextController, text: String, runs: [HighlightRun], theme: SyntaxTheme) {
        c.apply(text: text, fontSize: 13, theme: theme, runs: runs,
                wordWrap: false, showInvisibles: false, scrollLineRequest: noScroll(),
                findState: emptyFind(), onFindSummary: nil, onScrollChange: nil, onSelectionChange: nil)
    }

    func test_plainThenHighlight_sameText_recolorsInPlace_doesNotRebuildStorage() throws {
        let text = "func f() { let x = 1; return x }\nlet y = f()\n"
        let theme = SyntaxTheme.xcodeLight
        let runs = TreeSitterEngine.shared.tokenize(text, language: .swift)
        XCTAssertFalse(runs.isEmpty, "fixture should produce highlight runs")

        let c = SourceTextController(text: text, fontSize: 13, theme: theme, wordWrap: false)
        // 1) plain first paint (cache cold).
        apply(c, text: text, runs: [], theme: theme)
        let storage = try XCTUnwrap(c.textView.textStorage)

        // Plant a sentinel attribute the apply path never touches. A
        // `setAttributedString(NSMutableAttributedString(string:))` rebuild
        // would replace the entire attributed string and WIPE this sentinel
        // (and the glyph layout). The in-place recolor uses addAttribute over
        // the existing storage, so a foreign attribute survives. This is the
        // headless proxy for "the glyph layout was preserved" (which itself
        // is only observable under a live WindowServer — VM lane).
        let sentinelKey = NSAttributedString.Key("mdv.test.sentinel")
        storage.addAttribute(sentinelKey, value: "kept", range: NSRange(location: 0, length: 1))

        // 2) highlighted second paint, SAME text → in-place recolor path.
        apply(c, text: text, runs: runs, theme: theme)

        let survived = storage.attribute(sentinelKey, at: 0, effectiveRange: nil) as? String
        XCTAssertEqual(survived, "kept",
                       "sentinel attribute was wiped — the highlighted paint " +
                       "rebuilt the storage via setAttributedString instead of " +
                       "recoloring in place (the source-slow double-layout regression)")
        XCTAssertEqual(c.textView.string, text, "text content changed during recolor")
    }

    func test_highlight_appliesColorsAtRunPositions() throws {
        // A keyword-bearing line so a `.keyword` run lands at a known offset.
        let text = "func main() {}\n"
        let theme = SyntaxTheme.xcodeLight
        let runs = TreeSitterEngine.shared.tokenize(text, language: .swift)
        let keywordRun = try XCTUnwrap(
            runs.first(where: { $0.kind == .keyword }),
            "expected a keyword run for `func`")

        let c = SourceTextController(text: text, fontSize: 13, theme: theme, wordWrap: false)
        apply(c, text: text, runs: [], theme: theme)      // plain
        apply(c, text: text, runs: runs, theme: theme)    // highlighted (in-place recolor)

        let storage = try XCTUnwrap(c.textView.textStorage)
        // Color at a keyword position should be the theme's keyword color,
        // not the default text color.
        let probe = keywordRun.range.location
        let color = storage.attribute(.foregroundColor, at: probe, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, theme.color(for: .keyword),
                       "keyword run color not applied by in-place recolor")

        // A whitespace position OUTSIDE any run should carry the default
        // color (recolor reset the base before painting runs).
        // Find a gap: the space after `func` (offset 4).
        let defaultColor = storage.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
        XCTAssertEqual(defaultColor, theme.defaultText,
                       "non-run position should carry default color")
    }

    func test_reapplyIdenticalRuns_isNoOp() throws {
        let text = "let answer = 42\n"
        let theme = SyntaxTheme.xcodeLight
        let runs = TreeSitterEngine.shared.tokenize(text, language: .swift)
        let c = SourceTextController(text: text, fontSize: 13, theme: theme, wordWrap: false)
        apply(c, text: text, runs: [], theme: theme)
        apply(c, text: text, runs: runs, theme: theme)
        // Snapshot the attributed string, re-apply identical, expect no change
        // (the AttrKey no-op guard must short-circuit).
        let before = try XCTUnwrap(c.textView.textStorage).copy() as! NSAttributedString
        apply(c, text: text, runs: runs, theme: theme)
        let after = try XCTUnwrap(c.textView.textStorage)
        XCTAssertTrue(before.isEqual(to: after),
                      "re-applying identical runs mutated the storage (no-op guard defeated)")
    }

    func test_themeChange_onSameText_repaints() throws {
        // Changing only the theme must NOT take the in-place-recolor fast
        // path's same-theme branch — it must repaint with the new theme's
        // colors. (The fast path guards on prev.theme == theme.name.)
        let text = "func f() {}\n"
        let light = SyntaxTheme.xcodeLight
        let dark = SyntaxTheme.xcodeDark
        let runs = TreeSitterEngine.shared.tokenize(text, language: .swift)
        let kw = try XCTUnwrap(runs.first(where: { $0.kind == .keyword }))

        let c = SourceTextController(text: text, fontSize: 13, theme: light, wordWrap: false)
        apply(c, text: text, runs: [], theme: light)
        apply(c, text: text, runs: runs, theme: light)
        apply(c, text: text, runs: runs, theme: dark)

        let storage = try XCTUnwrap(c.textView.textStorage)
        let color = storage.attribute(.foregroundColor, at: kw.range.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, dark.color(for: .keyword),
                       "theme change on same text did not repaint with new theme colors")
    }
}
