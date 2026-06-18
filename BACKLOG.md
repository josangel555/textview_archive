# Backlog

## 2026-06-16 — VM harness completion (deferred; board-tracked)
- **TSK-954** (`fixed`) — MCP-driven UAT (`PluginsAndMcpAutomationUATTests`) still red on the VM GUI lane. Root cause
  found: its `MCPClient` spawns `--mcp-stdio` DIRECTLY as ROOT, so the MCP server's `NSHomeDirectory()` is `/var/root`
  while fixtures now live under the console user's home → `open_path` containment rejects them. Fix (ready, not landed):
  make `MCPClient` spawn the server as the console user too (mirror `AppLauncher`'s `sudo -u`). Needs a VM verify cycle.
  TSK-953 (`.error` class) is DONE/validated; this is the remaining PMA piece.
- **TSK-679** (`review`) — Vim mode shipped; remaining tail = VM keystroke smoke (`CodeMirrorVimSmokeTest`) for live
  modal behavior + cursor-pixel color (WebView-rendered; host covers model/wiring only).

## 2026-06-14 (late) — perf-lane tail + Section-A drain (deferred/ambiguous)

Surfaced during the Section-A drain (board tickets — link, don't duplicate):
- **TSK-861** (UTF-16 BOM fidelity) — `EditorWriter.save` writes BOM-less UTF-16; a short UTF-16 file edited+saved
  (editor OR the new TSK-726 project-wide replace) mis-decodes on reopen (falls to CP1252/Latin-1). Existing editor
  behavior, not introduced by 726; shared fix. Host-testable (EditorWriter + TextDecoder, ViewerCore).

Deferred from the WORK_QUEUE drain (board tickets — link, don't duplicate):
- **TSK-844** (CSV-open arena) — SPIKED + deferred. Careful: rewires the security-hardened CSV parser to write
  directly into the arena, which requires RE-DERIVING the TSK-557 heap cap for the arena footprint
  (`bytes.len()+offsets.len()*8`) — the current `field.len()+CELL_HEAP_OVERHEAD` models the discarded
  `Vec<Vec<String>>`. Full plan + the heap-cap landmine on the ticket. ~M, fresh-context.
- **TSK-845** (micro-bundle) — PROFILE-GATED. (a) ContentFingerprint utf8.count is a likely NO-OP (O(1) on native
  Strings — see LESSONS). (b)/(c)/(d) need profiling. Don't implement blind.
- **TSK-854** (delete Swift highlight twin) — OWNER-GATED. THE bundle-cap reclaim (~16 MB double-carried grammars).
  Likely blocker: the fold path (`TreeSitterEngine+Folds`) has no Rust equivalent yet.
- **TSK-855** (stale `mdv-serve` in the loopback gate) — real CI gap; fix = build the serve bin in the gate.
- **TSK-851/852** (ccache-for-grammars / CI `.build` cache) — owner approval / CI infra.
- **TSK-853 follow-up** — done (launch warm → Rust path); the integer-kind variant of **TSK-841** is the remaining
  deferred wire optimization (needs a shared TokenKind↔u8 ABI). **TSK-840** deferred: warm the opened-file language
  + the Rust highlight config at launch.
- **AMBIGUOUS Section-A items (need an owner UX decision, not a guess):** TSK-751 (which menu reorg?), TSK-709
  (unify ⌘K/⌘G — ⌘G is the standard Find-Next chord), TSK-746 (recents in the Open dialog — NSOpenPanel can't host
  custom recents; an Open Recent menu already exists). **TSK-355** is mostly DONE — "Reveal in Finder" already
  exists (`SidebarView.swift:1088`); only "Open in external app" may be missing.

## 2026-06-14 — build/test speedup + source-perf audits (docs/research/*-2026-06-14/)

**OWNER ASK — TOP NEXT ACTION:** the owner wants ways to improve **app perf / speed / latency / responsiveness
AND test speed** — and felt the build-speedup audit "led with storage wins." Spin up **another set of UNPRIMED
blank-slate subagents** (per `feedback_subagent_prompts` — raw question + minimal background + the MEASURE rule,
NOT the prior findings) for exploratory perf/latency/responsiveness analysis of the APP and the TESTS. Filed as
a tracker ticket (see Phase-2 of the handoff). Don't prime them with the existing audit findings — let them
rediscover/extend independently; synthesize + dedupe against the prior docs yourself when they return.

**Landed:** F2/F3/F4 build wins (TSK-832/833/834 validated, `5ebab1d`, ~7.7 GB reclaimed + shared rust cache);
TSK-828 line-ruler single-pass utf16 scan (validated, `2c7368c`); the TSK-366 memory-chip re-body regression
(`ee4c55b`).

**Open audit follow-ups (don't re-file — tickets exist):**
- **Perf, needs a profiler trace first** (MEASURE rule): TSK-826 (FFI whole-frame `MdvBuf→Array` copy at 7 sites
  — biggest leverage, extends TSK-564), TSK-827 (TreeSitterEngine.tokenize NSString bridge per predicate),
  TSK-829 (CrossFileSearch single-threaded → parallelize). TSK-830 (micro-bundle: Rust `kind.to_string()`→Cow,
  HTMLRenderer class lowercasing, MsgPackReader dict rebuild) is no-profiling-needed.
- **Build, owner/dep-gated:** TSK-831 (F1 — disable IDE background indexing, −1.7 GB, owner-decision: affects
  jump-to-def), TSK-835 (cargo-nextest, ~30–60% off rust tests, **dep-approval**), TSK-836 (split slowest test
  classes — needs `--xunit-output` per-class timing capture first).
- **VM-flaky test:** `TerminalForegroundBumpTests.test_backgroundOutput_feedsParser_withoutVersionBump` — file a
  flaky-test ticket or make the async-bump assertion timing-robust.

## 2026-06-04 — owner roadmap dump (triaged)

Captured verbatim from the owner, with triage tags. **CRASH fixed this pass:**
`GitLogTab` `lay.rows[idx]` out-of-bounds trap (EXC_BREAKPOINT, the 2026-06-04
03:04 `.ips`) — cached graph layout lagged `logEntries` on append; guarded the
subscript. Committed.

### Next — bugs (likely ONE shared root cause: the eager/over-observation baseline, see #210/#215)
- **Closing a tab takes ~1s** — must be instant. [perf]
- **Switching tabs is very slow.** [perf] — same cluster as tab-close.
- **Delay in opening files.** [perf] — same cluster.
- **1 MB HEX view extremely slow** — extends **#218** (6 KB already ~1s).
- **Random crashes** (Jun-04 03:04) — **FIXED** (GitLogTab OOB). Watch for others.
- **Can't see right border of last tab.** [QW layout] — relates to **#209** chrome-pin.
- **`+` icon should sit beside the last tab, not at the strip end** — dup of **B2** (docs/UX_OVERHAUL) ; partially attempted.
- **Tab bar must SHRINK to fit, never overflow.** [layout] — relates to **#183** tab-overflow.
- **PNG / media file-info don't respect zoom.** [QW] — extends **#228** zoom audit (native-preview metadata missed).
- **Up/Down in file-nav should change current tab content** — = **#220** (preview-tab/scrub); confirm commit-vs-click race.

### Next — features / behaviour
- **Sessions optional** (don't force the sessions layer). [D]
- **Multi-window session support.** [L]
- **Natural keybindings** (⌘⇧[ / ⌘⇧] next/prev tab, etc.) — extends **#232** keybinding config.
- **File ▸ New; right-click folder ▸ New [File].**
- **Undo audit** (every mutating action undoable; bookmark remove + undo below).
- **Drag-and-drop tabs INTO sessions.**
- **Render-FPS meter; flag jank when <60 fps.** [perf-observability] — pairs with **#208**.
- **Footer menus / buttons / drop-UPs.** [C follow-up]
- **Default to plain text when content is renderable ASCII** (+ allow-list known plain-text formats → plain text). [QW-ish]
- **Remove bookmark via Delete key + undo remove.**
- **Right-click folder ▸ Stats → a webpack-bundle-analyzer-style treemap of the repo.** [L]

### Wishlist (not scheduled)
- **Debugger:** Java, Chrome.
- **Claude:** session search, hook integration.
- **LSP:** LSP-MCP, LSP manager, custom LSP, dependency graph, click-through / find-usage / find-declaration. (extends **#144**)
- **Merges:** plugins, MCP, walkthroughs into the mainline UX.
- **Terminal:** tabs, persistence. (extends **#226**)
- **Syntax-highlighting expansion; Code Review** (extends **#142/#203/#204/#205**).
- **Image editor:** P0 resize/crop/quality → P0.1 history/revert → P1 raster paint (picker/brush/fill/selection) → P1.1 layers + own/GIMP format → P2 vector (shapes, arrows, connectivity, hierarchy, history, layers).
- **Extra:** vector store, project management (**#216**), GitHub + code review, walkthrough, AWS console/profiles/CLI-SDK.


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
- **Invisible characters appear too grey.** PARTIALLY DONE (item I2).
  Split by render path:
  - **Editable path (CodeMirror 6 / WKWebView) — FIXED.** Invisibles
    are an IntelliJ-style show-invisibles ViewPlugin (middle-dot `·`
    for space, arrow `→` for tab, pilcrow `¶` for line break), styled
    via `.cm-invisible` in `Resources/codemirror/codemirror.css`.
    Retuned from the washed-out flat `rgba(127,127,127,0.5)` to a
    subtle-but-readable theme-scoped *secondary* tone (light:
    `rgba(60,60,67,0.55)`, dark: `rgba(235,235,245,0.50)`, `font-weight:
    600` to thicken the hairline strokes). Pinned by
    `CodeMirrorBundleTests.testInvisibles*`. Fully compositor-safe (no
    NSLayoutManager).
  - **Read-only source path (NSTextView) — STILL BOUNDED.** Uses the
    built-in `layoutManager.showsInvisibleCharacters` flag, which renders
    in `tertiaryLabelColor` with no public color/glyph override. The only
    fix needs an `NSLayoutManager` subclass overriding
    `drawGlyphs(forGlyphRange:at:)` — deferred, that subclass has
    historically triggered the SwiftUI compositor bug (LESSONS.md
    "Things to NOT do"). Kept the OS default tone here on purpose.
  → `Sources/ViewerUI/TextDisplayView.swift` SourceTextController;
    `Sources/ViewerUI/Resources/codemirror/{codemirror.css,codemirror.html}`.

## Sidebar / folder UX

- ~~**Right-click folder → Bookmark Folder.**~~ DONE.
- ~~**Right-click folder → Set as Git Root.**~~ DONE.
- ~~**Right-click folder → Open in Terminal.**~~ DONE (commit `94e130d`).

## Scaling + chrome polish

- ~~**UI scaling audit.**~~ MOSTLY DONE. Remaining: ModeBar mode-picker
  text doesn't scale with `uiScale`.
- **Dual-zoom split (#228).** The footer (UX-C, #225) now shows a single
  "Zoom" readout because window-UI zoom and document zoom share one
  `model.zoom` value (the old `uiScale` knob was collapsed onto it). The
  full UI-vs-document zoom split belongs to the #228 zoom pass; when it
  lands, replace the single `StatusBar.zoomReadout` with two labeled
  readouts (Window-UI zoom + Document zoom) reading the two model values.
  See the TODO(#228) in `Sources/ViewerUI/StatusBar.swift`.
- **HEX byte-editing (#224 UX-A deferral).** The content-toolbar's
  `View Only` toggle exists for the HEX lens, but the byte grid is still
  RENDERED READ-ONLY — turning View Only off does nothing for HEX today.
  The grid is a pre-built `NSAttributedString` in a non-editable
  `NSTextView` (`HexView` / `HexTextRepresentable`), so editing needs:
  (1) a caret→byte-offset map over the hex+ASCII columns, (2) nibble-level
  hex entry + ASCII-column entry that stay in sync, (3) a dirty
  byte-buffer + write-back through a binary save path (the loader is
  read-only today), and (4) undo. `ViewModeControl.present(.hex)` returns
  `viewOnly: true` and the toolbar disables nothing for HEX — when the
  edit path lands, flip those. Sizable; not blocking UX-A.
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
- **RESOLVED (ad12a05) — was a REAL regression, NOT Foundation drift.**
  `test_decide_sameDocFragment_isAllowed` failed because 8da6efbb
  (2026-05-25) added `file` to the `.linkActivated` block ABOVE the
  same-doc-fragment allow in `decide()`, so every in-page #anchor/TOC link
  in the file://-loaded rendered markdown was cancelled. A host-Foundation
  probe showed the field compare returns true fine on macOS 26 — the
  "Foundation drift" label was wrong; it failed on every OS. Fixed by
  moving the same-doc allow before the file: block. 27/27 link tests pass.
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
  - **L1 (UX-overhaul "~200MB-after-close") — AUDIT DONE + tractable fixes
    landed.** A full retained-state sweep (per-tab/per-URL/per-session caches)
    found the Swift-heap caches are bounded/purged on close — `editorBuffers`,
    `csvFilterStates`, `hexBytesPerRow`, `languageOverrides`, `formattedTextCache`
    (TabCoordinator `cleanupAfterClose`), `renderedHTMLCache` + `htmlJavaScriptOptIn`
    (`DocumentModel.purgeCaches`), `highlightCaches` (per-tab actor dropped),
    `FileTreeRecency.cache` (LRU-capped), `SidebarModel.childrenCache` (LRU-pruned).
    **One real gap fixed:** `LSPDiagnosticsStore.byURL` accumulated one entry per
    file touched — `clear(url:)` existed but `purgeCaches` never called it; now
    wired (guarded on "no surviving tab still shows this URL"). Regression guard:
    `MemoryReclaimOnCloseTests` (T1m). **Residual ≈ WebKit-XPC** (rendered-MD +
    CM6-editor + Mermaid WebContent processes + ~35 MB persistent helper floor) —
    that's #191 proper. **OWNER DECISION needed:** tear the WKWebView down on tab
    close/switch (reclaims ~30–80 MB but pays re-render latency on reopen) vs.
    keep-alive (current; the BACKLOG "Tear down WKWebView on tab switch — not
    pursued" trade-off). LSPPool per-file `fileVersions`/`fileHashes` (~100 B/file)
    intentionally NOT cleared on close — doing so without a real
    `textDocument/didClose` would desync the server; that's a lifecycle feature,
    a separate follow-up, not a leak-plug.
- **#194 — #192 true fix.** SwiftUI AttributeGraph teardown so the
  in-process WKWebView suites can rejoin the bare `swift test` sweep
  instead of `#192`-gating themselves out. Low priority (VM lane covers
  them today).
- **#201 — RESOLVED (ad12a05).** NOT a Foundation/macOS-26 issue (a
  host-Foundation probe showed the field compare returns true). Real cause
  = code ordering: 8da6efbb put `file` in the `.linkActivated` block above
  the same-doc-fragment allow, cancelling ALL in-page #anchor/TOC links in
  rendered markdown — a real ~9-day regression mislabeled as the
  "acceptable macOS-26 gate red." Fixed: same-doc allow now precedes the
  file: block; cross-doc file: + dangerous schemes still blocked. The
  gate's deterministic red is gone.
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


## 2026-06-02 — queue (detail: docs/HANDOFF_2026-06-02.md §3)
- **IN FLIGHT** (wf `w0kz4p4kq`, branch `fix-loadbug`): fix `fd11e61` file-load failure + Editor→HEX mode-scramble + ADD a live-app smoke wired into `build-app.sh` as a pre-install gate. **`main @ fd11e61` is BROKEN (can't load files live) — do NOT ship.** Main checkout leaked onto `fix-loadbug`; reconcile per HANDOFF §0/§5.
- **BUG #218** HEX mode slow (6 KB → ~1 s) — sync full attributed-dump build on mode-switch; stream/cache.
- **BUG #219** Editor→HEX flash of Source — mode-routing transition; coordinate with the load-fix.
- **FEAT #220** sidebar preview-tab / scrub — single-select swaps current tab's content (preview); double-click pins a permanent tab.
- **#221** remove the "Open As" menu entirely → file-type chip dropdown is the sole affordance (sidebar submenu still present).
- **#222** holistic testing-improvement investigation (the live-app gap is the case study).
- **DESIGN AWAITING OWNER:** PM feature v2 (`docs/PROJECT_MANAGEMENT_DESIGN_v2.md`) — agree the WHAT + approve the `rusqlite` dep, then a HOW/build pass. Rust/Linux plan ready (execute when the Mac is free).

## 2026-06-03 — post-UAT + reconciliation queue

**Giga UAT outcome (run wf_7f6adec6-3ab):** 33 issues / 32 fixed / 1 non-bug.
**27 landed on main + gate-green + installed.** Catalog: `docs/uat/` (87 smokes,
12 T4 suites, UAT_REPORT/UAT_BUGS/STAGED_FIXES). Re-run: `giga-uat mode=run-only`.

**Pending fixes (2 branches kept; also in bundle + UAT_BUGS.md):**
- `worktree-wf_7f6adec6-3ab-54` — **BUG-010** off-menu view-mode clamp (S3).
  Conflicts with the landed BUG-007/019 view-mode guards; likely partly
  redundant — reconcile or drop. **DECISION owed.**
- `worktree-wf_7f6adec6-3ab-64` — **BUG-027** sessions-store pollution under the
  clean-room flag (S4, real-footgun-adjacent). Conflicts with `-62`'s landed TCC
  guard at `SessionsAppCoordinator`. Reconcile or drop. **DECISION owed.**
- Dropped (trivial/redundant, bundle only): -50 BUG-023, -63 BUG-013 (dup of
  landed -51), -79 BUG-031 (comment-only).

**Gate reliability:** `FoldBenchTests`/`CrossFileSearchBenchTests` are
parallel-contention perf FLAKES (pass in isolation, trip under `swift test
--parallel`). They didn't trip the final gate but are non-deterministic — de-flake
(serialize, or relax the budget under load, or move off the gate lane). **DECISION owed: approach.**

**giga-uat workflow polish:** `args.date` didn't propagate (deliverables came out
`*_undated.md`; the watchdog's date-keyed filename check would've mis-fired).
Fix arg threading before the next run.

**Backup to retire:** full-ref bundle at
`/Users/me/Documents/workspaces/claude/mdv-recon-backup-2026-06-03/` — delete
once confident nothing from the 51 deleted branches is wanted. 12-entry stash
stack (`RECOVERED-*`) still present + bundled; clear after eyeballing.

**Carried-forward queue:** #218 HEX-slow · #219 Editor→HEX flash · #220 sidebar
preview-tab · #221 remove Open-As · #222 holistic testing-improvement · #223
action-vocabulary catalog · #216 PM feature (needs `rusqlite` approval + WHAT→HOW)
· #202 sessions god-object split · #204/#205 code-review · #191/#194 memory ·
#208/#210 perf+memory accounting. UnifiedSearchPanel rework sits unlanded in the
bundle (main kept CrossSearchPanel) — resurrect or abandon. **DECISION owed.**

## 2026-06-06 (evening) — deferred / blocked after the owner UI-bug + VM-lane session

- **Status-bar live re-render (TSK-452)** — data source + wiring proven correct headlessly; loading-blank
  fixed. IF stats still go blank/stale switching between ALREADY-LOADED tabs, it's a SwiftUI re-body issue
  (live-only). Next: owner says which (blank/frozen/fine) → if frozen, audit StatusBar's `@ObservedObject`
  observation vs the publish that fires on `select` (PERF #1 severed tabCoordinator→model forwarding; StatusBar
  observes tabCoordinator directly so it *should* re-body). Live/VM repro needed.
- **VM full-suite hang (TSK-451)** — `bash scripts/test-in-vm.sh all` hangs after `TabBarWidthTests` (a T4/live
  suite never returns). Bisect which suite; add a per-suite timeout or move it to the gated WebView lane so the
  full VM lane can run unattended. Workaround today: targeted `--filter` runs. Orphan VM PIDs 28912/29140 need
  an owner `ssh macOS15 'kill ...'`.
- **GP_10 stale test (TSK-447)** — fix committed (`541b3df`), host-compiles; live VM validation pending a clean
  VM (blocked by TSK-451). Run `GitPanelUATTests` filter on the VM (6.3) to confirm → fixed.
- **Sidebar tool-window resize rework (TSK-440)** — lone-Files fill + every-adjacent-pair divider + uniform
  resize. Regression-prone layout zone; needs the VM live-verify loop (now possible once TSK-451 cleared).
- **Build flake follow-up:** `build-app.sh` now signs in a non-iCloud TMPDIR + `install-app.sh` `xattr -cr`s
  the install — closed. The repo living under iCloud `~/Documents` is the root environmental cause; if more
  iCloud-detritus issues appear, the fix pattern is "operate outside the synced tree."

## 2026-06-07 — terminal + editor follow-ups
- **Terminal alternate-screen buffer** (no task yet; flagged on TSK-489) — implement DECSET 1049/1047/47
  + save/restore cursor + a second grid in `ANSIParser`/`TerminalScreen` so `top`/`vim`/`less` render
  correctly. Host-testable at the parser level (golden tests) → self-validatable. Medium size. The real
  fix for "top renders wrong"; the TSK-489 scroll-persist fix only addresses tab-switch scroll.
- **Preview-tab Phase 2/3 (TSK-306, in `progress`)** — Phase 1 model core landed (`a37f861`). Remaining:
  Phase 2 sidebar single-vs-double-click + arrow-nav triggers + auto-promote-on-edit (live); Phase 3
  italic preview-tab title affordance (VM-visual). Persistence = Option A (promote-on-save), confirmed.
  Design in `docs/PREVIEW_TAB_DESIGN.md`.
- **indent-guides default (TSK-487, fixed/opt-in)** — owner may later flip default to ON; today off + a
  Settings toggle.
- **VM UI tests for editor/terminal render features** — folds collapse, indent-guide lines, date stamp
  at caret, terminal strip placement, scroll-persist-on-switch. Nightly `LiveAppTestCase`/`PixelTestCase`
  lane. Unlocks self-validation of these WebView/AppKit behaviours per the new policy.
- **tasked MCP gaps reported to owner (2026-06-07):** (1) no free-text/substring `task_list` search;
  (2) no `task_update` (edit title/report/type/prio post-create); (3) no agent dismiss for already-fixed/
  wontfix/duplicate/foreign — relevant since the board is shared across projects.

## 2026-06-07 — Rust-core Formatted mode + autonomous queue state

- **TSK-496 — XML/HTML pretty-print (`format::pretty_xml`)** — the deferred half of the
  JSON/XML Formatted feature. JSON shipped (`format::pretty_json`, validated TSK-217/218);
  XML was split out because mixed-content/CDATA/comment/attribute rules are a much larger
  no-dep parser than JSON. Then extend `view::classify` so `.xml` (and maybe `.svg`/`.html`)
  → `FileKind::Structured` and have `formatted_lines` try `pretty_json` then `pretty_xml`
  then raw. Medium confidence (XML correctness is the risk). REMEMBER the depth-cap lesson —
  the XML parser must bound recursion too.
- **Autonomous queue is `[PORT]`-lane-bound (owner steer needed).** As of this session the
  actionable autonomous queue is front-end `[PORT]` tasks only. Every SwiftUI app board task
  is `validated`, owner-gated (**TSK-202** Sessions god-object split — owner decision), or
  live/VM-blocked (**TSK-252/253/254** — need a VM UI-test lane). To point autonomous ticks
  back at the owner-prioritised SwiftUI lane, unblock one of those. Otherwise remaining PORT
  work is increasingly marginal polish (TSK-241 whitespace markers, TSK-247 keyboard-help
  overlay, TSK-243 theme tokens, …); the high-value W1/W2 items (JSON-formatted / reload /
  hex-search) are done + validated.

## 2026-06-09 — rust-core audit Phase 0 remainder (tracker = source of truth)

The production-readiness audit landed (see `docs/research/rust-core-audit-2026-06-09/synthesis.md`,
epic **TSK-538**, tag `rust-core-audit`, 39 tickets TSK-539..577). Five Phase-0 items shipped
at `02a10e7` + `dd6d345` (TSK-549/542/553/569/555 → fixed). Remaining Phase-0, in rough order —
all already tracked on the board, listed here only as the resume pointer:
- TSK-550 workspace-wide gate lane · TSK-576/565 hunk_marks i64 clamp + top-of-file Deleted
  mark (parity-lock with Swift) · TSK-540 hex_render width clamp · TSK-539 cbindgen
  rerun-if-changed + header-drift gate · TSK-551 web slot RAII guard · TSK-556 request
  deadline · TSK-558 dir-listing cap · TSK-557 CSV byte cap · TSK-566 string_slice deny ·
  TSK-567 dead render_view removal · TSK-575 clippy warning sweep.
- Dep adoptions (memchr, cargo-fuzz, proptest, cargo-deny, cargo-audit, Miri lane) are
  **owner-gated** — parked on their tickets, do not adopt without approval.
- T5 VM pixel lane: bump `waitForWindowID(timeout: 2.5)` → ~20 s in the visual-regression
  tests (root cause proven 2026-06-09: apps publish the windowid slowly under the root
  asuser context; see LESSONS).

## 2026-06-10 — priority pivot + reconciliation (tracker = source of truth)

- **OWNER PRIORITY (2026-06-10): user-facing bug fixes first** — encoded in
  `docs/TASK_WORKFLOW.md` §3 rank 1. The work pool: epic **TSK-590** (children
  TSK-591..610, owner bug-list reconciliation) + bumped P1s TSK-266/267/313/314/
  327/359/363/522/523. Start with broken flows (TSK-599/600 sessions, TSK-609
  shoulder buttons) and felt-perf (TSK-266/267/591/592/598/601).
- **rust-core Phase 0: COMPLETE except hygiene trio** TSK-566 (string_slice deny),
  TSK-567 (dead render_view), TSK-575 (warning sweep) — now BEHIND user-facing
  work per the pivot. Phase 1 (TSK-579 abi_version first) follows.
- **Gate-flake hardening** (load-tolerant deadlines + retry-once for PTY/LSP
  suites) — owner asked "any way to fix?"; options offered, not yet ticketed.
- 2026-06-09 entry below remains valid for the audit context/pointers.

## 2026-06-10 (later) — measurement-session follow-ups
- TSK-592 resize capture: when the in-flight VM run lands, parse main-thread
  Time Profiler samples inside the sweep window (export table schema
  `time-profile`; aggregate top frames) — the parse step isn't scripted yet;
  candidate: fold a `--report` step into `scripts/vm-profile.sh` (small).
- `resize-sweep` drives setFrame, not a real interactive drag — it misses
  `NSWindow.inLiveResize`-gated paths. If the jank only reproduces under a
  true drag, the driver needs a CGEvent/AX variant (Accessibility TCC on the
  VM; medium).
- TSK-591 hover lag: live counter read still pending (10s hover →
  `trackedRepos.norm.miss`/`.reset` in the observability projection).
- MountedPanesLRU supervised session: parked on TSK-598 with measurement
  backing (WebKit loadToFinish 3.46s = 94% of MD open); clears TSK-598 +
  TSK-266 residue + tab-switch lag in one move once approved.

## 2026-06-12 — port-wave follow-ups

- **Adapter-flip decision package** (M): fuzzy (TSK-633) + find (TSK-630) are validated
  with A/B parity but NOT consumed — no UI adapter routes through them yet. When 2+ more
  engines land (or on owner ask): a RustCoreFallback-gated adapter per engine, default-OFF,
  then the flip + Swift-twin deletion as its own reviewed change. Don't flip ad hoc.
- **Swift-twin deletions after flips** (S each): FuzzyMatcher.swift, FindEngine.swift +
  RegexComplexityGuard wall-clock half (compile-shape guard may stay for the MCP
  find tool if it keeps NSRegularExpression during transition).
- **mdvFrameCall `name:` param → TSK-636 audit-log emit point** — wire when 636 lands.
- **Miri/ASan nightly step** on the supply-chain lane (TSK-554 noted follow-up) — behind
  the nightly-toolchain approval (audit ask #5).
- **cargo-deny advisories re-merge** once it parses CVSS-4.0 (drop the cargo-audit split
  if so; see LESSONS 2026-06-12).
- **regex-lite escape**: hand-rolled `escape_literal` in find_engine.rs — if regex-lite
  ever exports `escape` under our feature set, swap and delete.

## 2026-06-12 evening — wishlist-wave follow-ups (features landed, refinements deferred)

- **clearRecents undoable** (S): the undo audit (TSK-330) left "Clear Recent Files" as a
  confirmed wipe ("can't be undone"). Making it undoable needs the alert reworded + a
  recents-snapshot undo stack. Low value; only if owner asks.
- **7z/rar archive support** (S-M): ArchiveCatalog (TSK-311) is zip/jar/tar/tgz/tbz2 via
  system unzip/tar. 7z/rar have no system tool — needs a best-effort locator like
  FFmpegLocator (PATH probe for `7z`/`unar`, disabled if absent). Owner-dep-shaped.
- **TSK-259 editor-font VM pixel case** (S): the CM6 font-family change is host-tested at
  the bridge/model layer; an EditorThemeParityTests-style computed-style assertion in the
  VM WebView lane would close the painted half before validated.
- **FrameRateMonitor as the MountedPanesLRU before/after** (note): TSK-275's FPS strip
  gives a live readout — use it during the supervised perf session to show the win on screen.

## 2026-06-13 — VM-validation tail + deferred refinements

User-facing work is host-drained; the remaining items are render/interaction-gated (VM) or owner-gated.

- **TSK-821 rendered-scroll WebView-lane test** (S) — add `PaneScrollRestoreWebViewTests` (#192-gated): load a
  tall HTMLRenderer page into a real WKWebView → `scrollTo(top:500)` → read `window.scrollY`==500 → reload (resets
  to 0) → `scrollTo({top:500,behavior:'instant'})` → 500. Validates the round-trip primitives on OUR page (the
  view-bridge wiring can't be unit-driven — Context not constructible). Wire into `test-in-vm.sh run_webview_tests`
  + `nightly-vm.yml` (TSK-621 rule). The store is already host-tested.
- **TSK-732 font View/Edit seamlessness** (M) — needs a VERSIONED bridge change: `CMOutboundMessage.setFontSize(Int)`
  → carry `Double` px + a derived line-height px from `SourceTextController.lineHeight` (the View's exact factor),
  so CM6 matches the View by construction (not a magic 1.2). Sketch on the ticket.
- **TSK-820 remove dead per-method FFI C symbols** (S) — post-soak cleanup; blocked on re-pointing the FFI A/B
  oracle (envelope-vs-symbol) onto the core dispatch fn first, then delete the symbols.
- **VM render/interaction validation tail** — TSK-806 (split re-render: AX-read of split source), TSK-743 (source
  visible scroll restore), TSK-763/789 (settings/recents a11y-presence), TSK-468 (dead-UI-removal glance),
  TSK-734 (no-crash smoke), TSK-728/730 (key-synthesis — needs the TSK-818 VM key lane). Each held at fixed/review.
- **Perf cluster (591/592/598/266/455) is PARKED on owner re-feel** (TSK-598, waiting:human) — measured as resolved
  (switch/resize fast); only first-open WebKit `loadToFinish` remains (inherent). If owner still feels lag, a
  progressive/lighter-initial-page render spike is the lever (bigger change, uncertain payoff).
