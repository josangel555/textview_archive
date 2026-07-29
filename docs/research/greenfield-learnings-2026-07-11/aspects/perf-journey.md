# Aspect analysis — Performance journey

Scope: the arc from perf catastrophes → measurement discipline → budget-gated infra, and what
day-1 vs week-N perf tooling this project actually built, with the numeric budgets it converged on.

## Taxonomy — the distinct types

### 1. Compositor/render catastrophes (early, severe, one-off but expensive)
The AppKit/SwiftUI compositor pathology: an opaque layer-backed `NSViewRepresentable`
(WKWebView, NSTextView) occludes SwiftUI siblings painted earlier in z-order — position-dependent,
invisible to `ImageRenderer`/`cacheDisplay` (false green).
- Frequency: rare as a *class* but recurred 4x before being understood as a pattern (TSK-488).
- Severity: high — broke basic UI (vanishing tabs, blank source view) on everyday interactions.
- Evidence: `docs/research/…/summaries/commits/c-01of19.md:56-71` — 4-5 commits, 3 re-attempts,
  one revert (`7ac0147c`), root cause = `NSRulerView` re-entrant glyph-range walks, finally fixed
  by abandoning AppKit containment (`377044f0`, 2026-05-14/15, day 1-2 of the project).
  `CLAUDE.md` §"Compositor occlusion + the ImageRenderer false-green trap (TSK-488, 2026-06-07)".

### 2. Reload-storm / re-render-from-scratch bugs (chronic, high felt-cost, slow to fix)
Any content swap that re-invokes `loadHTMLString` (full page reload) instead of patching the
existing DOM — 2-9 seconds of visible freeze on same-file re-render.
- Frequency: this specific instance took **~40 days** from first landing perf infra (06-01,
  `PerfSignpost`) to shipping the fix DEFAULT-ON (`847b7921`, 07-09) — the underlying defect
  (full WebView reload on every re-render) had been latent since the WebView renderer existed.
- Severity: high — directly felt by the user on every markdown edit-to-preview cycle.
- Evidence: commit `847b7921 perf(render): flip rendered-markdown DOM-patch ON by default —
  kills the 2-9s reload storm [TSK-838]`; `LESSONS.md:3886-3887` (slice-and-prove pattern);
  root cause is the SAME class as the scroll-reset-on-switch bug (`LESSONS.md:442`: "the WebView
  is REBUILT on switch... loadHTMLString/reload... scrollY=0").

### 3. Memory blowups from naive algorithms (rare, catastrophic when they hit)
An O(n×m) allocation in a hot/user-triggerable path (LCS diff matrix) that goes machine-wide,
not process-wide.
- Frequency: one confirmed instance (`TSK-1103`), but the failure MODE (tests have no memory
  ceiling — "a runaway takes the host, not just the test") is structural and got its own
  follow-up ticket (`TSK-1194` resource-bounded test exec).
- Severity: critical — 77 GB `phys_footprint`, 25 GB swap, whole-Mac thrash from a single test run.
- Evidence: `LESSONS.md:434` — `LineDiff.lcs` allocated `(n+1)×(m+1)` Int matrix; fixed via
  common-prefix/suffix trim → line-interning → Myers O(N·D) linear-space middle-snake →
  **size-guard** (≥1 MiB either side ⇒ store a snapshot, never invoke the differ). Commits
  `2fb9810c`/`85a212b8 fix(localhistory): linear-space Myers line-diff + size-guard`.

### 4. Per-frame / per-keystroke recomputation (chronic small-N, caught by measurement)
Work that should be O(1) or cached recomputed every SwiftUI `body` re-eval or every animation tick.
- Frequency: recurring pattern across the codebase — `ForEach(stride(...).map)` per-body alloc
  (`LESSONS.md:1102`), a `@StateObject` timer on a SwiftUI PARENT re-bodying the whole parent
  every tick (`LESSONS.md:3718`, TSK-366 status-bar memory chip), TUI per-frame O(file)/O(table)
  work (`c-09of19.md:67`, TSK-544, "130ms debounce consistency").
- Severity: low-medium individually, but this is the class that measurement discipline (below)
  was built specifically to catch — "lag caught by numbers not vibes."

### 5. Speculative/unmeasured "perf fixes" that were non-wins
Claimed hotspots that measurement disproved — cost was wasted engineering effort and
complexity-adding code that would have shipped without profiling.
- Evidence: `LESSONS.md:481` — "`text.utf8.count` is O(1)... the 'recomputed 3×/apply' claim
  was a non-win (~1ns; correctness-risky to 'optimize')"; the "45-92ms lazy-tab materialize"
  claim did not reproduce in an `os_signpost` trace (measured ~2ms/tab; the felt lag, if real,
  was WebView render, a DIFFERENT subsystem). [TSK-845/1022]

### 6. Perf-bench flakiness under the parallel gate (infra tax, not a real regression)
Wall-clock/ratio-based perf assertions inside `swift test --parallel` are noise-dominated by
CPU contention from the other 17 workers.
- Frequency: recurring — named repeat offenders `FoldBenchTests.testCold10KLineJSONUnder250ms`,
  `CrossFileSearchBenchTests` (flaked the gate 3x in one session), `HotPathPerf`.
- Severity: process tax (false-red chases), not a product bug.
- Evidence: `LESSONS.md:233` (`CrossFileSearchBenchTests:191`, `newMs 435 > oldMs*1.5 378`) —
  root cause: "both measurements are contended, so their ratio is noise-dominated"; fix pattern:
  gate the wall-clock ASSERTION behind `MDV_HEADLESS_GATE`-absent (skip under the gate, print
  under it), keep ABSOLUTE-budget asserts with generous margin (they're robust and need no gating).
  `CLAUDE.md` bottom: "A perf-bench-only gate failure... under machine load is flaky."

### 7. Bundle-size / binary-bloat drift (structural, caught by a ratchet)
TreeSitter grammar parse tables silently static-linking into the main executable (vs staying
as `Contents/Frameworks/` dylibs) is a multi-MB regression that looks like normal code growth.
- Frequency: the cap has been bumped 9+ times over the project's life (26→80 MB total,
  16→65 MB exec) — each bump investigated and either confirmed "real code growth" or would have
  caught a static-link regression.
- Evidence: `scripts/check-bundle-size.sh` header comments (own measurements logged inline:
  "measured release 63 MB bundle / 43 MB exec", "71.9 MB / 51.8 MB exec — only ~50 KB / ~160 KB
  under the [cap]"); `LESSONS.md:2368-2381` "Exec sub-cap is a moving target as the codebase grows".

## What worked — practices that earned their keep

- **Env-gated, zero-overhead-when-disabled instrumentation.** `PerfSignpost` (155 LOC,
  `Sources/ViewerCore/Perf/PerfSignpost.swift`, landed day 18: `1df52422`, 2026-06-01) wraps
  `OSSignposter`, gated on `MDV_SIGNPOSTS=1`; the env-var read is cached and every API is a
  branch-and-return when disabled — "no signpost ID minted, no string formatted." This is the
  pattern that made "measure, don't guess" actually cheap enough to reach for reflexively.
  Evidence: `docs/research/…/summaries/code/src-core-automation-infra.md:61,214,317`.

- **Per-kind absolute frame-duration budgets, not vibes.** `InteractionProfiler` (168 LOC,
  `Sources/ViewerCore/InteractionProfiler.swift`, TSK-1488) computes nearest-rank p50/p95/p99
  per `InteractionKind` and flags `exceedsBudget` when p95 > the kind's budget:
  `paletteKeystroke`/`searchScroll`/`uiNavigation` = 16.7ms (60fps, one frame), `switchTab`/
  `renderUpdate` = 33.3ms (one dropped frame OK), `openFile` = 50ms (brief content-load hitch).
  Env-armed via `MDV_PERF_HUD`. Pure + host-testable; the CADisplayLink feed and on-screen HUD
  are the VM tail. This is the CONCRETE budget table to carry forward verbatim.

- **Slice-and-prove for a high-stakes render/perf fix.** The DOM-patch fix (kills the 2-9s
  reload storm) shipped through 6 independently-proven layers: rust `html_patch` block differ
  (host proptest) → Swift `RenderedBlockDiff` diff/apply (host) → wire format (`jsPayload`,
  host) → JS-apply on a CLEAN body (VM WebView test) → **live-body alignment probe** (does the
  real rendered DOM match the model's assumed grain? — this step caught that WKUserScripts/
  find/mermaid could pollute `body.children`, so patching had to target `document.body`
  directly) → production helper on a live WebView (VM) → gated wiring in `updateNSView`
  (default-OFF, `loadHTMLString` fallback = non-regressing). Only after ALL layers were proven
  did the owner flip the default. Evidence: `LESSONS.md:3886-3887`.

- **Absolute-budget asserts survive the parallel gate; ratio/wall-clock-comparison asserts do
  not.** `elapsedMs < 5_000` and `min ≤ mean` invariants are robust under `--parallel`
  contention; `newMs > oldMs*1.5` is noise. This is a durable, generalizable finding — codified
  in `LESSONS.md:233` and the CLAUDE.md perf-bench-flake note.

- **A "kill criterion"/budget stated at PLANNING time, not discovered post-hoc.** The Canvas
  epic's M0-M6 milestone docs explicitly named "budgets, risks, kill criterion" per slice before
  building (`5d8240e4`, `39b7a75e`, `7124c92a`); `b604a1cb` closed "the M6 perf-budget criterion"
  by fixing an O(steps×nodes) walk to O(steps) + a scale guard. Perf budgets as ACCEPTANCE
  CRITERIA (not aspirational) forced the fix before ship, not after.

- **Honest memory accounting from day-ish-1-adjacent.** `ProcessMemory.swift`
  (`Sources/ViewerCore/Observability/ProcessMemory.swift`) exposes `phys_footprint` via
  `task_info` (not RSS/VSZ) and separately tracks WebKit XPC helper footprint, explicitly
  documenting why "per-tab memory" would otherwise be "a fabricated lie." This produced a
  reusable mental model (`reference_macos_memory_metrics` in MEMORY.md) that prevented at
  least one live misdiagnosis of a 77GB number ("I called it RAM, wrong; then benign VSZ, also
  wrong" — `LESSONS.md:433`) even AFTER the honest-accounting code existed, underscoring that
  the infra alone isn't sufficient without the corresponding mental-model doc.

- **Perf audits as a bounded phase that drives targeted single-commit fixes, not open-ended
  refactoring.** TSK-838-845 (`c-10of19.md:158-159`): a research/audit phase, then 8-10
  independently-measured, independently-shipped wins (grammar-warm parallelize, cross-file
  search parallelize [4.7x speedup, 586ms→124ms, `a3ca5304`], deferred file-read, getenv
  fast-path). Each landing is single-commit, validated, checked off — "avoid multi-day perf
  refactors; measure + fix specific bottlenecks."

- **A real regression-guard test, not just "build is green."** Every landed perf win in the
  audit era paired the fix with a test that pins the measured fact (e.g., `a3ca5304`
  "parity-tested" for the parallelized cross-file search) so a later regression fails a test,
  not just "feels slower."

## What hurt — costly failures and root-cause mechanism

- **The reload-storm fix took ~40 days from perf-infra-exists to shipped-default-on**, despite
  the mechanism being simple (full `loadHTMLString` reload instead of DOM patch) and despite
  `PerfSignpost` landing on day 18. Mechanism: the fix required a NEW capability (a block-level
  HTML differ in Rust + a JS-apply layer) rather than a config change — measurement told you
  WHERE the time went, but the fix was still a multi-slice build. **Implication: measurement
  infra alone doesn't compress a genuine architecture gap (persistent-WebView + DOM patching)
  into a quick fix; if reload-on-every-render is foreseeable from the WebView-as-renderer
  design choice, budget it as a day-1 architecture decision, not a week-8 audit finding.**

- **The compositor occlusion bug cost 4-5 commits / 1 revert in the first 36 hours** because the
  team validated with the WRONG tool tier (`ImageRenderer`/`cacheDisplay`, which cannot see an
  opaque `NSViewRepresentable` occluding SwiftUI — it rasterizes SwiftUI's own tree and draws a
  PLACEHOLDER for the representable, so an occluded view renders perfectly in the false-green
  tool). Mechanism: **wrong verification tier, not wrong fix attempts** — the first two "fixes"
  were plausible AppKit-containment approaches that LOOKED validated in-process and were STILL
  broken on real WindowServer pixels. Root cause (NSRulerView re-entrant glyph-range walk) was
  only found once WindowServer-tier pixel capture (`screencapture -l<windowid>`) was used.
  **This is why the project's CLAUDE.md now hard-bans `ImageRenderer`/`cacheDisplay` as proof
  for this bug class** — a costly lesson that should be a day-1 rule, not a day-2 lesson.

- **The 77GB LCS-diff memory blowup happened because "tests have no memory ceiling — a runaway
  takes the host, not just the test."** Mechanism: a naive O(n×m) algorithm in a
  user-triggerable code path (diff two large files) was written without an input-size guard;
  the test harness itself had no resource cap to fail-fast before the host started thrashing.
  Two independent fixes were needed: the ALGORITHM (Myers linear-space) AND a size-guard
  (bypass the differ entirely above 1 MiB) AND (follow-up, TSK-1194) resource-bounded test
  execution so a future runaway can't repeat this at the INFRASTRUCTURE level.

- **Perf-bench flakiness under the parallel gate consumed repeated diagnostic cycles** across
  multiple sessions (same two tests — `FoldBenchTests`, `CrossFileSearchBenchTests` — flagged
  independently at least 3 times per `LESSONS.md`/`CLAUDE.md` before the fix pattern (gate the
  assertion behind `MDV_HEADLESS_GATE`-absence) was codified). Mechanism: **ratio-based
  wall-clock assertions inside a parallel test runner measure contention, not the code under
  test** — this was knowable in advance (any two wall-clock numbers taken under N-way CPU
  contention are unreliable), yet the pattern had to be independently rediscovered.

- **Felt-perf (per-interaction budget) instrumentation didn't land until day ~56 of a ~58-day
  project** (`InteractionProfiler`, TSK-1488, `5a6c2452`, 2026-07-09 — one day before the corpus
  cutoff). Mechanism: `PerfSignpost` (Instruments-visible signposts, day 18) answers "where did
  the time go" for a DEVELOPER profiling session; it does NOT answer "was THIS interaction felt
  as janky" as a standing, always-on, budget-graded signal an agent or CI could consume. That
  gap persisted for the entire middle of the project — most user-facing perf regressions during
  that window could only be caught by manual xctrace sessions or owner "it feels slow" reports,
  not an automated per-interaction budget check.

## Design implications for the rebuild

**Ship on day 1 (cheap, and the project proved retrofitting these is costly):**
1. **`PerfSignpost`-equivalent (env-gated `OSSignposter` wrapper) from the FIRST render pipeline
   commit.** It's ~150 LOC and zero-overhead-when-off; there's no reason to wait 18 days.
2. **`InteractionProfiler`-equivalent (per-kind p50/p95/p99 + absolute budget verdict) from day
   1, not day 56.** Port the exact budget table verbatim (below) as a starting point; it's pure
   host-testable logic wired to a CADisplayLink/frame-tick feed. This should be a standing
   signal an agent can query (`overBudgetSpans()`/`dump()`), matching the project's own
   "agent-centric, non-blackboxy" philosophy for the rebuild — this is a direct precedent for
   giving the agent visibility into felt-perf, not just the owner.
3. **A `phys_footprint`-based memory accessor + a documented "VSZ/RSS lie" note** — this
   project relearned the VSZ≠RAM lesson live, mid-project, DESPITE already having the honest
   accessor written. Bake the mental model into onboarding docs immediately, not just the code.
4. **A resource-bounded test-execution ceiling** (memory/wall-clock cap on test workers) from
   day 1 — this is infra the project only added AFTER a 77GB host-thrashing incident (TSK-1194).
   Don't wait for the incident.
5. **Bundle-size / binary-size CI ratchet from day 1 of packaging**, even if the cap starts
   generously loose — the value isn't the cap NUMBER, it's the drift-detection mechanism
   (catching "did a native dependency silently static-link" class regressions).
6. **A WindowServer-tier (real pixel capture) verification tier planned architecturally BEFORE
   the first AppKit/SwiftUI-mixed view ships**, not discovered after a 5-commit compositor
   fire-fight. If the rebuild mixes SwiftUI with any AppKit/WebView representable (CM6's
   WKWebView almost certainly qualifies), assume compositor-occlusion risk exists from the
   FIRST such view and gate it with a `compositingGroup().zIndex()` convention + a pixel-diff
   regression test, rather than discovering the occlusion class empirically.
7. **Persistent-surface / DOM-patch as an architectural default, not a week-8 retrofit** — if
   any surface re-renders by reloading a WebView/webview-hosted document (markdown preview,
   Canvas, PDF viewer, spreadsheet), design the patch/diff path FIRST. This project's "2-9s
   reload storm" was a foreseeable consequence of choosing `loadHTMLString`-per-render for a
   WebView-backed renderer; the rebuild explicitly plans MULTIPLE WebView-hosted MicroApps
   (Canvas, Markdown, PDF, spreadsheet, DB viewer) — each is a candidate for the same bug class
   unless a patch-not-reload discipline is set as policy up front.

**Accept as inherent / ongoing cost (don't over-invest trying to eliminate on day 1):**
- Perf-bench flakiness under a parallel test gate is structural to wall-clock assertions in a
  contended runner — budget for it (absolute-budget asserts + gate-skip-under-parallel pattern)
  rather than trying to make ratio-based benches reliable; they aren't, ever, under contention.
- Bundle-size cap bumps are a recurring, expected maintenance cost as legitimate code grows
  (this project bumped 9+ times) — the ratchet's job is catching STEP-FUNCTION jumps
  (static-link regressions), not preventing organic growth; don't chase a permanently-tight cap.
- Speculative perf claims will keep surfacing from pattern-matching ("this LOOKS slow"); the
  fix is a cheap measure-first habit (an `os_signpost` trace before optimizing), not trying to
  prevent the claims from being raised.

## Portable rules — candidate directives for the next project

1. **Any env-gated instrumentation facility (signposts, perf HUD) ships in the FIRST week, not
   after the first perf complaint** — it's cheap (100-200 LOC), zero-cost when disabled, and is
   the prerequisite for "measure, don't guess" being a reflex instead of a project.
2. **Define per-interaction-kind absolute frame-duration budgets up front and treat them as
   acceptance criteria, not aspirational targets.** Starting table (this project's converged
   numbers, ms, p95): 60fps-critical interactions (keystroke, scroll, nav) = 16.7ms; one-frame-
   drop-tolerable (tab switch, content re-render) = 33.3ms; content-load hitches (open file) =
   50ms. Grade the p95 frame against budget, not the mean.
3. **NEVER treat `ImageRenderer`/`cacheDisplay`/any in-process rasterizer as proof a mixed
   AppKit-representable/SwiftUI view renders correctly on screen — only real WindowServer pixel
   capture (`screencapture -l<windowID>`) is authoritative.** Bake this into the FIRST test
   written for any WebView/AppKit-representable-hosting SwiftUI view.
4. **Any surface backed by a persistent renderer (WebView, native canvas) must diff-and-patch,
   never reload-the-whole-document, on same-content re-render** — decide this architecturally
   before the first such surface ships, given this project shipped MULTIPLE (markdown preview,
   Canvas plan) and the fix pattern (block differ → JS patch → live-alignment-probe → gated
   default flip) is reusable across all of them.
5. **Wall-clock RATIO/comparison perf assertions do not survive a parallel test gate — use
   absolute-budget assertions with generous margin instead, and explicitly skip ratio-style
   assertions when `<PARALLEL_GATE_ENV>` is set** (print-and-skip under the gate; assert live in
   a dedicated serial perf run).
6. **Any O(n×m)-or-worse algorithm operating on user-controllable input size gets a size-guard
   (bypass to a cheaper fallback above a threshold) AND a resource-bounded test-execution
   ceiling — both, not either** — an algorithmic fix alone doesn't protect the test harness from
   a DIFFERENT runaway input; a test-exec ceiling alone doesn't protect production.
7. **Memory reporting anywhere in the app or its diagnostics uses `phys_footprint`
   (`task_info`), never RSS/VSZ** — document this as a one-line rule in onboarding, since this
   project independently relearned it live even after writing the correct accessor.
8. **A binary/bundle-size CI ratchet ships with the FIRST packaged build**, sized generously,
   whose job is catching step-function jumps (a native dependency silently static-linking) —
   not policing organic per-feature growth (expect and allow periodic cap bumps).
