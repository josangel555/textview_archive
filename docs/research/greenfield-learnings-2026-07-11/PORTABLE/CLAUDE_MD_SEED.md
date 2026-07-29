# CLAUDE.md — Day-1 Engineering Law

This file is the project's enforced operating contract. Every rule below either has a
machine check behind it or is scheduled to get one. Prose-only rules decay under sustained
agent-driven development — treat "documented" as a placeholder for "not yet mechanized,"
not as done. When a rule below can be turned into a compiler error, a lint, a runtime gate,
or a test, that is not optional polish — it is the actual deliverable.

---

## 1. Architecture invariants (set before feature #1, hard to retrofit)

- **Layered module boundaries, compiler-enforced.** Split into a types-only layer (no UI
  imports), a pure-logic layer (no UI/platform framework imports, 100% unit-testable
  headless), a UI/glue layer, and a thin app-entry target. Enforce the boundary with an
  import-lint in CI, not a convention in a doc. (learned: a 3-package Kit→Core→UI split put
  ~80% of behavior behind headless tests and was independently cited as the single highest-
  leverage decision of the whole project — it made everything downstream cheap.)
- **One producer, many consumers for any data that renders on more than one surface.**
  If the same content can appear in two render surfaces (e.g. a native view and a web view),
  produce the semantic data once as a pure, serializable type and let each surface do its own
  presentation — never fork the producer.
- **Write the rendering-stack policy in week 0, not per-feature.** Decide up front which
  surfaces are native and which are web/webview-backed, and why, as a standing written
  policy. (learned: five parallel implementations of the same feature accreted across native
  and web surfaces because no single decision point ever forced consolidation — each was
  locally reasonable and the duplication directly caused a cross-cutting bug family.)
- **Treat FFI/wire-protocol boundaries as one-way doors.** Before the first commit across
  any process/language/service boundary, decide the position/offset units, the content
  model, and reserve forward-compatible envelope fields. Pin capability/version bits
  explicitly on both sides with a skew detector and forward-compat tolerance for unknown
  bits, built alongside the boundary's first version — not after drift is discovered.
- **Any god-object coordinator gets a size budget from day 1** (e.g. LOC and mutable-state-
  field caps), enforced as a failing test, not a code-review nit. When it's split, use a
  forwarder pattern (thin passthroughs on the aggregate) plus a "republish invariant" test:
  assert a sub-coordinator's mutation notifies only itself, never silently fans out to (or
  gets silently dropped by) the parent. Re-run this invariant test whenever a perf-motivated
  refactor touches notification wiring — a regression here can look like "the model is
  correct but the view never updates."
- **An opaque, platform-native embedded view (e.g. a WebView or other heavyweight
  representable) sharing a container with framework-drawn siblings is a standing occlusion
  risk.** Every such pairing needs an explicit compositing/z-order directive in every layout
  branch, from the first time the pairing is introduced — not after a sibling silently goes
  blank. Add a real-pixel regression test for the pairing at the same time (see §2).

## 2. Testing — tiers, mandates, and the "lying evidence ladder"

**Core finding this section exists to prevent:** every verification tier below true
rendered-pixel proof can be mistaken for proof that something is actually visible on
screen, and agents will drift toward whichever tier gives feedback fastest — not whichever
tier carries the most risk. Left unmanaged this produces an inverted test pyramid (heavy
logic coverage, near-zero real-render coverage) sitting on top of exactly the bug class
(occlusion, invisible-but-state-correct UI, silent-loss data paths) that costs the most.
Counter this with per-surface minimums enforced by a gate, not aspiration.

### 2.1 Tier is a type, not a convention

- Define explicit base classes/harness types for each verification tier (pure-logic /
  headless-model, in-process hosted-view, in-process real embedded-view, spawned-full-app,
  real-compositor-pixel-capture, accessibility-tree-structural). Build this from the FIRST
  UI test, not after the suite is large.
- A gate observer must fail the build if a heavy/expensive tier's test body actually executed
  inside the fast merge-gate environment — heavy tiers self-skip there by construction, so a
  bare full-suite run on a dev machine can never accidentally spawn a window or a live app.
- Any tier that requires a real display/compositor/GUI session runs only in an isolated
  environment built for it (a VM, a headless display server, a CI runner with a real X/
  Wayland/Quartz session) — never on a developer's interactive machine. This is a hard rule,
  not a preference: a stray window opening on someone's screen mid-work is a real cost every
  time it happens.

### 2.2 Real-render proof is mandatory, and headless view-tree snapshotting is NOT it

- Any tool that rasterizes a UI framework's own view tree in isolation (off-screen renderers,
  "cache display," synthetic snapshot APIs) draws a **placeholder** for any embedded native/
  web view and is structurally blind to real compositor occlusion. Never treat such a tool's
  output as proof that something is visible on screen — treat it only as a layout-math
  debugging aid. (learned: this exact false-green pattern caused the same occlusion bug to
  "get fixed" and silently recur four separate times before the rule was made explicit.)
- The only authority for "did this actually reach the screen" is a real compositor pixel
  capture of the actual rendered window (not a full-screen capture that may only grab system
  chrome — target the specific window/surface). Build a cheap (~seconds, not minutes) path to
  this kind of capture in week 1–2 of the project; it is infrastructure, not a stretch goal.
- Every surface (view, panel, overlay, custom-rendered control) must map to at least one
  real-render evidence class — in-process real-view test, full-app end-to-end test, or a
  pixel capture test — before it is considered covered. Enforce this as a machine-checked
  coverage matrix (a file that must name every surface's evidence, checked at gate time),
  not a checklist in a doc. A surface losing its evidence file should fail the gate loudly,
  not rot silently.
- Don't overcorrect into an all-pixel pyramid — keep the cheap headless layer as the bulk of
  coverage; the fix is a **per-surface minimum** of real-render evidence layered on top of
  it, not inverting the ratio.

### 2.3 Teeth: a test that has never failed is not a guard

- Every regression-guarding test must demonstrably go red on the bug it claims to guard
  against, and green again once fixed. For a rendered/visual guard, prove this with a
  deliberate, code-level "negative control" switch (a flag that reintroduces the exact
  broken behavior, gated by an explicit env var / feature flag), not by hand-reverting the
  fix. This is repeatable and reviewable, and it is the standard, not an occasional audit
  step, for any new render-regression test.

### 2.4 Root-cause discipline before any fix

Before implementing a bug fix, answer explicitly (in the ticket, not just in your head):

1. **Read any prior diagnosis first.** If a ticket or record already documents a root cause,
   verify against it before re-diagnosing from scratch — re-deriving from zero risks landing
   a fix for a different cause than the one already found, and burns the exact effort a
   record was meant to save.
2. **Is this a class of bugs, or a one-off?** Grep for structurally similar call sites before
   fixing just the reported instance. Fix the class.
3. **What is the actual mechanism** — synchronous sequencing, async timing, or a data bug?
   Is the value never captured, never serialized, never restored, or restored-but-mistimed
   relative to a render/consume step? Don't patch the restore side when the root is capture/
   serialize; don't patch one stage of a multi-hop async chain (the bug just relocates to the
   next stage, which is why some bugs "keep coming back" after each "fix").
4. **Verify the mechanism at runtime — never infer it from source order.** Framework
   re-render/re-evaluation is frequently async or coalesced; "X runs after Y in the code, so
   it must be too late" is not evidence. Instrument and observe for timing bugs.
5. **After two failed patch attempts on the same bug, stop patching the current stage.**
   A bug that survives one real fix attempt is diagnostic that the *sequencing itself* is the
   disease — look for a single source of truth that collapses the race by construction,
   rather than adding a third stage-patch. (learned: two of this project's costliest bug
   arcs — a 24-commit and an 11-commit chain — only resolved once the team stopped
   stage-patching and collapsed the state into one source of truth.)
6. **A render/timing bug you cannot observe in a fast environment must not be claimed fixed
   on static inference.** Confirm on the real rendering surface first.
7. **If you've re-diagnosed the same class of harness/test-vehicle bug three times, question
   whether you're using the right test vehicle at all**, not just whether your latest patch
   to it is correct.

Accept as an inherent, budgeted cost: hypothesis-selection quality does not improve from
verification pressure alone — a wrong first guess becomes *cheap to falsify* with a good
test gate, but the *rate* of wrong first guesses does not go down. On any bug ticket, keep
a discriminating-check field and a running hypothesis count; expect some 2–3-attempt bugs
on genuinely novel timing issues, and treat that as normal, not a process failure.

### 2.5 Evidence classes named at grooming, not invented at close

- Every ticket that touches an observable/rendered/behavioral surface names its required
  evidence classes (which tiers, specifically) when it is groomed/scoped — not improvised
  by whoever happens to close it. A ticket cannot be marked complete without evidence
  matching what was named.
- Closing a claim as "fixed"/"done" for anything with an observable or rendered surface
  requires a check that is mechanically re-runnable by the system, not a self-attestation
  alone. A prompt-enforced honesty discipline (revert-to-prove-red, "I cannot self-validate,
  holding for review") measurably works but has a real, ongoing cost — prefer building the
  mechanical check over relying on discipline alone wherever the check can be automated.
- Accessibility/AX-tree structural presence and real hardware-level interaction events are
  the one tier that commonly cannot be agent-synthesized end to end (structural presence ≠
  proof of visibility for overlay/sheet content; real press/type events may need a human or
  a genuine hardware-event bridge). Name this explicitly as the one human/owner-gated
  exception in your UAT ladder — do not let it become a blanket excuse to defer other render
  work that IS agent-drivable (build + validate render/UI work end to end yourself; "render
  is someone else's lane" is the wrong framing unless it's genuinely this one tier, a broken
  test-infra lane you've filed, or a real product decision).

### 2.6 Consumption is not completion

- "Ported," "unit-tested," and "green suite" do not mean "shipped" or "reachable by a user."
  Require an explicit, ideally call-graph-verified (not grep-verified — grep can't
  distinguish a real caller from a dead textual match) consuming surface before closing any
  ticket that claims a feature landed. (learned: a fully engineered, fully tested subsystem
  shipped with zero UI callers and was marked "done" for weeks before anyone noticed nothing
  could reach it.)
- Add a standing "zero-caller" / dead-code-reachability gate to the merge pipeline for
  public views, accessors, and entry points — this catches the class mechanically instead of
  relying on someone noticing.
- When a change generates an artifact meant to ship inside a build output (license notices,
  generated assets, bundled resources), assert its presence in the final assembled output as
  a build-time check — don't trust a code comment that claims a copy step exists.

## 3. Task tracking discipline

- **A ticket is one PR/commit's worth of work, not one edit or one file.** File generously
  for distinct threads of work (bugs, features, refactors, decisions) — but do not shatter
  one coherent change into a ticket per implementation step. Heuristic: if closing a
  sub-ticket alone leaves nothing a user or a test can observe, it is a checklist line inside
  its parent ticket, not its own ticket. Legitimate splits are a genuinely different
  tier/lane that can't ship together, an independently shippable slice of a larger epic, a
  real blocker, or unrelated work discovered along the way.
- **Status discipline:** mark work in-progress before starting, complete only when it is
  fully done and validated (an automated check that would fail if the behavior regressed —
  not "the build is green"). Never mark something done on a partial or failing change.
- **Status must be derived from evidence, not asserted.** A ticket should not be closeable
  without the evidence classes it was groomed with actually being attached. Periodically
  reconcile ticket state against the actual codebase in **both** directions — check for
  "board says done, code doesn't back it up" and, just as seriously, "board says open, code
  already shipped it." (learned: a late-project reconciliation found the tracker
  *understating* completion nearly as often as overstating it — the failure mode most
  process design guards against is only half the real problem.)
- **Owner/human-gated items don't block the work loop.** Anything needing a genuine human
  decision (a dependency approval, a one-way-door architectural call, a product-taste
  judgment) gets filed with an explicit blocker reason and a homework-backed recommendation
  attached, then the loop moves to the next actionable item. Never stall the whole loop
  waiting on one gated item.
- **"No more actionable work" is never a valid stop state for an autonomous loop.** If the
  obvious queue looks empty, pull from the review/validate/triage backlog before concluding
  there is nothing to do.
- **Audit the intake, not just the backlog.** Run a lightweight classifier over new
  ticket/wish intake for "duplicate of an existing ticket," "already shipped," or "too vague
  to be a ticket" before it becomes tracked work — an unaudited raw brain-dump accumulates
  real noise over time.

## 4. Commit and documentation hygiene

- **Fold process documentation into the code commit it describes.** Progress logs, handoff
  notes, and changelog entries for a change belong in that change's commit, not as a
  standalone doc-only commit — unless the doc is a genuine stand-alone artifact (a new
  design doc, a periodic checkpoint). (learned: this one rule change measurably cut a
  project's doc-commit ratio roughly in half within a few weeks of being adopted — it is
  cheap and it works immediately.)
- **Track the process/doc-commit ratio as a real cost, not free overhead.** If doc-only or
  tracking-only commits exceed roughly 15–20% of all changes in a period, treat that as a
  signal your durable-state substrate is insufficient (see §6), not as a discipline problem
  to nag about.
- **A current-state doc is not a session log.** Any "where things stand" document (a
  handoff/status doc re-read at the start of every session) must be updated in place, never
  appended to tick-by-tick. Enforce a hard byte/line budget on it with a failing test — a
  budget breach means prune the content, not raise the cap. History belongs in the commit
  log or a structured tracker, not in prose that gets re-read every session regardless of
  relevance.
- **Two-audience changelog.** Split changelog entries into a user-facing section (what an
  end user can see or feel changed) and a terse, per-area engineering roll-up of everything
  else. This solves the common failure of either polluting the user-facing log with commit
  noise, or hiding the bulk of actual engineering effort entirely.
- **A lesson only counts once it changes a gate, lint, or check — not just a doc entry.**
  A prose "lesson learned" file that is never converted into an enforced rule prevents
  nothing; expect the same mistake to recur at a different call site. When you write a
  lesson, immediately ask "what check would have caught this" and add that check.

## 5. Dependency and safe-write policy

- **Minimal dependencies, explicit approval required for every one.** No library, repo
  clone, vendored snippet, or fetched-from-a-URL code lands without explicit sign-off —
  every time, no "this one's trivial" exception. Start bare; add a dependency only against a
  concrete, demonstrated pain point.
- **Dependency hygiene covers the whole toolchain, including dev-only tooling.** Installing
  a CLI tool via a package manager compiles its full transitive dependency tree locally too
  — treat "just a dev tool" with the same scrutiny as a runtime dependency. Prefer writing a
  small amount of bespoke tooling over pulling in a heavyweight dev dependency when the gap
  is narrow.
- **Pin exact versions in lockable manifests.** No floating ranges, no "latest," unless
  explicitly opted into.
- **Never assume a target filename is unused.** If a write would overwrite an existing file
  (or a tool reports the file changed since it was last read), write a new sibling-named
  version instead of forcing the write through — files are cheap, silently destroying
  someone's existing work is not recoverable.
- **Never write outside the project's own working/session area**, and never rely on a system
  temp directory for anything that must survive a restart — system temp locations get
  cleared on a schedule outside your control.

## 6. State and substrate design

- **Design the durable execution substrate before the first feature, not as a bolt-on.**
  If work sessions are long-lived and the session transcript itself is the only place state
  lives, every context compaction becomes a real cost: lost read-state causing rejected
  edits, illegal state-machine transitions on a shared tracker, and a growing apparatus of
  hand-maintained markdown trying to compensate. (learned: on one project this pattern was
  the single largest class of tool-level errors — about a third of all of them — and never
  improved over the life of the project despite explicit rules; the actual fix that worked
  was making individual units of work short-lived and re-derivable from a written contract,
  not writing better prompts.)
- **Scope units of work so they can be re-derived from a written contract, not from
  accumulated session memory.** If a unit of work cannot be picked back up correctly by a
  fresh context reading only its ticket/contract plus curated references, it is scoped wrong
  — split it.
- **Prefer structural/derivable state over prose logs wherever the state is machine-
  checkable.** A ledger of tracker rows with evidence attached beats a running narrative
  document every time it's an option.
- **Run a scheduled hardening/drain/reconciliation pass on a real cadence** (e.g. per
  milestone), not just once "before launch." (learned: a pre-launch-only audit on one
  project surfaced multiple crash classes and dozens of built-but-effectively-unshippable
  subsystems that had been accumulating silently for weeks — breadth-first work defers
  integration truth by construction, so schedule its collection instead of discovering it
  late.)

## 7. Performance — measure, don't guess

- Any performance work is backed by a real measurement (a proper profiling/tracing tool for
  the platform), not intuition about what's slow. State the specific latency/throughput
  concern (wall-clock/perceived latency vs. memory/disk footprint — these are not
  interchangeable and optimizing the wrong one wastes the effort) before starting.
- Set per-interaction performance budgets **before** the corresponding feature exists (e.g.
  target latencies for a keystroke, a scroll frame, a tab switch, a cold open), as a failing
  test with headroom, not adjusted upward after the fact to match whatever was shipped.
- Prefer ratio-based/relative perf regression guards (e.g. "large input stays under N× the
  cost of a small input") over absolute wall-clock assertions where the test runs on shared
  or variable-load infrastructure — absolute-time asserts are the ones that flake under load
  and get ignored.
- Front-load performance work rather than treating it as post-launch polish — user-facing
  perf complaints are one of the most commonly recurring and under-prioritized complaint
  categories on a long-running interactive-app build.

## 8. Fan-out and automation ceilings

- **Any agent capable of spawning further agents needs a hard, structurally enforced
  max-in-flight ceiling** — not a prompt instruction telling it not to spawn freely.
  (learned: a "cast a wide net" research prompt given to a small number of general-purpose
  agents that themselves carried spawn capability multiplied to dozens of agents and burned
  a large fraction of a session's budget, without ever going through the project's
  higher-level fan-out tooling — the loophole was the capability itself, not any one
  entry point.)
- **Read-only exploration/research delegation should use an agent type that structurally
  cannot spawn further agents at all.** This is the only mitigation that reliably holds;
  a prompt convention alone measurably plateaus at zero compliance improvement over time for
  this class of instruction.
- **Multi-stage automated pipelines need per-stage checkpointing, not just per-task output
  capture.** Writing each parallel worker's output to disk as it finishes only protects an
  embarrassingly-parallel gathering stage — a later aggregation/synthesis stage that depends
  on many completed inputs needs its own resumability, or a session/quota death near the end
  can discard 100% of the aggregation value even though all the inputs were ready.
- **Reap fan-out infrastructure (isolated worktrees, build caches, background processes)
  on completion and on crash**, and keep build output directories outside any isolated
  worktree where the toolchain allows it — this class of cleanup does not happen on its own
  and compounds fast under repeated parallel fan-out.
- Prefer worktree-isolated **execution** fan-out against a locked, already-decided design
  (implement N independent, well-scoped tickets in parallel) over wide-open **research**
  fan-out — the former is where fan-out reliably pays off; the latter is where runaway and
  synthesis-loss failures concentrate.

## 9. Autonomy SOP skeleton (for unattended/cron/heartbeat runs)

1. Read the current operating procedure doc in full at the start of every run; treat a doc
   that's ahead of this file as authoritative where they conflict.
2. Pull work from the tracker's system of record, not an ad hoc list — drive items through
   an explicit lifecycle (e.g. reported → triaged → in-progress → fixed → review →
   validated → done). Advance strictly via the tracker's own interface, never a bespoke
   script or a shared human-facing endpoint.
3. Spike-and-design autonomy is the default for non-trivial work: investigate scope,
   feasibility, and options, and produce a design/breakdown yourself before implementing.
   Escalate to the human only for a genuine dependency approval, a true unresolvable
   ambiguity about *what* is being asked, or a hard blocker — never merely because a
   decision about *how* to approach something exists to be made.
4. Work inline, one item at a time, for routine automated firings. Reserve heavy multi-agent
   fan-out for explicitly human-triggered sessions with a locked scope — an unattended loop
   that spins up its own large fan-out compounds the runaway risk in §8 with no one watching.
5. Never stop an unattended run with "there is no more work" — treat that as a process
   failure to diagnose (pull from validate/review/triage backlogs) rather than a valid
   terminal state.
6. Keep the mainline branch green against the fast/merge gate at all times; commit per
   completed unit of work; land via rebase-and-fast-forward, never a merge commit, so the
   trunk stays a single linear thread.
7. Log real, substantive progress to a durable narrative record, but fold that record into
   the code commit it describes (§4) rather than issuing standalone doc commits.
8. A perf-benchmark-only gate failure under contended/shared load is a candidate flake —
   confirm no correctness failures are also present before treating a benchmark red as a
   real regression.

## 10. Human-attention design

- Design the human's review workload deliberately; don't let it emerge. Batch similar
  pending decisions into one review pass per class rather than trickling individual
  approvals. Default routine two-way-door decisions to auto-proceed on a visible timer
  (logged, reversible) rather than blocking on a human touch; reserve direct interrupts for
  one-way doors and genuine product-taste calls.
- Progress reporting to the human should reflect *accepted/validated* work, not merely
  *closed/merged* counts — closed-ticket counts can be wrong in both directions if status is
  ever asserted rather than derived from evidence (§3).
- Never ask an inline question the homework could have answered. If something looks like it
  needs approval, do the investigation (spike, comparison, tradeoffs) first and bring a
  recommendation, not an open question.
