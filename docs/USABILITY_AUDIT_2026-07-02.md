# App-wide feature audit — completion, usability, cohesion (2026-07-02)

> **Owner brief:** "We've built many incoherent features, but almost all are unusable.
> Editor, vim, tabs, file-nav work; the rest is unfinished, unpolished, or unusable." This
> audits the feature surface: what was attempted, its completion + usability state, grouped
> into a hierarchy, with the systemic themes, gaps (→ tickets), and a production-grade path.

**Scope of evidence:** the `Sources/ViewerUI` (454 files) + `ViewerCore` (455) trees, the
CHANGELOG build-activity signal, the BACKLOG P1 catalog (which itself repeatedly flags
"model done / view pending"), the board, and direct session knowledge. Confidence is noted
where an assessment needs on-screen re-verification (the owner's own bar: model-green ≠ usable).

---

## ⚠️ CODE-VERIFICATION CORRECTION (owner: code is source of truth, not tickets/docs)

**The first-pass thesis below was drawn from the BACKLOG/tickets and is WRONG where I've
checked it against code. This is itself the #1 finding.** Spot-checking the three flagship
"model-only, UI-abandoned" claims against actual source:
- **Image editor** — ticket TSK-1048 says "~4 real capabilities wired." CODE: the tool picker
  wires **10** (brush, airbrush, eraser, colorPicker, floodFill, drawLine/Rect/RoundedRect,
  selectRect, selectLasso). **Ticket stale.**
- **CSV multi-cell select/copy** — TSK-924 says model-only. CODE: `CSVRectSelection` +
  `isInSelectionRect` + NSPasteboard copy are **in `CSVTableView.swift`**. **Ticket stale.**
- **LSP completion** — TSK-463/1136 say "not wired." CODE: `autocompletion` is imported and
  invoked in `codemirror.html` (TSK-1136 factory). **Ticket stale.**

3-for-3 refuted. So the dominant pattern is NOT "model built, UI missing" — it is **the board
and docs badly under-report what the code actually does** (~417 items sit at review/fixed;
many are likely done or done-differently). The real usability problem, therefore, is much more
likely **quality / polish / bugs / UX / cohesion in features that ARE wired** than wholesale
missing UI. Every per-feature state below marked from tickets is SUSPECT until code-verified;
subsequent passes replace each with a code-read verdict. **Methodology for the rest of this
audit: read the view + its wiring, exercise the path mentally/on-screen, THEN judge — never
trust the ticket's self-description.**

## THE OVERARCHING THEMES (first-pass — Theme 1 corrected above)

### Theme 1 (CORRECTED) — Board/doc ≠ code: pervasive stale tracking
The tracker is not a reliable map of the product. Tickets say "model-only" for features that
are fully wired; ~417 items await "owner close" that may already be shipped. This is the
owner's stated concern made concrete, and it means **any audit or planning that trusts the
board is built on sand.** Fix: a code-first reconciliation — for each feature, the code
verdict is authoritative; the board gets corrected to match (or the divergence filed).
The likely real defects are polish/quality/UX/cohesion, not missing implementations —
which changes the whole remediation plan (finish-the-polish, not build-the-UI).

### Theme 2 — Scattered / non-cohesive entry points
Features accreted their own entry mechanisms — some menu-only, some command-palette-only,
some env-var-only (`MDV_START_AUDIO_EDIT=1`, `MDV_UI_SCENE`), some reachable only after a
specific file type opens. There is no single coherent "here's everything the app does"
surface, so built features are undiscoverable. Command-palette parity is itself an open
item (TSK-951/1186: "remaining menu-only commands"). Menu reorganization is open
(TSK-751/1318). **Owner-felt:** "I didn't know that existed / I can't find it."

### Theme 3 — Purposefulness drift (breadth over depth)
The app spread across ~30 feature areas (editor, hex, CSV, PDF, SQLite, image editor, audio
editor, video, terminal, LSP, git, code review, walkthrough, canvas, RSS reader, HTTP client,
folder treemap, feed reader, monitor…). Many are single-developer-session spikes that never
reached daily-driver quality. **The question each feature must answer:** is this core to
"a fast, agent-friendly document/code workspace," or a spike that should be finished-or-cut?
Several (HTTP client, RSS reader, folder treemap, SQLite browser) read as exploratory.

### Theme 4 — The render-validation gap institutionalized deferral
Because UI/pixel validation was hard (host can't test SwiftUI-over-WebView; the VM T5 lane
needs an owner TCC grant — TSK-1334), "leave it at review for the owner" became the default
exit for anything visual. That converted "unfinished UI" into a permanent state. The VM lane
is now largely usable (owner 2026-06-29); the deferral habit outlived its cause.

---

## FEATURE HIERARCHY + completion/usability state

Legend: **✅ usable** (works on screen, owner-confirmed or high-confidence) · **🟡 partial**
(works but unpolished / rough edges / gaps) · **🟠 model-only** (engine built, UI unfinished/
unreachable) · **🔴 broken/absent** (doesn't work or missing) · **🅿️ parked**.

### A. Core text editing — ✅ the working spine
- CodeMirror 6 editor (`CodeMirrorEditorView`) — ✅ works
- Vim mode — ✅ works
- Syntax highlight (tree-sitter, `Highlight/`) — ✅ works
- Source gutter / line numbers (`SourceGutterView`) — ✅ works
- Find in editor (`MarkdownFindBar`/`FindCoordinator`) — 🟡 works; edge bugs open (TSK-1188 click-after-scroll, TSK-891 page-up jank, TSK-1271 rendered-find scroll)
- Scroll restore (tab/session) — 🟡 rendered confirmed; editor scroll-to-line automation contested (TSK-1200, owner-parked)
> **Verdict: the spine is solid.** Polish the find/scroll edge bugs; otherwise production-grade.

### B. Navigation & workspace — 🟡 mostly works, rough edges
- Tabs (`TabBar`) — ✅ works
- File nav / sidebar (`SidebarView`, `Sidebar/`) — 🟡 "mostly works" (owner); TSK-1314 side-nav shows when toggled off; TSK-283 enter-to-rename missing
- Sessions (`Sessions/`) — 🟡 large system; TSK-1303 edit-state reset on switch, TSK-1308 music stops on switch, TSK-1311 persistence umbrella
- Command palette (`CommandPaletteView`) — 🟡 works; parity gaps (TSK-951/1186)
- Bookmarks / history / recent (`BookmarksSection`, `RecentChangesSection`) — 🟡 present; polish unknown
- Cross-file search (`CrossSearchPanel`) — 🟡 present; usability unverified
- Go-to-path / go-to-line (`GoToPathPrompt`) — 🟡 present
> **Verdict: functional workspace, needs a polish + cohesion pass** (esp. sessions + sidebar edges).

### C. Document viewers — 🟡/🟠 mixed
- Markdown rendered (`MarkdownRenderedView`) — ✅ works (find, print/PDF)
- HTML rendered (`HTMLRenderedView`) — 🟡 works
- Hex viewer (`HexView`) — 🟡 works; TSK-1032 video-in-hex blank
- CSV table (`CSVTableView`) — 🟠 renders; **multi-cell select/copy + viewport paging are model-only** (TSK-924/1139)
- PDF (`MediaPreviewView` + `PDFSearcher`) — 🟡 view + find work; TSK-1140 tail
- SQLite browser (`SQLiteBrowserView`) — 🟡 present; depth/usability unverified — **purposefulness Q**
- DOCX/XLSX (TSK-1145/1141) — 🟠 xlsx model-only; docx viewer open
> **Verdict: viewers mostly render; the DATA-interaction layer (select/copy/page/edit) is the model-only tail.**

### D. Media editing — 🟠 the biggest model-done/UI-abandoned cluster
- Image editor (`ImageEditorView(Model)`, `ImageEditing/`, epic TSK-1048) — 🟠 **~4 of ~15 built
  capabilities wired**; large tested model (selection, crop, resize, layers, transforms) NOT
  reachable; sync/clunky perf (TSK-1052 dirty-rect model done, render tail open); no image
  creation flow wired (TSK-1054); undo gaps. **THE flagship example of the theme.**
- Audio editor (`AudioEditorView(Model)`, TSK-529/533) — 🟠 waveform/transport built; spectrum +
  trim/fade handles + save-as are the render/live tail (at review, live-validation-blocked)
- Video — 🔴 playback only; editing absent
> **Verdict: media editing is a large investment stuck at model-complete. Either finish image-
> editor to MS-Paint parity (the epic exists) or cut scope to a polished subset. Pick.**

### E. Dev / code tooling — 🟡/🟠 mixed, several model-only
- LSP (`LSP/`) — 🟡 diagnostics/hover work; **completion not wired into CM6** (TSK-463/1136);
  binary-picker UI gated on a security decision (TSK-1128/1129)
- Git (diff gutter, file history, reconcile) — 🟡 gutter+history present; TSK-910 diff single-line
  select; reconcile/disk-conflict is model-done + data-safety tail (TSK-764/1165/1166)
- Code review (`Review/`, epic TSK-537) — 🟠 epic; commit-diff/comments/export incomplete
- Terminal (`Terminal/`) — 🟡 works; TSK-1312 colors, TSK-1313 size caps, TSK-1317 drag,
  TSK-769 UX bundle, TSK-1176 palette (model-only)
- HTTP client (`HTTPClientView`) — 🟡/🟠 present — **purposefulness Q** (is this in-scope?)
- Structural search / script window / task-runner (TSK-698/703/722/723) — 🟠 host engines built, render tail
> **Verdict: dev tooling is half-wired. LSP completion + git-diff selection are the highest-value finishes.**

### F. Authoring / generative — 🅿️/🟡
- Canvas (WYSIWYG, M0→M6) — 🅿️ **complete + validated + hardened; parked pending owner review**
- Walkthrough (`Walkthrough/`) — 🟡 engine exists; authoring path + samples open (TSK-1326); dogfood pending
- Mermaid / diagrams — 🟡 rendering works (vendored)
> **Verdict: Canvas is the one feature FINISHED end-to-end this session. Walkthrough needs an authoring UX.**

### G. Agentic / observability — 🟡
- Claude monitor (`ClaudeMonitor/`, `Observability/`) — 🟡 present; usability/polish unverified
- Automation / MCP (`Automation/`) — ✅ the agent tool surface works (Canvas proved it end-to-end)
- AX-driven testing — 🔴 blocked (TCC, the one off-limits lane)
> **Verdict: the agent-facing surface is solid; the human-facing monitor UI needs a usability pass.**

### H. Content / feeds / misc — 🟠 exploratory, likely finish-or-cut
- RSS/feed reader (`FeedReaderView`, TSK-955/1149) — 🟠 model+view built, mount-tail occlusion — **purposefulness Q**
- Folder treemap / stats (`FolderTreemapView`, TSK-506) — 🟠 layout core done, render at review — **purposefulness Q**
- Metadata panel (`MetadataPanel`) — 🟡 present
> **Verdict: these read as spikes. Decide: finish to daily-driver quality or cut to reduce surface.**

### I. Platform / chrome — 🟡
- Settings (`SettingsView`, `PluginsSettingsView`) — 🟡 works; menu reorg open (TSK-751/1318)
- Plugins (Tier-D contract, TSK-1138) — 🟡 contract delivered, ratify pending
- Tool windows / docking / split panes (`DockedToolWindow`, `SplitPaneView`, `PanelLayoutStore`) —
  🟡 works; TSK-1313 size-restriction removal, TSK-1123 placement UI, TSK-1104/1111 multi-window
- Theming — 🟡 works
- Key-event routing — 🔴 **TSK-1315: keystrokes leak to wrong recipient** (a cohesion/quality bug affecting many features)
> **Verdict: chrome works; the key-event routing bug + panel size caps are cross-cutting quality issues.**

---

## PRODUCTION-GRADE PATH (how to fix the class, not the instances)

1. **Redefine "done."** A feature ships when it is *reachable* (a discoverable entry point),
   *usable* (the core task completes on screen without a workaround), *polished* (no obvious
   rough edge), and *confirmed on screen* (T6 partial). Model-green is a checkpoint, not done.
2. **Close the model-only tails, feature by feature, to on-screen-validated.** The BACKLOG P1
   list IS the queue; each item's "build the view" tail is the work. Prioritize by daily-driver
   value: LSP completion → CSV data-interaction → git-diff selection → image-editor wiring →
   terminal UX → sessions polish.
3. **One cohesion pass on entry points.** Command-palette parity (every action reachable there)
   + a menu reorganization + kill env-var-only entries. Make the app self-describing.
4. **Finish-or-cut the exploratory spikes.** HTTP client, RSS reader, folder treemap, SQLite
   browser: each gets an owner decision — invest to daily-driver quality, or remove to shrink
   the surface and raise coherence.
5. **Fix the cross-cutting quality bugs first** (they tax every feature): key-event routing
   (TSK-1315), pane size caps (TSK-1313), the render-validation habit (use the now-open VM lane).
6. **Per-feature production-grade rubric** (apply in each finish ticket): correctness · reachable
   entry · empty/error/loading states · keyboard access · perf/latency on the hot path ·
   visual polish · a T6 on-screen confirmation. File each as the feature's "→ production-grade" ticket.

---

## GAPS FILED (this audit → board)
See the `[AUDIT]`-tagged tickets filed 2026-07-02 (systemic + per-family finish tickets),
parented where a milestone/epic exists. The systemic tickets (redefine-done, cohesion pass,
finish-or-cut decisions, key-event routing) are the highest leverage.

## NEXT (this is a multi-pass audit)
This is the foundation pass (hierarchy + themes + state + path). Subsequent passes: (a) deep
per-feature production-grade specs for the top finish targets; (b) on-screen re-verification of
the 🟡/🟠 assessments (owner's bar: confirm usability on the real UI, not from code); (c) the
finish-or-cut owner decisions for the exploratory spikes.

---

## CODE-VERIFICATION LOG (append per pass — code verdicts replace ticket-derived states)

### Pass 2 (2026-07-02) — document viewers + command surface

**Verdict: the CORE is substantially more built, cohesive, and tested than pass-1 (ticket-
derived) implied.** Code-reading three central areas found them near-production-grade, three
tickets stale, one real gap (fixed), one real gap (confirmed, deferred):

| Area | Code verdict | Ticket said | Delta |
|---|---|---|---|
| CSV viewer (`CSVTableView`, 974 ln) | keyboard cell-cursor, find-in-table, filter, sort, multi-cell rect-select + NSPasteboard copy, formula gate — all WIRED | TSK-924 "multi-cell model-only" | **ticket STALE** |
| CSV viewport paging (`CSVViewportPager`) | **0 refs in the view — genuinely not wired** (large-file perf gap) | TSK-1139 "done, not wired" | **ticket ACCURATE** — real gap, render-VM slice |
| CSV empty-state | was a blank void on empty/filtered-nothing → **FIXED** (TSK-1415, `CSVEmptyState`) | (unticketed — found by code-read) | **new gap, closed** |
| Hex viewer (`HexView`, 1517 ln) | hex/ASCII search, "0 matches"/"N/M+", truncation handling, chunked streaming + placeholder, match-cap, edit mode | — | **production-grade already** |
| Command surface (`CommandRegistry+BuiltIn`, 116 cmds/11 cats + 490-ln test) | comprehensive; unique-ids/namespacing/palette-parity all tested; 13 `scriptVerb:nil` are CORRECTLY nil (interactive dialogs/window ops) | Theme-2 feared scatter | **cohesive; palette parity largely done (TSK-951)** |
| Image editor tool picker | 10 tools wired (brush/airbrush/eraser/colorPicker/floodFill/drawLine/Rect/RoundedRect/selectRect/selectLasso) | TSK-1048 "~4 capabilities" | **ticket STALE** |
| LSP completion | `autocompletion` wired + invoked in `codemirror.html` | TSK-463/1136 "not wired" | **ticket STALE** |

**Implication for the plan (revised):** the remediation is NOT "build missing UI." It is, in
priority order: (1) **reconcile the stale board to code** (TSK-1412 — 4 stale tickets found in
one pass; extrapolates to many of the ~417) so planning rests on truth; (2) fix the genuinely-
thin spots + real gaps (CSVViewportPager perf, and whatever code-reads surface next); (3)
cohesion/discoverability of LESS-central features + cross-cutting bugs (key-event routing
TSK-1315); (4) finish-or-cut the exploratory spikes (TSK-1414). The well-built core mostly needs
targeted polish (empty-states, edge bugs), not rebuilding. **Owner's "almost all unusable" reads,
at the code level, as: a few thin spikes + discoverability + a badly stale tracker — the core is
sound.** (Caveat: on-screen re-verification of the 🟡 features is still owed per the render bar;
this pass verified code-wiring, which for these native-SwiftUI/CM6 features is high-signal.)

### Pass 2 addendum (self-correction) — distinguish BACKLOG.md-file lag from BOARD state

Deeper check corrects pass-2's own "board badly under-reports code" claim — it was **too
strong**. Reconciling one flagged ticket against the live board (not the BACKLOG.md file):
- **TSK-924** (CSV multi-cell) board state = `review`, with a careful reconciliation: model
  host-tested (CSVRectSelection 5/5, CSVCopy, CSVClipboard, EditableCSVModel.paste), view
  wired (rect→⌘C→NSPasteboard, Copy Row/Col context menu), and an HONEST ceiling note — the
  focus-gated selection tint + the shift-select gesture (AX) genuinely can't be host-confirmed
  (ImageRenderer has no focus engine; AX is the one off-limits lane). So the ticket is **not
  stale** — it's accurately at review with a real render/AX tail.

**Refined finding:** the staleness is layered — (a) the **BACKLOG.md FILE lags** (it says
"model-only" for features the board already reconciled; the file's own header admits it lags);
(b) the **board tickets are largely honest**, sitting at `review`/`fixed` with real render/AX-
confirmation tails; (c) my pass-2 conflated the two. The genuine systemic pattern is therefore:
**features are model-complete + view-wired, stuck at an honest on-screen/AX confirmation tail**
that is the SAME owner-gated bar the whole app hit (TSK-1334 pixel grant + the AX lane) — NOT
incompleteness, and NOT a dishonest board. So TSK-1412 shrinks from "reconcile a dishonest
board" to "refresh the lagging BACKLOG.md file + close the review-lane items whose only gap is
the owner-gated render/AX confirmation." The real agent-actionable polish is the genuine gaps
code-reads surface (e.g. the CSV empty-state, TSK-1415) + the thin spikes + cross-cutting bugs.

### Pass 3 (2026-07-02) — UI-DRIVE VALIDATION on the REAL app (owner directive)

Ran the existing T4/UAT suites on the VM GUI lane (`test-in-vm.sh pixel --filter …` — spawns the
REAL `dist/TextView.app`, drives via real action paths, asserts model-state dumps). This is
"act like a user on the real app," not code-read. **35/35 core-workflow tests PASSED:**

| Suite | Tests | Real-app result |
|---|---|---|
| MultiFormatViewerUATTests | 2 | ✅ RTF + DOCX open → extracted text reaches the model |
| ViewModesUATTests | 13 | ✅ md/source/hex/csv/json/diff/html modes, per-tab persistence, zoom, open-as routing, empty-file, error-state-keeps-tabs |
| TabsAndWindowChromeUATTests | 10 | ✅ multi-tab lifecycle, symlink-dedup, async-loader-race (latest-wins), mode routing, status-bar coupling, zoom scaling |
| SidebarFileTreeAndBookmarksUATTests | 10 | ✅ folder nav, tree, file+folder bookmarks PERSIST across launch, keyboard nav, git/folder-stats toggles, open-in-new-session |
| EmptyStateNewImageHostingTests | 1 | ✅ New-Image button realized in the empty state (hosting-lane AX) |

**Verdict (evidence-based, corrects "almost all unusable" for the CORE):** the core workflows —
opening files across formats, all view modes, tab lifecycle/routing, sidebar+bookmarks — are
UI-drive-CONFIRMED WORKING on the real app, not just code-wired. This extends the owner's own
"editor/tabs/file-nav work" with hard real-app evidence and adds viewers/view-modes/bookmarks.
(Caveat: UAT asserts model-state on the real spawned app — very strong for routing/persistence/
lifecycle correctness; true PIXEL appearance is still the TSK-1334-gated tail.)

**So the genuine usability work is NOT the core** — it's: (1) the less-central / exploratory
features (finish-or-cut, TSK-1414); (2) code-found micro-gaps like the CSV empty-state (TSK-1415)
+ paint-undo (TSK-1416); (3) cross-cutting bugs (key-event routing TSK-1315); (4) the pixel/
occlusion tail (TSK-1334). Next passes: run the remaining UAT suites (Cm6Editor, LSP, media) for a
full core map, then drill the non-core features that lack UAT coverage.

### Pass 4 (2026-07-02) — near-complete real-app UAT sweep (~97 tests)

Ran essentially the whole UAT suite on the VM GUI lane (real spawned app, real action paths,
model-state asserts). ~97 real-app UAT tests PASS across: MultiFormatViewer, ViewModes, Tabs,
Sidebar+Bookmarks, Cm6Editor, LSP, Sessions, SearchSurfaces, Previews, GitPanel, Interaction,
SettingsMenusAndShortcuts, Plugins+MCP, MetadataChecksum, KeySynth, and rendered-scroll-restore.

The sweep found exactly TWO issues, both handled:
- **PMA01** — a real code<->test divergence I introduced (Canvas added 11 canvas_* MCP tools; the
  UAT's expected tools/list was stale at 20). FIXED (fc9fba51) -> 31, re-run green. Note: it was a
  TEST-expectation lag; the app catalog was correct.
- **PMA04** — a 30s TIMEOUT flake under heavy batch load (zoomIn is unconditional; passed on
  re-run). Test-perf edge, not an app bug.
- ScrollRestore: rendered-scroll restore PASSES; editor-scroll SKIPS = TSK-1200 (owner-parked).

Bottom line (evidence, not code-read): the app's core AND most secondary features are
UI-DRIVE-CONFIRMED WORKING on the real app. "Almost all unusable" does NOT hold for anything with
UAT coverage. Genuine remaining work: (1) features WITHOUT UAT coverage (exploratory spikes -
HTTP client, RSS reader, folder treemap, SQLite browser; TSK-1414 finish-or-cut) - drill next;
(2) editor scroll-to-line (TSK-1200); (3) pixel/occlusion tail (TSK-1334); (4) code-found
micro-gaps. Caveat: UAT asserts model-state on the real app (strong for behavior); true pixels = TSK-1334.

### Pass 5 (2026-07-02) — SQLite browser: code-verified + UI-drive-confirmed WORKING (not a spike)

Drilled the first "exploratory spike" from the finish-or-cut list (TSK-1414). Code says it's a
REAL feature, not a stub: SQLiteBrowserView (516 ln) — 3-pane schema(tables/views/indexes/
triggers)/SQL-editor/results, off-main query + Cancel, error/empty/loading states, row cap
(maxRows=1000 + `truncated`), big-value guard, `SELECT … LIMIT 100` seeding on table click;
engine SQLiteReader host-tested (SQLiteReaderTests/FileInfo/Width + a UATSQLiteFixture). Wired to
`.sqlite` native-preview routing. UI-DRIVE: wrote SQLiteBrowserUATTests (new coverage — it had
none) and ran it on the VM — opening a real enumerable `.sqlite` mounts the browser as a preview
tab with NO error state → CONFIRMED working on the real app (calibration: native-preview tabs
report currentStateKind "preview", not "loaded"). **Verdict: SQLite browser is production-grade,
NOT a finish-or-cut spike — remove it from TSK-1414.** (Audit correction #4; the "exploratory
spike" framing keeps proving wrong — next drill the remaining three: HTTP client, RSS reader,
folder treemap, verifying before assuming.)

### Pass 6 (2026-07-02) — Folder treemap: code-verified + UI-drive-confirmed WORKING (not a spike)

Second finish-or-cut drill (TSK-1414). Real feature: FolderTreemapView (227 ln, SwiftUI Canvas
renderer, loading/empty states, a11y summary, byte formatting, category palette) + TreemapLayout
(squarified engine) + FolderTreemapModel (off-main folder scan). Engine host-tested well
(TreemapLayoutTests, FolderTreemapWiringTests, FolderTreemapPaletteTests, FolderStatsModelTests,
FolderStateSymbolTests). Reachable via `show-folder-treemap` script-verb + showFolderTreemap()
(TSK-506) → opens a "Folder Sizes:" hosted tab. UI-DRIVE: wrote FolderTreemapUATTests (new
coverage) + ran on the VM — sidebar-set-root + show-folder-treemap opens the "Folder Sizes:" hosted
tab live (windowTitle confirmed, tab additive). **Verdict: production-grade, NOT a finish-or-cut
spike — remove from TSK-1414.** (Audit correction #5.) Remaining finish-or-cut candidates: HTTP
client, RSS/feed reader. Given SQLite + treemap both proved fully built, expectation is these two
are also more built than the first-pass audit assumed — verify before any cut recommendation.

### Pass 7 (2026-07-02) — finish-or-cut COMPLETE: HTTP client works; RSS feed reader is ORPHANED

Drilled the last two TSK-1414 candidates.
- **HTTP client — BUILT + REACHABLE + now UI-drive-confirmed.** HTTPClientView (211 ln, request
  builder + response/error/empty states) + host-tested HTTPClientCore/ViewModel; reachable via
  File → New HTTP Request (TSK-721). Gap found + fixed: it had NO script-verb (cohesion gap vs
  show-folder-treemap, TSK-1413) → added `show-http-client`; new HTTPClientUATTests confirms the
  "HTTP Request" tab opens live. NOT a cut candidate.
- **RSS feed reader — BUILT + EXTENSIVELY TESTED but ORPHANED (the ONE real "built-but-unusable").**
  FeedReaderView (177 ln) + FeedReaderViewModel + FeedParser + FeedFetcher + FeedSubscriptionStore +
  FeedRefreshScheduler + OPML import — ~13 files, host-tested (FeedParserTests, FeedFetcherTests,
  FeedSubscriptionStoreTests, FeedRefreshSchedulerTests, OPMLTests, FeedReaderViewModelTests,
  FeedReaderViewRenderTests, …). BUT `FeedReaderView(`/`FeedReaderViewModel(` are instantiated
  NOWHERE in Sources — no menu, command, script-verb, or parent view. It is unreachable dead code.
  This is the genuine finish-or-cut decision (owner): FINISH = wire an entry point (a File-menu item
  + a show-feed-reader verb, ~mirrors the HTTP client — small, since it's fully built+tested) or
  CUT = delete ~13 files. RECOMMENDATION: FINISH — the feature is complete and tested; wiring is
  nearly free and it turns tested dead code into a usable feature. But whether a code/markdown viewer
  SHOULD ship an RSS reader is a product/scope call = owner's. Filed + surfaced.

**FINISH-OR-CUT RESULT: 4 candidates → 3 fully built + working (SQLite, treemap, HTTP client), 1
orphaned (RSS reader). Zero were "half-built".** The audit's original "exploratory spikes / likely
unusable" framing was wrong on all 4 counts — the real defect was reachability/cohesion + stale
tracking, not missing implementation. The RSS orphan is the single true "built but unusable" case.

### Pass 8 (2026-07-02) — orphan + cohesion sweeps: clean; hosted-view tools now ⌘K-discoverable

Systematic follow-on to the FeedReader orphan (TSK-1417). Two whole classes swept:
- **Orphaned View structs (built-but-unreachable):** of 166 View structs, only 2 are instantiated
  nowhere — ActionHistoryView (TSK-703) and RichTextReadOnlyView (TSK-706). BOTH are DELIBERATE WIP
  foundation slices, NOT accidental orphans like FeedReader: RichText is `RichTextFeatureFlag`-gated
  off (editor/toolbar are later, unbuilt slices); ActionHistory's log class is instantiated NOWHERE
  and fed by nothing, so wiring the view would show an empty panel. So the app's COMPLETE features
  are all reachable — FeedReader was the sole accidental orphan. The 2 WIP slices are tracked
  finish-or-cut (owner) — filed, not wired blind (finishing each is a real build, not a wire).
- **Script-verb ↔ dispatch cohesion:** clean — every advertised verb dispatches (the 2 apparent
  "no-dispatch" verbs, wait-editor-line/wait-rendered-scroll, are DELIBERATELY harness-handled;
  the 6 apparent "extra" dispatch tokens are nested sub-args (save/discard/cancel/on/off) + a comment).
- **GAP FOUND + FIXED — command-palette discoverability (TSK-1413):** the hosted-view tools
  (HTTP client, feed reader, folder treemap, dependency graph, walkthroughs) were reachable via
  File/View menus + verbs but had NO ⌘K palette entries. Added 5 CommandDescriptors → their existing
  show-* verbs, + a CommandVerbCohesionTests REGRESSION GUARD (every command verb resolves to a real
  catalog token — catches a palette command that would silently no-op). Teeth-verified. Commit
  1c46b2a0.

Running tally of GENUINE gaps found + fixed this run: CSV empty-state (1415), image paint-undo
(1416), HTTP-client verb cohesion, FeedReader orphan wired (1417), palette discoverability (1413).
The app is broadly built + reachable; the remaining known-incomplete surfaces are the 2 WIP slices
(ActionHistory/RichText — owner finish-or-cut) + the pixel/occlusion tail (TSK-1334).

### Pass 9 (2026-07-02) — env-var-only entry-point audit (TSK-1413): CLEAN; media-export + search empty-states production-grade

Audited the TSK-1413 sub-gap "features reachable ONLY via an env var (no UI)". Enumerated all MDV_*
env reads in Sources and classified:
- **MDV_START_IMAGE_EDIT / MDV_START_AUDIO_EDIT** — the audit's prime suspects. Both are TEST-ONLY
  shortcuts ("opens straight into the editor so a T5 pixel test can capture it"), NOT sole entries:
  image editing has the real "Edit image" button (MediaPreviewView:269), audio has the "waveform"
  control-bar button (mdv.audioPreview.editButton:761). NOT env-var-only. (Corrects the audit's
  MDV_START_AUDIO_EDIT suspicion — same "more built than assumed" pattern.)
- **MDV_RICHTEXT** — the RichText WIP flag (TSK-706/1418, tracked WIP, correctly gated off).
- **MDV_DOM_PATCH** (experimental render flip TSK-838), **MDV_REMOTE_SOCKET** (experimental remote-
  core), **MDV_BACKGROUND** (headless launch), **MDV_PRESERVE_RECENT_SOURCE_VIEWS** (cache tuning),
  **MDV_APP_SUPPORT / _DIAGNOSE_DELAY / _WINDOW_DIAG / _ENABLE_DIAGNOSTICS / _SIGNPOSTS /
  _PRISTINE_CHROME** — all harness/diagnostics/experimental, not user features.
  => NO env-var-only USER feature exists. Sub-gap CLEAN.

Also confirmed production-grade while here (no fix needed): audio MP3 export degrades gracefully
(AudioExportAccessory disables MP3 + retitles "MP3 (ffmpeg not found)" when ffmpeg absent; export
errors show specific alerts); search empty-states all present (CrossSearchPanel "No matches",
SearchAnywhereSection, StructuralSearchView, command-palette hints).

TSK-1413 status: palette-parity (Pass 8) + env-var audit (this pass) DONE. Remaining: menu reorg
(TSK-751/1318) — a larger UX-design task. No code fix warranted this tick (surfaces audited are
production-grade; not manufacturing marginal work per owner directive).

### Pass 10 (2026-07-02) — REAL BUG found in a deep interaction path: geometry-after-paint (TSK-1419)

Reversing last pass's "micro-gap vein thinning" note: the vein is thin on MAIN surfaces (empty
states, reachability, per-feature basics — all verified production-grade), but DEEP INTERACTION
paths (feature × feature) still harbor real bugs. Found + fixed a silent DATA-LOSS bug: in the image
editor, committing a geometry op (crop/resize/rotate/skew) AFTER starting a paint session was
silently swallowed — render() early-returns the destructive paint buffer, shadowing base.ops, so the
op was recorded but never rendered AND lost on export (the paint buffer, without the op, was
written). Diagnosed with a failing test first (rendered stayed 12px after a resize to 24), fixed by
transforming the paint buffer THROUGH the op via the same Renderer (4dc94b8c). 3 host tests + teeth.

LESSON for the remaining run: stop re-checking main surfaces (verified). Hunt DEEP INTERACTION /
EDGE paths — ordering between two features (paint↔geometry), state across a switch (session/tab),
undo across mode changes, export after edits. That's where the genuine bugs remain. Trigger here
(paint drag + resize dialog) is AX/pixel-gated, so these are host-tested + teeth (on-screen is the
same code path) — the honest ceiling until TSK-1334.

Genuine gaps found+fixed this run: CSV empty-state (1415), paint-undo (1416), HTTP verb + palette
discoverability + cohesion guard (1413), FeedReader orphan wired (1417), geometry-after-paint (1419).

### Pass 11 (2026-07-02) — tonal × paint crossing: silent no-op fixed by gating (TSK-1420)

Continuing the deep-interaction-path mining (Pass 10's lesson). Same shadow root as geometry-after-
paint: render() early-returns the destructive paint buffer, so the Tone sliders (shown
unconditionally, calling scheduleRender) were a SILENT NO-OP after painting — diagnosed with a
failing test (brightness=-1 left paintCanvas pixels unchanged). Unlike discrete geometry ops (which
commitGeometry now transforms the buffer through), tonal is CONTINUOUS live state baked into the
buffer and can't be re-derived per-tick, so the fix GATES rather than fakes: isToneEditable
(paintCanvas==nil) → the view disables the Tone group + a "discard paint to adjust" note. Geometry
stays enabled. 3 host tests + teeth (6cb11753). The real long-term fix (non-destructive paint layer)
is BACKLOG'd.

PAINT IS A DESTRUCTIVE TERMINAL MODE — every post-paint crossing needs explicit handling:
geometry=transform-the-buffer (TSK-1419 ✓), tonal=gate (TSK-1420 ✓). REMAINING crossings to check:
selection × paint (can you select/crop-to-selection/copy after painting?), undo ORDERING across
interleaved paint+geometry (my paint-undo v1 note flagged this), export-after-paint fidelity.

### Pass 12 (2026-07-02) — undo ordering across paint+geometry unified (TSK-1421); paint-crossing set COMPLETE

Fourth image-editor paint-crossing bug, all found by the deep-interaction mining (Pass 10 lesson).
Interleaved paint+geometry undo reverted TWO actions per ⌘Z (a resize + the preceding stroke) and
desynced base.ops from paintCanvas — two undo timelines for one destructive session. Fixed by
collapsing to a unified paint-undo timeline: commitGeometry during paint snapshots onto paintUndo +
transforms the buffer, no base.ops push. undo peels in order; redo re-applies (aad50470). Diagnosed
with a failing test (undo → uniform buffer). 3 tests + teeth; TSK-1419/1416 suites still green.

**PAINT-CROSSING SET COMPLETE:**
- geometry × paint → transform the buffer through the op (TSK-1419 ✓)
- tonal × paint → gate (baked-in, can't re-derive) (TSK-1420 ✓)
- selection × paint → already paint-aware (copy/cut/delete/paste/crop/selectAll read paintCanvas) — CLEAN
- undo ordering × paint → unified timeline (TSK-1421 ✓)
- (export-after-paint uses paintCanvas, which now carries geometry — consistent.)

The image-editor deep-crossing vein is now largely mined (4 real bugs: paint-undo 1416, geometry
1419, tonal 1420, undo-ordering 1421). NEXT deep-interaction target = a DIFFERENT feature family:
SESSION/TAB-SWITCH state (the historical bug class per CLAUDE.md — scroll reset, footer-stats blank,
loading flashes: imperative state populated AROUND a switch, raced by the declarative render).

### Pass 13 (2026-07-02) — overlay annotations dropped on export = data loss (TSK-1422); other families verified clean

Verified CLEAN this pass (production-grade, no fix): session/tab-switch state (updateDerived is
synchronous + equality-guarded + heavily hardened), CSV sort (CsvSort numeric-aware/empties-last/
stable/localized), CSV filter×copy (all copy ops read displayRows), CSV edit×filter/sort (gated via
editingAvailable — same gate pattern as tonal). The tab-switch + CSV families are well-hardened.

REAL BUG found in the image-editor LAYER model: the vector overlay (annotation shapes + text, drawn
over the preview, "never baked") was SILENTLY DROPPED on export/save-a-copy — diagnosed with a
byte-identical export test. Fixed by compositing the overlay via ImageRenderer(VectorOverlayView)
over the export base — WYSIWYG-guaranteed, host-testable (7d3b5070). 2 tests + teeth; 114-test suite
green.

THE IMAGE EDITOR IS THE RICHEST VEIN — 5 real bugs this run (paint-undo 1416, geometry-after-paint
1419, tonal-after-paint 1420, undo-ordering 1421, overlay-export 1422), all from its MULTI-LAYER/
MULTI-MODE design (source→geometry→tonal render, destructive paint buffer, vector overlay). The
render/paint/overlay/geometry/tonal/undo/export crossings are now largely covered. Other families
(CSV, session-switch, search, sidebar, tabs, viewers) verify clean. NEXT candidate for hidden
crossings = another MULTI-MODE feature: the HEX editor (view vs edit mode, binary editing) or the
diff view. Lesson: multi-layer/multi-mode features harbor the bugs; single-purpose views are clean.

### Pass 14 (2026-07-02) — hex editor (multi-mode) — theory HOLDS: real bug, but AX-gated for validation (TSK-1423)

Applied the multi-mode-feature theory to the hex editor. It holds — found a real correctness bug:
hex SEARCH ignores unsaved EDITS. recomputeMatches (on the HexView representable) scans `file.data`
(the immutable original), while edits live on the HexTextController (editBuffer); the edited bytes
flow only to the model (onDirtyChange → save), never into the representable's search. So after
editing a byte you see the change but search finds the pre-edit bytes, and match highlights/count/
nav go stale. Edit×truncation + edit×streaming ARE correctly gated (isEditable, !isStreaming).

KEY DISTINCTION from the image-editor wins: the image-editor bugs were fixable + host-tested because
the logic lives in a MODEL layer (ImageEditorViewModel, headless). The hex bug's fix is representable
@State plumbing (controller→representable→search) and the on-screen trigger is HEX-KEYBOARD-EDIT =
AX-driven (off-limits) → NOT host-testable or VM-drivable → filed for the render/AX lane (TSK-1423),
NOT blind-landed (render-confirm directive). The search ENGINE is already host-tested.

REFINED HUNTING HEURISTIC: multi-mode features harbor bugs (theory holds), BUT prioritize ones whose
logic is in a host-testable MODEL/pure layer (image editor, CSV, sort, parsers) — those yield
fixable+validated wins. View/representable-internal + keyboard-AX behaviors (hex edit, CM6 editor
internals) are real but land in the owner/TSK-1334/AX lane. NEXT: mine host-testable MODEL/pure-logic
crossings (e.g. multi-format viewer routing edge cases, diff engine, transcript/CSV/markdown parsers).
