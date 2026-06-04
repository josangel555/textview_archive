# Autonomous run — progress tracker (2026-06-04)

> **STANDING DIRECTIVE (owner, 2026-06-04):** "Tackle as much as you can, do it
> methodically and progressively, but **don't stop**. If you need my input,
> document it [in DECISIONS NEEDED below] and share later — don't block. No time
> rush. Break down, investigate, research, build PoCs. **Validation is key** —
> find ways to validate automatically without me staring. Screen is yours until
> tomorrow (launch the UI as needed). Build PoCs: image editing; an Agent-
> monitoring view over `~/.claude` (list sessions, search transcripts, detailed
> per-session view); research Claude Code hooks for richer info. Prioritization
> not important — if blocked, document and move on; if nothing to do, research
> best practices. Work in waves/chunks, don't stop."
>
> Hourly cron `1c077a77` (:37) revives this if the session stalls. If you are a
> fresh/compacted session: read this file top-to-bottom, then continue from the
> first unchecked item. Keep `main` headless-gate-green; commit per item.

## Validation methods available (no owner staring required)
- **Headless gate** (window-free): `bash scripts/test-headless-gate.sh` → exit 0 + "tier enforcement OK". The merge gate.
- **`--diagnose`**: `MDV_BACKGROUND=1 .build/debug/MarkdownViewer --diagnose [-MarkdownViewer.<key> <val>] <file>` → JSON view tree (frames + classes). Confirms which view mounts / layout geometry. Window-free-ish (brief offscreen).
- **Live footprint**: launch debug binary bg → `footprint <pid>` (phys_footprint), `vmmap -summary <pid>`, `pgrep`-by-ppid for child procs. Screen is ours.
- **Self-read screenshots**: `screencapture -x -o /tmp/x.png` then Read the PNG. (System-wide capture — note the owner's other windows; don't comment on them.)
- **Perf timing**: instrument with signposts / wall-clock logs to stderr, parse from the log.

## Waves
### Wave 0 — infra + land pending fixes  [IN PROGRESS]
- [x] Hourly safety-net cron (`1c077a77`).
- [x] This progress doc.
- [ ] Reinstall the fixed build to /Applications (terminal `6153c9b` + crash `49647fb` + L1 `1625563`) so the owner tests current code. Needs one live smoke (authorized).

### Wave 1 — perf cluster  [DIAGNOSED; fixes need LIVE validation]
**Finding (2026-06-04):** model-side ops are fast (~4ms, TabOpPerfTests); the freeze is
view-side. AND all three fixes touch view-observation TIMING, so none is headless-safe:
- Fix#3 (skip immediate updateDerived for lazy tabs): the immediate `updateDerived()`
  is what republishes DocumentModel so the view switches to the loading tab promptly
  (ContentView observes DocumentModel, NOT tabCoordinator selection — LOADBUG note
  DocumentModel.swift:3688). Skipping it risks a delayed/wrong-content switch.
- Fix#1 (per-tab view retention) + Fix#2 (narrow observation): load-bearing view refactors.
→ **DECISION/PLAN:** do the perf cluster as ONE focused LIVE-validated effort (build →
`--diagnose` frame dump + screenshot self-read + InteractionProfileHarness timing), not
piecemeal-headless. The mount-count/republish-count guards still apply. Parked from the
piecemeal quick-win flow; pick up when doing a dedicated perf turn with the screen.

### Wave 1 (orig) — perf cluster (tab close/switch/open slow)  [superseded by the block above]
Hypothesis: same root as the 108 MB baseline — DocumentModel god-object republishes the whole content tree + touches every always-on subsystem per tab op (#210/#215 lineage). Plan: live-profile a tab switch/close with wall-clock signposts → find the synchronous hot path → fix → validate with a headless timing test + live footprint/timing.
- [ ] Instrument tab switch + close + open with timing.
- [ ] Identify + fix the synchronous hot path(s).
- [ ] Regression guard (headless timing assertion where possible).

### Wave 2 — quick wins (low risk, visible)
- [~] File ▸ New + right-click folder ▸ New [File] — **model core done** (`5026518`
  NewFileCreator, collision-safe O_CREAT|O_EXCL, 9 tests). UI wiring (menu +
  sidebar context menu + in-place rename) needs the view layer → screen-unlock turn.
- [~] Bookmark remove via Delete key + undo — **model core done** (`217f92d`
  removal-undo stack). UI wiring (Delete key + Cmd-Z in the bookmarks list) → unlock.
- [x] **Default plain-text / allowlist known plain-text formats** ✅ — FileTypeDetector
  known-basename map + config-extension allowlist (commit 3206cf1, headless tests, gate-green).
- [ ] Can't-see-right-border-of-last-tab. (view-layer — needs --diagnose/visual)
- [ ] PNG/media file-info respect zoom. (view-layer)

### Wave 3 — PoCs (research + build, validate automatically)
- [x] **Image editing PoC engine spine** ✅ — ViewerCore ImageDocument/Renderer/Exporter (op-list history, lossless revert, ImageIO export). 16 headless tests. Commit 8420b29. (UI not built; engine only.)
- [x] **Image engine: rotate/flip verbs + orientation algebra** ✅ — `065d482` ImageDocument
  rotate/flip verb API + D4 `.then()` compose + gesture coalescing; FIXED a shipped
  leftMirrored render bug (off-canvas); 8×8 render-equivalence + all-8 corner-pin tests.
- [x] **Agent-monitoring index PoC** ✅ — ViewerCore ClaudeSessionIndex over ~/.claude transcripts (streamed, redaction gate, byte-offset index) + ClaudeLogParser+SystemRecords. 21 headless tests. Commit ab4f583. (UI not built; index only.)
- [x] **Claude Code hooks research** ✅ — docs/research/autorun-2026-06-04/hooks.md; recommendation = passive JSONL logger feeding the monitor. (Owner flag: ~/.claude/settings.json has no hooks key → existing scripts dormant.)
- [x] **Claude hooks logger + reader** ✅ — `814c470` scripts/hooks/monitor-log.sh
  (passive per-session JSONL, env-overridable, exits 0, NOT auto-wired) +
  ViewerCore/ClaudeMonitorLog (typed events + tool-freq/failures/turn-latency
  aggregations). 14 tests incl. script→reader round-trip. **OWNER OPT-IN:** to
  activate, register the hooks block (documented in the script header) in
  ~/.claude/settings.json + restart claude. I did NOT modify that shared file.
- [ ] NEXT for these: build the SwiftUI surfaces on top of the engines (image editor view; agent-monitor sidebar/panel) — separate wave, needs view-layer + live validation.

### Wave 4+ — bigger rocks (from BACKLOG 2026-06-04 dump)
HEX 1 MB slow (#218), tab overflow/shrink (#183/#209), `+`-beside-last-tab (B2), up/down nav (#220), natural keybindings (#232), multi-window, sessions-optional, god-object split (#202), FPS meter (#208), drag tabs→sessions, footer drop-ups, repo-stats treemap, undo audit.

## BLOCKER (2026-06-04 ~07:46): SCREEN LOCKED → live validation unavailable
The Mac auto-locked, so screenshots / live-profiling / build-app smoke / install are all
blocked until the owner unlocks. **While locked, do HEADLESS-ONLY work** (swift test,
pure-logic engines). Queued headless items: perf republish-count + mount-count GUARD infra
(reusable for the live perf turn); File-New model core (create-file + open, FS logic);
expand image engine (rotate/flip/flop ops + tests); Claude Code hooks logging script + test.
View-layer / live-validation items (perf Fix#1/#2/#3, monitor + image-editor UI polish,
bookmark-undo UI wiring, last-tab border, PNG zoom, reinstall) WAIT for unlock.
Owner: `.build/debug/MarkdownViewer --claude-monitor` to eyeball the monitor PoC when back.

**Headless queue status (2026-06-04 ~09:40): the original queue is DRAINED** — perf
republish-guard, File-New core, hooks logger+reader, image rotate/flip+leftMirrored fix
all landed, then an adversarial review (wf_511ce2c0) caught+fixed 8 real issues (7fac492).
**Transcript search DONE** (`ead4b12`). **Fix#1 DESIGN-LOCKED** (`38f40a7`
docs/research/perf-fix1-view-retention.md). **Fix#1 LRU MODEL CORE DONE** (`8e23540`
MountedPanesLRU + 12 tests) — the live turn now just WIRES it into DocumentModel +
the ZStack ForEach (per the design doc's code shape) and adds the mount-count probe.
**Headless work is now genuinely exhausted** (build queue drained, dominant fix's
design + model core both done). Remaining = screen-gated (Fix#1 view wiring + all UI)
or owner-gated (TSK-113). The cron should idle-tick until screen-unlock, not
manufacture marginal code; if it finds a NEW clean model-core-extractable item it may
build it, else hold.

## DECISIONS NEEDED (owner — non-blocking; I proceed on best-judgment defaults meanwhile)
- **WebView/memory lever** — parked on the board as TSK-113 (default: trim compositing layers + measure).
- **Rust slice #6 (FuzzyMatcher) — grapheme dep?** Its `matchedIndices` index into
  Swift's `[Character]` (grapheme clusters); Rust `str` only iterates Unicode
  scalars in std. For ASCII / single-scalar targets (≈ all palette/file-nav
  inputs) a scalar port is byte-identical, but combining-mark / ZWJ-emoji targets
  would diverge. **Options:** (a) approve `unicode-segmentation` (~1 small, widely
  used crate) for a fully-faithful port; (b) ship a scalar-domain port with a
  documented "ASCII/BMP-single-scalar only" limitation + a gate-OFF default; (c)
  leave FuzzyMatcher in Swift (it's cheap; the migration value is "one core" reuse,
  not speed). **My default if unanswered: (c) leave in Swift** — lowest risk, no
  dep, and fuzzy scoring is not a hot path. Deferred, not blocking.
- **Rust slices #9/#10/#11 deps** — `regex` (FindEngine), `serde_json` (Claude log,
  or hand-decode via the existing rmp path), `comrak`+`tree-sitter` (markdown→HTML,
  size-cap-gated). Each first link is a real build/size event; see the migration
  plan's "Owner approvals required".
- **Perf Fix#1 (per-tab content-view retention)** — this is the dominant ~1s fix BUT it's a
  load-bearing refactor: `loadedView` renders only the ACTIVE tab via `model.currentViewMode`/
  `currentState`; retaining N tabs needs per-tab view-state plumbing (#202 territory). I will build
  the mount-count + republish-count headless guards and attempt it behind them; **if headless
  validation can't confidently prove visual correctness, I'll PARK it for your review** with the
  design + measurements rather than ship a risky half-validated refactor to the central view.
  Meanwhile I land the safe wins (PoCs, Wave-2 quick-wins, Fix#3 double-republish, Fix#4 off-main stat).

## LOG (per item: commit + what shipped + how validated)
- 2026-06-04 `6153c9b` terminal runtime-toggle fix (body greedy + clip + focus) — --diagnose verified, gate-green.
- 2026-06-04 `1625563` L1 LSP-diagnostics reclaim on close + MemoryReclaimOnCloseTests — gate-green.
- 2026-06-04 `49647fb` GitLogTab OOB crash fix + roadmap capture — gate-green.
- 2026-06-04 `5026518` NewFileCreator (collision-safe File-New model core, O_CREAT|O_EXCL) + 9 tests — gate-green. UI wiring deferred to unlock.
- 2026-06-04 `096246f` republish-count guard (TSK-108 infra) — gate-green. **FINDING below.**
- 2026-06-04 `814c470` Claude hook logger (scripts/hooks/monitor-log.sh) + ClaudeMonitorLog reader + 14 tests — gate-green. NOT auto-wired (owner opt-in documented).
- 2026-06-04 `065d482` image rotate/flip verb API + D4 compose/coalesce + **FIXED a shipped
  bug**: Renderer.leftMirrored (from 8420b29) drew off-canvas (all-black) — no test had
  exercised its pixels. Found via an exhaustive 8×8 render-equivalence property test;
  fixed by composing two verified primitives. All-8 corner-permutation pin test added. Gate-green.
- 2026-06-04 `7fac492` **adversarial-review fixes** (8 confirmed of 24 raw; workflow
  wf_511ce2c0). monitor-log.sh: drop full-payload persistence (secrets→sizes+200-char
  preview), atomic mkdir-lock + small flat lines (closes >PIPE_BUF concurrent-append
  interleave → silent loss), malformed→<log>.errors. NewFileCreator: reject traversal
  baseName + O_NOFOLLOW. +concurrency proof, +traversal-rejection, +privacy-regression
  + jq-via-`which` test fixes. Gate-green. (Rejected 16 raw incl. a minor formatter dup.)
- 2026-06-04 `ead4b12` ClaudeTranscriptSearch (substring/regex over ~/.claude, 13 tests).
- 2026-06-04 `8e23540` MountedPanesLRU — Fix#1 model core (12 tests).
- 2026-06-04 `38f40a7` Fix#1 view-retention design doc (Approach A; opacity:0-not-.hidden gotcha).
- 2026-06-04 `067a40a` **wave-2 review fixes** (workflow wf_fe28208a, 17 confirmed of 30;
  fixed the real subset, skipped over-confirmed/out-of-scope). ClaudeTranscriptSearch:
  reuse RegexComplexityGuard.reject (ReDoS) + clamp Options≥0 + cap-0 correctness.
  monitor-log.sh: trap INT/TERM, input 256KB cap (disk-DoS), session_id 128-char cap,
  lock-or-drop (no torn append) + stale-lock steal. NewFileCreator: reject NUL baseName.
  +5 tests. Gate-green. SKIPPED (judged not worth it): dir-symlink TOCTOU (documented
  out-of-scope — user's own folder, not privileged), S3 test-path fragility.
  **Unsupervised code now reviewed TWICE; further re-review is diminishing returns.**

### Rust-core migration (headless, no new deps) — `docs/RUST_MIGRATION_PLAN_2026-06-04.md`
- **Slice #2 (CMEditApplier) COMPLETE** — established the Type-1 stateless template
  (`0cead3c`/`0419c72`/`568ce40`).
- **Slice #3 (DiffParser) COMPLETE** (this wave):
  - `02fa9a2` Stage 1 — `diff::parse` Rust port (File/Hunk/Line + 4-strategy path
    split + coord clamp), 13 cargo tests. Also cleared the workspace's deny-level
    `clippy::indexing_slicing` panics — incl. **two pre-existing slices in
    `cm_edit.rs`** that shipped in `0cead3c` because nothing ran clippy.
  - `057f220` **CI hygiene** — `scripts/rust-core-gate.sh` (clippy deny-enforce +
    cargo test) wired into `pr.yml`. The no-panic lints were dead letters before;
    the 65+ pure cargo tests never gated a merge either.
  - `0b292a5` Stage 2 — `mdvcore_diff_parse` FFI + `mdvCoreParseDiff` (nested
    MessagePack decode) + `RustDiffAdapter` behind `RustCoreFallback(.diff)`
    (default-OFF) + 14-case A/B parity vs `DiffParser`. Headless gate green (3539).
- **Slice #4 (HEX dump render) COMPLETE** (`75fb1d7`): `hex::render_all` +
  row math; FFI `mdvcore_hex_render` (bytes by pointer, dump out as RAW UTF-8 —
  no MessagePack, a 4 MB file → ~18 MB string); `RustHexAdapter` behind `.hex`;
  12-case A/B vs `HexDumpBuilder.buildAll` (all-256-bytes/widths/trunc/empty).
- **Slice #5 (HEX search) COMPLETE** (`24f1796`): `hex::hex_search_parse/find/
  search` + `hex_search_frame`; FFI `mdvcore_hex_search` ({offsets:[u32]} frame);
  `RustHexSearchAdapter` behind `.hexSearch`; 13-case A/B vs `HexSearchEngine.search`.
- **Remaining slice #3/#4 sub-items (lower value, deferred):** `DiffHunkParser`
  (diff→gutter-marks flattener), `HexCaretMap` + `HexLayout` caret/click mapping,
  `HexSearchEngine.offsets(ofByte:)` (single-byte click-highlight).
- **Slice #7 (IndentDetector) COMPLETE** (`17de8e3`): `indent::detect`; FFI
  `mdvcore_indent_detect` (text by pointer, result raw UTF-8); `RustIndentAdapter`
  behind `.indent`; 13-case A/B vs `IndentDetector.detect`.
- **No-dep Phase-A wave COMPLETE** for the clean slices (diff, hex render, hex
  search, indent). The two remaining no-dep slices are BLOCKED on real reasons,
  NOT skipped lightly (see DECISIONS NEEDED):
  - **#6 FuzzyMatcher** — its `matchedIndices` are **grapheme** (Swift
    `Character`) indices; Rust `str` iterates **scalars**. Byte-exact parity on
    combining-mark / ZWJ-emoji targets needs a grapheme-segmentation crate
    (`unicode-segmentation`, owner-gated). A scalar-domain port would silently
    diverge there — incompatible with the honest byte-for-byte A/B discipline
    every shipped slice has held. Deferred to an owner dep decision.
  - **#8 FileIconClassifier** — output is ViewerKit's `FileIconKind` (enum with
    associated values); RustCore can't import ViewerKit, so a port needs a
    parallel Rust enum + Swift remap, **doubling** a 290-line drift-prone mapping
    table, for "low value." Not worth the maintenance surface vs the payoff.
- **NEXT (owner-gated deps):** #9 FindEngine (`regex`), #10 Claude log
  (`serde_json`), #11 markdown (`comrak`+`tree-sitter`) — size-cap-gated.
- **OWNER-GATED (deps):** `regex` (FindEngine #9), `comrak`+`tree-sitter`
  (markdown #11), `serde_json` (Claude log #10) — size-cap-gated, see plan.

### KEY FINDINGS (this headless wave, 2026-06-04 morning)
- **Tab-op republish is NOT the bottleneck.** RepublishCountTests measured: warm
  same-mode `selectTab` fires EXACTLY 1 `DocumentModel.objectWillChange`
  (mean=1.0, worst=1); `closeTab` worst=2. The model side is already minimal →
  the live tab freeze is **entirely view-side** (cost of reacting to that 1
  republish: full ContentView re-eval + WebView reload). **Implication for the
  live perf turn:** Fix#1 (per-tab view RETENTION) is the only lever that
  matters; Fix#2/#3 (model-side republish trimming) are marginal (1→0). Don't
  spend the live turn on them. Guard bounds (switch≤4/close≤6) catch a fan-out
  regression now; tighten to 0 only after Fix#2 ships.
- **#218 (HEX 6KB ~1s) is view-side, not model-side.** HexDumpBuilder is a clean
  single-pass build; a 6KB file is ONE chunk (defaultRowsPerChunk=4096). The
  existing `test_microbench_4MB_firstChunk_isFast` already proves even a 4MB
  first-chunk build is <500ms. So #218's ~1s is the mode-switch view remount /
  Task.detached→main.sync scheduling vs a busy main thread — SAME cluster as
  #219. Fold #218 into the live perf turn; no headless fix exists.

## Project tracking — `tasked` board (http://localhost:8787, owner's app)
Integrated (owner asked to dogfood it). MCP server registered at user scope
(`claude mcp add --transport http tasked http://localhost:8787/mcp`) → native
`mcp__tasked__task_*` tools in fresh/cron sessions. THIS session uses curl helper
`/tmp/tk.sh <tool> '<json>'`. Tools: task_create/claim/restate/record/park/
comment/triage/next/list/get. Use `task_park(id,agent,kind,question,options)` to
surface owner decisions (sets waiting:"human"). Active tasks: TSK-108 perf
(claimed), TSK-109 quick-wins, TSK-110 image-PoC, TSK-111 agent-monitor-PoC,
TSK-112 hooks-research, **TSK-113 parked decision (WebView/memory lever)**.
Dogfood feedback: (1) helper needed `--data-binary @-` not `-d` to avoid a brace
parse error; (2) no `task_delete` tool (stray test TSK-107 can't be removed);
(3) mid-session `claude mcp add` doesn't hot-load tools — needs reconnect.

## Wave-1 research workflow
`wf_44d60a03-41e` (background): perf hot-path · ~/.claude schema · CC hooks ·
image-edit approach · blank-slate explorer → synthesis. Persist results to
docs/research/autorun-2026-06-04/ when it returns; act on the synthesis.

## Locked plan (from research synthesis wf_44d60a03 → docs/research/autorun-2026-06-04/PLAN.md)
**Perf (TSK-108), ranked:** Fix#1 per-tab content-view RETENTION (bounded LRU ~4,
keep inactive panes mounted via ZStack opacity keyed by tab.id) — kills the ~1s
close + A→B→A WebView reload, THE dominant fix. Fix#2 narrow ContentView
observation off DocumentModel (observe tabCoordinator directly; the documented
pattern at ContentView.swift:7-33) — AFTER #1 (dead-toggle regression history).
Fix#3 collapse double-republish on lazy materialize (DocumentModel.swift:3699).
Fix#4 move refreshDiskStateForActiveTab stats off-main (only matters on network
vols). DO NOT touch git-diff/repoFocus/LSP (already async — confirmed).
**Validation:** existing `InteractionProfileHarness` (MDV_PROFILE-gated, hosts real
ContentView offscreen, has tab.switch/openClose interactions) for timing; ADD a
makeNSView/dismantleNSView mount-count probe (headless-gate: A→B→A ⇒ 0 remounts)
+ a DocumentModel.objectWillChange republish-count test (selectTab on warm
same-mode tab ⇒ 0 god-object republishes).
**Image PoC (TSK-110):** engine spine in ViewerCore (ImageDocument+EditOp ops-list,
Renderer crop-before-resize+orient, Exporter ImageIO); quality is export-only.
**Agent-monitor PoC (TSK-111):** extend existing ClaudeLogParser.swift; ClaudeSessionIndex
streams ~/.claude/projects/*/*.jsonl top-level, key=filename-stem, redaction gate.
**Hooks (TSK-112):** passive JSONL logger feeding the monitor; FLAG FOR OWNER: your
~/.claude/settings.json has NO hooks key — backup-on-write.sh / block-edit-fullfile-
rewrite.sh are on disk but DORMANT/unregistered (you may think they're active).

## STATUS
Wave 1 plan LOCKED + research persisted (d0c87da). Two PoC-build agents dispatched
(image engine + ~/.claude index; write-only, disjoint files; I build+gate centrally
to avoid concurrent-build races). NEXT (on agent completion): build+gate their PoCs,
then measure tab-switch view cost via InteractionProfileHarness, then implement perf
Fix#1 (view retention) behind the mount-count guard. CANNOT run `swift test` until
the writing agents finish (compile race). main @ d0c87da gate-green + reinstalled.
