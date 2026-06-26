# Backlog — the single curated worklist (updated 2026-06-22)

> **The ONE backlog** (owner directive 2026-06-22): a curated, prioritized list of *what to work on*. The
> `tasked` board is the **system of record** for task STATE/detail; this file is just the prioritized selector.
> Stale tracking docs (old handoffs, dated curated lists, WORK_QUEUE, completed archives) → `archive/tracking-2026-06-22/`.
> A by-kind **disjoint / not-fully-wired** sweep (ports · model · core-seam · wiring-tail · render · design-only) is
> preserved at the top of `archive/tracking-2026-06-22/BACKLOG_historical_2026-06-22.md`; its items map to the P1
> wiring-tail + the ports listed below.

**Goal: drive every task → `done`.** The `tasked` board (`http://localhost:8787/`) is the
**system of record**; this doc is the human-scannable selector — actionable work up top,
carried-forward context below. The next-50 list is prioritized by the owner's standing rule:
**user-facing value first** (app bugs + perf the owner can feel → user-facing features →
internal-quality / rust-core / test work).

## Current worklist (checkable — updated 2026-06-23)

> **Checkboxes are the at-a-glance progress mirror; the `tasked` board is authoritative for STATE.** Tick `[x]` when the board item reaches `done`/`validated` (render items: when on-screen-confirmed). From the 7-subagent board reconcile (the board is ACCURATE — done work already left the open lanes; no shipped-but-unmarked backlog). The OLD curated Next-50 + lane snapshot below are the prior capture, superseded by this section.

### Low-hanging-fruit sweep (2026-06-25) — outcome + NEXT 10

**Sweep result** (the 2026-06-20 Quick-Wins list, re-verified against current `main`): **5 of 10 already shipped** since the audit — tooltip delay (TSK-1209), find-text-preserve (TSK-1207), View-only toggle (TSK-936 validated), rendered find-highlight clear (`MarkdownRenderedView`), text-transforms menu (TSK-1113 validated). **3 fixed + committed `30a3af2f`**: editor 2px caret + literal-Tab insert (**TSK-1250**, render → `review`) and the `check-bundle-size.sh` 48/26→80/65 doc drift (residual of the validated **TSK-1098**). **2 deferred as tickets** (prereqs missing, not blind-hacked): Cmd+F sidebar routing (**TSK-1248**), terminal header row (**TSK-1249**). LESSON: the Quick-Wins audit is stale — verify each item against `main` before working it.

**NEXT-10 RECONCILED 2026-06-25 — all 7 "host cluster" picks were ALREADY DONE; the file tags were stale, the BOARD is accurate.**

> ⚠️ **The `[reported]`/`[progress]` tags in the Next-50 + lane snapshot below are the 2026-06-20 capture and are STALE.** The BOARD moved most to `fixed`/`validated`; this file wasn't re-synced. **Derive picks from the live BOARD (`task_next` / `task_list ready=true`), NOT this file.** Two sweeps in a row picked already-done items off these stale tags.

Verified this sweep (every host pick already shipped): TSK-1120 footer (fixed `41017b83`) · TSK-986 hex debounce (review `50521d04`) · TSK-991 sidebar cap (done, `childrenCacheEvictions`) · TSK-1036 readers (validated) · TSK-1100 deps-graph entry (done) · TSK-1116 focus-mode menu (done) · TSK-1132 webview heavy-tier (done, `isHeavyTier`). Render picks: TSK-1182 triaged/execute-ready · TSK-1102 + TSK-891 still open.

**Actually-open (live board query, markdown_viewer, non-foreign — the host-fixable pool is DRAINED):**
- **Image-editor epic** (TSK-1048 + P0 perf slices TSK-1049/1052 dirty-rect) — owner-flagged "clunky"; concrete model-testable slices + render tail.
- **Render-gated perf** — TSK-891 (Page Up jank, CM6/CA-commit class), TSK-839 family.
- **Owner-gated levers** — rust flips TSK-1215 (formula) / TSK-1202 (folds); deps TSK-399/400; zoom-split TSK-470.
- **Agent-integration features** — TSK-941–945, TSK-691 (large, net-new).

Next real work = a deliberate epic/perf investment or an owner decision — not a quick host fix.

### A. BUILT user-facing fixes — unmerged on worktree branches; verify → merge (highest leverage)
- [x] **TSK-921 / 922** — close/open-split race — **FIXED on main** (`17932af8`: wave2 re-applied the worktree fix — `ContentView` observes `tabCoordinator` so `splitURL` re-bodies on open/close). Host teeth green (`SplitObservationTests` 5/5 + `ChromeBodyEvalCount` open/close re-body). At **review** (on-screen pixel = VM/owner). Board was stale (reconcile predated `17932af8`); both → `fixed` 2026-06-23.
- [x] **TSK-1046** — scroll-reset on session/tab switch (**owner top priority**) — **FIX LANDED + VALIDATED on both surfaces** (`e50e4538` fix; `d1a1c36e` editor validation). RENDERED: on-screen green (`ScrollRestoreUATTests` SCROLL01/02, spawned-app UAT). EDITOR: live-CM6 green **in-process** (`EditorScrollRestoreWebViewTests.test_restoreSeed`, wired into `run_webview_tests` + nightly) — the spawned-app editor UAT is a dead end (CM6 WebContent jetsam in the GUI lane; see LESSONS). MODEL: host-tested (`editorMountSelectionSeed`) + owner manual confirm. At `review` (owner closes to done). Owner CONFIRMED fixed on-screen.
  - Residual follow-ups (low-pri test-infra; not blocking): (a) `scrollToLine`-puts-line-at-TOP is NOT reliably testable in a headless in-process WKWebView (`applyScrollToLine` needs a measured viewport/rAF cycle that doesn't run headless — same limit BlameGutter works around with a repaintNudge); the restore path uses `scrollIntoView` which works headless, so the sibling guard was dropped. (b) TSK-1243's spawned-app diag scaffolding (`LiveScrollProbe.navLog`, `renderedProbeDiag`/`editorProbeDiag` dump fields, `EditorWarmCacheProbe`) is committed + harmless + useful, but could be tidied once the UAT lane is fully stable.
- [ ] **TSK-1047** — warm-WebView cache for the CM6 editor pane (PERF: avoid the rebuild entirely on session/tab switch). DISTINCT from TSK-1046: the `editorMountSelectionSeed` SEED-belt (validated by `EditorScrollRestoreWebViewTests`) restores scroll on re-mount; TSK-1047's warm-cache would skip the re-mount. The warm-cache impl (`WarmEditorWebViewCache`, branch `worktree-agent-a7b9fc7b...`, commits `e25fc38f`/`539eb8f0`/`3c80a3c7`) FAILED on the VM (SCROLL03/04 still reset) and is at `progress` with DEBUG probes added — needs the VM `[WARMCACHE-PROBE]` trace to diagnose where park→re-attach breaks.

### B. Render/VM tails — host/model half shipped, render remains (need the screen)
- [ ] **1049** off-main image pipeline
- [ ] **1055** paint commit-on-drag-end · [ ] **1101** paint gesture · [ ] **1102** CSV cell-cursor
- [ ] **1127 / 1129 / 1136 / 463** LSP completion + workspace-binary-trust
- [ ] **1151** View↔Edit line-height · [ ] **1175 / 1176** terminal color / history UI
- [ ] **1182** diff multi-line select · [ ] **838 / 1183** WebView DOM-patch · [ ] **1141** xlsx sheet UI

### C. Owner-gated — need a decision/flip
- [ ] **TSK-1215** formula flip (`MDV_RUST_FORMULA`) — parity-clean; ON → live computed CSV formula values (user-facing)
- [ ] **TSK-1202** folds flip (`MDV_RUST_FOLD`) — backend swap, parity-proven (no new user-visible feature)
- [ ] **TSK-1138** Tier-D plugin contract · [ ] **1045** per-session DocumentModel · [ ] **854** kill Swift TS twin (approved) · [ ] dep-gated rust lanes 399/584/585/587/835

### D. Epics (ongoing, slice-and-iterate)
- [ ] **1048** image · [ ] **537** code-review · [ ] **538** rust-audit · [ ] **379** rust-migration
- [ ] **694** log-clustering · [ ] **697/703/706/713/715/716/722/723** P7/P8 wish · [ ] **764** git-reconcile · [ ] **955/956/957/958** feeds/AU/macros/paste

Metadata: TSK-589 `blocker=owner-decision` is stale (resolved 2026-06-19) → pure implementation now.

> **Snapshot caveat:** this lane sweep was taken WHILE `board-reconcile-v2` was concurrently
> refining the OPEN lanes (re-triaging, un-claiming stale leases, merging dupes). A handful of
> these `TSK-###` ids may have shifted lane / been folded / re-stated since capture. Re-`task_get`
> before acting on any single id; the board — not this file — is authoritative.

## Lane snapshot (OPEN lanes, observed 2026-06-20)

| Lane | ~Count | Notes |
|---|---|---|
| `reported` | ~176 | backlog; includes the large `[IMG]` MS-Paint-parity epic (TSK-1048..1090, ~43 tickets) + the wiring-tail (TSK-1100..1183) spun out of landed foundations |
| `ack` | ~19 | acknowledged big `[WISH]` epics / spikes / very-large |
| `triaged` | ~10 | scoped (incl. parked design-Qs + a few unblocked-but-not-started) |
| `progress` | ~57 | claimed — mostly **stale-lease** (abandoned mid-work, lease long expired), a few genuinely in flight |
| **= OPEN total** | **~262** | needs implementation (does NOT count `fixed`/`review`/`validated` awaiting-close) |

(The `fixed`/`review`/`validated` "awaiting-close" pile from 06-19 — ~215 — is unchanged and lives
in `docs/COMPLETED_ARCHIVE_2026-06-19.md` + `docs/AUTONOMOUS_PROGRESS.md`; closing those is the
owner's `→done` / a VM render-validation pass.)

---

## Next 50 — work list

Prioritized; numbered 1–50. `task_next`'s pre-ranked head is **TSK-590** (review-lane epic, already
agent-done — not an implementation pick). De-duped against the 06-19 carry-forward (those items are
board tickets too; they are NOT repeated here). **Skip-but-note** owner-blocked items are listed at
the very end of the tiers, not picked.

### P0 — user-facing bugs + perf the owner can feel (1–14)

1. **TSK-1046** [progress] — Scroll STILL resets on session/tab switch (render-path restore not applying) — live regression the owner sees every switch; model landed but bug persists.
2. **TSK-598** [progress] — Opening MD files is very laggy (re-reported after the rendered-MD latency fix) — direct owner pain on the app's core action.
3. **TSK-591** [progress] — Mouse-over on the file nav is very laggy — constant friction in the sidebar; perf the owner feels.
4. **TSK-891** [reported] — Page Up is janky / not smooth (editor) — visible scroll-jank in the editor hot path.
5. **TSK-838** [progress] — Rendered-MD WKWebView persistent page + DOM-patch (kill the 2–9s full-reload storm) — biggest single perf lever for the rendered view.
6. **TSK-1183** [reported] — Wire the JS DOM-patch APPLY path (consume RenderedBlockDiff) — the apply half that actually delivers TSK-838's win to the screen.
7. **TSK-986** [reported] — Hex search scans the full buffer synchronously on the main thread per keystroke (no debounce) — main-thread stall on every hex-search keypress.
8. **TSK-1120** [reported] — Footer file-stats flaky between already-loaded tabs (SwiftUI re-body on selection) — visible footer flicker the owner notices on tab switch.
9. **TSK-910** [progress] — Commit diff: only one line selectable — enable multi-line selection — broken interaction in the git-diff view.
10. **TSK-1182** [reported] — Diff multi-line selection (collapse hunk into one selectable Text) — the plain-diff-mode half of the same multi-line-select bug.
11. **TSK-732** [progress] — Font mismatch between View/Edit (and Shoulder); make seamless — jarring font shift the owner flagged.
12. **TSK-1151** [reported] — View↔Edit line-height + size-rounding mismatch (CM6 hardcodes 1.45 / Int-rounds size) — the concrete root cause behind the View/Edit mismatch.
13. **TSK-1049** [reported] — Image editor: off-main render pipeline + cached CIContext + render cancellation — image-editor responsiveness (do-first perf foundation).
14. **TSK-1050** [reported] — Image editor: debounce + coalesce slider re-renders (make the claimed debounce real) — slider lag the owner feels in image editing.

### P1 — user-facing features (15–38)

15. **TSK-1051** [reported] — Image editor: decode-once base CGImage cache (stop re-decoding source per render) — image-editor perf foundation, unblocks the paint tools.
16. **TSK-1053** [reported] — Image editor: off-main non-blocking save (drop runModal) — removes the save-time UI freeze.
17. **TSK-1054** [reported] — New blank image creation flow (size + bg color) + File→New Image — net-new user-facing capability.
18. **TSK-1101** [reported] — Wire tap/drag-to-paint gesture on the image-editor preview (TSK-285 gap) — makes the shipped raster-paint model actually usable on screen.
19. **TSK-1056** [reported] — Pencil tool (1px free draw) — first concrete paint tool.
20. **TSK-1057** [reported] — Eraser tool (erase to background color) — core paint tool.
21. **TSK-1058** [reported] — Real click-drag Line tool (live preview + width) — core paint tool.
22. **TSK-1059** [reported] — Real click-drag Rectangle tool (outline/fill/both) — core paint tool.
23. **TSK-1060** [reported] — Ellipse tool (click-drag, outline/fill) — core paint tool.
24. **TSK-1100** [reported] — Wire DependencyGraphView to a user-reachable entry point (TSK-280 follow-up) — surfaces a built-but-unreachable feature.
25. **TSK-1102** [reported] — CSV grid: wire CSVCellCursor (arrow-key nav + focus ring + Cmd-C whole-cell copy) — surfaces the shipped cell-cursor model; long-standing CSV ask.
26. **TSK-1103** [reported] — Local History: wire snapshot-on-save + version-list/restore UI (owner policy: diffs-only, 20MB cap, text-only, exclude secrets, default-on) — owner-resolved feature, store built, needs wiring.
27. **TSK-1036** [reported] — Route .docx/.rtf/.ods/.xlsx into the viewer (consume the landed readers) — turns four shipped readers into a visible open-these-files capability.
28. **TSK-1113** [reported] — Wire TextTransform case engine to an editor Transformations menu (Upper/Lower/Capitalize) — small visible TextEdit-parity win.
29. **TSK-936** [reported] — Shortcut to toggle View-only mode — quick owner-requested shortcut.
30. **TSK-709** [reported] — Unify Cmd+K, Cmd+G — owner-requested shortcut cleanup.
31. **TSK-751** [reported] — Organize the menu items properly — owner-requested menu hygiene.
32. **TSK-747** [progress] — New tab: offer other types (Sheet, Image) — visible new-tab UX.
33. **TSK-1105** [reported] — Sessions-optional: user-facing Settings toggle for sessionsEnabled — exposes an existing pref the owner wants reachable.
34. **TSK-1112** [reported] — Settings → Extensions tab: wire ExtensionsInventory into a unified Settings tab — surfaces installed extensions.
35. **TSK-1107** [reported] — Walkthrough catalog/history/versioning UI — File>Walkthroughs browser (run/rename/delete + resume) — user-facing walkthrough management (TSK-316).
36. **TSK-1115** [reported] — Render the awaitUser checkpoint reply UI (prompt + choice pills + free-form field) — completes the interactive-walkthrough loop (TSK-378).
37. **TSK-1116** [reported] — Wire FocusWorkMode into a reachable View → Focus Mode menu — surfaces the focus-mode preset (TSK-381).
38. **TSK-1143** [reported] — Unified search palette UI over SearchRouter (epic TSK-677 tail) — visible unified-search surface.

### P2 — internal quality / rust-core / build / test (39–50)

39. **TSK-1098** [reported] — Bundle-cap doc drifted AGAIN (docs say 48/26 MB; check-bundle-size.sh defaults 80/60 MB) — quick correctness fix, prevents silent budget drift.
40. **TSK-543** [progress] — cm_apply ships the FULL document across FFI both ways per edit batch (~10x doc-size memory traffic/tick) — rust-core perf foundation behind editor latency.
41. **TSK-1124** [reported] — Wire the stateful cm_apply-delta seam end-to-end (FFI method + Swift consumer) — the delivery half of TSK-543; stops shipping the full doc per keystroke.
42. **TSK-589** [triaged] — CoreRuntime session eviction (owner-resolved: 512MiB/64docs/TTL-off, configurable) — owner-decided, now pure implementation; bounds unbounded handle map.
43. **TSK-991** [reported] — SidebarModel.pruneChildrenCacheIfNeeded can't enforce the cap when expanded dirs exceed it — memory-bound correctness bug.
44. **TSK-1110** [reported] — DocumentModel SRP split — continue extraction (slice 2+) — maintainability of the central model (TSK-382 follow-on).
45. **TSK-847** [progress] — Bump headless-gate swift test to --num-workers 18 (run phase is I/O-bound) — faster CI/test loop (owner wants speed).
46. **TSK-1181** [reported] — Split the slowest swift test classes (data-enabled follow-up to TSK-836) — test wall-clock reduction.
47. **TSK-1131** [reported] — Add a non-gating code-coverage step (no coverage measured anywhere today) — test-infra gap from the TSK-788 audit.
48. **TSK-1132** [reported] — Add a WebViewTestCase heavy-tier base so the 6 live-WKWebView suites stop escaping TierGateObserver — closes a tier-discipline hole.
49. **TSK-1133** [reported] — pr.yml does NOT run the MDV_RUN_WEBVIEW_TESTS lane though CLAUDE.md/TierBaseCases claim it does — doc/CI truth mismatch.
50. **TSK-1130** [reported] — Swift Testing hybrid pilot: one pure-logic suite + CLAUDE.md convention (owner-ratified TSK-787) — incremental test-framework modernization.

### Skip-but-note — owner-blocked (do NOT pick autonomously)
- **TSK-1045** [reported, `owner-decision`, waiting:human] — Per-session DocumentModel (Phase-2 seam): MAJOR refactor needing owner sign-off.
- **TSK-854 / TSK-810** [reported, `owner-decision`] — Delete the Swift highlight twin / Stage-B hex carve-out fallback model.
- **TSK-831 / TSK-852 / TSK-835** [reported, `owner-decision`/`dep-approval`] — Duplicate index-build tree reclone / CI .build cache / cargo-nextest.
- **TSK-399 / TSK-584 / TSK-585 / TSK-587 / TSK-1137** [`dep-approval`] — memchr SIMD / fuzz / property-test / WASM / cargo-mutants lanes.
- **TSK-508 / TSK-470 / TSK-956→TSK-1097 (VST)** [`owner-decision`] — digraph render approach / zoom split / VST-hosting non-goal.

---

## Carried forward (06-19)

The non-done content from `docs/CURATED_TASKS_2026-06-19.md`, de-duped against the Next-50 above
(items already pulled into the 50 are not repeated). Done/landed items were dropped (archived in
`docs/COMPLETED_ARCHIVE_2026-06-19.md`).

### 🔓 OPEN — needs owner (decisions / dep-approvals — don't autonomously guess)
- **Design decisions (spiked + parked):** 787 test-framework→HYBRID (note: TSK-1130 above ships the pilot) · 781 LSP→external+fallback (note: TSK-1126/1127/1128/1129 ship the slices) · 779 plugins/terminal-Tier-D · 775 migration D1/D2/D3 · 788 T5-coverage prioritization.
- **Dep-approvals:** 897 (TreeSitter grammars + budget) · 399 (memchr SIMD) · 835 (cargo-nextest) · 851 (ccache) · 584/585/587 (fuzz/property/WASM lanes) · 1014 (tree-sitter-swift pin).
- **Decisions:** 854 (delete Swift highlight twin) · 810 (Stage-B hex carve-out) · 589 (session eviction policy — NOW owner-RESOLVED → implementable, see TSK-589 #42 above) · 470 (zoom split) · 709 (Cmd+K/Cmd+G — picked at #30, owner may still want input on the unification scheme) · 751 (menu organization — picked at #31) · 791 (CM6 direction) · 936 (View-only shortcut keys — picked at #29) · 956 (VST hosting → 1097) · 301 (local history — owner-resolved → TSK-1103 at #26) · 508 (digraph render) · 498/852 (CI policy) · 831 (IDE indexing).
- **Repro-needed:** 343 (image history/revert) · 733 (save-prompt on session switch).

### 📋 OPEN — backlog not yet pulled (next waves)
- **Perf (need VM/Instruments trace first):** 889 (JSON warm re-open) · 887/888 (palette/search residuals; follow-ons TSK-1179/1180 spun out) · 382 (DocumentModel memory — SRP-split continues at TSK-1110 #44).
- **Architectural perf:** 838 (rendered-MD WKWebView persistent page + DOM-patch — biggest lever; **now picked at #5/#6** with the apply-path split out).
- **Big epics (one-slice-and-iterate):** 711 CSV-editor · 712 3-way merge (UI tail TSK-1171) · 716 worktree-UX (UI tail TSK-1159) · 717 notebooks (UI tail TSK-1172) · 706 richtext (UI tail TSK-1156) · 703 action-history (UI tail TSK-1155) · 722 task-runner (UI tail TSK-1160) · 723 structural-search (UI tail TSK-1161) · 691 agent-harness · 701 SDLC-surface · 697 agent-services (tail TSK-1154) · 725 inspections · 764 git-reconciliation (TSK-1165/1166 wiring) · 772/773/777/782 plugin-expansion · 688 walkthrough-presentation · 680/682 docx/rtf (tails TSK-1144/1145) · 673/674 Excel (tail TSK-1141) · 715 profiling (tail TSK-1158) · 320/380/403-406 paint (now the large `[IMG]` epic TSK-1048..1090 + wiring tails TSK-1114/1118/1168).
- **Very-large / aspirational:** 689 PinBoard · 694 log-clustering (UI tail TSK-1153) · 695 credential-handling · 700 collaboration · 702 Mac-intelligence · 774 Music · 687/693/699 agent-integrations · 250/256/409 web-port tail (note: TSK-256 markdown rendered web view is **unblocked + triaged**, a ready pick).

### 🚧 Earlier follow-ups still open
- **TSK-1023** tmux controller → live PTY + SwiftUI split render wiring (VM-tail / live-validation).
- **TSK-1018** tmux live PTY+render (VM-tail).
- **897** TreeSitter grammars (dep-approval).

### New since 06-19 (board additions to be aware of)
- **`[IMG]` MS-Paint parity epic** (TSK-1048 + ~43 children TSK-1049..1090): perf foundation (P0/do-first) → tools (pencil/eraser/line/rect/ellipse/brush) → selection → color model → transforms → file formats → advanced. The P0/do-first slices are pulled into the Next-50 (#13–#23); the rest iterate behind them.
- **`[AU]` Audio Units hosting epic** (TSK-956 + TSK-1091..1097): mostly `live-validation`-gated; TSK-1097 (formalize VST as a non-goal) is host-completable.
- **`[LSP]` robustness slices** (TSK-1126..1129, TSK-1136) and **`[TEST-INFRA]`** gaps (TSK-1130..1134) spun out of the owner-ratified TSK-781/787/788 spikes.
- **Wiring-tail cluster** (TSK-1100..1183): each surfaces a built-but-unreachable foundation from the ultracode wave (deps graph, CSV cursor, local history, treemap, focus mode, walkthrough catalog, search palette, feed reader, etc.).
```

---

## Quick Wins — to get OwnerWishlist items fully DONE (2026-06-20)

**Source:** `OwnerWishlist.md` (truth-marked: `x`=done, `>`=partial/near-done, `-`=not-done). Each item below was
judged against the actual repo (`Sources/`/`Tests/`) by four exploration passes, so "quick" is measured, not assumed.
Effort buckets: **TINY** = a constant/one-rule change; **SMALL** = ~5–60 lines + a test; bigger items excluded.
Ordered smallest-effort-first within each area. (Board `q` free-text filter is currently broken — IDs were
cross-checked via `task_get` + the docs; topics with no dedicated open ticket are marked "no ticket".)

> **Reconciliation note (read before picking):** many wishlist `>` items turned out ALREADY DONE on a fresh repo
> read and were dropped from this list — multi-cursor (TSK-639 validated), git blame gutter + toggle (TSK-814
> validated), Cmd+F-toggles-closed (TSK-739 validated), terminal tab rename (TSK-771, model+menu shipped),
> plain-text-default for renderable-ASCII (TSK-332 validated), markdown outline panel (already wired in
> `LSPOutlineSection.swift`), LSP rename + code actions (fully wired in `DocumentModel`), and several pure-CSS/markup
> items already shipped (task-list `[x]` strikethrough `markdown.css:185`, preview-tab italic-not-bold
> `TabTitleStyle.swift:19`, unsaved blue dot `TabBar.swift:404`, CM6 default keymap arrows/Cmd/Opt/Home/End,
> sidebar lock/pin, file-nav fuzzy filter, right-click New File, terminal open-in-pwd, window-size persistence).

### Editor / find (CM6 + find bars)

- **no ticket** — *Tooltip popup fires too soon (open delay should ~2×)* — change `TooltipTiming.appearDelay` `0.3 → 0.6` in `Sources/ViewerUI/FloatingTooltip.swift:34` (+ optional matching `delay:` on the CM6 LSP `hoverTooltip` in `codemirror.html`). **TINY.**
- **no ticket** — *Blinking cursor width +1px in Editor* — add a `.cm-cursor { border-left-width: 2px }` rule in `Sources/ViewerUI/Resources/codemirror/codemirror.css` (or a base-theme override). Pure CSS, no Swift. **TINY.**
- **no ticket** — *Cmd+F "again should keep the prev find text" for Rendered + Source bars* — `dismissRenderedBar()`/`dismissSourceBar()` (`FindCoordinator.swift:47,97`) wipe the query; the editor bar already preserves it (TSK-770) — copy that pattern (don't null the query on dismiss) + 1 test. **TINY.**
- **no ticket** — *Tab should insert a literal tab, not indent the line* — swap the `indentWithTab` keymap binding (`codemirror.html:979`) for an insert-`\t` command (keep Shift-Tab dedent), behind the existing keymap compartment. **SMALL.**
- **no ticket** — *After dismissing Find bar in Rendered MD view, highlights remain* — clear-on-empty-query IS wired (`MarkdownRenderedView.swift:329-337` → `__mdvFindClear()`) but fails silently/raceily; add the `evaluateJavaScript` completion-handler + a clear-on-dismiss test. **SMALL.**
- **no ticket** — *Cmd+F when File-nav is focused opens the tab's finder* — `findInPage()` (`main.swift:3251`) routes by view-mode only, never checks first-responder; add a `firstResponder`-is-sidebar check before routing. **SMALL.**
- **no ticket** — *In Find mode, can't scroll past the currently-selected match* — JS `scrollIntoView({block:'center'})` exists (`MarkdownRenderedView.swift:847`); needs user-scroll-aware re-centering (or a documented behavior note). **SMALL (UX, no data risk).**

### Wiring-tail (engine built + tested, needs a menu/UI hook)

- **TSK-936** — *Shortcut to toggle View-only mode* — `readOnly` facet already plumbed into CM6 (`CodeMirrorEditorView.swift:40`); add a `View → Toggle Read-Only` menu item + keybinding + `@Published` toggle. **TINY.**
- **TSK-1113** — *TextTransform → editor Transformations menu (Upper/Lower/Capitalize)* — `TextTransform.edit(...)` engine done + tested (`ViewerCore/TextTransform.swift`); add 3 DocumentModel methods + an Edit-menu submenu. **SMALL.**
- **TSK-1103** — *Local History: snapshot-on-save + version-list/restore UI* — `LocalHistoryStore.swift` engine done + tested; owner policy already resolved (diffs-only/20MB/text-only/default-on); build the version-list view + restore action + save hook. **SMALL.**

### Special chars / invisibles

- **TSK-359** — *Special chars appear grey / invisibles too grey* — readable-invisibles infra exists (`SourceInvisiblesView.swift` Canvas overlay); remaining = stop the OS `NSLayoutManager.showsInvisibleCharacters` grey from double-rendering under the overlay. NOTE: ticket is currently `wontdo` (owner park-resolved the NSLayoutManager conflict) — would need a reopen before working. **SMALL.**

### Terminal

- **no ticket** — *Terminal header pane: "Terminal — Name [pwd, pid]"* — tab labels/titles + live cwd (OSC 7) already tracked (`TerminalPaneStore.swift:243`, `TerminalModel.swift:148`); expose `PTYProcess.childPID` up to the model + add a header SwiftUI row. **SMALL.**
```
