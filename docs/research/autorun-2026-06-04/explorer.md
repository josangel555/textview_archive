I have a thorough, evidence-based picture. The empty state is functional but bare (no recents grid, no drag hint). Final synthesis below.

---

# Fresh review: markdown_viewer (TextView) — highest-leverage observations

First, calibration: this is a **genuinely well-engineered codebase**, not a prototype. The SwiftUI republish-scoping discipline (sibling coordinators with non-forwarded `objectWillChange`), the multi-tier file-size caps with explanatory rationale, FSEvents-driven git (not polling), 60fps-coalesced terminal output, the shared `WKProcessPool`, lazy Mermaid injection with a security model, and 322 test files all signal a mature team that already knows the easy stuff. So I've aimed past the obvious. Findings are prioritized by leverage-for-daily-dev-use, not by ease.

## P0 — Real bugs that make it feel unfinished

1. **Live system Light/Dark switch does not update syntax highlighting or the editor theme.** `DocumentModel.activeTheme` (`Sources/ViewerUI/DocumentModel.swift:2305-2308`) reads `NSApp?.effectiveAppearance` inside a *computed* property, but the only `@Published` near it is `themeOverride`. There is **no `effectiveAppearance` KVO observer and no `@Environment(\.colorScheme)` reader anywhere** (`grep` for both returns only that one line). So when the user toggles appearance while the app is open, `activeTheme` doesn't re-publish — code/source highlight runs and the CodeMirror `isDarkTheme:` flag (`ContentView.swift:538`) stay stale until some *unrelated* republish happens to fire. Markdown survives only because its CSS has a `prefers-color-scheme` media query inside the WebContent process (`markdown.css:155`) — which actually makes the bug *worse* perceptually: rendered markdown flips instantly, the code panes next to it don't. **Fix:** observe `NSApp.effectiveAppearance` (KVO) or the `AppleInterfaceThemeChangedNotification` distributed notification and bump a `@Published`. Cheap, high visibility.

2. **Editor "dirty dot" never appears (BUG-001, S2, OPEN).** Editing in Editor mode doesn't surface the unsaved indicator — the single most important "is my work safe?" signal in an editor. Given the product has drifted from view-only (DESIGN.md §1 still says "Editing. View-only." as a non-goal) into a real editor (CM6, wired replace, editable hex), this is exactly the kind of affordance that has to be airtight before users trust it with edits.

3. **Large images open at 100% / overflowing instead of fit-to-window (BUG-005, S2, OPEN).** First impression killer for an image preview — Preview.app fits by default and everyone expects that.

4. **LSP diagnostics don't reach Source view (BUG-002, S2).** A `.swift` file with an obvious type error shows "No problems detected." in the PROBLEMS panel while in source mode. For "daily developer use" this undercuts the headline LSP feature — diagnostics appear in Editor mode but not the default read mode.

There are **24 OPEN UAT bugs** total (`UAT_BUGS.md`); the S1/S2 set above is the slice that directly dents the "polished and professional" feel.

## P1 — Architectural smell with the biggest "feels fast" payoff

5. **No per-tab content-view retention; every tab switch tears down and rebuilds the document view.** `ContentView.content` (`ContentView.swift:447-487`) is a `switch model.currentState` that only ever renders the *active* tab. Switching tabs re-instantiates the `WKWebView`/CodeMirror representable, which means a fresh `loadHTMLString` (DOM reparse) for markdown and a full CM6 remount for the editor, then scroll position is *re-derived* from persisted state (`restoreScroll`, `DocumentModel.swift:1374`). The shared `WKProcessPool` (`MarkdownRenderedView.swift:54`) keeps the WebContent *process* warm, but not the *document* — so A→B→A reloads B and reloads A. This is the classic source of tab-switch latency and a brief content flash, and you've clearly been chasing flashes already (the CRIT-4 "vanishing tabs" reload-storm fix is right there at `MarkdownRenderedView.swift:178`). **Highest-leverage perf win:** retain a small LRU of realized per-tab content views (or per-tab `WKWebView`s) so re-selecting a recent tab is instant. This is the difference between "snappy like Xcode tabs" and "reloads every time like a browser back button."

6. **WebView find walks the entire DOM and rewraps text nodes on every query (`MarkdownRenderedView.swift:469-514`).** `walkAndMark` builds the full text-node list and does regex + `replaceChild` across the whole document each time the query changes. Fine for a README; on a large rendered markdown doc (up to the 4 MB render cap) this will jank on each keystroke. Consider incremental/visible-range marking or capping match count with a "showing first N" affordance.

## P2 — Resource & correctness concerns worth a look

7. **`--mcp-stdio` process never exits on stdin EOF (BUG-004, S2).** Agents that spawn one MCP server per task leak a process each. For an app explicitly designed as a Claude-Code companion, an orphaned-process-per-invocation is a real operational smell — worth fixing before agent-driven usage scales.

8. **TCC-protected roots aren't refused on the programmatic session-open path (BUG-003, S2).** `isUnderTCCProtectedRoot` exists and is the documented contract, but `SessionsCoordinator.openFolder` / `SessionsAppCoordinator.openFolder` (`SessionsAppCoordinator.swift:141`) don't enforce it — a session opened on `~/Documents` gets created *and persisted*. Privacy-adjacent; the guard already exists, it's just not wired on that path.

9. **Full-file resident cost on open: ~1.5–2× file size, single `String` + UTF-16 `NSTextStorage` backing, hard ceiling 512 MiB** (`TextFileLoader.swift:106-118`). Documented and bounded, and `isLargeReadOnly` degrades overlays gracefully — but for a "code viewer" identity, opening a few large logs simultaneously can still spike memory hard. Not a bug; flagging it as the known scaling wall if "open giant logs" becomes a use case. Memory-mapped / windowed reads are the eventual answer.

## P3 — Polish / affordance gaps (easy wins)

10. **Empty state is bare (`ContentView.swift:1214`).** Two buttons + a ⌘K hint. For daily use the highest-value first screen is a **recents/bookmarks grid** (the data already exists on the model) and an explicit drag-drop target hint — the `.onDrop` handler is already wired (`handleDrop`, `ContentView.swift:435`), it's just invisible to a new user. Cheap, and it's the first thing everyone sees on launch with no restored session.

11. **Accessibility coverage is partial — 25 of ~54 view files** carry any `accessibilityLabel`/`.accessibility(...)`. Good start (HexView, TabBar, StatusBar, sidebar all covered), but the rendered-markdown WebView and CodeMirror editor — the primary content surfaces — are where VoiceOver users will hit walls. Worth an audit pass if "professional" includes a11y.

12. **DocumentModel is 4,071 lines** and is explicitly a god-object with dozens of forwarders to coordinators (its own header at `DocumentModel.swift:7-13` admits the legacy-forwarder accretion). You've already extracted `TabCoordinator`/`EditorCoordinator`/`RepoFocusTracker` — the smell is that the *forwarders* stayed, so the file keeps growing instead of shrinking. Not urgent (it's well-organized and tested), but it's the one file that will keep being a merge-conflict magnet and a comprehension tax for new contributors. Continuing to delete forwarders as call sites migrate (the headers say "new code should call X directly") is the right trajectory; consider a lint that forbids *new* forwarders.

## What's genuinely strong (so you don't "fix" it)

- **SwiftUI republish granularity** — the sibling-coordinator pattern with deliberately non-forwarded `objectWillChange` is exactly right and rare to see done well.
- **Cache-key design** — using mtime+byteCount instead of content-hash to avoid O(N) per-body-eval (`DocumentModel.swift:2357`) is a sharp, correct call.
- **Terminal** — PTY fork with async-signal-safe child setup, EIO/EAGAIN handling, 60fps coalescing (`TerminalModel.swift:94`). Clean for a dep-free terminal.
- **WebKit navigation security** (`MarkdownRenderedView.decide`) — the WV-4 post-load `.other` file:/data: escape guard with a pure testable kernel is genuinely careful security work.
- **SQLite** read-only-by-construction + 1,000-row cap + cancellable queries; **cross-file search** cancellable with cheap modulo-strided checks.

**Net:** the codebase doesn't need rescuing — it needs the gap closed between its excellent internals and its user-perceived finish. If I had to spend a week for maximum felt impact: **(5) per-tab view retention** for snappiness, **(1) live appearance switching** + **(2) the dirty dot** for trust, and **(10) a real empty state** for first impression. Those four touch the perception of "fast, polished, professional" far more than any internal refactor.