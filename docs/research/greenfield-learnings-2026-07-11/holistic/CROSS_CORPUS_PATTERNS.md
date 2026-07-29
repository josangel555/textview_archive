# Cross-Corpus Patterns — the view no single batch could see

2026-07-11 · Fable holistic agent (W2). Inputs: `summaries/INDEX.md` + `summaries/commits/INDEX.md`
(read in full), 15 batch reports skimmed for diversity (core source ×2, UI source ×2, rust-core,
LSP slice, test suites ×4 incl. the un-tallied `t-ui-root-5of6`, harness, LESSONS ×2, decision
archive, research docs, docs-root ×1, commit eras c-01/c-16/c-17/c-19), triangulated against the
prior studies treated as independent evidence: the 1.3 GB session-transcript struggle study
(`TEXTVIEW_STRUGGLE_METAANALYSIS_2026-07-04.md`), the repo+board archaeology
(`project-meta-analysis-2026-07-04/SYNTHESIS.md`), and the (unverified) pre-launch audit themes in
`BACKLOG.md`.

This report deliberately does NOT re-list the per-batch KEEP patterns (the INDEX scoreboard does
that well). It covers what per-batch summarizers structurally cannot see: cross-batch recurrences,
time trends, places the corpus disagrees with itself or with the project's self-narrative, and the
second-order conclusions that only emerge from combining independent evidence streams.

---

## 1. Macro patterns — recurring across many batches

### M1. The false-green taxonomy is THE cross-cutting theme of the entire corpus

No other idea appears in as many independent evidence streams: code reports (`src-ui-root-1of4`,
`-3of4`), test reports (`t-ui-root-3/4/5/6of6`, `t-ui-harness`), LESSONS (`d-lessons-1of2` calls
the compositor bug "the single most expensive, most-referenced lesson"), commit eras (c-01's
3-attempt rework, c-05's TSK-488 9-commit arc, c-17's "real WebKit ≠ in-process hosted WebView"),
the struggle study (the render-verification gap = "the app's real fight", the owner's most-quoted
complaint), and the board archaeology (24 T4/T5 test fns for ~30 surfaces).

The taxonomy, assembled across batches, is a *ladder of lying evidence*:

```
model-green            → proves the model, not that any view reaches it
element-in-tree        → proves layout membership, not visibility (size/z/occlusion/alpha)
ImageRenderer/cacheDisplay → rasterizes SwiftUI in isolation; representables are placeholders
in-process WKWebView   → real-ish WebKit, but window-hosting/channel-death bugs don't reproduce
T4 live-app model dump → proves state, not pixels
T5 WindowServer screencapture → the only authority for "did it composite"
```

Every rung was, at some point in this project, mistaken for the rung above it, and each mistake
cost a multi-round rework arc. The rebuild's test strategy should be *organized around this
ladder* — each tier exists to catch what the tier below structurally cannot.

### M2. Lessons stick only when mechanized; prose lessons recur

Visible only by joining LESSONS batches with commit eras and the struggle study:

- Compositor occlusion recurred **4×** across c-01→c-05 *while documented in LESSONS.md*; it
  stopped recurring only when converted into (a) a structural prohibition (never NSRulerView /
  never SwiftUI-before-opaque-representable without `.compositingGroup().zIndex()`), (b) a T5
  pixel test, and (c) a meta-test proving the pixel test goes red on a deliberate break.
- `killall`-by-exec-name was fixed at `AppLauncher`, documented in LESSONS + CLAUDE.md + MEMORY,
  and **recurred weeks later at a second call site** (`install-app.sh`, per `d-lessons-2of2`) —
  the fix pattern was right but only a grep/lint sweep would have caught the class.
- Tracker-lifecycle violations (180 errors) "**never improved across 7.5 weeks** despite constant
  rejection feedback" (struggle study) — prompt-level rules do not train away a structural
  affordance problem.
- Conversely, every mechanized rule held: `TierGateObserver` (tier membership machine-checked),
  `SurfaceCoverageMatrixTests` (exemption ratchet can only shrink), ABI-version skew detector,
  `WebViewLaneCoverageTests` (un-laned test = red gate), ratchet perf baselines, bundle-size dual
  caps, even a byte-budget test on `HANDOFF.md` itself.

**The pattern:** this project ended with a "gate for everything" culture because gates were the
only intervention that ever worked twice. LESSONS.md grew to 3,803 lines and did not prevent a
single recurrence by itself; its value was as *source material for gates*. The rebuild should
treat every hard-won lesson as unfinished until it exists as a red-able check, a lint, or a
structural prohibition — the prose entry is the larva, the gate is the adult form.

### M3. "Model now, render tail later" is both the best delivery pattern and the biggest defect generator

The slice discipline (host-testable model lands now; VM-gated render tail tracked separately) is
praised across c-16/c-17/c-19 ("enables clean stacking of host-green work", 50+ concurrent
features) and it demonstrably worked — d-progress-1of3 credits it with unblocking 100+ items from
false "VM-only" brakes.

But joining it with the pre-launch audit (BACKLOG THEME 5) and `d-docs-root-2of2` shows its shadow:
the audit's only P0-class findings are **dead render tails** — conflict-resolution 3-pane
(TSK-1171), HTML network-consent UI (TSK-1203), dynamic content menu (TSK-1319) with *zero UI
callers*; the FormulaEngine was "100% ported, never wired to a view, shipped as done in
CHANGELOG". The very pattern that made throughput possible manufactures orphans unless the
consumption stage is a *gated lifecycle stage*, not a follow-up ticket. The project discovered
this late and named it (`consumption ≠ completion`, RUST_MIGRATION_ROADMAP); the rebuild should
bake it in: **engine → FFI → consumption/wiring → real-render evidence → bake-in**, with "done"
refused before the consumption stage lands.

### M4. Seams + purity as the universal enabler

The single most-cited KEEP across all 40 code/test batches (seam-based injection, pure planners +
side-effecting executors, sans-IO no-clock no-RNG Rust core, immutable-base + replayable ops) is
not just style: it is what made ~80% of logic host-testable, which is what made the autonomous
loop viable at all. The causal chain — **purity → host-testability → agent-verifiable → agent
velocity** — is the deep reason an agent-built project must be seam-heavy. The corollary from the
UI side: narrow per-domain observation channels (cited by 7 reports; ~90% re-body reduction,
~249× republish amplification killed) are the same idea applied to reactive state.

### M5. Collapse the chain; don't patch the stage

Three independent multi-commit arcs (scroll-restore TSK-1046/1047 — 24 commits, 3 failed
sequencing patches; UAT env-delivery TSK-1243 — 11 commits, 10+ VM round-trips; flake TSK-1328 —
2 rounds) all resolved the same way: stop sequencing the async handoff, eliminate the handoff
(single source of truth, pull-based read; config-file side-channel; retry-with-varying-action).
The commit INDEX elevates this correctly; the struggle study adds the cognitive half — the agent
nominated "the real bug" 2–4× per arc (12 owner interrupts in 58 min at peak). The full rule is
therefore two-sided: **architectural** (after 2 failed patches on a timing bug, redesign to remove
the race by construction) and **procedural** (hold ≥2 candidate causes until a discriminating
check splits them).

### M6. Forward-fix culture: 2 reverts in 3,733 commits

Essentially zero reverts, and both were deliberate diagnostic tools. This only works because the
gate lattice (headless gate per commit, VM lane, parity fuzzing) catches breakage before it
compounds — git history was never the rollback mechanism, gates were. The rebuild inherits this
posture only if it builds the gates first; forward-fix without gates is just drift.

### M7. Audit-as-ritual, evidence-as-artifact

The 47-agent/172-finding fanout (c-03) became a reusable playbook (80-finding deep audit c-04,
17-pass sweep c-18, crash-class audit c-19, pre-launch audit 07-09): severity-triaged batch
response, per-subsystem landing. In parallel, validation converged on **evidence artifacts**:
scene code committed + pixel PNG + reproduction command in the commit message (c-19's
"VERIFIED ON THE REAL VM UI (tmp/uat-videocard.png)" pattern). The end-state norm — *a claim is a
pointer to a repeatable artifact* — is the cultural core worth porting.

---

## 2. Trends — how the project changed over 8 weeks

### T1. Docs-to-code ratio is a control loop, not a constant

`~0.7:1` (bootstrap, docs bundled with features) → `1.5–1.7:1` peak (c-06–c-12, the "log every
item" autonomous mandate) → `0.30–0.48:1` (c-16/c-19, after the 06-22 fold-docs directive). Two
readings must be held together: the c-01 analyst praises early doc discipline; the meta-analysis
condemns the aggregate (36.5% of ALL commits doc-only; 17% of the entire history = appends to ONE
file, `AUTONOMOUS_PROGRESS.md`, 14,987 lines). Both are right — see contradiction N2. Trend
lesson: owner directives visibly changed agent behavior with a ~1–2 week lag and *held*; process
rules are steerable, but only the fold-in discipline should exist from day 1.

### T2. Test discipline deepened in waves, each wave a reaction to a burn

12 tests (commit 1) → tests-with-features (c-01/02) → tier system + pixel genesis after the
compositor burns (c-01/05) → hermeticity + 36× speed fix + proptest vein (c-16, reacting to
pollution/slowness) → differential fuzzing as port insurance (c-14) → per-surface matrix + four
MANDATES (07-04, reacting to the meta-analysis) → pixel-proof-as-default UAT (c-19). Teeth
demonstration went from one clever meta-test (c-01, 4f21ac7b) to a pervasive per-commit norm
(c-17: every significant commit documents its deliberate break). The trend's direction is
constant: **from "tests exist" toward "tests are proven able to fail, at the tier that can't
lie."** The rebuild can skip the burns and start at the end-state.

### T3. Render/UI validation moved from "owner's lane" to "agent's lane" — slowly and expensively

Early: hand-off to owner; a manufactured "host-only backlog". Mid: VM lane unblocked piecewise
(TCC, ulimit, launchctl, toolchain skew, stale-dist, env-delivery — each its own multi-commit
arc, spread over the whole timeline). Late: agent-driven UAT with pixel proof as default, and
CLAUDE.md directives killing the "render is the owner's lane" framing. The struggle study shows
why this mattered: false render-"fixed" claims were the owner's #1 complaint. Trend lesson: the
capability existed weeks before the *culture* used it by default; and the harness never had "a
single clean landing" — treat VM/render validation as **permanent infrastructure tax with a
week-2 bring-up deadline**, not a one-time setup.

### T4. Architecture debt was paid in one scheduled sprint, not continuously — and only partially

Refactor share is near-zero in 17 of 19 slices; c-16 is the deliberate outlier (28.4%, the
40-slice DocumentModel SRP split, 7,542→5,150 lines, zero render regression). Yet the pre-launch
audit still counts DocumentModel at ~10.7K LOC across 74 files with 90 `@Published`, and
`main.swift`/AppDelegate at 4.4 KLOC. The split *worked as a technique* and *failed as a cure*:
extraction-by-extension organizes a god object but does not decompose it. This is why every UI
batch report lands on the same rebuild note: partition by domain **from day one**; the refactor
sprint proves it can be done safely mid-flight, and the end-state proves it's still 10× more
expensive than never accreting it.

### T5. Agent-orchestration failure modes were discovered, priced, and encoded

75-agent Canvas research runaway (~half a session quota, c-17) → "no broad fan-out" rule;
9-agent fleet death on account session limits (~2M tokens lost) → model-split + write-own-report
checkpointing (visible in *this very workflow's* design); worktree disk exhaustion (~124 GB) →
reap SOP; board-vs-code drift → reconciliation audits (c-18). The trend: orchestration went from
improvised to a costed playbook. These rules are day-1 operating procedure for the rebuild, not
things to relearn.

---

## 3. Nuances & contradictions — where the corpus disagrees with itself

### N1. The board understates AND the docs overstate — simultaneously

c-18 + `d-docs-root-2of2`: the board *understated* completion ("3-for-3 model-only claims refuted
by code-read; features fully wired but tickets stuck at review"). The same batch +
RUST_MIGRATION_ROADMAP: CHANGELOG *overstated* completion (FormulaEngine "done", never wired; the
outline model built but unreachable). These aren't contradictory data — they're the two failure
modes of *asserted* status. Model-tier work outruns its tickets (agents forget to advance);
end-to-end claims outrun reality (nobody proves the wiring). **Conclusion: no textual record
tracked ground truth in either direction.** Status must be *derived from attached evidence
classes*, with periodic code-first reconciliation — exactly the v4 tracker thesis, and the single
most important requirement the PM app should inherit.

### N2. "Docs discipline" vs "process tax" — both narratives are true, at different scales

c-01's analyst: "docs-to-code of 25% is sustainable... reflects discipline, not bloat. No
standalone doc-churn commits." The meta-analysis: doc churn was ~⅓ of all motion, "the
compaction-survival apparatus... the cost of having no durable execution substrate." Resolution:
*bundled, feature-paired* docs (c-01, c-16, c-19 mode) are cheap and good; *append-only progress
narration* (the c-06–c-12 mode: `AUTONOMOUS_PROGRESS.md` touched 1,031 times) is a symptom — the
project was paying a 36.5%-of-commits tax to survive 150 context compactions. The rebuild + PM
app should delete the *reason* for the apparatus (short-lived, contract-fed worker sessions;
tracker as substrate) rather than optimize the apparatus.

### N3. The KEEP verdicts cluster suspiciously — per-file quality ≠ system correctness

The code batches read like a hall of fame: "production-grade", "exemplary", "crown jewel",
"defense-in-depth security", "zero false-green findings". Meanwhile the pre-launch audit (30
substantive, unverified reports) found: ⌘S can persist a stale CM6 mirror (debounce never flushed
at save/close/quit); session-switch deletes the hot-exit spill it just wrote; every caller
discards `JSONFileStore.write`'s Bool (disk-full = silent session loss); one malformed bookmark
wipes all bookmarks; an unauthenticated always-on MCP socket exposing exec/write/exfil tools; the
Canvas WebView with no CSP; the shipped bundle redistributing ~45 dependencies with zero
attribution; a notarization pipeline never once run.

Two readings, both needed:
1. **Methodological:** Haiku per-file summarizers grade what code *looks like* (seams, caps,
   guards) — they structurally cannot see cross-file wiring gaps, silent error sinks, unflushed
   debounces at lifecycle boundaries, or ship-path omissions. Downstream consumers must not read
   the KEEP scoreboard as a correctness certificate.
2. **Substantive:** per-file craftsmanship and system-level correctness are nearly independent
   axes here. The defects cluster in exactly the places no file owns: lifecycle boundaries
   (save/quit/switch), error *surfacing* (results computed then discarded), the last mile of
   wiring, and the release path. A rebuild that only ports the patterns will faithfully re-create
   the gaps. The countermeasures are cross-cutting gates: a "no silently discarded Result/Bool"
   lint, lifecycle-boundary flush tests, the consumption-stage gate (M3), and exercising
   sign/notarize/attribute in week 1.

### N4. The corpus disagrees about the test pyramid's shape

`t-ui-root-6of6`: the 81%-headless distribution is "INVERTED from the MANDATE priority — the
rebuild will invert this: pixel-first". `t-ui-root-5of6` (the report missing from the INDEX
tallies): the 70/20/5/2 lean "pattern is scalable", pixel is correctly a "last-resort top layer".
`t-ui-harness`: the tier *system* is the crown jewel regardless of ratio. The meta-analysis
supplies the discriminating fact: the failure was not the ratio per se but **zero-coverage
surfaces** (24 real-render test functions for ~30 surfaces) while render bugs were the #1 owner
pain. Synthesis: don't flip to a pixel-heavy pyramid (T5 is expensive, serial, VM-bound); keep
the headless mass AND enforce a **per-surface real-render minimum** via the matrix guard
(mandate #1) so no surface has zero authoritative coverage. The project's own 07-04 MANDATES are
the correct resolution of its own internal disagreement; `t-ui-root-6of6`'s "flip it" is an
overcorrection.

### N5. Design docs were falsified by shipped code — and the reviews that caught it were the value

The archive decisions batch shows the designed core-owns-domain / client-owns-view state split
"explicitly falsified by shipped code" (`SessionSnapshot` persisting view-state fields); the
"defer Rust core, boundary first" recommendation was overtaken by events; postcard and comrak
recommendations were reversed within days once someone ran `cargo tree`. Pattern: **design docs
drift from code within weeks; hardening reviews and measurement passes are what keep them
honest.** Carry the *review cadence* (one-way-doors checklist, dependency blast-radius
measurement) more than any specific design conclusion.

### N6. Self-narrative vs corpus on autonomy

CLAUDE.md/MEMORY present agent-driven render validation as a solved directive ("the VM is UP —
render is the agent's lane"). The corpus shows the directive was the *end* of a 6-week fight the
owner personally paid for (the struggle study's densest complaint cluster), that the "sufficient
evidence" bar moved repeatedly (`d-lessons-2of2`), and that harness upkeep continued to the final
week. Also: the struggle study honestly credits the agent's *honesty guard* (68 teeth-reverts, 12
held-for-gate admissions) as a strength — the self-narrative underclaims this. Net: the rebuild
should trust the end-state directives but budget the infrastructure reality behind them.

---

## 4. Second-order insights — from combining independent evidence

### S1. The inverted pyramid is a feedback-cost gradient, not a discipline failure

Agents accreted coverage where feedback was seconds (host headless) and avoided where it was
minutes-to-hours (VM round-trip, TCC, stale dist). Exhortation ("write more pixel tests") never
changed the shape; changing the **cost gradient** did (scene registry + `vm-uitest.sh` +
window-id capture made pixel-proof a 30-second operation by c-19, and adoption followed
immediately). Rebuild rule: make the authoritative tier cheap *first*, and coverage will follow
the gradient; mandates only work when the mandated action is cheap.

### S2. 56% of all tool errors were substrate, not work — the strongest datum in the corpus

260 post-compaction file-amnesia errors + 180 tracker-lifecycle violations, neither of which
*ever* self-healed, vs an app whose real fight was one loop (render verification). Combined with
Finding 1 of the board archaeology (the doc-churn tax is the same cost seen from the commit
ledger), this is decisive for the PM app: **the tracker must be the execution substrate**
(stateless short-lived workers rehydrating from contract-shaped tickets; runner-walked states;
evidence-attached transitions), not a status mirror the agent narrates into. The markdown_viewer
project effectively spent ~⅓ of its motion and ~half its error budget simulating that substrate
with markdown files.

### S3. Parity-by-construction beats parity-by-testing

The Rust port program (8/9 engines, zero reverts, 5 silent parity bugs caught by differential
fuzzing pre-ship) succeeded because divergence was made *structural*: one engine, N thin shells;
shared constants live in core (`HEX_WIDTH`); scoring constants locked to an A/B corpus. Contrast
the places with two implementations of one semantic (NSTextView vs CM6 highlighting — flagged as
divergent by the audit; ScriptRunner DSL vs MCP catalog vs CM6 bridge — "zero shared code" drift).
Every place the project had twins, it either ran the full deleted-twin playbook or accumulated a
parity bug. Rebuild: one source of truth per capability, generated/derived elsewhere; twins only
as a *migration state* with a scheduled deletion.

### S4. Security hardening is per-surface and does not generalize

Early-audited surfaces are genuinely hardened (archive zip-slip, subprocess env allowlists,
SQLite ATTACH denial — praised across core batches). Surfaces added *after* the audit waves
shipped soft (Canvas WebView: no CSP/nav-policy; MCP socket: no auth; Task Runner: unscrubbed
env). Audits harden a snapshot; they don't install a reflex. The mechanizable fix: a
surface-registration gate — adding a WebView, socket, or subprocess call site requires a named
threat-model entry the same way adding a view requires a matrix entry (the
SurfaceCoverageMatrixTests shape, applied to security).

### S5. The drain phase is where truth surfaces — schedule it, don't discover it

The 37-tick drain (c-19) surfaced 3 production crash classes, 22 built-but-unshipped subsystems,
and ~40 render tails — *after* "all 25 batches done". The pre-launch audit then found more. The
lesson isn't "this project was sloppy" (the crash fixes landed in days); it's that **breadth-first
agent development systematically defers integration truth**, and only a dedicated
convergence phase (drain + crash-class audit + code-first reconciliation + ship-path rehearsal)
flushes it. The rebuild should put drain/hardening phases on the roadmap from day 1 (the c-19
report suggests ~3 weeks) and rehearse the release path (sign/notarize/attribution) in week 1,
not week 8 — the one lane this project never once exercised is the one it needed to launch.

### S6. Measurement reversed intuition every time they met

postcard (reversed by `cargo tree`), comrak default features (reversed), vim-mode bundle estimate
(280→100 KB), `utf8.count` micro-opt (false positive), "restoreScroll runs too late" (wrong
without runtime instrumentation), UAT reds that were stale-dist artifacts. There is no recorded
case of intuition beating measurement in this corpus. "MEASURE, don't guess" already exists as an
owner directive; the cross-corpus addendum is that it applies to *dependency choices and research
claims*, not just perf: a numeric claim without a measurement command attached was later
corrected, every time.

### S7. The project's best invention is the evidence-class vocabulary

Across testing (WV-DOM / AX-press / T5-pixel / T6-journey), validation (checks artifacts,
pixel-proof + scene + repro command), and grooming (mandate #4: tickets name required evidence at
grooming), the project converged on a shared, machine-checkable vocabulary for "how do we know."
This is the connective tissue between the editor rebuild and the PM app: the tracker stores and
enforces evidence classes; the editor's harness produces them. Port the vocabulary as a schema,
not as prose.

---

## 5. The 10 conclusions the rebuild must not lose

1. **Sans-IO, deterministic Rust core behind a thin-waist versioned wire boundary — from commit
   #1.** No clock/RNG/IO/panics in core; caller-supplied `now_ms`; stable method IDs (never
   renumbered); MessagePack named-field maps (`to_vec_named` mandatory, documented); borrowed
   decode for document-sized payloads; UTF position units decided up front; core-owns-document
   (mirror + op-log + content-based dirty) decided up front, because it drives everything
   downstream. This is the one decision cluster the corpus is unanimous on, and it's
   unretrofittable.

2. **Partition UI state by domain from day one; god objects are 10× cheaper to prevent than to
   split.** Per-domain coordinators, narrow `@Published` channels, documented observation intent;
   the 40-slice SRP sprint proves mid-flight splitting is *possible* — and the ~10.7 KLOC residue
   proves it's not a cure. Carve at 800 lines, not 7,500.

3. **Real pixels are the only authority for UI claims; encode the false-green ladder as
   infrastructure.** Tier-as-type + runtime gate observer, per-surface real-render matrix with a
   shrink-only exemption ratchet, negative-control switches proving every guard can go red, and a
   cheap (≤30 s) pixel-proof path (scene registry + windowed screencapture) operational by week 2.
   Budget the VM/harness as a permanent tax.

4. **A feature is not done until the consumption stage lands.** Lifecycle = engine → FFI →
   consumption/wiring → real-render evidence → bake-in; "model now, render tail later" is the
   right delivery pattern *only* with tails tracked as gated stages. Schedule the drain phase;
   it's where the truth surfaces.

5. **Mechanize every lesson or expect its recurrence.** Structural prohibition > lint/grep sweep
   > red-able test > prose, in that order of durability. LESSONS.md is the intake queue for
   gates, not the defense.

6. **Status must be derived from evidence, never asserted.** The board understated and the
   CHANGELOG overstated in the same repo. Tickets name required evidence classes at grooming; the
   gate refuses "done" without them; run code-first board reconciliation as a standing
   checkpoint. (This is the load-bearing requirement for the coupled PM app; the 260+180-error
   substrate finding is its empirical mandate.)

7. **Staged migration playbook for every engine port:** default-OFF capability gate + fallback →
   A/B parity corpus + differential fuzzing → named soak stages → deleted twin with the adapter
   seam kept. Zero reverts across 8/9 engine ports; 5 silent bugs caught pre-ship. And more
   broadly: one source of truth per capability — twins only as a migration state with a deletion
   date.

8. **Race/timing bugs: after two failed patches, collapse the chain — and hold ≥2 hypotheses
   until a discriminating check splits them.** The 24-commit and 11-commit arcs both ended the
   day the handoff was eliminated rather than re-sequenced; the misdiagnosis spirals were the
   densest owner-interrupt clusters and no architecture fixes them — only SOP.

9. **Agent-substrate operating rules from day 1:** short-lived contract-fed worker sessions (the
   compaction-amnesia killer); hard fan-out caps with model-tier routing; workflows checkpoint by
   writing per-agent reports to disk; fold docs into code commits (no append-only progress
   narration); worktree/build-dir hygiene with reaping; never let feedback latency force
   agents onto lying evidence tiers.

10. **Decide the product tier up front, measure before choosing, and rehearse the ship path in
    week 1.** "Viewer-first workbench, intentionally below VS Code" clarified priorities late —
    declare the equivalent on day 1 and finish-or-cut against it (~30 attempted features, breadth
    over depth, was the audit's product-level finding). Every dependency and perf claim gets its
    measurement command. And run sign → notarize → attribute → install-on-clean-machine before
    the second feature lands: it was the one lane this project never exercised, and it ended the
    run as a ship-blocker cluster.

---

*Written by the cross-corpus pattern agent, 2026-07-11. Companion holistic reports:
`holistic/` siblings (PM-level patterns; greenfield architecture). Verification note: BACKLOG
audit themes cited here are UNVERIFIED (the audit's verify phase never ran) — used as evidence of
*gap classes*, not as confirmed individual bugs.*
