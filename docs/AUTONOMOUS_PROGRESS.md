# Autonomous run — progress tracker (2026-06-04)

## DECISIONS NEEDED (owner) — as of 2026-06-26

**NEW this autonomous run (2026-06-26) — what needs YOU to unblock the bottleneck:**
- **TSK-1257 — prod-build crash: M5-Pro RETEST (the one real acceptance left).** Fixed (Bundle.resolveResourceBundle + the `--verify-resources` gate); fixed dist vended to `github.com/josangel555/textview_dist` (`TextView-2026-06-26-packagingfix.zip`) + installed locally. Download on the M5 Pro → `xattr -dr com.apple.quarantine` → launch. Should now start.
- **TSK-1129 — LSP workspace-binary RCE guard: block-vs-prompt UX (PARKED, pings you).** Decision core + persisted trust store built; the spawn site now WARNS (vector visible). Closing it needs the BLOCK + a one-time confirm prompt: (a) prompt-first then block [rec] · (b) block-by-default now · (c) warn-only.
- **Rust flips — ALL RESOLVED by owner 2026-07-04 (chat):** TSK-649 no-soak (single-user; validation = docs/STAGE_B_DELETION_UAT_2026-07-04.md) → **fold FLIPPED ON same day**; TSK-1215 formula display decided (computed in-grid + separate formula edit box + subtle marker TSK-1515) → consumption slice next, then formula flip; TSK-589 eviction decided (dirty never; clean LRU, min(1–2 GB, 200 files)). Stage-B twin deletion executing inline per the UAT plan.
- **Spike ratifications now at REVIEW (deliverables done → ratify to done):** TSK-787 (Swift Testing hybrid — already adopted/in use), TSK-779 (plugin/core boundary), TSK-788 (audit depth: STANDARD).
- **TSK-775 (migration horizon) — RESOLVED 2026-06-28 (owner: "no need to stagger, do all" = WHOLE-CORE greenlit, NOT just engines-only).** Reconciled the stale board (was triaged despite the delivered roadmap + the owner's resolution) → advanced to review. **CAVEAT (verified 2026-06-28 by reading the rust state — this corrects an initial over-claim that 583 was the next autonomous slice):** the whole-core greenlight does NOT re-open meaningful AUTONOMOUS work. TSK-583 (DocId registry) is DONE/`wontdo`/already-fixed — built in `ffi/handle.rs` (soundness registry from the TSK-541 fix) + `runtime.rs` (`CoreRuntime<D>` + `DocId(u64)` + eviction_plan). `CoreRuntime<D>` is built-but-UNCONSUMED (instantiated only in its own tests; no concrete stateful doc / EditorBuffer in rust). The next step (concrete stateful doc + FFI wiring + the Swift DocumentModel→projection restructure) is the SUPERVISED #202 / TSK-1117 tier (owner-watching only); building an unconsumed rust EditorBuffer speculatively is the roadmap's flagged anti-pattern. So the autonomous host surface stays DRAINED; the whole-core remainder is supervised/owner-gated (1117 supervised, 649 bake-in D1-authorized + needs soak-window number, 538 audit largely done).
- **DELETE-candidates (TSK-1268 orphaned-cores audit) — confirm to delete:** LSPService (superseded by LSPPool/LSPClient) + other dead/superseded orphans. ~30 cores were built+tested but unconsumed; treemap/LSPBinaryTrust/InFileCompletion/ClipboardTableExtractor now WIRED, the rest triaged (wire-now / wire-when-UI / delete).
- **THE BOTTLENECK = the REVIEW pile (~220+ render features awaiting your on-screen close).** All host/model-verified this run; remaining is open-it-and-look. Highlights: vim steady caret (TSK-1259, VM-validated), in-file completion (TSK-1127), clipboard-table→CSV paste (TSK-958, user-visible), **image editor (TSK-1048 + 13 tool tickets — model+ViewModel host-verified, ~166 tests)**, audio editor (TSK-529, 108 tests), split-pane fixes (TSK-921/922), folder treemap (TSK-506), rust highlight (TSK-660). Open each feature, confirm on-screen, close.
- **wave-12 (P1)** awaits P0 drain + your groom (BACKLOG ▸ NEXT WAVE 12).

---

**Earlier owner-gated items (still open) — as of 2026-06-22:**

Five owner-gated items block the highest-value next steps; each is parked with full homework on the board:
- **TSK-1215 — formula on-screen.** View-wiring (a) now BUILT @ 32388631 (gated, zero-risk: CSVTableView shows computed formula values when `MDV_RUST_FORMULA` on + file order; off → raw, unchanged). Remaining is just YOUR call: (b) flip `MDV_RUST_FORMULA` ON after a soak (lights up engine + display together) → VM/owner on-screen confirm → (c) delete the Swift twin. THE unlock for the whole formula investment; the agent build is done. **FLIP IS NOW PARITY-CLEAN — all 5 differential-fuzz-found Rust port blockers FIXED + validated:** TSK-1218 (whitespace-only cell → Blank, should be text " "), TSK-1219 (inf/nan textual forms wrongly parsed as numbers), TSK-1220 (the `&` concat operator was missing entirely → parse error), TSK-1221 (numbers formatted at 16 digits vs Swift's `%.10g` 10 sig digits), TSK-1222 (TRUE/FALSE boolean literals → #NAME?, breaking VLOOKUP(...,FALSE) and every bare TRUE/FALSE). Each fixed in `rust-core/.../formula.rs`, host-tested, and guarded by the differential fuzz (Swift==Rust, zero divergences). The fuzz now spans EVERY core eval path — arithmetic/aggregate/text/date/coercion/number-format/concat/comparison/criteria/recalc/logical/lookup — so the migration-target engine matches Swift+Excel comprehensively. The flip soak should pass parity; remaining is the owner's soak + on-screen confirm + Swift-twin deletion.
- **TSK-1202 — folds on the rust core.** The folds port is FUNCTIONALLY COMPLETE behind the `.fold` gate (ships OFF; zero-risk). Rust fold engine for all 6 languages (json/js/ts/xml/swift/markdown) + FFI envelope (id 15) + Swift `RustFoldAdapter` + `refreshEditorFolds` routed through the gate (OFF = the incumbent cached `computeFolds`, unchanged; ON = rust, fail-safe). PARITY-PROVEN: 6-language A/B vs the Swift `computeFolds` — 5 strict-clean, swift direct (the Swift engine returns `[]` for swift in the host test — its lazy grammar dylib — a fragility the rust port's STATIC grammar fixes). Same ceiling as the formula flip: remaining is YOUR call — flip `MDV_RUST_FOLD` ON after a soak → VM-confirm the gutter folds render on-screen → THEN delete the Swift `TreeSitterEngine` + SwiftTreeSitter + 6 grammar packages (~3.4 MB reclaim, toward TSK-1214) + drop the test-only `StructuralSearchEngine`. The deletion can't precede the VM render-confirm (the Swift path is the gate-OFF fallback). Slices @ 5c145d40/126d69aa/6916b759/e1f551db/2f17de88/3b532faf/20910ff5/42a09e65.
- **TSK-775 — migration horizon.** Engines-only (recommended; ~done) vs whole-core (larger, later). Roadmap: `docs/RUST_MIGRATION_ROADMAP_2026-06-21.md`.
- **TSK-1214 — bundle cap target.** Exec ~60MB at cap (caps are 80 MB total / 60 MB exec per `scripts/check-bundle-size.sh`). **TSK-1098 (doc-drift) RESOLVED 2026-06-22** — CLAUDE.md + `docs/MERMAID_IMPL.md` now state the real 80/60 caps (no more stale 25/26/48 policy figures in the active docs; historical log/design figures left as point-in-time record). Remaining owner call is the real BUDGET: grammar lazy-load (meaty, ~30 MB reclaim — TSK-1214 spike) vs accept+keep 80/60. Spike findings on TSK-1214.
- **TSK-788 — test-audit depth.** Recommend STANDARD (sufficient). `docs/TEST_SUITE_AUDIT_2026-06-21.md`.


> **ROTATION (TSK-1548, 2026-07-07):** this file is BUDGETED (64 KB, enforced by
> `ContextBudgetTests`) — a red budget test means ROTATE: move the older LOG entries to
> `archive/AUTONOMOUS_PROGRESS_<range>.md` and keep the DECISIONS section + the most
> recent entries here. History: `archive/AUTONOMOUS_PROGRESS_2026-06-04_to_2026-07-02.md`
> (14.9k lines, the 2026-06 era). Do NOT let this file grow unbounded again.

## 2026-07-02 — M4 COMPLETE: design system + gauntlet, all 9 slices (TSK-1380..1388)
- Components (expansion-at-lowering, cycle-fenced, incremental instance repaints),
  overrides, DSL forms, zero-op retheme, vendored kit w/ drift-blocks-overwrite,
  THE GAUNTLET (10/10, 0% escapes), table/code/chart/diagram kinds (injection-safe,
  deterministic SVG), each-blocks (author-time, zero runtime JS), measured lint
  (overflow/contrast on the real page, merged at canvas_lint w/ a `measured` marker).
- M5-feeding findings on the board tickets: input/form primitives, grid primitive,
  standalone-if + expression data-context, live mermaid shell integration.

## 2026-07-02 — M5 COMPLETE: UI-Design mode Tier 1, all 6 slices (TSK-1389..1394)
- The FIRST MODE, proven as a thin PRESET over the shared core (the thin-mode law held
  end-to-end: zero engine branches on mode, zero new record kinds; a mode is just a token
  + template + presentation presets + export flavors). Slices: mode infra + artboard
  template; artboard chrome (token-colored, responsive check rides the existing measured
  stage); export flavors (fragment inlines token literals, drops the theme); mode-aware
  shell (kit strip over the op path); UAT-M5 (the designer journey, host + real-page
  responsive check); prototype nav (linkTo → scroll-to-artboard).
- New general capabilities banked: #anchor as a prop VALUE (nd:id); token css_var_pairs
  forward map; CanvasComponentIndex. Bars: kit-strip + linkTo-flash PIXELS pinned to
  TSK-1334 (owner Screen-Recording grant); behavior all host/webview-validated.

## 2026-07-02 — M6 COMPLETE: Presentation mode, all 7 slices (TSK-1395..1401) — THE EPIC CHAIN IS DONE
- Deck mode infra + slides; the step model (deck.rs timeline_state, pure+proptest);
  timeline_state FFI + canvas_timeline tool; the JS player (reveal == timeline_state,
  two-consumers law proven); identity-morph (morph_pairs diff + FLIP); offline deck export
  (self-contained, plays with zero network); UAT-M6 the deck journey.
- Thin-mode law HELD across BOTH modes (M5 UI-Design + M6 Presentation): the TIME model rides
  as props (step/morphId) + engine queries, zero new record kinds, zero engine branches on mode.
- Milestone chain M0→M6 all at fixed/validated. Standing bars unchanged: TSK-1334 (owner
  Screen-Recording grant → T5 morph/transition PIXELS), TSK-1365 (VM webview residual), owner
  Q-review. Findings for later: PDF deck export, richer morphs (path/cross-kind), walkthrough
  dogfood (P7).
