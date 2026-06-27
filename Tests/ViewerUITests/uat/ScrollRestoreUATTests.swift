import XCTest
import Foundation

/// VM live-app (T4) scroll-restore-across-switch suite — TSK-1046.
///
/// ## What this guards
/// Switching between sessions/tabs must NOT reset the on-screen scroll position
/// to the top. The host model fixes (TSK-1037 editor / TSK-1041 rendered-MD)
/// proved the captured offset is serialized + hydrated correctly, yet the bug
/// PERSISTED on screen: the restored offset was never applied to the LIVE
/// WKWebView / CM6 on switch-IN (TSK-1046, two render root causes):
///   - EDITOR: `restoreScroll` re-seeded `editorScrollByTab`, but the only
///     mount-time CM6 scroll path was the `initialSelection` seed, built solely
///     from the CARET (`editorCursorByTab`). A scroll-only restore (no caret)
///     left CM6 at the top. Fixed by `DocumentModel.editorMountSelectionSeed`,
///     which seeds the once-per-mount selection at the restored LINE when there
///     is no caret.
///   - RENDERED-MD: the restored `window.scrollY` was applied ONLY in
///     `didFinish` (i.e. only on a reload). A retained/already-loaded pane that
///     re-received the offset with no HTML change never re-applied it. Fixed by
///     the no-reload re-apply block in `MarkdownRenderedView.updateNSView`.
///
/// ## Why this is a TRUE on-screen test (not a model dump)
/// The model dump is pure model state and CANNOT see a WebView's real scroll —
/// which is EXACTLY why the bug was invisible to headless tests. This suite reads
/// the LIVE scroll the views themselves report:
///   - `renderedScrollY` — the rendered preview's actual `window.scrollY`,
///     probed via the `capture-rendered-scroll` verb → `LiveScrollProbe` →
///     surfaced in the very next per-step dump.
///   - `editorScrollTopLine` — the active editor's top-visible line as reported
///     by CM6's own `scrollChanged` event (the live channel, not a model-only
///     value).
/// The setup scrolls the live views via the `rendered-scroll-to` /
/// `editor-scroll-to-line` verbs (genuine on-screen scrolls through the real
/// WebViews) — synthesized CGEvent keys can't reach a WKWebView (KeySynthUATTests
/// / TSK-1020), so a key-driven scroll is impossible here.
///
/// TIER-JUSTIFY: T4 — the observable is the LIVE WKWebView / CM6 scroll position
/// after a real cross-process session/tab switch, read back from the spawned
/// `dist/TextView.app`. No in-process `(model, sessions)` pair can produce it:
/// the headless lane has no WebView, so it can only see the model-layer offset
/// (which was already correct while the screen reset). Self-skips off the VM GUI
/// lane (`MDV_VM_GUI_SESSION=1` + built bundle).
@MainActor
final class ScrollRestoreUATTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "ScrollRestoreUAT" }
    // We open files, scroll live WebViews (need load+layout to settle), switch
    // sessions/tabs, and probe live scroll — give the WebViews room to mount.
    override class var defaultScenarioTimeout: TimeInterval { 90 }
    // TSK-1243: live WebView/CM6 scroll only renders when the app is genuinely
    // ACTIVATED (LaunchServices) — a fork/exec'd sudo-direct spawn isn't, on
    // macOS 14+. viaOpen activates it; its launch config + --script now run via the
    // AppDelegate module-scope fallback (LS-under-sudo doesn't post didFinishLaunching).
    override class var launchViaOpen: Bool { true }

    // A document long enough to scroll meaningfully in both lenses.
    private func longMarkdown(_ leadHeading: String) -> String {
        var s = "# \(leadHeading)\n\n"
        for i in 1...400 {
            s += "Paragraph line \(i) — lorem ipsum dolor sit amet, consectetur "
            s += "adipiscing elit, sed do eiusmod tempor incididunt ut labore.\n\n"
        }
        return s
    }

    private func longText(_ lines: Int) -> String {
        (1...lines).map { "code line \($0) ;; ;; ;; ;; ;; ;; ;; ;; ;; ;;" }
            .joined(separator: "\n") + "\n"
    }

    // MARK: - dump helpers

    private func model(_ dump: [String: Any]) -> [String: Any] {
        (dump["model"] as? [String: Any]) ?? [:]
    }
    private func renderedScrollY(_ dump: [String: Any]) -> Double {
        (model(dump)["renderedScrollY"] as? Double) ?? -999
    }
    /// The LIVE CM6 viewport top line read straight off the editor WebView
    /// (`__mdvView`), surfaced by the `capture-editor-scroll` / `wait-editor-line`
    /// verbs as `liveEditorTopLine`. This is the RENDER AUTHORITY — NOT the
    /// model-only `editorScrollTopLine`, which is keyed by the current `Tab.id`
    /// and goes stale/empty after a switch mints a fresh id (the very gap that
    /// made the old harness a false red). `-1` until a probe verb resolves.
    private func liveEditorTopLine(_ dump: [String: Any]) -> Int {
        (model(dump)["liveEditorTopLine"] as? Int) ?? -1
    }
    private func currentURL(_ dump: [String: Any]) -> String {
        (model(dump)["currentURL"] as? String) ?? ""
    }
    private func viewMode(_ dump: [String: Any]) -> String {
        (model(dump)["currentViewMode"] as? String) ?? ""
    }

    // MARK: - SCROLL-01 — rendered-Markdown scroll restored across a TAB switch

    /// Open two markdown files (rendered). Scroll file A down, switch to B,
    /// switch back to A, and assert A's LIVE `window.scrollY` is back near where
    /// it was — NOT reset to the top. Pre-fix this came back ~0.
    func test_SCROLL01_renderedScroll_restoredAcrossTabSwitch() throws {
        let a = try harness.writeFile("doc-a.md", longMarkdown("Doc A"))
        let b = try harness.writeFile("doc-b.md", longMarkdown("Doc B"))
        let target = 1500.0
        // SETUP is now PROVEN, not gambled: `wait-rendered-scroll` blocks until the
        // live `window.scrollY` actually reaches ~N (polling the real WebView with
        // a timeout) and stashes the settled value, so the precondition can't be a
        // false red from reading before the async scroll settled. Each `wait-…`
        // both establishes/re-reads the live scroll AND surfaces it on its own dump.
        let script = """
        open \(a.path)
        delay 1.2
        rendered-scroll-to \(Int(target))
        wait-rendered-scroll \(Int(target))
        open \(b.path)
        delay 1.0
        select-tab 1
        delay 1.2
        wait-rendered-scroll \(Int(target))
        """
        try runScenarios([
            Scenario(
                name: "rendered-tab-switch",
                argFile: a,
                script: script,
                assert: { [self] dumps, file, line in
                    // ONE dump per non-comment/non-blank script LINE (delays
                    // INCLUDED — ScriptRunner filters only `#`/empty), so lines
                    // map to CONSECUTIVE 0-based dump indices:
                    //   0 open A · 1 delay · 2 scroll · 3 wait#1 (settled) ·
                    //   4 open B · 5 delay · 6 select-tab 1 (back to A) ·
                    //   7 delay · 8 wait#2 (settled)
                    // `wait-rendered-scroll` BLOCKS until the live scroll settles
                    // and stashes it, so the SAME dump (the wait verb's own dump)
                    // carries the settled `renderedScrollY` — no off-by-one
                    // async-lag index math.
                    guard dumps.count >= 9 else {
                        XCTFail("expected >=9 dumps, got \(dumps.count) "
                            + "(app may not have launched / produced step JSON)",
                            file: file, line: line)
                        return
                    }
                    let afterScroll = dumps[3]   // wait#1
                    let afterReturn = dumps[8]   // wait#2
                    XCTAssertGreaterThan(renderedScrollY(afterScroll), 800,
                        "setup: the live preview should have scrolled down "
                        + "(got \(renderedScrollY(afterScroll)))", file: file, line: line)
                    XCTAssertTrue(currentURL(afterReturn).hasSuffix("doc-a.md"),
                        "should be back on doc-a.md after select-tab 1 "
                        + "(got \(currentURL(afterReturn)))", file: file, line: line)
                    // The headline assertion: the on-screen scroll is RESTORED,
                    // not reset to the top. Allow generous slack for layout.
                    XCTAssertGreaterThan(renderedScrollY(afterReturn), 800,
                        "TSK-1046: rendered scroll RESET on tab switch-back "
                        + "(restored=\(renderedScrollY(afterReturn)), "
                        + "expected ~\(target))", file: file, line: line)
                })
        ])
    }

    // MARK: - SCROLL-02 — rendered-Markdown scroll restored across a SESSION switch

    /// Scroll a rendered markdown file, switch to a DIFFERENT session (which
    /// drains the tab list + mints fresh Tab.ids), switch back, and assert the
    /// live scroll is restored. This is the session-switch half of the headline
    /// bug — the snapshot round-trip the model fix (TSK-1041) covers, now proven
    /// to actually re-apply on screen.
    func test_SCROLL02_renderedScroll_restoredAcrossSessionSwitch() throws {
        let projA = try harness.makeDir("projA")
        let projB = try harness.makeDir("projB")
        let a = try harness.writeFile("projA/long.md", longMarkdown("Session A doc"))
        _ = try harness.writeFile("projB/other.md", "# B\n")
        let arg = try harness.writeFile("arg.txt", "scratch\n")
        let target = 1400.0
        let script = """
        session-open-folder \(projA.path)
        delay 0.6
        open \(a.path)
        delay 1.2
        rendered-scroll-to \(Int(target))
        wait-rendered-scroll \(Int(target))
        session-open-folder \(projB.path)
        delay 1.0
        session-activate 1
        delay 1.4
        wait-rendered-scroll \(Int(target))
        """
        try runScenarios([
            Scenario(
                name: "rendered-session-switch",
                argFile: arg,
                script: script,
                assert: { [self] dumps, file, line in
                    // ONE dump per script LINE (delays INCLUDED), 0-based:
                    //   0 open-folder A · 1 delay · 2 open long.md · 3 delay ·
                    //   4 scroll · 5 wait#1 (settled) ·
                    //   6 open-folder B (switch session) · 7 delay ·
                    //   8 activate 1 (back to A) · 9 delay · 10 wait#2 (settled)
                    // `wait-rendered-scroll` BLOCKS until settled + stashes on its
                    // OWN dump → no async-lag off-by-one.
                    guard dumps.count >= 11 else {
                        XCTFail("expected >=11 dumps, got \(dumps.count) "
                            + "(app may not have launched / produced step JSON)",
                            file: file, line: line)
                        return
                    }
                    let afterScroll = dumps[5]    // wait#1
                    let afterReturn = dumps[10]   // wait#2
                    XCTAssertGreaterThan(renderedScrollY(afterScroll), 800,
                        "setup: live preview scrolled down "
                        + "(got \(renderedScrollY(afterScroll)))", file: file, line: line)
                    XCTAssertTrue(currentURL(afterReturn).hasSuffix("long.md"),
                        "back on long.md after session-activate 1 "
                        + "(got \(currentURL(afterReturn)))", file: file, line: line)
                    XCTAssertGreaterThan(renderedScrollY(afterReturn), 800,
                        "TSK-1046: rendered scroll RESET on session switch-back "
                        + "(restored=\(renderedScrollY(afterReturn)), "
                        + "expected ~\(target))", file: file, line: line)
                })
        ])
    }

    // MARK: - SCROLL-03 — CM6 editor scroll restored across a TAB switch

    /// Open a long file in the CM6 EDITOR, scroll to a known line WITHOUT moving
    /// the caret (the wheel-scroll analogue), switch tab, switch back, and assert
    /// the editor's LIVE top-visible line (CM6's own report) is restored — NOT 1.
    /// This is the editor render root cause (TSK-1046, cause b): the scroll-only
    /// restore that the caret-derived `initialSelection` seed used to drop.
    func test_SCROLL03_editorScroll_restoredAcrossTabSwitch() throws {
        // TSK-1047: SKIPPED in the spawned-app VM suite. CM6's WebContent is
        // jetsam-killed under the viaOpen lane (documented 2026-06-23), so
        // editor-scroll-to-line no-ops and the wait-editor-line poll times out
        // (got top line 1) — a HARNESS false-red, not a product bug. Editor
        // scroll-restore is reliably covered IN-PROCESS by
        // EditorScrollRestoreWebViewTests. Un-skip + drive CM6 in-process (not
        // via the spawned app) when resuming the TSK-1047 warm-cache work.
        try XCTSkipIf(true, "TSK-1047: CM6 jetsam under spawned-app viaOpen — use in-process EditorScrollRestoreWebViewTests")
        let a = try harness.writeFile("a.txt", longText(600))
        let b = try harness.writeFile("b.txt", longText(50))
        let targetLine = 220
        // THE SETUP FIX: the old script issued `editor-scroll-to-line` then read a
        // dump at a fixed index that often landed BEFORE CM6's async DOM scroll +
        // `scrollChanged` settled → `got top line 1`, a false red that never
        // established the scrolled precondition. `wait-editor-line` BLOCKS the step
        // (polling the LIVE WebView with a timeout) until the editor's TRUE
        // on-screen viewport top reaches ~N, then stashes it — so the precondition
        // is PROVABLE and the read comes from the live WebView, not the stale
        // tab-id-keyed model field.
        let script = """
        open \(a.path)
        delay 0.8
        editor-set-mode editor
        delay 1.2
        editor-scroll-to-line \(targetLine)
        wait-editor-line \(targetLine)
        open \(b.path)
        delay 0.6
        editor-set-mode editor
        delay 1.0
        select-tab 1
        delay 1.4
        capture-editor-scroll
        delay 0.6
        """
        try runScenarios([
            Scenario(
                name: "editor-tab-switch",
                argFile: a,
                script: script,
                assert: { [self] dumps, file, line in
                    // ONE dump per script LINE (delays INCLUDED), 0-based:
                    //   0 open A · 1 delay · 2 set editor · 3 delay ·
                    //   4 scroll-to-line · 5 wait-editor-line (SETTLED) ·
                    //   6 open B · 7 delay · 8 set editor (B) · 9 delay ·
                    //   10 select-tab 1 (back to A) · 11 delay ·
                    //   12 capture-editor-scroll · 13 delay
                    // wait#1 (line 5) BLOCKS until the live scroll settles and
                    // stashes it on its OWN dump → dumps[5]. After the switch-back
                    // the re-attached editor re-settles; `capture-editor-scroll`
                    // (line 12) reads the LIVE WebView async, surfacing on the
                    // trailing delay → dumps[13]. Both reads are the LIVE
                    // `liveEditorTopLine` (render authority), never the stale model
                    // field.
                    guard dumps.count >= 14 else {
                        XCTFail("expected >=14 dumps, got \(dumps.count) "
                            + "(app may not have launched / produced step JSON)",
                            file: file, line: line)
                        return
                    }
                    let afterScroll = dumps[5]    // wait-editor-line (settled)
                    let afterReturn = dumps[13]   // capture-editor-scroll → next dump
                    XCTAssertEqual(viewMode(afterScroll), "editor",
                        "setup: tab A should be in editor mode", file: file, line: line)
                    XCTAssertGreaterThan(liveEditorTopLine(afterScroll), 100,
                        "setup: CM6 should have scrolled down to ~\(targetLine) "
                        + "(got LIVE top line \(liveEditorTopLine(afterScroll)))",
                        file: file, line: line)
                    XCTAssertTrue(currentURL(afterReturn).hasSuffix("a.txt"),
                        "back on a.txt after select-tab 1 "
                        + "(got \(currentURL(afterReturn)))", file: file, line: line)
                    // Headline: the editor's on-screen scroll is restored, not
                    // reset to line 1. Generous slack for viewport-block rounding.
                    XCTAssertGreaterThan(liveEditorTopLine(afterReturn), 100,
                        "TSK-1047: editor scroll RESET to top on tab switch-back "
                        + "(restored LIVE top line=\(liveEditorTopLine(afterReturn)), "
                        + "expected ~\(targetLine))", file: file, line: line)
                })
        ])
    }

    // MARK: - SCROLL-04 — CM6 editor scroll restored across a SESSION switch

    /// The headline owner-reported bug, editor half: open a long file in the CM6
    /// EDITOR, scroll to a known line WITHOUT moving the caret, switch to a
    /// DIFFERENT session (which drains the tab list, tears down the editor
    /// WebView, and mints fresh `Tab.id`s — defeating the in-memory
    /// `editorScrollByTab` AND the `Tab.id`-keyed `MountedPanesLRU`), switch back,
    /// and assert the editor's LIVE top-visible line is restored — NOT 1.
    ///
    /// This is the session-switch case the warm-editor cache (TSK-1047) targets:
    /// the path-keyed `WarmEditorWebViewCache` re-attaches the parked editor
    /// WebView with its scroll intact (no reload), and the model belt
    /// (`seedEditorScroll` / `editorMountSelectionSeed`, TSK-1037/1046) restores
    /// scroll on the cache-miss path (eviction / fresh open). Pre-fix the editor
    /// came back to the top on a session switch even though the model serialized
    /// the top line correctly (TSK-1037).
    func test_SCROLL04_editorScroll_restoredAcrossSessionSwitch() throws {
        // TSK-1047: SKIPPED — same reason as SCROLL03 (CM6 jetsam under the
        // spawned-app viaOpen lane → harness false-red, not a product bug).
        // Reliable coverage is in-process (EditorScrollRestoreWebViewTests);
        // un-skip + drive CM6 in-process when resuming the warm-cache work.
        try XCTSkipIf(true, "TSK-1047: CM6 jetsam under spawned-app viaOpen — use in-process EditorScrollRestoreWebViewTests")
        let projA = try harness.makeDir("projA")
        let projB = try harness.makeDir("projB")
        let a = try harness.writeFile("projA/code.txt", longText(600))
        _ = try harness.writeFile("projB/other.txt", longText(40))
        let arg = try harness.writeFile("arg.txt", "scratch\n")
        let targetLine = 240
        // Same SETUP fix as SCROLL03: `wait-editor-line` BLOCKS until the LIVE CM6
        // scroll provably reaches ~N before the session switch, and the read after
        // the switch-back comes from the LIVE WebView (`liveEditorTopLine`), not
        // the model field that the freshly-minted `Tab.id` leaves stale.
        let script = """
        session-open-folder \(projA.path)
        delay 0.6
        open \(a.path)
        delay 1.0
        editor-set-mode editor
        delay 1.5
        editor-focus
        delay 0.6
        editor-scroll-to-line \(targetLine)
        wait-editor-line \(targetLine)
        session-open-folder \(projB.path)
        delay 1.2
        session-activate 1
        delay 2.0
        capture-editor-scroll
        delay 0.6
        """
        try runScenarios([
            Scenario(
                name: "editor-session-switch",
                argFile: arg,
                script: script,
                assert: { [self] dumps, file, line in
                    // ONE dump per script LINE (delays INCLUDED), 0-based:
                    //   0 open-folder A · 1 delay · 2 open code.txt · 3 delay ·
                    //   4 set editor · 5 delay · 6 editor-focus · 7 delay ·
                    //   8 scroll-to-line · 9 wait-editor-line (SETTLED) ·
                    //   10 open-folder B (switch session) · 11 delay ·
                    //   12 session-activate 1 (back to A) · 13 delay ·
                    //   14 capture-editor-scroll · 15 delay
                    // wait#1 (line 9) BLOCKS until the live scroll settles and
                    // stashes it on its OWN dump → dumps[9]. After the switch-back
                    // the re-attached editor re-settles; `capture-editor-scroll`
                    // (line 14) reads the LIVE WebView async → surfaces on the
                    // trailing delay → dumps[15]. Both are LIVE `liveEditorTopLine`.
                    guard dumps.count >= 16 else {
                        XCTFail("expected >=16 dumps, got \(dumps.count) "
                            + "(app may not have launched / produced step JSON)",
                            file: file, line: line)
                        return
                    }
                    let afterScroll = dumps[9]    // wait-editor-line (settled)
                    let afterReturn = dumps[15]   // capture-editor-scroll → next dump
                    XCTAssertEqual(viewMode(afterScroll), "editor",
                        "setup: tab A should be in editor mode", file: file, line: line)
                    XCTAssertGreaterThan(liveEditorTopLine(afterScroll), 100,
                        "setup: CM6 should have scrolled down to ~\(targetLine) "
                        + "(got LIVE top line \(liveEditorTopLine(afterScroll)))",
                        file: file, line: line)
                    XCTAssertTrue(currentURL(afterReturn).hasSuffix("code.txt"),
                        "back on code.txt after session-activate 1 "
                        + "(got \(currentURL(afterReturn)))", file: file, line: line)
                    // Headline: the editor's on-screen scroll survives the session
                    // switch (the warm-editor cache re-attach / the seed belt) —
                    // NOT reset to line 1.
                    XCTAssertGreaterThan(liveEditorTopLine(afterReturn), 100,
                        "TSK-1047: editor scroll RESET to top on SESSION switch-back "
                        + "(restored LIVE top line=\(liveEditorTopLine(afterReturn)), "
                        + "expected ~\(targetLine))", file: file, line: line)
                })
        ])
    }
}
