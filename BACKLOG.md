# Backlog

> **Update 2026-05-18:** UTM CI mirror is fully wired. Xcode 16.4
> installed on macOS15 VM. VM baseline: **726 tests, 3 XCTSkip, 0 fail**
> in ~95s. `ssh macOS15 'cd markdown_viewer && swift test'` is the
> one-command verifier. `scripts/vm-smoke.sh` runs end-to-end (rsync +
> build + launchctl-asuser launch + screencap + scp back) but window
> content is censored by macOS 15 Screen Capture Privacy — see
> `LESSONS.md` "macOS 15 Sequoia Screen Capture Privacy" section.
>
> **Update 2026-05-17 (overnight session):** Shipped a sweep of small
> UX fixes (sidebar top-align + static heights, current-line backdrop
> visibility, language override dropdown, Reveal in Sidebar, Files
> lock, jq CLI integration). Landed 6 large design docs under `docs/`
> (Walkthrough v2, Code Review, Sessions, LSP, Plugins v2, Mermaid
> impl). Mermaid + Code Review Phase 1 implementations spawned to
> parallel agents — see commits.
>
> **Update 2026-05-16 (afternoon session):** shipped the tabbed Git
> panel (Status / Log / Stash / Trees / Remotes with topological
> Canvas graph), proper DiffView for `.diff`/`.patch` tabs, Swift 6.3
> strict-concurrency migration (caught by VM build canary), and the
> JSONFileStore refactor (Batch 3 partial). Items below are what's
> left unticked after the sweep.
>
> **Previous overnight session swept:** Bug fixes, Sidebar / folder UX,
> Scaling polish, Build hygiene, CSV → tables, Accordion sidebar,
> Split view (Phase 2.5). Design docs landed for Mermaid,
> Walkthroughs, and Automation/MCP under `docs/`.

Roll-up of pending items as of 2026-05-16. Each line links to the
relevant module / file when applicable. Ordering inside each section
is rough priority — most-asked-for first.

## Bug fixes (small, urgent)

- ~~**Find mode: can't scroll past currently-selected match.**~~ DONE
  (commit `f12ee43` — `lastScrolledMatchIndex`).
- ~~**Rendered-MD find: highlights persist after dismiss.**~~ DONE
  (commit `f12ee43` — `window.__mdvFindClear` on empty query).
- **Invisible characters appear too grey.** NSLayoutManager renders
  invisibles in `tertiaryLabelColor` (very faint). No public API to
  override. Fix needs an `NSLayoutManager` subclass that overrides
  `drawGlyphs(forGlyphRange:at:)` to substitute our own color +
  glyphs. Deferred because NSLayoutManager subclassing has
  historically triggered the SwiftUI compositor bug (LESSONS.md).
  → `Sources/ViewerUI/TextDisplayView.swift` SourceTextController.

## Sidebar / folder UX

- ~~**Right-click folder → Bookmark Folder.**~~ DONE.
- ~~**Right-click folder → Set as Git Root.**~~ DONE.
- ~~**Right-click folder → Open in Terminal.**~~ DONE (commit `94e130d`).

## Scaling + chrome polish

- ~~**UI scaling audit.**~~ MOSTLY DONE. Remaining: ModeBar mode-picker
  text doesn't scale with `uiScale`.
- ~~**Left sidebar resize feels janky.**~~ DONE (commit `f12ee43` —
  `@State liveWidth` during drag).

## Build hygiene

- ~~**Bundle size guard.**~~ DONE (`scripts/check-bundle-size.sh`,
  wired into `build-app.sh`). Current caps: **37 MB total + 16 MB
  main-executable sub-cap** (the old "25 MB" single cap predated the
  lazy TreeSitter grammar expansion, which moved parsers into
  `Contents/Frameworks/`). Override via `BUDGET_MB` / `EXEC_BUDGET_MB`.
- ~~**Third-party attribution (DEP-001).**~~ DONE.
  `scripts/gen-third-party-notices.sh` aggregates every shipped
  component's license (SwiftPM checkouts + vendored Mermaid/CodeMirror)
  into `THIRD_PARTY_NOTICES.md`; `--check` mode flags staleness;
  `ThirdPartyNoticesTests` guards coverage. The build-app.sh copy into
  `Contents/Resources/` is G14's step.
- ~~**CTSPatch scanner provenance (DEP-003).**~~ DONE. Each vendored
  `Sources/CTSPatch*/scanner.c` carries an upstream-repo / pinned-
  revision / MIT-license banner; `CTSPatchProvenanceTests` pins a
  SHA-256 drift guard.

## Larger features (named)

- ~~**Bookmark current line + gutter marks.**~~ DONE (commit `f37af90`).
- ~~**CSV → tables.**~~ DONE.
- ~~**Collapsible accordion sidebar sections.**~~ DONE.
- ~~**Split view (Phase 2.5).**~~ DONE (commit `6fdad21`).
- ~~**Tabbed Git panel.**~~ DONE (commits `b1cd878` + `bbd273b`):
  Status / Log / Stash / Trees / Remotes; topological Canvas graph;
  per-row branch chips + HEAD chip; ⌥⌘R refresh.
- ~~**Proper file diff tab.**~~ DONE (commit `c8ea29c`): structured
  DiffView with per-hunk colored rendering; default mode for
  `.diff` / `.patch`.
- **Mermaid diagram support.** Pending — design in `docs/MERMAID.md`.
  3 user decisions waiting (vendor mermaid.min.js ~2.5 MB, %% @step N
  convention, ← / → bindings).
- **Mermaid animations.** Pending — depends on above.
- ~~**Walkthrough system.**~~ DONE 2026-05-18. Engine + drop
  transport + loader (`Sources/ViewerCore/Walkthrough/`, 30 tests).
  UI player merged via `feat/walkthrough-ui` (docked-bottom strip,
  full anchor suite, 1x/1.5x/2x speed, Note button, --walkthrough
  CLI flag, 22 tests). All 5 originally-waiting decisions resolved:
  JSON schema (locked), file-drop transport (built), step taxonomy
  (12 verbs), persistence (in-progress/completed log via store),
  branching (engine reads `Step.guardOn`, UI not yet wired for
  awaitUser-based branches).
  Open follow-ups: precise sidebar/gitTab/window popover anchoring
  via PreferenceKey; per-SHA runDiff verb; Note button →
  CodeReview thread integration.
- ~~**MCP automation surface.**~~ DONE 2026-05-18 via roll-our-own
  stdio JSON-RPC (rejected swift-sdk's pre-1.0 churn + swift-nio
  3-6 MB cost). 10 tools shipped (open_path, select_tab,
  set_view_mode, find, goto_line, visible_text, current_state,
  toggle_bookmark, list_bookmarks, snapshot_window). 51 tests +
  manual e2e against `MarkdownViewer --mcp-stdio` confirmed init/
  tools/list/tools/call. Zero new dependencies. +492 KB binary
  delta. Cut: `subscribe(events)` streaming, Unix socket / TCP
  transports, App Intents facade, audit log + first-connect prompt.

## Deferred features

- ~~**jq query for JSON files.**~~ DONE (commit `89f45de`) — shells
  out to `/usr/bin/jq` with Homebrew fallback. View menu → "Apply
  jq Filter… (⌥⌘J)". 6 unit tests + 200 KB no-deadlock test.
- ~~**Expanded TreeSitter language support.**~~ DONE 2026-05-18 via
  lazy-load through dlopen. 6 new grammars (Java, C, C++, C#, Rust,
  Lua — Kotlin skipped). Main exec shrunk 15 MB → 11 MB; total
  bundle 18 MB → 31 MB (under new 35 MB cap, 15 MB exec sub-cap
  enforced post-migration). C# was the surprise at 5.1 MB (vs
  2.0 MB design estimate). Codesign workaround: reverted to
  `--deep` because per-dylib `--options runtime` walked into SPM
  resource bundles and stamped FinderInfo. Flag for revisit before
  Developer ID + notarization.

- **Expanded TreeSitter language support — IN DESIGN (lazy-load).** [SUPERSEDED]
  Original notes:
  Decision: implement the lazy-load architecture from
  `docs/TREESITTER_LAZY_LOAD.md` — each new grammar ships as a
  dylib in `Contents/Frameworks/`, loaded via dlopen on first
  request. ~2.5 dev days; touches Package.swift, build-app.sh,
  TreeSitterEngine, and signing pipeline. Replaces the original
  "7 deps in one commit" plan, which was infeasible at the cap.
- ~~**Diff +/- line coloring in diff tabs.**~~ DONE (commit `94e130d`
  for runs; `c8ea29c` for proper DiffView with row backgrounds).
- **Phase 9 distribution.** Real Developer ID + notarization. User
  said "local signing only for now"; revisit when shipping public.

## Polish backlog

- Recents section uses generic icons; switch to `FileIconView`.
- ModeBar mode-picker text doesn't scale with `uiScale`.
- ClaudeTimeline section uses generic icons.
- Recents-list could show modified-since-last-open badge.

## Architectural / tech debt

- **DocumentModel SRP split.** 41 `@Published`, ~970 lines. Split
  into `SourceViewState` + `FindState` + facade. Mechanical but
  invasive.
- **TOCTOU on bookmark symlinks.** Bookmark resolves at add time;
  attacker can swap symlink later. Architectural fix: store
  resolved-path + inode + watch.
- **Regex DoS on main thread.** `NSRegularExpression` has no
  timeout API. Right fix: run on a background actor with
  cancellation; show "regex slow" feedback after 200ms.
- **Batch 3 refactor.** PARTIAL. `JSONFileStore` extracted (commit
  `bf2f886`). `LineNumberRulerView` deletion deferred — it's still
  gated behind `MDV_ENABLE_BROKEN_RULER=1` for the meta-regression
  test that catches the compositor bug class. Shared test helpers
  not addressed.
- **Dead-code doc clarifications (BR-06 / BR-09 / BR-10).** Audit
  follow-up; doc-only here, the in-file edits live in their owning
  groups:
  - **BR-06 — keep `LineNumberRulerView`.** It looks like dead code
    but is intentionally retained as the `MDV_ENABLE_BROKEN_RULER=1`
    fixture for the compositor-bug meta-regression test (see
    `LESSONS.md` compositor section). Do NOT delete it. A keep-note
    header on the file itself is owned by G1.
  - **BR-09 — retired `WorkspaceStore` comments.** Stale references to
    the retired `WorkspaceStore` should be scrubbed from the comments
    in its successor type (owning group's file).
  - **BR-10 — selector hardening.** `NSSelectorFromString(...)` in
    ContentView (G1) should become a compile-checked `#selector(...)`.
    Deferred — tracked here, fix in G1.
- **API-03/04 — test-only hooks demoted to `internal`.** DONE.
  `GrammarLoader._resetForTesting` / `._injectForTesting`,
  `TreeSitterEngine._jsonLanguagePointerForTesting` (now also
  `#if DEBUG`), and `PluginRegistry._setSubprocessHost` /
  `._resetForTests` were `public`, widening ViewerCore's API. Demoted
  to `internal` (tests reach them via `@testable import`). Do NOT
  re-promote. TODO (owner of `LESSONS.md`): add these to the
  "Internal-for-testing surfaces" list there — that file is outside
  this group's edit scope, so it's recorded here instead.
- ~~**`test_zoom_persistsAcrossNewTab`.**~~ NO LONGER FLAKY as of
  2026-05-18 VM run (passed in 4.681s clean). Guard remains as
  defensive (`return XCTFail` on dumps.count mismatch) but no
  longer fires. Likely fixed incidentally by recent
  Tab-Equatable-trim / lazy-materialization changes.
- **TESTS_AUDIT.md deletions.** E2E dedup proposed; awaiting
  user review.

## Hard-to-test features (manual smoke only)

These shipped without automated tests because the test cost
outweighs the value. Manual checks are in `MANUAL_TESTING.md`:

- Bookmark current line (`⌘⌥D` keyboard activation)
- Sidebar bookmark row showing `:42` suffix
- Click bookmark → scroll-to-line behavior
- Gutter diff stripe colors / placement
- Gutter bookmark dot color / placement
- `xattr -dr com.apple.FinderInfo` bundle hygiene during signing
- `NSServices` "Open in TextView" in Finder context menu
- VoiceOver labels on stars, icons, gutter
- HEX mode on PDF / MIDI / PNG (visual)
- UI-scale slider's effect on all chrome
- Right-side metadata panel for preview tabs

---

## Audit follow-ups — 2026-05-18

Multi-agent memory + perf audit landed 14 commits this push (see
`git log --oneline d45a7e2..943243a`). Highlights in `LESSONS.md`
under "Memory + perf audit (2026-05-18 multi-agent sweep)".

### Shipped

- **CSV/SQLite `LazyVStack` fix.** Was `VStack` inside `ScrollView`,
  materializing every row up-front. 1 MB CSV (~50K rows × 10 cells)
  → ~1 GB process memory → now ~10-20 MB. The bug-class fix.
- **Markdown render size cap (4 MB).** `markdownRenderMaxBytes` in
  `Sources/ViewerCore/Highlight/HighlightRun.swift`. Above the cap,
  `LargeMarkdownPlaceholderView` offers a "View as Source" button.
- **AppIcon trim.** 1024×1024@2x dropped → ~14 MB less ImageIO at
  baseline. `Resources/AppIcon.icns` now 786 KB (was 1.08 MB).
- **Shared `WKProcessPool`.** No per-WebView WebContent spawn on tab
  switch.
- **`Tab` / `DocumentState` / `TextFile` / `BinaryFile` Equatable
  metadata-only.** Eliminates O(file-size) compare on SwiftUI diffs.
- **`BookmarksStore.contains(_:)` O(N) → O(1).** Set index maintained
  alongside entries.
- **`openTabURLs: Set<URL>` published.** SidebarView's
  `isOpenInOtherTab` becomes O(1).
- **`publishSelection` binary search.** Newline-offset cache; O(loc)
  → O(log lines) per arrow-key move.
- **`SidebarModel.gitStatus(for:)` URL normalize cache.** No more
  `resolvingSymlinksInPath()` syscall per visible row.
- **`StatusBar.currentMetrics` memoized.** Per-keystroke cost on
  multi-hundred-KB source dropped from ~5-15 ms to dict-lookup.
- **CSV `parsedCache` on `@State`.** Was a computed property; was
  re-parsing the entire CSV per body re-eval (per filter-bar
  keystroke).
- **DiffView / GitLogTab / GitStatusTab `@State` caches.**
  `DiffParser.parse` / `GraphLayout.layout` / `Self.group` no longer
  run per body re-eval.
- **`@Published` equality guards.** GitPanelModel entry lists,
  SidebarModel gitStatuses, source/rendered find summaries.
- **Lazy workspace restore.** Tabs append with `state: .empty`; only
  the focused tab materializes.
- **`closeTab` URL-keyed cache purge.** Mirrors the existing
  `formattedTabIDs` cleanup; also handles `languageOverrides`,
  `formattedTextCache`, `highlightCache`, `renderedHTMLCache`.
- **Static `Palette` enum.** System `Color(nsColor:)` wrappers
  hoisted from per-cell allocations to `static let`.
- **Static formatters everywhere.** `ISO8601DateFormatter`,
  `NumberFormatter`, `JSONEncoder` previously per-call.
- **Critical bugs fixed:** FolderWatcher UAF, FileWatcher reattach
  race, WorkspaceStore silent schema downgrade, GitClient stdout
  deadlock, TreeSitterEngine compile race, cachedRegex dead
  negative-cache, CSVParser ragged-row padding.

### Pending — deferred from audit, by impact

- **`materializeIfNeeded` off-main.** Selecting a lazy tab pointing
  at a large file (32 MB log) freezes the UI briefly. Needs a
  `.loading(URL)` case added to `DocumentState` + ContentView
  placeholder; controller.open then runs in a detached Task.
  Medium-sized refactor. **Highest-leverage remaining UX win.**
- **CSV cells → `Substring` slices.** Each cell is currently an
  independent Swift `String` allocation. For a 1 MB CSV that's
  ~500K String headers (~8 MB) plus per-cell heap entries when cell
  > 15 chars. Substring sharing the source-text backing storage
  drops both. Half-day refactor; needs full CSVParser + CSVFilter
  + tests rewrite because Substring is `StringProtocol` not `String`.
  ~5-15 MB savings on multi-MB CSVs.
- **Gutter `NSString` per-paint.** `SourceGutterView` builds a
  fresh `"\(n)" as NSString` per visible line per Canvas redraw to
  compute label size. Canvas re-renders on every selection / scroll.
  Cache labelSize per `(fontSize, digitCount)`. Monospaced fonts
  → digit width is constant. Low-impact, easy fix.
- **`LineNumberRulerView` per-paint.** Same shape, but gated behind
  `MDV_ENABLE_BROKEN_RULER=1` env var — dev-only meta-regression
  test. Don't bother.
- **Lazy TreeSitter grammars.** Currently all 8 grammars imported
  at compile time → ~22 MB resident at baseline. Real fix is a
  `dlopen`-based plugin model where grammars are bundles loaded on
  first request for their language. Multi-day refactor. **User
  said skip indefinitely.**
- **Tear down WKWebView on tab switch.** Currently SwiftUI may keep
  the WebView alive across tab switches via view-tree identity.
  Force-destroy would save ~30-80 MB across switches but cost
  recreation time on switch-back. UX tradeoff; not pursued.
- **CSV ↔ filter `lowercased()` per keystroke.** `CSVFilter.apply`
  lowercases per row × per cell × per keystroke against `globalQuery`.
  Pre-compute a `[[String]]` of lowercased cells on reparse() (one-
  time cost) and filter against pre-lowercased data. ~3-10× faster
  filter typing on big CSVs. Easy, ~30 LOC.

### Memory expectations (post-audit)

Reference numbers for "what's normal":

```
Empty TextView (no files)                    ~60 MB main process
+ first markdown file (rendered mode)        +50-100 MB (WebKit XPC startup)
+ subsequent markdown files                  +5-10 MB each
+ 1 MB CSV (table mode)                      +10-20 MB
+ 1 MB JSON (source mode)                    +3-5 MB
+ 50 MB markdown                             refused, shows placeholder
```

The unreclaimable floor for a WKWebView-using app is ~35 MB of
WebKit XPC helpers (Networking + GPU) once any WKWebView has been
created in the session. They persist for app lifetime.

Activity Monitor's "Memory" column sums all WebKit XPC processes
under the parent app — so "TextView 230 MB" with one MD tab open
really means: ~110 MB main + ~35 MB persistent helpers + ~80 MB
active WebContent. Only the 110 MB is in our code.

---

## CM6 integration — 2026-05-23 Q&A follow-ups

These items were surfaced by the 16-question capabilities Q&A
(`docs/CM6_CAPABILITIES_QNA_2026-05-23.md`) and folded back into
the integration design (`docs/CM6_INTEGRATION_DESIGN_2026-05-23.md`
§12, §17, §18, §21). Listed here because they're project-level
risks / decisions that outlive the design doc — they touch bundle
budget, viewer-policy, signing, and cross-cutting UX.

### Risks (active, not yet mitigated)

- **CM6 JS-heap ceiling at large files.** `[Q4]` Hard wall around
  ~4 GB Safari WebContent process; pressure starts at 100 MB.
  NSTextView is 6× lighter per tab and handles 1 GB log files
  fine. Mitigation: **50 MB hard cap for CM6 mode**, NSTextView
  fallback for >50 MB. Design lock in design doc §17.5. **Open**:
  implement the cap in the CM6 wrapper before Phase 2 ships
  diagnostics (otherwise a 200 MB Swift file with LSP enabled =
  pathology).
- **CM6 bus factor.** `[Q14]` Marijn Haverbeke is the keystone
  for ~10 years. **Mitigated** by OpenAI sponsorship (2025) +
  fork-feasibility (~40K LOC TS for the non-language core). Lower
  risk than NSTextView TK2's documented bugginess but not zero.
  Action: pin exact CM6 versions in `scripts/codemirror-build/package.json`;
  add a quarterly check on Marijn's funding page + project commit
  cadence. Add the check to a CALENDAR item or `BACKLOG.md`
  quarterly review.
- **WebKit responder-chain order for Cmd-* keystrokes.** `[Q15]`
  Our plan (design §17.12, feature #44) depends on the AppKit
  menu seeing ⌘Z before WKWebView's `keydown` handler swallows it.
  This is not contractual. **Open**: write a VM smoke test that
  binds ⌘Z to a menu item, focuses the CM6 webview, presses ⌘Z,
  asserts the menu handler fires — *before* Phase 1 lands.
- **Tree-sitter-via-bridge regression surface.** `[Q5, Q6]`
  Choosing the bridge over `@codemirror/lang-*` means we own
  byte-range → UTF-16 conversion correctness on every push (existing
  `LSPPositionConverter` handles this). Bug class to watch: emoji /
  surrogate pairs in code comments breaking highlight offsets on
  CM6 side. **Open**: extend `LSPPositionConverter` round-trip
  tests to cover the tree-sitter→CM6 path before feature #39 lands.

### Open questions (decisions deferred)

- **Source viewer unification timeline.** `[Q2, Q3]` Design §17.9
  defers to Phase 5 conditional. Re-evaluate after feature #24
  (shared WebView) lands and we have empirical RAM numbers per
  tab. **Trigger**: when shared-WebView ships, run an A/B prototype
  on 10+ open tabs and compare against NSTextView baseline.
- **Async paste UX threshold.** `[Q16]` Where does "large paste"
  begin? Lines (50+? 100+?), bytes (100 KB+?), or both? Design
  §17.13 / feature #43 needs a product call. **Trigger**: Phase 3.
- **History snapshot persistence location.** `[Q13]` Per-tab
  sidecar file vs workspace state vs disk-cache? 100 KB doc ×
  100 undo entries ≈ 5 MB JSON per tab. Design §17.11 / feature
  #46 defers. **Trigger**: Phase 5 planning.
- **Lezer fallback for languages without tree-sitter coverage.**
  `[Q5]` We have no Lezer-only language today, but if a user
  asks for (e.g.) Vue / PHP / Kotlin support, do we ship the
  `@codemirror/lang-*` package or build a tree-sitter grammar?
  Bundle cost vs Swift code complexity tradeoff. **Trigger**:
  first user request for a CM6-only language.
- **`@codemirror/lsp-client` re-evaluation.** `[Q7]` Design
  §17.2 says don't use it. The package matures; revisit in 12
  months if the JS-side LSP transport story changes (e.g. SourceKit-LSP
  ships a WebSocket binding).
- **Per-language indent auto-detection.** Design §17.7 — defer to
  Phase 4. Not Q&A-derived but stays on this list because it's
  one of the few CM6-area decisions still open.

### Cross-doc pointers

- Full feature breakdown: `docs/CM6_INTEGRATION_DESIGN_2026-05-23.md`
  §12 rows 39–46 + §21.1 (post-Q&A change log).
- Full risk dump: same doc §17.8–17.13 + §21.2.
- Citations / source: `docs/CM6_CAPABILITIES_QNA_2026-05-23.md`
  (all `[Q#]` tags above reference its question numbering).

---

## 2026-05-29 — code-review remediation backlog

Items from the 5-lens review (2026-05-25) that landed partially or
not at all. See `docs/code-review/*_2026-05-25.md` for full
context.

### LANDED 2026-05-29 (workflow `wf_fd4d4db5`, 14 worktree agents → main `45aa0d8`)

Tier 1 + Tier 2 fanout from `docs/NEXT_STEPS_2026-05-29.md`. All
host-verified (`ViewerCoreTests` 1248 → **1347**, 0 failures; +132
host UI suite). VM E2E sweep still pending (VM was offline at merge).

- ✅ **Perf #6** — SidebarView flattened to `SidebarModel.flatVisibleRows()`
  so the outer `LazyVStack` actually virtualizes deep trees (was eager
  recursion). Keyboard-nav order preserved.
- ✅ **Perf #7** — `LSPPositionConverter` real binary search (was a
  reverse linear scan mislabeled "binary"). ~4600–5000× on a 10k-line
  doc, fuzz-checked vs linear oracle.
- ✅ **Perf #8** — `HexView.buildDump` → `HexDumpBuilder` actor streaming
  in chunks (beginEditing/endEditing per chunk). ~65× faster
  time-to-first-paint, full work off main.
- ✅ **Perf #10** — `CSVParser` streams `unicodeScalars` via iterator
  (was `Array(...)` materialization, ~2× peak RSS on big CSVs). All 16
  existing parser tests unchanged.
- ⚠️ **Perf #9** — was already done (`.caseInsensitive` option, not
  `lowercased()`). Agent instead removed a per-line `String(lineSub)`
  alloc before the reject check (reject on `Substring`, allocate only
  on match). Modest (~1.14× debug) but safe + regression-pinned.
- ✅ **Security setrlimit** — `ProcessRunner.ResourceLimits` (CPU +
  file-size + nofile via `/bin/sh ulimit … exec`) wired into jq / git /
  LSP-discovery. **NB:** macOS does NOT enforce `RLIMIT_AS`/`RLIMIT_DATA`
  so there is no memory cap — see LESSONS.md.
- ✅ **Security MCPServer** — `DispatchQueue.main.sync` → `Task{@MainActor}`
  + `DispatchSemaphore` continuation bridge (reader thread no longer in
  libdispatch drain; `precondition(!isMainThread)` guards main-on-main).
- ✅ **Security Mermaid flag** — reset per document + evict runtime when
  switching to a non-mermaid doc (was set-once for WebView lifetime).
- ✅ **Security Data slice-offset** — `Data(rawBuffer)` defense applied to
  `MCPFraming.DataReader`/`FileHandleReader` + `ClaudeLogParser.parse`.
- ✅ **Tests LSPPool** — 14 tests against `MDVFakeLSPServer` (idle reaper,
  restart-on-crash, dead-cooldown, concurrent `ensureLive`).
- ✅ **Tests dishonest discards** — the 3 named files were already clean;
  agent restated 5 real discards in the LSP smoke suites instead.
- ✅ **Test-doc audit** — `docs/UI_TEST_GAPS_2026-05-29.md` (new; old doc
  preserved).
- ✅ **CM6 diff gutter** — `DiffGutterFeeder` (pure transform) fed from
  the existing debounced `refreshDiffMarks` through a new
  `EditorCoordinator.pendingEditorGutterMarkers` dict (drained via the
  TabCoordinator close hook; republish-invariant tested).
- ✅ **CM6 lsp.json** — per-workspace override loader (`LSPWorkspaceOverrides`)
  wired into the default registry launchers; override beats discovery.

### New follow-ups surfaced by the fanout

- **LSP `initializationOptions` not forwarded.** `lsp.json` parses +
  round-trips `initializationOptions` into `ServerOverride`, but
  `LSPClient.initialize()` still builds a fixed init-params dict and
  ignores it. Small thread-through. (cm6-lsp-json risk note.)
- **`lsp.json` re-read per cold spawn**, not cached. Matches §11's
  "rarely changes" assumption; revisit if pool churn becomes a concern.
- **`LSPLog.warn` → status-bar surface.** Malformed `lsp.json` logs one
  stderr line; design §11 wanted a status-bar warning. No ViewerCore
  observability sink exists yet.
- **No subprocess memory cap** (macOS `RLIMIT_AS` unenforced). If a true
  RSS bound is needed: `sandbox-exec` (deprecated) or private
  `posix_spawnattr_setjetsam_ext_np`. LESSONS.md documents the trap.
- **Pre-existing host test failure (macOS 26).**
  `MarkdownRenderedViewTests.test_decide_sameDocFragment_isAllowed`
  fails on the host (Darwin 25.x) — Foundation URL fragment parser
  regressed past the 15.6.1 `c0a9092` fix. Fails identically on clean
  `main`; not a regression. Needs a Foundation-version-robust
  same-doc-fragment compare. Passes on the macOS 15.6.1 VM.
- **VM E2E sweep for this batch** still owed (VM offline at merge time) —
  CM6 gutter render, mermaid evict in a live WebView, HexView streaming
  responsiveness, sidebar deep-tree virtualization visual.

### Performance — findings #6–#10

The first-tier perf root causes (#1 sidebar republish chain, #2
renderedHTML key, #5 highlightCache `@Published`) landed in commit
`bf88840`. Remaining:

- **#6 Eager `ForEach` recursion inside `LazyVStack`** —
  `SidebarView.swift:763`. Only top-level rows are lazy; deep
  trees materialize eagerly. Probable fix: hoist each level into
  its own `LazyVStack` or use `OutlineGroup`.
- **#7 `LSPPositionConverter` linear scan labelled "binary search"**
  — `LSPPositionConverter.swift:70`. Built per-hover, walked
  linearly. Probable fix: actual binary search on the cached line-start
  array.
- **#8 `HexView.buildDump` synchronous on main thread** —
  `HexView.swift:477`. 4 MB file at width=16 builds ~20 MB string
  + attributed string before `setAttributedString`. Move off main
  to a background actor; stream into NSTextView in chunks.
- **#9 `CrossFileSearch.lowercased()` per file** —
  `CrossFileSearch.swift:130, 140`. Plus per-line in matched files.
  Pre-compute lowercased buffer per scan, not per match.
- **#10 `CSVParser Array(text.unicodeScalars)`** —
  `CSVParser.swift:66`. Doubles peak memory on big CSVs. Iterate
  scalars in-place without materializing the array.

Each is an independent small agent; can ship in parallel.

### Security — remaining findings

`docs/code-review/SECURITY_CONCURRENCY_2026-05-25.md` listed 27
findings. Top 11 landed in commit-batch around 2026-05-25. Still
open (M/L severity):

- §3.4 LSP/jq/git lack `setrlimit`-style CPU+memory caps. Needs a
  small C bridging layer (only `PluginSubprocessHost` has it
  today). Per-request timeouts mitigate but don't bound CPU on a
  single request.
- §5.7 / §6.3 / §6.4 — additional regex-engine and URL-handler
  hardening. Diminishing returns now that the primary surfaces
  are covered.
- `MCPServer` `DispatchQueue.main.sync` from a background thread —
  latent wedge risk if a future MainActor handler awaits anything
  bouncing through the same thread. Refactor to a continuation-based
  bridge.
- Mermaid `mermaidInjected` flag is permanent per-WebView once
  set. Should reset on document change. (`MarkdownRenderedView.swift`.)

### Tests — open follow-ups

- `Tests/ViewerUITests/{ComponentVisualTests, InteractionScriptTests,
  InteractionDeepTests, DragDropTests}` had 9 of 12 dishonest
  assertions restated in commit `3707629`. The 3 remaining were
  borderline (smoke tests with `_ = result` discards); evaluate
  whether the smoke value justifies the brittle shape.
- `FakeLSPServer` covers transport behaviors; the LSP `Pool` actor
  hasn't been exercised against the fake (only `Client`). Extend
  to cover idle reaper, restart-on-crash, dead-cooldown, concurrent
  `ensureLive` races.
- VM E2E tests for the CM6 editor (hover popover render, Cmd-click
  jump, NSMenu context-menu pop, paste-large-confirm prompt) are
  not exercised. Per CLAUDE.md they're VM-only — sweep via the
  `MultiScenarioTestCase` harness when VM is up.

### Code quality — landed decisions + remaining

E (DocumentModel split), F (git layer), G (WorkspaceStore retire),
H (ProcessRunner), I (main.swift slim), J (find-bag collapse) all
landed across commits `bb9dc4d` / `38f8175` / `bc5f320` / `b89f767`.

Remaining quality follow-ups:

- **`TabKeyedStore<T>` generic**: deferred per the TabCoordinator
  agent's report. Would fold the 9× per-tab dict cleanup into one
  fan-out. Pairs naturally with whatever-comes-next-coordinator if
  there is one.
- **`HighlightCacheActor` map + `renderedHTMLCache` extraction**.
  Currently still on DocumentModel; they're per-tab-keyed and
  conceptually subsystem state. Candidates for a future
  `CacheCoordinator` if a fourth split is needed.
- **`main.swift` further extraction**: 1580 LOC after `I` landed.
  Menus, NSServices, walkthrough wiring, MCP startup are all still
  inline. Each is a small further-extraction.
- Apply the `Data(rawBuffer)` defensive pattern in any other framing
  code beyond `LSPFraming`. Audit `MCPFraming` + any other custom
  framing for the macOS 26 `Data.subdata` slice-offset bug.

### CM6 — Phase 4 items held for explicit decision

- **Vim mode** (`@replit/codemirror-vim`, MIT, ~210 KB). New JS
  dep — awaits explicit user approval per the no-new-deps rule.
- **Shared WebView refactor** — conditional on a perf prototype.
  Current per-tab WebView is stable; the perf win is speculative
  until measured.
- **Diff/blame gutter Swift-side wiring**. JS API in place; the
  Swift-side feed belongs in `GitService`/`DocumentModel`, not the
  CM6 layer.
- **LSP `requestHover` markdown rendering**. Plain-text today;
  `LSPMarkdownRenderer` is AppKit-only and can't run in WKWebView.
  Either ship a ~5 KB JS markdown→HTML in the CM6 bundle or
  convert to NSAttributedString → HTML at the bridge.
- **`workspaceSymbol/resolve` for URI-only stubs**. Modern lazy
  resolve shape isn't supported. Rare in practice; sourcekit-lsp
  + pyright inline the full `Location`.
- **`lsp.json` per-workspace override**. Designed in
  `docs/LSP_DESIGN.md` §11; not implemented.

## Merge-campaign follow-ups (2026-05-31)

- **VM-verify the landed UI merges** (build + host-unit verified, NOT
  VM-verified — VM was offline):
  - multi-repo: git badges, repo picker, repo-root glyphs, per-repo accordion
    presence.
  - session-ui: shoulder rails on all 3 edges, large-file source render
    (>64 MiB → `isLargeReadOnly` fast path), view-mode picker, Claude-rail
    filled-state.
- **Two merges DEFERRED** (large UI conflict regions; need VM + careful
  resolution):
  - `feat/unified-search-panel` — ~305-line `main.swift` conflict
    (post-integration) + `CrossSearchPanel → UnifiedSearchPanel` replacement
    cascading through `DocumentModel`/`SearchAnywhereSection`.
  - `fix/sidebar-zoomshortcut-metadatafont` — ~480-line `SidebarView` conflict.
- **If `unified-search` lands later, RE-APPLY the audit's CrossSearchPanel
  fixes to `UnifiedSearchPanel`.** The branch DELETES `CrossSearchPanel`
  (created before the 2026-05-30 audit), so its a11y labels + hardcoded-color
  fix (audit finding #57 / the WV·a11y pass) are NOT in the replacement.
  Verify/port them.
- **Branch cleanup available**: ~14 already-shipped feature branches
  (`feat/cm6-editor`, `feat/lsp-v1`, `feat/sessions-v1`, `feat/walkthrough-ui`,
  `feat/plugins-v1`, `feat/treesitter-lazyload`, `feat/code-folding`,
  `feat/lsp-roadmap-phases-A-E`, `feat/mcp-stdio`,
  `feat/search-anywhere-highlight`, `feat/editor-mode-poc`, `agent-cm6-phase2`,
  `fix/sidebar-panels-polish`, `phase5b-treesitter`), plus `audit/pre-launch`
  (now an ancestor of `main`) and `docs/reusable-core` (content on `main`).
  Prune the confirmed-landed; KEEP `poc/{lsp,plugins,sessions}` (per owner).

## 2026-06-01 — post-integration backlog (open items from the merge/feature run)

Landed this run (on `main`, headless-gate-green): testing-pyramid flip
(#195/#196), Rust-CSV integration behind a flag (#198), HTML rendering
(#199), CI headless-gating + image viewer (#200), sessions per-session
independence + types + GLOBAL zoom/wrap/theme (#184). Items still open:

### Open tasks
- **#191 — Memory peak-bounding for large files.** The real "memory
  stays high" fix; architectural, touches Core-ish state. Held pending
  design (and partly gated by the Rust-core migration, which may reframe
  it).
- **#194 — #192 true fix.** SwiftUI AttributeGraph teardown so the
  in-process WKWebView suites can rejoin the bare `swift test` sweep
  instead of `#192`-gating themselves out. Low priority (VM lane covers
  them today).
- **#201 — macOS-26 URL-fragment test.** `MarkdownLinkPolicyTests`
  `test_decide_sameDocFragment_isAllowed` fails on Darwin 25.x
  (Foundation URL-fragment parser regressed past the 15.6.1 fix); green
  on the macOS-15 VM + CI. Fix = a Foundation-version-robust field-by-
  field same-doc-fragment compare. Pre-existing, not a regression.
- **#202 — Sessions R1-R3 structural god-object split.** #184 achieved
  per-session independence BEHAVIORALLY via the shared-DocumentModel
  façade (detach→snapshot→hydrate + leak-guards). The structural split
  (extract FindModel/GitPanelModel/per-session DocumentModel off the
  ~3184-line singleton + re-point observed view sites) is multi-day +
  view-touching — OWNER DECISION: do it, or is the behavioral façade
  sufficient? Small companion: wire `SessionKind` to a "New Session ▸
  Kind" menu (plumbed + tested via `openFolder(kind:)`, no UI entry yet).
- **#203 — Code-review `.textview/` relocation + UI.** Model/export/git
  layer already built + tested (`Sources/ViewerCore/Review/`,
  `docs/CODE_REVIEW_DESIGN.md`). Open: relocate the store from the global
  Application-Support path to a project-local `.textview/` folder,
  evaluate JSONL vs the current per-review JSON, and build the missing UI
  (diff-with-line-comments, comment cards, export-to-Claude). Driven by
  its own workflow.

### Rust integration review-laters (all behind the flag-off default)
- **arm64-only vs xcframework** — the CSV integration links the Rust
  `.a` via `unsafeFlags` (arm64 only), not a cross-platform xcframework
  `binaryTarget` (the x86_64 slice is blocked by the no-install rule).
  THE one genuine future fork + the PoC→shippable gate
  (`RUST_CORE_MIGRATION.md` §5/§7 step 2). Decide before any "core is the
  product" / cross-platform direction.
- **Static-link → dylib at Developer-ID.** Self-signed local cert blocks
  dylib loading under hardened runtime ("different Team IDs"); static
  `.a` is the workaround. dylib path opens at notarization. (LESSONS
  candidate.)
- **`deny.toml` unenforced** + **trace-sink FFI not wired** — PoC
  carryovers; fold in when the real Rust workspace stands up
  (`RUST_CORE_MIGRATION.md` §7 step 1).
- **Size caps bumped** (18→20 / 37→40 MB) surfaced that main's exec was
  ALREADY over the old 18 MB cap pre-Rust — pre-existing drift worth an
  independent look.

### VM-owed visual verifications (host-built + headless-verified, NOT VM-verified)
- Sessions #184: per-session panel rails + tab/selection restore across a
  session switch; GLOBAL zoom/wrap/theme actually shared on screen.
- Image viewer: scroll/pinch zoom + drag-direction sign.
- WAVE 1/2 UI + the session-ui shoulder rails / large-file render +
  multi-repo git badges (carried from the 2026-05-31 merge campaign).

