# Testing Strategy — Day-1 Seed

Copy this into the new repo's `docs/` on day 1. It encodes lessons paid for in full on the
prior project (a mature macOS editor: Swift/SwiftUI/AppKit shell + Rust core over FFI + WKWebView
surfaces including a CM6 code editor). The single biggest finding: **the test pyramid was
inverted for the first ~7 of 8 weeks** — 81% pure-logic unit tests, 1.4% real-pixel tests — the
exact inverse of where the costliest bug class (state-perfect-but-invisible UI) actually lived.
Everything below exists to make that impossible to repeat.

If this project also mixes a native-framework UI layer (SwiftUI/AppKit, or an analogous
retained-mode toolkit) with embedded web/native representables (WebView, terminal surface,
canvas, any third-party-rendered widget), assume compositor-occlusion risk and the false-green
tooling trap from day one — don't wait to discover it empirically.

---

## 1. The tier pyramid — build the TYPE HIERARCHY before writing test #1

Tier must be a machine-checkable *type*, not a convention, a comment, or a naming pattern.
Define base classes (or the equivalent typed-fixture-trait in your language) before any real
test exists:

| Tier | What it proves | What it CANNOT prove |
|---|---|---|
| **T1 — pure-logic unit** | State machine / parsing / geometry math correctness | Nothing about rendering |
| **T1m/T2′ — headless-hosted-view** | View-model wiring, layout math, verb dispatch against an in-process model, no real window | Nothing about compositing, z-order, actual pixels |
| **WebView-inprocess** | Real embedded-web-view mounts, DOM structure, JS eval | Pixel/scroll/visual correctness — smoke only unless paired with real capture |
| **T4 — live-app (spawned binary)** | End-to-end flows via a real spawned app process + a script-verb runner; catches process/lifecycle wiring the in-process harness structurally cannot reach | Whether pixels actually composited on screen |
| **T5 — real-compositor-pixel** | THE ONLY tier proving pixels reached the screen — occlusion, z-order, true visibility | — (this is the ground truth tier) |
| **AX / real-event interaction** | Element presence in the accessibility tree | Real press/type events — treat as the ONE genuinely off-limits agent tier unless you solve hardware-level event synthesis; plan an explicit human/owner-gated exception for it from the start, not an aspiration |

Enforce with a **runtime gate observer**, not documentation: a sentinel-file mechanism that fails
the *build* if a heavy-tier test's body executes inside the merge-gate env var. This was called
"the keystone innovation... the single highest-ROI thing to transplant" — cheap (a few hundred
LOC), and its entire value is preventing silent tier drift once the suite is too large for anyone
to read every file. Build it alongside the FIRST UI test, not after the suite has 50 files.

**Dual-path harness, one shared dump schema.** Build an in-process (spawn-nothing) harness and a
real-spawned-process harness that both emit the *same* JSON/structured dump shape to the *same*
Page-Object-style accessors. A test written once then runs at the cheap tier (microseconds,
host-mergeable) or the expensive tier (real process, VM/CI-only) with zero assertion rewriting.
Build this early: it means every subsequent feature test defaults to the cheap path and escalates
to the expensive path only when it genuinely needs a real window/process — instead of everything
defaulting to expensive because the cheap path didn't exist yet.

---

## 2. Per-surface real-render coverage matrix — mandatory from surface #2

As soon as there is a second custom-rendered UI surface (i.e. almost immediately), require every
panel/lens/aux-surface to map to **≥1 real-render evidence class** (in-process WebView / spawned
process / real-compositor-pixel) OR carry an explicit exemption ticket. Make this a
compile-time-forced table + file-exists disk check, so a renamed/deleted evidence file reds the
gate — not a checklist in a doc that silently rots. (Learned the hard way: this landed at week
~7 of an 8-week project, after the false-negative pattern had already recurred 4 times on one
surface.)

**Tickets name their required evidence classes AT GROOMING, not at close.** A ticket for a
render-touching feature states up front, e.g., "WV DOM + real-process press + pixel-tier
capture" — workers implement to the named classes, and the validation gate refuses to mark it
done without them. This closes the loophole where "model tested" quietly substitutes for
"feature shipped" (see §5).

---

## 3. The false-green trap: know which tool can see which bug class

**Any in-process rasterizer (SwiftUI's `ImageRenderer`, `NSView.cacheDisplay`, or your
framework's equivalent snapshot API) is a layout-debugging tool, NEVER a render-validation
tool.** It rasterizes the native-framework tree in isolation and draws a **placeholder
rectangle** for any embedded representable (WebView, terminal surface, any foreign-rendered
view) — there is no opaque layer to occlude in that isolated raster, so an actually-occluded
view renders "fine" in the test. This produced a real, repeated bug class: an opaque
layer-backed representable's own compositor layer occludes a sibling drawn earlier in z-order —
position-dependent, invisible to every in-process check. It recurred **4 separate times on the
same UI element** before real compositor-pixel capture caught the actual mechanism.

- The ONLY authority for "did this actually reach the screen" is a real windowing-system pixel
  capture of the live compositor output (e.g. window-ID-targeted screen capture, not a
  full-screen grab — a full-screen capture of a *specific window* can still return only system
  chrome and skip the app's own content if targeted wrong; verify you're getting real
  content-level pixels, not just window presence).
- **Bake this into the FIRST test written for any framework-native-view + embedded-representable
  pairing** — apply the "quadrant-color fixture, assert ≥3 distinct colors present" sniff-test
  pattern proactively to every such pairing the first time it's introduced, not after the 4th
  recurrence.
- Maintain an explicit, written "which tool can see which bug class" taxonomy (compositor
  composition needs real display-server pixels; async races need runtime instrumentation, not
  code-order inference; env-var/IPC propagation needs the actual OS mechanism verified, not
  theorized) and consult it before trusting ANY green result on a rendering or timing bug.

**Also structural, not just testable:** treat "an opaque representable can occlude a
same-container native sibling" as a code-review-time, statically-greppable architectural rule
(explicit z-order / compositing-group convention on every such pairing) — this is cheaper and
stronger than any pixel test, because the pixel test only runs on a heavier/less-frequent lane,
not on every commit. The pixel test is belt-and-suspenders, not the primary defense.

---

## 4. Negative-control "teeth" switches — every regression guard must prove it can fail

A test that has never been shown to go red is a false green, full stop. For every
regression-guarded render/behavior test, gate a *deliberate* break behind one committed switch
(e.g. `NegativeControl.isBroken("<NAME>")` reading `ENABLE_BROKEN_<NAME>=1`) and have the heavy
test assert the guard goes RED with it set. This is a repeatable, CI-committed teeth proof —
not a one-off hand-revert-and-confirm that nobody re-runs. Use one consistent, greppable
mechanism project-wide, applied to every such guard as it's written, not retrofitted onto the
important ones after a review.

---

## 5. "Ported/unit-tested" ≠ "shipped" — the dead-render-tail pattern

A fully-tested model/engine (dense unit tests, even cross-implementation parity tests) can have
**zero UI consumers** and ship as a totally inert dead path — a passing test suite proves the
model, never that a view/consumer actually reaches it. This recurred repeatedly in the prior
project's final weeks: a conflict-resolution UI with 0 callers wired to the exact merge path that
needed it as an escape hatch; a dynamic menu model with 0 UI consumers; a security-escalation
core with 0 callers because no grant UI existed. In every case the ticket had gone `fixed`/`done`
on model+data-layer coverage alone, with the missing UI mount noted as a *comment*
("the live X is the render/AppKit tail") — comments don't show up in a board sweep, tickets do.

**Countermeasures, both required, both from day one:**
- **Ticket-typing rule:** a ticket that ships a model/data layer with a UI mount point deferred
  MUST spawn a separate, linked, *blocking* child ticket for the mount — never a prose note.
- **CI/gate script** (not a periodic audit): flag any diff that adds a public type/view/accessor
  with zero callers outside its own defining file. Run on every merge, not just pre-launch.
- Require an explicit, ideally call-graph-verified (not merely grep-verified) non-test consumer
  before closing any ticket that claims a feature landed.

---

## 6. Contracts backing default-flips must be assertions, not comments

A perf-motivated default-flip (e.g. flipping a fast-path optimization to default-ON) is only
as safe as its documented fallback. In the prior project, a comment said "the caller falls back
to full-reload on failure, non-regressing by construction" — the actual caller discarded the
completion handler that would have triggered that fallback, so a failure silently left stale
state on screen with no recovery. Nobody had written a test that would fail if the fallback
stopped firing; "the contract is documented" was treated as sufficient.

**Rule:** any prose safety contract backing a default-flip ships a test, in the SAME commit as
the flip, that injects the failure path and asserts the fallback actually fires. Never trust a
comment as the enforcement mechanism.

---

## 7. Perf: budgets and instrumentation from day 1, not week 8

Ship these in the FIRST week — each is cheap (100-200 LOC) and the prior project proved
retrofitting them after the fact is costly (one instrumentation layer landed on day 56 of a
58-day project, after most of the middle third of the project could only detect jank via manual
profiling or "it feels slow" reports):

1. **Env-gated, zero-overhead-when-disabled signpost/tracing wrapper.** Cached env-var read,
   branch-and-return when disabled — no signpost minted, no string formatted, when off.
2. **Per-interaction-kind absolute frame-duration budgets, graded on p95 not mean, treated as
   acceptance criteria.** The prior project's converged numbers (carry forward as a starting
   point, ms, p95):
   - 60fps-critical interactions (keystroke, scroll, nav) = **16.7ms**
   - one-dropped-frame-tolerable (tab switch, content re-render) = **33.3ms**
   - content-load hitches (open file) = **50ms**
   Make this a standing, queryable signal (`overBudgetSpans()` / `dump()`) an agent can consult
   directly — not just a human-facing HUD — matching an agent-centric, non-blackboxy philosophy.
3. **Honest memory accounting from day 1: use the OS's true resident-footprint metric (e.g.
   `phys_footprint` via `task_info` on macOS), never RSS/VSZ.** The prior project *relearned this
   live mid-project even after already having the correct accessor written* — bake the mental
   model into onboarding docs immediately, not just the code, or the lesson evaporates.
4. **A resource-bounded test-execution ceiling (memory/wall-clock cap on test workers) from day
   1.** A single O(n×m) algorithm on user-controllable input (a naive diff) produced a 77 GB
   resident-footprint, whole-machine swap-thrash from one test run — because the test harness
   itself had no cap to fail-fast before the *host* started thrashing. Any O(n²)-or-worse
   algorithm on user-controllable input needs BOTH an algorithmic size-guard (bypass to a cheaper
   fallback above a threshold) AND a resource-bounded test-exec ceiling — the algorithm fix alone
   doesn't protect the harness from a *different* runaway input, and the ceiling alone doesn't
   protect production.
5. **Bundle/binary-size CI ratchet from the first packaged build**, sized generously — its job is
   catching step-function jumps (a dependency silently static-linking) not policing organic
   growth. Expect to bump the cap repeatedly as legitimate features land; that's normal.
6. **Absolute-budget perf assertions, never wall-clock ratio/comparison assertions, inside a
   parallel test runner.** `elapsed < N_ms` survives CPU contention from other parallel workers;
   `newMs > oldMs * 1.5` measures contention noise, not the code under test — this was
   independently rediscovered and had to be fixed 3+ times before the pattern (skip ratio
   asserts under the parallel-gate env var; keep absolute-budget asserts) was codified. Know it
   going in.
7. **If any surface is backed by a persistent renderer (embedded web view, native canvas,
   anything with retained DOM/scene state), it must diff-and-patch, never reload-the-whole-
   document, on same-content re-render — decide this architecturally before the first such
   surface ships.** A full-reload-per-render design choice produced a felt 2-9 second freeze on
   every edit-to-preview cycle; the fix took ~40 days from "perf infra exists and shows exactly
   where the time goes" to shipped, because the fix required a NEW capability (a differ + a
   patch-apply layer), not a config change. Measurement tells you WHERE the time goes; it doesn't
   compress a genuine architecture gap into a quick fix. If your project plans MULTIPLE
   persistent-web-view-backed surfaces (as this kind of project typically does — a markdown
   preview, a canvas, a PDF/spreadsheet/DB viewer), budget the patch-not-reload discipline as
   policy up front, applied identically across all of them.

**Every cache/store/list gets TWO caps, decided at design time, not one.** The recurring miss
shape: "the acute/first-touch path is capped, the cumulative/long-horizon path isn't" — a restore
path capped at N items while the interactive-open path that feeds it is uncapped; a per-file disk
cap with no global cap/GC; a directory-tree render capped for search but not for display. Write
"what caps the *rate of accumulation*, not just the size of one entry?" into every such ticket's
acceptance criteria before the first line of code.

---

## 8. Rust/native-core testing lanes (if the architecture has a compiled core over an FFI/IPC boundary)

- **ABI-version skew detector + explicit capability-bit pinning, with forward-compat tolerance
  (unknown bits tolerated) — built alongside the FIRST version of the boundary, not retrofitted
  after drift.** This is the foundational gate for any architecture with a native core exposed
  over FFI; skipping it means nothing downstream can be trusted once the header and the library
  drift out of sync.
- **A negative/fuzz test per malformed-input class on every wire-protocol/parser boundary**
  (short header, truncation per field/tag type, OOM-guard, unsupported-tag, depth-cap) — tie
  each test to a named finding (audit-driven naming, e.g. `Audit_<module>_<finding>`) so the
  test's provenance is traceable.
- **proptest-style property tests (round-trips, invariants, differential-vs-naive-reference) for
  new pure-logic engines**, not just example-based unit tests. Especially valuable for anything
  doing a byte-for-byte port between implementations — an A/B parity harness proving
  byte-identical output against a retired twin implementation is the strongest possible proof a
  migration didn't silently change behavior, and the same loopback-style test proves
  local-vs-remote transparency if a remote-core/RPC path is also a goal.
- **cargo-fuzz (or equivalent) on any new parser that decodes untrusted bytes.**
- Keep the compiled core sans-IO / cfg-gated for IO so it stays buildable to a portable target
  (e.g. wasm) if a "run the same core in the browser/remote" goal exists — verify with a CI
  build-check on that target, not just a design intention.

---

## 9. VM/CI heavy-lane setup checklist — pre-empt these traps, don't discover them

If UI/pixel/live-process tests require a separate machine or VM lane (common when the host dev
machine can't safely spawn GUI windows mid-work, or CI runners lack a real display server), set
up the lane with these known failure modes pre-empted, based on traps that each cost real time on
the prior project:

- **Toolchain version skew between "default" and "what the test target needs."** A lane's default
  compiler/runtime version may be *older* than what the test target requires (e.g. rejecting a
  newer async/actor-isolation pattern) — this can block the ENTIRE test bundle from compiling.
  Pin/select the required toolchain explicitly in the lane-runner script; never assume "the
  default on that machine" matches the host.
- **Screen-recording / capture permission (TCC-equivalent) attaches to the wrong process.** If
  pixel capture runs inside the test-runner process itself, it may not hold the grant given to an
  interactive terminal session. Workaround pattern: spawn capture via a disclaiming subprocess
  wrapper so it inherits a *different*, already-granted process's responsibility.
- **Stale build artifact traps.** If the lane's sync step excludes build output (to save
  bandwidth) and a "just run tests" mode never rebuilds it, render/UAT runs can silently validate
  a build that's WEEKS stale — producing symptoms indistinguishable from a real regression (a
  fake "data doesn't persist" alarm was traced to a month-old binary, not a bug). **Any
  render/UAT validation run must go through a mode that rebuilds the artifact first; verify
  freshness (mtime of the actual binary vs. latest commit) before trusting a heavy-lane failure.**
- **Cross-user process/temp-dir splits.** If the test runner and the spawned app run as different
  OS users (e.g. a root-run xctest bridge spawning a console-user app), tmpdir/artifact paths can
  silently diverge between the two — explicit chown/user-aware pathing is needed, not assumed.
- **fd/resource exhaustion under full-suite parallel load.** Raise file-descriptor ceilings
  explicitly in the lane-runner rather than discovering `EMFILE` floods as false test failures.
- **Orphaned processes hanging the lane silently.** A stuck/orphaned process from a prior run can
  hang the entire heavy lane for an extended period with the render tier "silently red" and
  nobody noticing — add a pre-flight reap step, and treat lane health (freshness, orphan-process
  check, permission grants) as a standing, recurring maintenance line item across the project's
  life, not a one-time setup task. This class of infra fragility is structural, not a one-time
  fix — budget explicit maintenance time for it rather than treating each occurrence as a
  surprise.
- **Never bulk-kill by process name if the SAME binary name is also what the developer's
  interactively-running instance uses.** Tag test-spawned instances explicitly and reap by tag.
  A blanket kill-by-name in a script or test can terminate the developer's live running app.

---

## 10. Coverage priorities, sequencing, and what to accept as inherent cost

**Roadmap for the first 1-2 weeks of the test harness itself** (this ordering was validated by
the prior project's own retrospective as the right build sequence):
1. Days 1-2: the headless/in-process tier + its harness; verify with 2-3 trivial fixtures.
2. Days 2-3: the Page-Object-equivalent accessor layer over the shared dump schema.
3. Days 3-4: the Scenario struct + multi-scenario runner (name + script + assertion-with-call-
   site-attribution, bundled as one composable unit) for failure attribution at scale.
4. Day 4+: heavy tiers as the real binary/app becomes buildable — porting from the cheap tier is
   mechanical (same Scenario + Page Objects, different producer) if the schema was shared from
   the start.

**What to prioritize covering first**, roughly by ROI observed on the prior project: core
lifecycle flows (open/close/switch/undo — cheap, covers ~80% of interaction paths), surface/type
routing (which renderer handles which input — easy to regress silently), keyboard/menu-action
parity (small, catches gesture-routing bugs cheaply), then persistence/round-trip chains
(deliberately keep these at the heavy/real-process tier — a test that writes then immediately
reads in the same in-process harness instance structurally cannot catch a serialize/deserialize
bug).

**Accept as inherent, ongoing cost — don't over-invest trying to eliminate:**
- Real-lane infra fragility (toolchain/permission/staleness/orphan-process) recurs across a
  multi-month project regardless of how well it's built once; budget a recurring maintenance
  line item rather than treating each break as a surprise.
- Some fraction of harness-building work will always be "test infrastructure debugging," not
  product work — the prior project's own estimate was **15-20% of velocity** on a comparable
  UI-heavy rebuild. Budget it explicitly rather than being surprised by it.
- A genuinely novel async/timing bug will likely cost 2-3 wrong fix attempts even with good
  discipline — the win is capping it there. **Rule: when a fix survives 2 patch attempts and the
  bug returns, stop patching stages/sequencing and find the single source of truth to collapse
  the chain onto (a pull-based read, not another push-based side-effect timed against others).**
  Two large arcs (13 commits, 11 commits + 10 VM round-trips) on the prior project were each
  ultimately fixed in ~5 lines once the multi-stage handoff was collapsed to one source of truth
  — most of the commit cost was debugging the *test harness itself* being unable to observe the
  real timing, not the product bug.
- Perf-bench flakiness under a parallel runner is structural to wall-clock ratio assertions, not
  fixable by tuning — use the absolute-budget pattern from §7 instead of chasing reliability that
  doesn't exist under contention.
- Root-cause discipline still needs an explicit step-0: **before re-diagnosing any recurring bug,
  read the ticket's/issue's existing documented understanding and prior fix attempts first.** A
  session was independently burned re-deriving a fix that already existed, undiscovered, on an
  unmerged branch — because the prior diagnosis wasn't checked first.
