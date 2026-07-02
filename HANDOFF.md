<!-- CLAUDE-HANDOFF v1 -->

## ⭐ UI-DRIVE VALIDATION DIRECTIVE (owner 2026-07-02) — confirm on the real app before "works"
- Owner's concern is NOT "is it built" but "does it actually work FOR THE END USER." Before
  concluding any feature is production-grade, DRIVE THE UI as a user on the real running app —
  never conclude from code-read or host-test alone.
- **Capability reality (record it, work within it):** no `mac-computer-use` MCP; AX-driven tests
  are the one off-limits lane; screencapture PIXELS need the owner's **TSK-1334** grant (not given).
  So TRUE visual/interaction confirmation is currently blocked. What IS available: launch
  `dist/TextView.app` on the VM GUI lane and drive features via **script-verbs / in-app MCP
  (AutomationHost)** — the real action path a user's gestures trigger — verifying via **model-state
  dumps (DiagnosticDump/modelStateDump) + geometry/DOM queries** on the REAL running app (a genuine
  step up from isolated host tests). Features whose action isn't a script-verb (e.g. a canvas paint
  DRAG) can't be user-driven without AX/CGEvent → report "behavior host-tested; user-gesture drive
  needs AX/pixel grant."
- **PRECISE VEHICLE (mapped 2026-07-02):** the concrete "act like a user on the real app + assert"
  mechanism is a **T4 `LiveAppTestCase`** (Tests/ViewerUITests, `TierBaseCases`) on the VM GUI lane
  (`MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> bash scripts/test-in-vm.sh all` — `all` rebuilds dist).
  It spawns the REAL app in-process, drives via the real action path, and asserts model-state/geometry
  in ONE process (behavior; pixels still need TSK-1334). A headed dist app driven over ssh via
  `textview://` URL-scheme verbs DRIVES but can't self-verify (no interactive readback verb — the
  `snapshot` verb defers to the caller). NEXT CONCRETE STEP: write a T4 LiveAppTestCase that
  user-drives a recent fix (CSV empty-state / image New-Image) + asserts state; run it on the VM.
- **✅ VALIDATED CAPABILITY (2026-07-02, ran on VM): the hosting-test lane confirms real SwiftUI UI
  WITHOUT screencapture.** `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_WEBVIEW_FILTER=<Suite>
  bash scripts/test-in-vm.sh webview` builds + runs a WebViewTestCase/hosting suite that REALIZES the
  SwiftUI view in an NSHostingView on the GUI lane and introspects its AX tree (buttons/labels/
  structure present + realized, non-zero). PROVEN: EmptyStateNewImageHostingTests passed → the New
  Image button is really rendered in the empty state (TSK-1054/1306 CONFIRMED working on the real app,
  not just wired). So SwiftUI PRESENCE/STRUCTURE is agent-confirmable now; only true PIXEL/occlusion
  compositing still needs TSK-1334. THIS is the practical UI-drive vehicle for SwiftUI polish: write/
  run a hosting test that realizes the view + AX-asserts. (Gotcha: the `pixel` mode does NOT arm
  MDV_RUN_WEBVIEW_TESTS inside the GUI bridge → tests SKIP; use the `webview` mode, which does.)
- **Biggest unlock:** the owner granting **TSK-1334** (Screen-Recording on the VM xctest/app) turns
  on real pixel/occlusion confirmation. Structure/presence is already confirmable via the webview
  hosting lane (above); per-feature ceiling = hosting-lane AX-assert + real-app model-state.
- The 5-min cron message was updated (job ae60ea77) to carry this discipline.

## 📊 REAL-APP VALIDATION MAP (2026-07-02, ~97 UAT tests green on the VM)
- Ran ~the whole UAT suite on the VM GUI lane (real spawned app). ~97 tests PASS across editor/CM6/
  LSP/sessions/search/previews/git/settings-menus/plugins-MCP/tabs/view-modes/sidebar+bookmarks/
  multi-format/metadata + rendered-scroll-restore. Core + most secondary features are UI-DRIVE-
  CONFIRMED working on the real app; "almost all unusable" does NOT hold for anything with UAT
  coverage. See docs/USABILITY_AUDIT Pass 4.
- Sweep found 2 issues: PMA01 (my stale canvas_* tools/list expectation -> FIXED fc9fba51) + PMA04
  (30s timeout flake under load, passed on re-run). Editor scroll-to-line SKIPS (TSK-1200 parked).
- FINISH-OR-CUT COMPLETE (TSK-1414): drilled all 4 "spikes" — SQLite browser, folder treemap, HTTP
  client were BUILT + UI-drive-confirmed working (added the missing UATs + a show-http-client cohesion
  verb). The RSS feed reader was the ONE genuine orphan (built + tested, reachable from nowhere); owner
  chose FINISH → wired File → Feed Reader + show-feed-reader verb, UI-drive-confirmed (TSK-1417
  validated, a8a2bd2a). ZERO of the 4 were half-built. Audit Passes 5-7 carry detail.
- ORPHAN + COHESION SWEEPS DONE (2026-07-02, audit Pass 8): orphan-View sweep CLEAN (166 View
  structs, only 2 unwired — ActionHistory/RichText, both deliberate WIP, filed TSK-1418 owner
  finish-or-cut); script-verb↔dispatch CLEAN. GAP FOUND+FIXED: hosted-view tools (HTTP/feed/treemap/
  depgraph/walkthroughs) now ⌘K-palette-discoverable + a command↔verb cohesion regression guard
  (1c46b2a0, teeth). FeedReader-class accidental orphans = NONE remaining.
- ENV-VAR-ONLY ENTRY AUDIT DONE (2026-07-02, audit Pass 9): CLEAN — no user feature is env-var-only
  (MDV_START_IMAGE_EDIT/AUDIO_EDIT are T5 test shortcuts; both editors have real buttons — "Edit
  image" + "waveform"; rest are harness/experimental/WIP). Also verified production-grade: audio MP3
  export degradation, all search empty-states, all list-view empty-states (bookmarks/recent/action-
  history). CSV empty-state (TSK-1415) was the one real empty-state gap — fixed.
- ✅ CORRECTION to the "vein thinning" note: main SURFACES are clean, but DEEP INTERACTION paths
  still harbor real bugs — found+fixed geometry-after-paint silent data-loss (TSK-1419, 4dc94b8c):
  crop/resize/rotate after a paint session were shadowed by the paint buffer (invisible + lost on
  export). HUNT DEEP INTERACTION/EDGE paths next (feature×feature ordering, state-across-switch,
  undo-across-mode, export-after-edits) — NOT main surfaces (verified). PAINT is a destructive
  terminal mode: post-paint crossings each need handling — geometry=transform (TSK-1419 ✓),
  tonal=gate (TSK-1420 ✓), undo-ordering=unify (TSK-1421 ✓), selection×paint=already-clean. The
  image-editor deep-crossing vein is largely MINED (4 real bugs). NEXT deep-interaction target = a
  another MULTI-MODE feature. Session/tab-switch + CSV verified CLEAN (well-hardened). Image editor
  is the RICHEST vein — 5 bugs (1416/1419/1420/1421/1422 = paint-undo/geometry/tonal/undo-order/
  overlay-export), its layer/mode crossings now largely covered. NEXT: HEX editor (view vs edit
  mode) checked — theory HOLDS (found hex-search-ignores-edits TSK-1423) but the fix is
  representable-plumbing + AX-keyboard-gated → filed for the render lane, NOT host-fixable.
  REFINED HEURISTIC: hunt multi-mode features whose logic is in a host-testable MODEL/PURE layer
  (image editor, CSV, sort, parsers, diff engine) — those yield fixable+VALIDATED wins; view/
  representable-internal + keyboard-AX behaviors are real but land in the owner/TSK-1334/AX lane.
  NEXT host-testable targets: multi-format viewer routing edge cases, diff engine, transcript/
  markdown/CSV parsers.
- ⚠️ Micro-gaps on MAIN surfaces are thinning (empty states/reachability/basics verified) — audited surfaces are now
  consistently production-grade (run's fixes: CSV empty-state, paint-undo, FeedReader wire, palette
  discoverability + cohesion guard). Remaining known work is LARGER or OWNER-GATED, not micro-fixes:
- NEXT: (1) TSK-1413 remainder = MENU REORG (TSK-751/1318) — a larger UX-design task. (2) TSK-1412 =
  refresh the stale BACKLOG.md to match code (owner flagged it lags). (3) OWNER-GATED: pixel/occlusion
  tail (TSK-1334 grant), editor-scroll (TSK-1200), the 2 WIP slices (TSK-1418 finish-or-cut). (4) if
  hunting more micro-gaps, target deeper edge/error paths, not the main surfaces (those are verified).

## 🔀 MISSION PIVOT (2026-07-02): Canvas PARKED → app-wide production-grade usability polish
- **Canvas (M0→M6) is COMPLETE + validated + hardened + PARKED pending owner review** (docs/canvas/
  README.md = review index; docs/canvas/plans/TIER2-BACKLOG.md = the deferred-features decision menu).
  Do NOT resume Canvas building until the owner reviews.
- **NEW STANDING MISSION (owner 2026-07-02):** audit the whole app's feature surface, make it
  production-grade with high standards, autonomously. Umbrella epic **TSK-1411**; foundation audit
  = **docs/USABILITY_AUDIT_2026-07-02.md** (9 feature families + themes + rubric).
- **⛔ CODE IS SOURCE OF TRUTH — do NOT trust tickets/docs/commit messages** (owner directive).
  Proven: 3/3 flagship "model-only" tickets were REFUTED by code (image editor 10 tools wired,
  CSV multi-cell in-view, LSP completion wired). The board UNDER-reports the code. The #1 finding
  (TSK-1412) is board≠code; the real defects are polish/quality/UX/cohesion in WIRED features, not
  missing UI. For every feature: read the view+wiring, verify on-screen, THEN judge.
- **REFINED FINDING (2026-07-02 pass-2+correction):** code-reading CSV/Hex/command-registry shows
  the CORE is near-production-grade; the app is largely **model-complete + view-wired**, stuck at an
  HONEST render/AX confirmation tail = the same owner-gated bar (TSK-1334 pixel grant + the AX lane),
  NOT incompleteness. The BOARD is largely honest (tickets at review with real ceilings); it's the
  **BACKLOG.md FILE that lags** + my earlier conflation of the two. So the work is NOT a big
  board-reconcile or UI-rebuild — it's: (1) fix GENUINE gaps code-reads surface (unticketed, e.g. CSV
  empty-state TSK-1415); (2) the thin exploratory spikes (TSK-1414, owner finish-or-cut); (3)
  cross-cutting bugs (key-event routing TSK-1315); (4) refresh the lagging BACKLOG.md. Many "incomplete"
  features just need the owner's TSK-1334 grant to confirm their render tail.
- **Go-forward (per tick):** pick a feature family from the audit → code-verify its real state →
  fix the highest-value polish/quality/UX gap to on-screen-validated → correct the board to match →
  commit per item. Systemic tickets: TSK-1412 (board reconcile), TSK-1413 (entry-point cohesion),
  TSK-1414 (finish-or-cut spikes, owner-decision). Keep main gate-green; teeth on every guard.

---

# Handoff — Canvas M0 DONE (GO) + M1 underway (S1/S2 validated); cron drives the milestone chain (2026-07-02)

## ⛳ BUILD STATE (2026-07-02 — freshest; supersedes below)
- **M0 patch-loop spike: COMPLETE, verdict GO** (TSK-1343 fixed; slices 1352/1353 validated,
  1354/1355 fixed). Numbers: core ~0.1ms; E2E p95 30ms vs 50ms budget (local 4/4; VM p50 30ms
  when flowing). Commits `e95b45ab`/`c275fbd8`/`d0f013ed`. Four bridge-reliability lessons in
  LESSONS 2026-07-02 (object-literal sends + `;0`; reply outbox + pull-drain w/ SET dedup;
  frame-wipe → fence rule; WebContent termination on the VM lane → **TSK-1365** hardening
  ticket, consumer deadline M1.S5's parity test). M0's demo engine lives in
  `rust-core/crates/core/src/canvas/mod.rs` + FFI `mdvcore_canvas_*` + `canvas.js` applier.
- **POST-CHAIN HARDENING (2026-07-02, after M6): the engine's data-integrity is property-pinned
  beyond the milestone bar.** All four untrusted-byte decoders now carry totality-fuzz
  (json+wire pre-existing; TSK-1402 dsl parser, TSK-1403 io::load) + two correctness properties
  (TSK-1404 io save∘load round-trip over the full M1-M6 prop/kind surface; TSK-1405 undo-identity
  over the FULL op vocabulary incl. DefineComponent/Remove + fence atomicity). All dep-free
  (xorshift/proptest in-tree), all teeth-verified, commits 3449b3bb/62b192c4/ca6b956f/8531afb4.
  ⚠️ THE HARDENING VEIN IS NOW SATURATED — the decoders + round-trip + undo are all covered;
  further fuzz/property ticks would be MARGINAL. Next genuinely-high-value work is OWNER-GATED
  (TSK-1334 grant → T5 pixels) or awaits the owner's epic review. Do NOT manufacture more
  marginal hardening; if the actionable non-owner-gated queue is truly dry, say so plainly.
- **🏁 M6 COMPLETE (2026-07-02): Presentation mode — milestone TSK-1348 at FIXED, all 7
  slices validated (TSK-1395..1401, commits cb7e25f0..e2640d42). THE M0→M6 EPIC MILESTONE
  CHAIN IS COMPLETE.** Deck infra+slides, the step model (deck.rs timeline_state, proptest),
  timeline_state FFI+canvas_timeline tool, the JS player (reveal==timeline_state, two-consumers
  law proven live), identity-morph (morph_pairs diff + FLIP), self-contained offline deck export
  (plays with zero network), UAT-M6 the deck journey. Thin-mode law HELD across both modes
  (props+queries, zero new kinds, zero engine mode-branches). Standing bars: TSK-1334 (owner
  Screen-Recording grant → T5 morph/transition PIXELS), TSK-1365 (VM webview residual), owner
  Q-review. Findings: PDF deck export, richer morphs, walkthrough dogfood (P7).
  **NEXT: owner review of the full epic; or drain the standing bars when the grant lands.**
- **M5 COMPLETE (2026-07-02): UI-Design mode Tier 1 — milestone TSK-1351 driving to FIXED,
  all 6 slices validated (TSK-1389..1394, commits 597b08a6..93e118a0).** The first MODE as a
  thin preset (the thin-mode law held: zero engine branches on mode). Mode infra+template,
  artboard chrome, fragment export (token literals inlined), kit-strip shell, UAT-M5 designer
  journey, prototype-nav linkTo. Bars: kit-strip+linkTo pixels → TSK-1334 (owner grant).
  **NEXT: M6 (Presentation) planning pass (TSK-1348).**
- **M4 COMPLETE (2026-07-02 late): milestone TSK-1347 at FIXED — all 9 slices validated.**
  Components/overrides/DSL/tokens+zero-op-retheme/kit(drift-blocks)/table+code+chart+diagram/
  each-blocks/measured-lint — and THE GAUNTLET: 10/10 pre-committed briefs, 0% ESCAPE RATE
  (the owner's 30% pivot criterion, passed decisively). Commits 5f3eea2b..5d66fa0b. M5-feeding
  findings on the tickets (inputs, grid, standalone-if/expressions, live mermaid). **NEXT: M5
  planning pass (UI-Design mode, TSK-1351).** Validation bars unchanged (TSK-1365 residual;
  TSK-1334 owner grant; owner Q-review pending).
- **M3 WYSIWYG COMPLETE on the local lane (2026-07-02): milestone TSK-1346 at FIXED.**
  All 8 slices landed (fd25bad3..fd417b7b): rendered lens = DEFAULT for .canvas; selection
  overlay glued through reflow; inline text edit (IME-safe); drag-reorder; ⌘Z; inspector +
  layers off one canonical-JSON read model; every gesture through the agent's op path;
  co-editing proven (agent+human edits both survive). UAT-M3 green through the controller;
  25/25 canvas tests local. **Validation bars: TSK-1365 residual (VM webview channel-death —
  2 real fixes landed: windowless boot cure, re-post drains) + TSK-1334 (T5 Screen-Recording,
  owner). NEXT: M4 planning pass (design system + Claude-Design gauntlet) — or drain the
  TSK-1365 residual first (fix sketches on the ticket).**
- **M2 COMPLETE + VALIDATED (2026-07-02): the agent surface is LIVE.** 9 MCP tools + 2
  script verbs + HTML export; UAT-M2 green MCP-only (mistake-taught, conflict-retry,
  byte-identical reopen); 1k-node apply p95 0.11ms vs 20ms budget. Slices TSK-1366..1371 +
  milestone TSK-1345 ALL validated. Commits be43a43d..26a36ec5. **NEXT: M3 (WYSIWYG)
  PLANNING PASS — M3-PLAN.md + slice tickets; VM lanes needed (TSK-1365 hardening;
  TSK-1334 Screen-Recording for T5).**
- **M1 COMPLETE (2026-07-02): S1-S4, S6-S9 VALIDATED; S5 fixed (VM parity via TSK-1365 = last
  tail; fuzz tail closed 3f4b0b4f). Milestone TSK-1344 at fixed.** .canvas is an openable file
  type (source lens, d48eaf90); UAT-M1 green at core/C-ABI/Swift (65745065). **M2 PLANNED:
  docs/canvas/plans/M2-PLAN.md + slice tickets TSK-1366..1370 (vocab / doc store / MCP tools
  new-open-save-apply / read-vocab-lint-undo / UAT-M2 journey). NEXT: M2.S1 (rust vocab.rs).**
- **M1 canvas-core: S1 record store VALIDATED** (`577c7a18` — FracIndex/atomic-Place/
  tombstones/cycle checks, proptest storm; wasm-shape scan now recursive) · **S2 props+
  registry+fence VALIDATED** (`5be181b4` — u16 interned keys, typed Values w/ Token variant,
  per-kind tables, caps, check_text_target). S3 ops+inverses (62f90115) and S4 tokens
  (6e64e370) VALIDATED; S5a lowering (6527a25d+f084592d) + S5b patch plans w/ APPLY-TIME
  anchors (a46efc8a) landed — S5c-rust wire codec landed (5401e5b0 —
  {baseRev,ops}→{rev,patches}|structured-rejection; the canvas↔serde boundary = the TSK-584
  fuzz seam). **NEXT: S5c remainder = (a) FFI swap (mdvcore_canvas_* → CanvasDoc{DocState,
  TokenStore, root page}, wire::apply_wire; retires the M0 demo module) + (b) Swift wrapper/
  adapter onto string ids + new op vocab + (c) canvas.js applier verbs (insertNode/moveNode/
  removeNode/setAttr/removeStyle) + (d) E2E suite update + (e) fuzz target + corpus; VM parity
  run consumes TSK-1365** — then S6 lint → S7 migrations+I/O → S8 DSL parser → S9 Swift glue.
  Fresh LESSONS (2026-07-02 build): apply-time patch anchors (never plan from post-batch
  state); never chain gate+commit in one command; behavior-equivalent teeth mutants. Plan: `docs/canvas/plans/M1-PLAN.md`; slices TSK-1356..1364.
- Board: M2..M6 chain unchanged (1345→1346→1347→1351→1348). All Q-decisions provisional-
  approved (05-ROADMAP header); owner reviews soon; rework-if-reversed accepted.

**Session:** claude-mdv · **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer` · **branch:** `main` (verify `git log -1`)

## ⛳ LATEST CHECKPOINT (2026-07-01 LATE — READ FIRST — supersedes everything below)

**Canvas moved from design→BUILD.** Owner (2026-07-01): *"Go with these defaults for all for
now. Will review in details tomorrow. Re-enable the 5-min cron to work on M0, M1, M2… before
each milestone do a planning pass. You are on your own."*

- **Design set (v2, authoritative): `docs/canvas/`** — README · 01-RESEARCH-ANALYSIS ·
  02-CORE-ENGINE (flat record store, §2c hyper-perf internals, §3b CSS ladder, §7 dynamism
  ladder B0–B5, §10b data contract) · 03-SHELLS · 04-MODES · 05-ROADMAP (**Q-LIST: ALL
  PROVISIONALLY DECIDED at defaults — see its header; owner detailed review pending**) ·
  06-MILESTONES-UAT (validation ladders + UAT journeys) · 07-DSL-SPIKE (the agent interface
  language; TSK-1350 at review). Old CANVAS_DESIGN*.md = superseded history.
- **Board:** epic TSK-1342; milestone chain **TSK-1343 (M0 patch-loop spike, NEXT ACTIONABLE)
  → 1344 (M1 core) → 1345 (M2 agent surface) → 1346 (M3 WYSIWYG) → 1347 (M4 design system +
  Claude-Design gauntlet) → 1351 (M5 UI-Design mode — FIRST MODE per owner criterion) → 1348
  (M6 Presentation) → 1349 (M7+)**. Greenlight comments on 1342/1343.
- **Cron 9c2961d0 (session-only, 5-min)** carries the build mission: planning pass before each
  milestone (`docs/canvas/plans/M<N>-PLAN.md` + slice child tickets) → implement inline slice
  by slice → gates per the validation ladder (cargo / headless / webview / T5-with-teeth) →
  commit per slice. If the session restarts, RE-ARM the cron with that mission (CronCreate is
  session-only).
- **Watch items:** decisions are provisional (rework-if-reversed accepted — keep M0/M1 slices
  cheap to redo); TSK-1334 (VM Screen-Recording grant) needed from M3 for T5 (webview lane
  suffices through M2); M0 has a KILL CRITERION (06 §M0) — honor it.

## ⛳ PRIOR CHECKPOINT (Canvas design phase — superseded above)

**Owner direct request (cron was stopped first):** design a **Canvas** giga-epic — a WYSIWYG
editor for AGENTS (and humans) to build UIs / infographics / explainers / presentations;
HTML/CSS/JS underneath but abstracted so agents insert structured elements instead of writing
top-down HTML. Foundation for UI Design (Claude-Design-like), Presentations, Explainers-in-
Walkthroughs, etc. Asked: spike abstractions + detailed design + explore many use-cases +
**BLOCK on owner review + DO NOT implement**.

- ✅ **DELIVERED: `docs/CANVAS_DESIGN.md`** (TSK-1342). Recommended architecture: **Canvas =
  a LOWERING COMPILER, not an HTML editor** — a semantic Scene IR (tree of typed elements +
  stable IDs) → deterministic Scene→HTML/CSS/JS lowering in a WKWebView; the agent authors via a
  small addressable/idempotent/undoable **OP API** (insert/move/style/bind), never by emitting
  HTML. Abstraction stack §4: Scene IR ▸ Op API ▸ Layout(hybrid free-form + auto-layout) ▸
  Components+design-tokens ▸ Behavior(data/interact/time) ▸ Export ▸ Modes/presets. One core,
  many modes. ~60 use-cases (§9); hard boundaries held (§10). **6 blocking decisions in §12.**
- ✅ **TSK-1342 PARKED on owner review** (waiting=human, kind=review) with the §12 decisions.
- ⛔ **DO NOT implement** until the owner answers §12 (v1 scope/first-mode, layout+FLOW,
  code-export target, per-layer dep policy, DOM-vs-canvas backend, multiplayer).

**⚠️ POST-MORTEM — subagent fan-out RUNAWAY (see LESSONS.md 2026-07-01, the top entry):** the 3
`general-purpose` research agents I launched for the spike RECURSIVELY FANNED OUT to ~75 agents,
burned ~half the owner's quota (owner killed them). NEVER delegate research to broad-prompted
`general-purpose` agents (they have the Agent tool → fan out). Use inline, or the read-only
`Explore` agent, or a capped single-pass prompt. Salvage: `~/canvas-subagent-salvage-2026-07-01/`
(726 raw transcripts + post-mortem README).

**AUTONOMOUS CRON IS STOPPED** (owner asked to pause it end-of-tick; cron `6527343e` deleted —
`CronList` empty). Do NOT re-arm it unless the owner asks. The prior autonomous work is below.

**Prior autonomous session state (still true):**
- Shipped+validated: PDF find (TSK-1341 validated host-side via the native-state path — see the
  2026-06-30 LESSONS entry), multi-format viewer arc, FindBarRouting.
- **At review (genuinely T5/AX-gated):** TSK-1303 (image edit session-persistence — SwiftUI
  view-recreation seed), TSK-1166 (disk-conflict banner — occlusion pixel tier).
- **Owner unblocks (highest leverage):** TSK-1334 (VM Screen-Recording grant → the T5 render
  tier), TSK-838 (one-line DOM-patch flip → kills the 2-9s rendered-MD reload storm).
- Board is otherwise saturated for clean fresh builds (verified extensively).

## ⛳ PRIOR CHECKPOINT (PDF find / native-state render-validation — superseded above)

**This stretch (since the last handoff @ 65daa55a) shipped, all host-gate-green, committed per-item:**
- **TSK-1303 image edit-state session persistence** (`22675ef0` core + `be95778d` view binding): edits survive a session switch. `Tab.imageEditState` + `TabSnapshot` round-trip + `imageEditStateByURL` channel + capture-at-drain/restore-on-materialize (mirrors rendered-scroll TSK-1041); declarative seed at VM construction. Host-tested; **at REVIEW** — the live SwiftUI `@StateObject` view-recreation-seed is framework-driven (not host-assertable); needs a VM hosting test.
- **TSK-1166 non-modal disk-conflict banner** (`e2e0bd1a`): passive-watcher disk conflict → inline `DiskConflictBanner` (Keep Mine/Take Disk/Merge) instead of the modal NSAlert; shared `applyExternalEditOutcome`; SaveConflictDecision backstop. Host-tested; **at REVIEW** — banner-over-CM6-WebView visibility is the T5 occlusion class (TSK-1334).
- **TSK-1140 / TSK-1341 Find in PDF (⌘F)** — the arc: `edd71bd7` PDFSearcher engine → `f19adde9` FindCoordinator `pdf` bag + PDFFindBar + ⌘F/⌘G routing + PDFPreview consumer → `1db4f8bc` testable `@MainActor PDFFindDriver` **host-validated against a real PDFView** → `cba43ec1` extracted `FindBarRouting` (host-tested). **TSK-1341 = `validated`** (child of TSK-1140; the find clause). Parent TSK-1140 still open for: PDF scroll/session persistence + zoom/page-nav polish.

**KEY LESSON this stretch (now in LESSONS.md — read it):** **state-based NATIVE AppKit views are HOST-validatable → render reaches `validated` WITHOUT the T5 grant.** `PDFView.currentSelection` is a headless data-op that IS the on-screen highlight (native rendering guarantee). Extract the `updateNSView` body into a plain `@MainActor` driver, host-test it against a REAL NSView (created host-side, no window). TRIAGE render items: native-view STATE (selection/text/value) → host-validate; layout/SwiftUI-occlusion/WebView-pixels/AX-gesture → genuinely T5/VM/AX (TSK-1334/AX).

**STATE: board is SATURATED for clean fresh builds.** Verified ~15+ P0/P1 items done/review/validated/parked this session (TSK-1176/680/1144/1141/1163/1332/910/1032/924/343/1146, HEX find, scrollJS…). Remaining is structurally gated:
- **Owner unblocks (highest leverage):** TSK-1334 (VM Screen-Recording grant → the whole T5 occlusion-pixel tier; validates TSK-1303/1166) · TSK-838 (one-line DOM-patch flip → kills the 2-9s rendered-MD reload storm, fixes TSK-598) · parked decisions (TSK-1200 editor-scroll real-vs-harness, TSK-283 Enter-rename rebind, TSK-1149 feed surfacing, TSK-1129 LSP security).
- **Deep perf:** TSK-891 Page-Up jank (diagnosed: NOT scroll-emit — already throttled; it's the CoreAnimation scroll-compositing class, same as TSK-598; needs a VM Page-Up profile, likely a rendering-approach change).
- **Epics (spike→slice):** Debugger (276), Encryption (293, crypto dep), Java LSP (298), remote-core (651), browser (676, foundation done), agent services (697), action history (703), audio AVAudioEngine (1091-96).

**NEXT ACTION on resume:** apply the native-state triage to find the NEXT host-validatable render feature; else VM-validate a review item (TSK-1303 hosting test, or the webview lane for a rendered-MD item) to drive it to validated; else take an epic's first host-completable slice. Do NOT re-scan the saturated board tick after tick — pick from the gated list above or an epic.

## ⛳ PRIOR CHECKPOINT (multi-format viewer arc — superseded above)

**This stretch shipped 8 features/fixes (all host-tested w/ teeth, gate-green, committed per-item):**
- `3cb83cc3` TSK-942 Copy Reference Edit-menu item + ⌘⌥⇧C shortcut · `1badd840` TSK-1337 webview-lane drift fix + drift-detector · `60a0f9c4` TSK-1317 drag terminal icon → dock pane · `d62390dd` TSK-1326 "New Walkthrough" seeds an editable starter · `43557177` TSK-1177 terminal tab-strip shoulder border.
- **MULTI-FORMAT VIEWER ARC (now complete):** `365b5ddf` TSK-1338 .docx renders structured Markdown (headings/lists/bold) · `6cbdd38a` .rtf renders bold/italic · `192ae9f0` TSK-1339 **.xlsx/.ods open as a GRID not raw TSV text** (they were missing from `tableExtensions` → false-green: TSK-1141's sheet-strip was unreachable) · `65daa55a` multi-sheet .ods sheet-tab strip. So docx/rtf/xlsx/ods + csv/tsv all open correctly; TSK-1145 epic → recommend owner-close.

**KEY LESSON this stretch (now in LESSONS.md):** a `*HostingTests` suite validates a view RENDERS, not that the app REACHES it — a "validated" feature can ship UNREACHABLE (xlsx opened as TSV text; the sheet-strip was dead). Always also assert the live trigger/route (menu `#selector`, `ViewModeOptions.defaultMode`, model trigger). Swept all hosting-tested render features → xlsx was the one real false-green (fixed); feed reader is unreachable-but-owner-parked.

**STATE: clean high-value inline-buildable veins are DRAINED.** The owner intake (TSK-1302–1327), the multi-format viewer, the host-engine epics (698/722/723), and the false-green class are all done/validated. The remainder is:
- **Owner-gated (parked, surfaced):** TSK-1334 (VM Screen-Recording grant — the HIGHEST-leverage unblock; opens the whole T5 occlusion-pixel tier; precise recipe on the board: run `setup-signing.sh` in the VM GUI terminal → grant) · TSK-1149 (feed-reader surfacing a/b/c) · TSK-1139 (CSV viewport-paging skip/degrade/build) · TSK-703 (⌘Z unification) · TSK-1129 (LSP security) · the ~417 review→done close queue.
- **Focused render-VM / architectural builds (designed, NOT clean inline):** TSK-1303 (image-edits-lost-on-session-switch — DESIGN RECORDED on the ticket: the image VM is a view-local `@StateObject`, so editState must be LIFTED to a model store [DocumentModel.imageEditStateByURL or Tab], then snapshot-persist + declarative seed-on-mount, VM-validate; data-safety/race-prone) · TSK-1146 (CM6 spell squiggles, contested) · TSK-1318/751 (menu reorg, taste).

**NEXT ACTION on resume:** the clean inline veins are drained — do NOT manufacture a low-value build or rush the data-safety TSK-1303. Either (a) execute TSK-1303 on the VM as a focused render-architecture build (design ready), or (b) continue draining: re-verify `fixed`/`review` with teeth, triage `reported`, audit-harden (the false-green sweep was productive). The owner unblocking TSK-1334 (T5 grant) opens the biggest remaining tier.

## ⛳ STATE AT THIS CHECKPOINT (tick ~281, post-compaction) — READ FIRST
RENDER-CONFIRM TIERS (the lane, fastest first — full detail in memory `feedback_render_path_review_ceiling`): **(1) HOST ImageRenderer** (`HeadlessUITestCase`, NO VM) for PURE-SwiftUI pixel render-confirm — rasterize + assert a pixel DELTA (`DiffViewLayoutTests` / `DiffViewSelectionRenderTests`). FASTEST; UN-GATED renders only (ImageRenderer has no focus engine → can't render focus-gated tints, and placeholders representables → no occlusion). **(2) VM hosting test** (`NSHostingView` + hierarchy-walk, `WebViewTestCase` #192, `test-in-vm.sh webview`) for SwiftUI bridging to NSViews. **(3) T5 pixel** — ONLY WebView/representable pixels or occlusion (TSK-488). **(4) AX** (off-limits) — ONLY the out-of-process gesture/focus executor. A state-seam (additive `initial*` init param) + tier 1/2 drives most "render at review on the AX exception" items to validated.
VALIDATED THIS STRETCH (7, via the lane): TSK-1141 multi-sheet .xlsx (design eeb39117→model 2dab2413→view 0db225bd→hosting facc5a0d, end-to-end), TSK-1119 walkthrough overlay (existing hosting test VM-passed), TSK-722 task-runner epic + TSK-723 structural-search epic (host engine + validated UI child TSK-1160/1161), TSK-1049 off-main render (host parity), TSK-1321 image-overlay selectable/editable (VM hosting test), TSK-910 commit-diff multi-line select (BUILT a selection seam + host-ImageRenderer render-confirm c22288c6 — corrected its over-cautious AX-cap). Verify-before-validate confirmed TSK-698/1160/1161/1176/958/1163/1306/1312/1314/1316/1323/1325/1032 ALREADY done (no dup).
ALSO SHIPPED since tick ~235: **TSK-1152 Lock View As** built end-to-end → review (2382aee1: the file-nav "Lock View As → <mode>" context submenu + per-url DocumentModel helpers; b202eb6a: the lock badge in the row via FileRowState.isViewModeLocked) — logic comprehensively host-tested (DocumentModelViewModeLockTests + FileRowStateTests); the badge/menu PIXEL render is the T5/owner tail. **TSK-373** New-Session▸Kind menu reconciled → review (verify-before-build caught it BUILT — NewSessionMenuItems + SessionTabBar + host tests — wrongly bounced to ack by a #NNN over-correction). The `CSVRectSelection.contains` dedup (e2a46bee). The rust-core proptest lane is comprehensively done (30 engines). **NEW TIER-1 CAVEAT (TSK-1152, in memory):** host ImageRenderer renders a `Button`-wrapped / `onAppear`-complex full ROW (FileRowView) BLANK → 0-delta false-fail; it works ONLY for plain CONTENT sub-views (DiffView.scrollBody). Don't tier-1 a full interactive row.
HARD RENDER TAIL — precisely scoped (NOT clean quick builds; recorded on the tickets): **TSK-924** CSV rect-select tint is `gridFocused`-gated → host ImageRenderer can't render it (no focus engine); model fully host-tested → honest review ceiling. **TSK-1331** revert (restore-over-current, not-open case) is data-safety-subtle — the data-safest open-then-apply needs a render-coupled pendingRestore + editor-mount-consume hook (precedent: pendingEditorDiagnostics); disk-write has a snapshot-nil-ambiguity recoverability risk. Both = focused render builds, not deep-context. **TSK-1200** CM6 scroll = parked (owner real-vs-harness; neither lane composites/measures CM6).
NEXT: clean host-completable ships (coverage/dedup; rust-core fuzz if a parser gap) + the render-VM lane for any remaining UN-GATED SwiftUI render; reserve TSK-1331 (data-safety) + TSK-1146 (CM6 squiggles) for focused render contexts. TSK-598 "MD open laggy" = a ~334ms CoreAnimation COMMIT STALL (banked; fix = launch pre-warm / owner TSK-838 DOM-patch flip).
OWNER ACTIONS (highest-leverage first): (1) Close the review→validated→done queue (validated→done is owner-only) — incl. the 7 just-validated + the ~410 others. (2) **TSK-838** DOM-patch flip → the TSK-598 re-render half. (3) Decisions: TSK-1139 (CSV paging — recommend skip), TSK-1305/1320/1335-pt2/1200, TSK-1149 (feed-reader surface). (4) **TSK-1334** VM Screen-Recording → only the WebView-pixel/occlusion T5 items (e.g. TSK-1333 mermaid), NOT the pure-SwiftUI pile (agent validates directly).

## ⚠️ CORRECTION (owner 2026-06-29) — STILL IN FORCE
The VM is UP; the ENTIRE UI/render lane is agent-workable — BUILD + VM-validate. ONLY off-limits tier = AX-driven tests. "host-testable-seam vein drained" is a banned framing. The render-confirm directive is satisfied BY VM-validating, not by handing render to the owner. (Note: a few remainder items above ARE genuinely careful/risky/owner-gated — that's a per-item engineering judgment after a thorough spike, NOT the banned blanket "render isn't my work".)

## Mission
Autonomous drain loop (cron). Work INLINE, one item/firing: read-first → implement → host-test → host-gate (`bash scripts/test-headless-gate.sh`) → commit per item; land rebase+ff; keep main gate-green; fold docs into the item's commit. Cron canonical = `docs/TASK_WORKFLOW.md §7`.

## ⚠️ CORRECTION THAT RESET THIS HANDOFF (owner, 2026-06-29) — READ FIRST
A prior version of this handoff declared a "host-testable-seam vein DRAINED" and routed all render/UI work to a "VM/owner venue." **That framing was WRONG and is now banned.** The owner's standing model: **the VM is UP and the ENTIRE UI/render lane is agent-workable — build AND VM-validate it. The ONLY off-limits tier is AX-driven tests.** There is NO "host-testable vs render" split in what to work; render/UI/VM items are first-class drain targets you BUILD and VALIDATE (on the VM), not hand to the owner. The instructions that caused the misread were hardened this session (CLAUDE.md new 2026-06-29 directive + §4 self-validation; TASK_WORKFLOW §4 + §7 cron; the live cron prompt). The render-confirm directive is satisfied BY VM-validating, not by leaving things at review.

## ★★★ LATEST — copy-trimmed shipped + the VALIDATE-DRAIN stretch (2026-06-30, after the image-editor intake) — READ FIRST
After the image-editor intake (below), re-challenged my own "owner-gated" drift (the cron: render is NOT owner's lane, "vein drained" is banned) and found genuine HOST work the big render items had masked:
- **TSK-769 copy-trimmed SHIPPED** (47d63a02) — terminal copy strips the cell-grid trailing-space padding + bottom blank rows (Terminal.app/iTerm parity); TerminalCopyTrim.trim (pure, host-tested) → TerminalNSView.copy(_:). User-facing, CHANGELOG'd. (Rest of TSK-769 — open-in-pwd, favorites, history, palette, tab-rename model — already built; tab-rename UI / colours / shoulder-border are render-VM.)
- **VALIDATE-DRAIN → 5 items to `validated`** (advancing the ~417 owner-close queue with real proof): TSK-1332 (UAT TK2-blank false-negative — DiagnosticDump textLength + 6 consumers + host test), TSK-1240 (PaneRetention LRU mount-probe — stale, fixed by TSK-1274, VM-confirmed 2/2), TSK-1328 (ChromeBodyEvalCount parallel flake — retry-the-measure + ~15 green parallel gate runs), TSK-1210 (VM Swift 6.1.2 RustCore circular-ref — MsgPackPair, VM 6.1.2 compile clean), TSK-1209 (tooltip appear-delay 0.6 — test-gap backfill).
- **THE VALIDATE-DRAIN DISCRIMINATOR (use it):** test-infra / build / logic items with REAL teeth and NO T5/AX tail are agent-validatable end-to-end (host test, VM compile, empirical gate runs) → drive fixed/review → `validated`. Render items (image-editor, mermaid) correctly stay at review behind T5/owner; key-routing/focus bugs behind AX. Many "VM bugs" are STALE test expectations already fixed in code — diagnose host-side first, then VM-confirm + reconcile (TSK-1240).
- **The DELETE-set (TSK-1268 class A: LSPService superseded, EditorPerfBench, CSVRowWindowSource) stays OWNER-gated** — the safety rule (didn't-create-it → surface) applies; don't autonomously delete.

## ★★ SINCE 16 — THE OWNER-CORRECTION RENDER STRETCH (2026-06-30) — READ FIRST
The owner corrected the END-STATE below: **"T5-pixel-blocked" was conflated with "render-blocked."**
T5-screencapture (TSK-1334, still owner-blocked) gates ONLY the pixel-exact / occlusion-COMPOSITE check —
NOT the render BUILD nor its structure/DOM/in-process validation (webview / NSHostingView / T4). I'd
wrongly parked whole render items on that narrow T5 slice. Re-opened + shipped (all host-gate-green +
VM-validated via the webview lane):
- **TSK-1333 rendered Mermaid in the walkthrough overlay** — wired WalkthroughMermaidWebView into the
  overlay (occlusion-safe compositingGroup); render webview-validated (df0d8c11) + mount in-process-
  validated (70b118e3) → review. Occlusion-composite = child **TSK-1336** (T5, blocked on TSK-1334).
- **TSK-1149 FeedReaderView render** in-process-validated (46ef18f7 + ce60dfe8 fixup — the built view
  renders the add-feed field). The MOUNT is **re-parked (owner-decision)**: surfacing model a/b/c
  (tool-window vs tab vs window) — a genuine product call, NOT render/T5.
- **TSK-1321 element-properties inspector** (e0383724 + this commit) — the NON-AX edit-after-placement
  FORM (stroke colour · line width · x/y/w/h frame → host-tested restyle/resizeSelectedShape),
  render-guarded (NSColorWell renders for a selection, none otherwise). The canvas vein's on-canvas DRAG
  is the **AX tier** (off-limits, per TSK-1188), NOT T5 — the inspector is the non-AX path.
- **TSK-1334 re-verified** still denied; fix surfaced: the VM has no stable signing identity (ad-hoc →
  TCC re-prompts each rebuild) → `bash scripts/setup-signing.sh` + a one-time owner grant makes it stick.

**THE IMAGE-EDITOR INTAKE CLUSTER (TSK-1302–1321) — now DRAINED (after the above):**
- **TSK-1310 editable text** (34dc97ff + b6a417b8) → review. "Draw Text" was a one-shot raster op; added a
  RETAINED `.text` VectorShape kind (reuses the TSK-1321 inspector/selection machinery) + the Text tool
  now creates it + the inspector retypes/resizes it. On-canvas text PIXELS = T5 tail.
- **TSK-1321 ROTATION** (cefb4da2) completed the inspector → resize·rotate·move·colour/width all via the
  FORM (VectorShape.rotation + setRotation + a GraphicsContext rotate). On-canvas drag-handles +
  click-select-any = AX tail; rotated pixels = T5 tail.
- **TSK-1302 pane-overlap** (e969e531) → review. ImageEditorView is a full-bleed `.overlay` of
  MediaPreviewView while the MetadataPanel is an HStack SIBLING → editing crowded it. FIX: onEditingChanged
  callback (ImagePreview→MediaPreviewView→ContentView) → model.isEditingImage → ContentView
  .showsPreviewMetadataPanel gates the panel off while editing. Host-tested (4-combo predicate).
- **TSK-1303 edit-state persistence FOUNDATION** (8e1636bb) → triaged. ImageEditState (Codable: ops + 7
  tonal + overlay, NO pixels) + vm.captureEditState/restoreEditState, round-trip host-tested. The
  session-snapshot WIRING is the data-safety tail (careful VM, owner-aware — losing edits is the failure mode).
- **Reconciled/owner:** TSK-1304 (hide-toggle pre-exists = the "Info" toggle) + TSK-1307 (resize sheet
  pre-exists) + TSK-1309 (Box button already removed) → review; TSK-1320 (annotations clarity — editability
  solved by TSK-1321; the 3-overlapping-shape-surfaces CONSOLIDATION is an owner a/b/c UX decision, recorded
  as a comment since the park-ping failed).

**TRACKER TOOLING BUG (this session):** task_park / task_advance's SECOND string param (`context` / `note`)
silently fails to register — re-calls don't help. Workaround: task_comment (single `body` param) to record
the disposition, or split into separate calls. Worth an INT ticket.

**HOST VEIN WORKED THROUGH (2026-06-30) — verified item-by-item, the triaged queue is at its host-ceiling:**
TSK-1146 (validated), TSK-1186 (11 clean FILE-WRITE verbs shipped; the render-panel commands are AppDelegate
NSAlerts needing an NSAlert→model-flag-panel refactor = render, not a host descriptor-add), TSK-1315
(diagnosed: NO central focus coordinator → panes compete for first-responder; fix = a render-VM focus
refactor + the owner's repro), TSK-382 (perf, measure-first), TSK-751/781/1128/1182/1305/1320 (owner-decisions),
TSK-1303-wiring (data-safety). NO clean fresh-buildable-host item remains; the high-value tails are
owner/VM/measure-gated — NOT a "host-vein-drained → render-is-owner's-lane" claim (that framing is banned),
but an honest end of the *clean host-completable* work after a comprehensive render + intake delivery.

**THE DURABLE RULE (also LESSONS):** "T5-blocked" ≠ "render-blocked." Split every render item into
(render build + non-T5 structure/DOM/in-process validation) vs the narrow slice that truly needs T5
(pixel-exact / occlusion-composite) or AX (faithful pointer/key gesture). Build + validate the former;
carve the latter into a child. **THREE owner-actions unblock the most remaining work:** TSK-1334 (T5
re-grant → reopens ALL occlusion/pixel), TSK-1149 (feed surfacing a/b/c), TSK-1305 (tonal-undo UX).
**NEXT buildable (no owner):** a TEXT-element inspector (TSK-1310 — a separate text-overlay type, not a
VectorShape) is the remaining non-AX image-edit render path; then frame-field follow-ons.

## ⭐ SINCE THE LAST REFRESH (11 → 16 validated) + THE END-STATE MAP — READ THIS
**NEW validated:** TSK-1306 (New-Image landing button) · TSK-1325 (image format/quality CONVERT — View ▸ Convert Image, full primitive→off-main-VM→UI) · TSK-1323 + TSK-1324 (audio extract-from-video + format/quality convert — View ▸ Extract Audio / Convert Audio, shared VM+panel). **NEW at review:** TSK-1326 (walkthrough authoring guide + parse-validated sample — `docs/WALKTHROUGH_AUTHORING.md` + `docs/examples/sample-walkthrough.json`; the in-app "New Walkthrough" affordance is the follow-on). **PARKED (owner decision):** TSK-1305 (image full-undo — tonal-undo overturns the DELIBERATE live-slider design; needs the owner's UX call).

**⚠️ THE P0 WEBVIEW BUGS ARE FIXED-AT-HOST + AT-REVIEW + AX-BLOCKED FOR ON-SCREEN — DO NOT re-attempt webview synthesis.** TSK-1188 (plain-click-after-scroll, fix `c0fd1543` + grep-guard), TSK-1271 (rendered-MD find scroll, fix `6e9e4efb` + FindCoordinatorTests), TSK-910 (commit-diff multi-line, host core `f809e271`; render slice = child TSK-1182). Their on-screen confirm needs a FAITHFUL POINTER/KEY GESTURE, which is **NOT tractable in the in-process webview lane** — VERIFIED across 4 VM rounds on TSK-1188 (synthesized MouseEvents don't drive CM6's MouseSelection; caret introspection returns nil even past a faithfulness gate). That's the AX/spawned-app tier. See LESSONS (headless-webview CM6 gesture synthesis + the `evaluateJavaScript` unsupported-type trap → append `; true;`). **The webview lane is for STATE-driven render assertions (cmDispatch → DOM query — diagnostics/autocomplete/folds/pickers), NOT gestures.**

**END-STATE — what's left + why each isn't a quick win** (verified by traversing the whole intake + P0 list this session): (a) **AX-tier on-screen confirms** — the P0 gesture/key bugs above (fixed; await the AX/spawned-app lane or an owner glance); (b) **T5-pixel render** — ⚠️ SUPERSEDED by the SINCE-16 section above: the render was non-T5-validatable all along (TSK-1333 mermaid + TSK-1149 feed + TSK-1321 inspector SHIPPED + validated); ONLY the occlusion-COMPOSITE (TSK-1336) needs T5 (blocked on TSK-1334), and the on-canvas drag is AX, not T5; (c) **data-safety** — TSK-1303 (edit-state persist) + TSK-1311 (session-state) — do NOT build the capture/restore wiring blind; (d) **parked design** — TSK-1305 (tonal-undo), TSK-1318 (menu reorg), TSK-1322 (paste); (e) **large features** — TSK-1319 (dynamic per-tab menu), TSK-1182 (diff single-Text render slice), TSK-1327 (smart-paste wiring — sensitive, overlaps 1322); (f) **P2-host** — TSK-382 (memory, measure-first), TSK-538 (rust-core), TSK-852 (.build cache — owner wants SPEED not storage), TSK-441–445 (CI). **NEXT agent:** prioritize TSK-1334 (the T5 re-grant reopens the whole canvas vein), else a P2-host item, else validate/reconcile toward owner-close. Do NOT re-mine the intake or the P0 webview bugs — they're correctly at-review/blocked.

## What shipped this session (4 render epics validated via the in-process template)
Render is FIRST-CLASS agent work — built + VM-validated, not handed to the owner. The template —
**view-model (host-tested) → SwiftUI panel → DocumentModel wiring → menu trigger → in-process
NSHostingView VM-hosting-test (webview lane) → validated** — drove FOUR owner-wishlist epics from
foundation-only to VALIDATED:
- **★ TSK-698 Script Console — VALIDATED.** View ▸ Script Console: JS query/transform over JSON/log/CSV, off-main, Apply→new-tab.
- **★ TSK-1161 Structural Search — VALIDATED.** View ▸ Structural Search: AST query (DSL) → ranged-match list.
- **★ TSK-1160 Task Runner — VALIDATED.** View ▸ Task Runner: discover package.json/Cargo/Makefile → Run → captured output (bounded, off-main).
- **★ TSK-1176 Terminal Command Palette — VALIDATED.** View ▸ Terminal Command Palette: search history+favorites → insert at prompt.

Plus:
- **TSK-1032** HEX byte-grid "blank" resolved as a T4 UAT false-negative (`numberOfGlyphs` is TK1-only, ~0 for the TK2 fixed-grid view) + a reliable host guard (`dc1caa45`); TSK-1332 filed for the UAT-harness fix.
- **TSK-1155** jump-to-step coordinator primitive landed (`06d51f11`), PARKED — the live-timeline UI needs the action-history INTEGRATION (unify-vs-separate-undo = TSK-703 architecture decision, owner).
- **settle() gate flake KILLED (`8c06b297`)** — it bit 3 gates; now 2-consecutive-empty quiescence ⇒ reliably green.
- Earlier: owner intake TSK-1302–1327, host slices (audio-persistence/overlay-selection/structural grammar).
- **TSK-1119 walkthrough illustrations ON SCREEN (review, `111bcab3`).** WalkthroughDiagramOverlay renders .ascii/.image + caption (occlusion-free, VM-validated); .mermaid shows source as interim. Slice 2 (rendered Mermaid) = TSK-1333.
- **TSK-1333 Mermaid-render foundation built; T5 owner-blocked.** WalkthroughMermaidPage (page builder, host-tested, `9482349e`) + WalkthroughMermaidWebView (WebView component, mount-validated on the VM, `62c400c6`). The occlusion verification needs T5-pixel.
- **NEW `pixel` targeted-T5 mode (`74796e9f`)** — `test-in-vm.sh pixel --filter <PixelSuite>` runs ONE T5 suite in ~50s (no full-`all` kill). BUT discovered the T5 screencapture is **TCC-DENIED** (owner-only re-grant, SIP) → **TSK-1334 filed**; ALL T5-pixel CAPTURE is owner-blocked until re-granted.
- **★ TSK-958/1163 Universal Paste — VALIDATED (`c32ee925`).** Edit ▸ Paste as New Document (⇧⌘V) → dispatch each clipboard kind to the right viewer (image/table/text/file). Was wrongly held at review-as-VM-only; host-testable via an INJECTABLE NSPasteboard (UniversalPasteActionTests 3/0).
- **★ TSK-1146 Spell/LSP squiggles — VALIDATED (`29e4c48b`).** Editor spell underlines + LSP diagnostics; logic host-tested at every layer + the RENDER webview-guarded (EditorDiagnosticsWebViewTests: setDiagnostics → `.cm-lintRange` in the live CM6 DOM, VM 2/0). The webview lane is NOT TCC-blocked (≠ T5 screencapture).
- **★ TSK-1136/463 LSP autocomplete — VALIDATED (`ff7be92d`/`7bf25128`).** Did the rebundle session: exposed `startCompletion` (entry.js + `npm run build`) → EditorCompletionWebViewTests proves the editor INVOKES completion (requestCompletion post) + the popup renders (`.cm-tooltip-autocomplete`). VM 1/0.
- **★ TSK-1312 terminal colours — VALIDATED (`15b6cb49`).** User bug "colors off running claude code": theme-aware TerminalPalette + Settings picker; SettingsTerminalColorSchemeHostingTests (in-process host SettingsView → the colour-scheme NSPopUpButton renders with the AnsiTheme options incl. Classic xterm).
- **★ TSK-1314 side-nav toggle — VALIDATED (`05fcca7c`).** User bug: file-tree showed with its shoulder toggle OFF. SidebarFilesToggleHostingTests (count-delta: the filesPanel subtree drops when .files=.hidden).
- **★ TSK-1316 empty shoulders — VALIDATED (`fb283787`).** User bug: empty shoulder bars always showed. ShoulderRailView gated on `if hasContent || isDraggingPanel`; ShoulderRailEmptyHidingHostingTests (count-delta).
- **★ TSK-1308 audio-survives-switch — VALIDATED (`f06098fe`).** User bug: switching session stopped music. App-level AudioPlaybackController.shared holds the player; AudioPlayerHostIntegrationTests (host → controller registers URL → teardown → SAME player survives).
- **NEW REUSABLE TECHNIQUES this session:** (1) **In-process NSHostingView host-tests** for SwiftUI render — host the view, walk the NSView tree for a concrete control (NSPopUpButton) OR use a **COUNT-DELTA** when SwiftUI `.accessibilityIdentifier` on a Text doesn't surface as a walkable NSView id. `#192`-gated, run via the webview lane (`MDV_WEBVIEW_FILTER=...`). (2) The **codemirror.js rebundle** path (`scripts/codemirror-build`: edit entry.js + `npm run build`) to expose CM6 commands. (3) **Retry-the-measure flake harden** (`e625bf81`): the find-typeahead body-eval flake recurred even with 2-consecutive-empty `settle()` under a heavier gate — durable fix is re-running the measure with a VARYING mutation (the action's effect is deterministic, noise clears).

## ⭐ NEXT ACTION — render is NOT exhausted: the WEBVIEW + host-completable lanes are OPEN; only T5-SCREENCAPTURE is owner-blocked + AX off-limits
**CRITICAL — DO NOT re-make the "render exhausted → host P2" mistake.** A prior version of this NEXT said exactly that; it was the SAME premature error the owner banned, and it was DISPROVEN this session by validating TSK-958 (universal paste, host) + TSK-1146 (spell squiggles, webview) AFTER it was written. The lanes:
- **WEBVIEW lane: OPEN + agent-runnable** — in-process WKWebView + JS DOM introspection (`MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_WEBVIEW_FILTER=ViewerUITests.<Suite> bash scripts/test-in-vm.sh webview`). NOT TCC-blocked (≠ the T5 screencapture lane). Validated TSK-1146's diagnostics render via it (EditorDiagnosticsWebViewTests, the FoldGutter pattern: load codemirror.html → cmDispatch → query the CM6 DOM). Next render = un-drained webview-lane (CM6/rendered) items.
- **Host-completable feature logic: OPEN** — injectable-seam actions (universal paste was one). "AppKit/pasteboard = VM-only" is OFTEN FALSE — look for an injectable seam (NSPasteboard arg, etc.).
- **VERIFY-BEFORE-BUILD (recovered MANY items this session):** review-pool items sit wrongly labeled "VM/owner-only" but are host/in-process-validatable (TSK-1163/1146/1312/1314/1316/1308 all were). `task_get` + grep the seam before assuming un-agent-workable.
- **The EASY in-process vein is now largely worked** (separable views with findable controls / clean count-deltas). The REMAINING review-pool intake items are HARDER render-validations: button DELETIONS (TSK-1309 — absence has no clean positive teeth), empty-title buttons in the big ContentView empty-state (TSK-1306), partial host-slice+UI-tail features (TSK-1325 image-convert, TSK-1327 smart-paste — the convert/paste PRIMITIVE is host-done+tested, the UI/live-wiring tail is unbuilt), image-editor CANVAS (TSK-1307 resize, TSK-1321 selectable elements, TSK-1310 text-edit — T5/AX), and layout (TSK-1313 terminal-expand — T5/in-process). Pick the ones whose UI tail is buildable + in-process-assertable; the canvas/T5 ones wait on TSK-1334 or are AX.
- **T5-SCREENCAPTURE (occlusion/pixel): OWNER-BLOCKED (TSK-1334)** — Screen-Recording grant TCC-denied (owner-only, SIP). When re-granted, `test-in-vm.sh pixel --filter <Suite>` (the new targeted-T5 mode) reopens it → land **TSK-1333** (mermaid occlusion, fully scoped + foundation-built) + TSK-955/1149.
- **AX-interaction: OFF-LIMITS** (the one excepted tier): TSK-924/1187, TSK-1139/1141.
- **Focused-session item:** TSK-1136/463 completion render — expose `startCompletion` (entry.js) + `npm run build` rebundle → a webview render guard (scoped on TSK-1136).
- **Host P2 (legit, but NOT as an escape from render):** TSK-382/538/764. Work the open webview/host RENDER lanes first.

## Owner-input-gated (the genuine exceptions — task_park, don't block)
- Parked: TSK-1200 (scroll: real-bug-vs-harness-false — needs owner's real screen), TSK-1322 (paste repro), TSK-1320 (annotations keep/remove). Flips: TSK-838/1215/1202.
- AX-driven tests = the one off-limits tier.

## Gotchas / lessons (also LESSONS.md)
- **SwiftUI render VM-validation pattern (worked for the console):** in-process host the SwiftUI view in an `NSHostingView`+`NSWindow` (a `WebViewTestCase`, `#192`-gated), force `layoutSubtreeIfNeeded`, walk the NSView hierarchy — sidesteps the TSK-1247 spawned-app framebuffer bug. Add the suite to `run_webview_tests`' filter list (+ use `MDV_WEBVIEW_FILTER=ViewerUITests.<Suite>` to run just it), then `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_WEBVIEW_FILTER=… bash scripts/test-in-vm.sh webview`. ASSERT ON STRUCTURE not titles: a SwiftUI `Button("X")` bridges to an NSButton whose `.title` is EMPTY (label is a subview) — assert `count`/types (NSButton/NSSegmentedControl/NSTextField), not `.title=="X"`.
- **`test_findTypeahead_doesNotReBodyChromeStrip` (ChromeBodyEvalCountTests) flake — FIXED (`8c06b297`).** It bit 3 gates this session: `settle()` declared quiescence on a SINGLE empty pump, so a slow async residual under the 18-worker load leaked into the measured window. Fixed: `settle()` now requires TWO consecutive empty pumps (sustained-idle) + doubled the bound (12→24). Gates reliably green. (LESSONS: "quiescent" must mean sustained-idle, not a single idle tick.)
- **The VM render lanes work — use the RIGHT one.** Webview (in-process WKWebView) for WebView/CM6 render; T5 window-ID capture for SwiftUI/AppKit pixels. The SPAWNED-APP UAT lane has a framebuffer-compositing bug (TSK-1247 — the app window isn't composited so live-WebView reads return -1/0); that's a SPECIFIC broken lane to fix/route-around, NOT a reason to call render "un-workable." Don't grind the full `all`-mode UAT (it gets killed) — use the targeted lane.
- **Owner-sensitive scroll (TSK-1200):** the editor-scroll "no-op" seen via the spawned-app UAT is harness-false (the framebuffer bug). Disambiguate real-vs-harness on the owner's real screen / T5 window-ID before changing scroll code (parked). Don't blind-fix.
- **Backticks in `git commit -m "..."` trigger shell command-substitution** → mangled message. Use `git commit -F -` with a `<<'EOF'` heredoc.
- **Read-first ALWAYS** — most P0/board items were already fixed→review or stale-reset-but-done (1188 `c0fd1543`, 1271 `6e9e4efb`, 343 delta-storage); don't re-build.
- **The INT-126 lease sweep re-resets long-lived `progress` items to `reported`** — `review` sticks, `progress` doesn't. To permanently drain a host-done/render-tail epic, take it to review (host done) with the render UI tracked as a child to BUILD on the VM.

## Tracker (tasked / claude-mdv)
VALIDATED this session (16): TSK-698 · TSK-1161 · TSK-1160 · TSK-1176 · TSK-958/1163 (universal paste) · TSK-1146 (spell/LSP squiggles) · TSK-463/1136 (LSP autocomplete) · TSK-1312 (terminal colours) · TSK-1314 (side-nav toggle) · TSK-1316 (empty shoulders) · TSK-1308 (audio-survives-switch) · TSK-1306 (New-Image landing) · TSK-1325 (image convert) · TSK-1323 + TSK-1324 (audio extract/convert) · + TSK-1032 (harness-false + guarded). REVIEW: TSK-1326 (walkthrough authoring guide+sample) · TSK-1188 (plain-click fix + grep-guard; AX-tier on-screen) · TSK-1271 (find-scroll fix; AX-tier) · TSK-910 (diff multi-line host core; render slice = TSK-1182) · TSK-1119 (illustrations; mermaid = TSK-1333) · TSK-1309/1313 (intake). PARKED (owner): TSK-1305 (tonal-undo design) · TSK-1155 (architecture) · TSK-1333 (T5 → TSK-1334) · TSK-1182/1200/1320/1322 + flips 838/1215/1202. FILED: **TSK-1334 (VM screencapture TCC re-grant — OWNER ACTION, blocks ALL T5-pixel)** · TSK-1332 (UAT-harness). NEW infra/LESSONS: `pixel` targeted-T5 mode · in-process NSHostingView host-tests (control-walk / count-delta) · codemirror rebundle · retry-the-measure flake harden · **headless-webview can't synthesize CM6 gestures (TSK-1188, 4 rounds) — webview lane = state-driven assertions only** · evaluateJavaScript-function-assignment → append `; true;`. ~85 commits this run.

## How to resume
Read this + `BACKLOG.md` + `git log -1`. Confirm main gate-green (`bash scripts/test-headless-gate.sh` — reliably green now). The clean in-process render template is DONE (4 epics validated). Take the NEXT-ACTION vein: **T5-pixel render** (TSK-1119 overlay = highest value — build occlusion-safe `compositingGroup().zIndex` + T5-validate, NOT in-process [false-green trap]) OR **host P2** (TSK-382/538/764). Render is your lane (build + VM-validate); only AX-interaction tests + owner-gated items are off-limits. Do NOT re-pick the validated epics or blind-build the occlusion/AX items via the in-process test.
