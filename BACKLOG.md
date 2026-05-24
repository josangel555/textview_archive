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
  25 MB cap, wired into `build-app.sh`).

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
