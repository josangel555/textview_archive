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
- **Walkthrough system.** Pending — design in `docs/WALKTHROUGH.md`.
  5 decisions waiting (JSON vs YAML, transport, step taxonomy,
  persistence, branching).
- **MCP automation surface.** Pending — design in `docs/AUTOMATION.md`.
  3 decisions waiting (swift-mcp dep, bundle ID, opt-in TCP).

## Deferred features

- ~~**jq query for JSON files.**~~ DONE (commit `89f45de`) — shells
  out to `/usr/bin/jq` with Homebrew fallback. View menu → "Apply
  jq Filter… (⌥⌘J)". 6 unit tests + 200 KB no-deadlock test.
- **Expanded TreeSitter language support — IN PLAN.** User
  approved: Java, C, C++, C#, JS, TS, Rust, Swift, Kotlin, Lua.
  Currently wired: Swift, JS, TS. Currently declared but unwired:
  Java, C, C++, Rust, Kotlin (no grammar deps). Missing entirely:
  C#, Lua. Strategy: 7 new SwiftPM deps in one commit; bundle delta
  ~2 MB (22 MB after, still under 25 MB cap); roll back any grammar
  whose ABI doesn't match SwiftTreeSitter. Deferred from
  2026-05-17 overnight because adding 7 deps autonomously is risky
  when the user can't verify and the VM build canary won't run
  until Xcode finishes installing.
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
- **`test_zoom_persistsAcrossNewTab`.** Known regression after
  view-mode normalization; guarded to not crash; not investigated.
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
