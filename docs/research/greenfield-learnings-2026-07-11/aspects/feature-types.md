# Feature Types — what got built, what got used (markdown_viewer, 2026-05-14 → 07-10)

Dimension: categorize everything shipped by feature TYPE (editor core, lenses/viewers, MicroApps,
agent-centric surfaces, chrome/UX, automation/MCP, infra); for each, shipped-vs-usable, dead
render tails, and the sequencing lesson for the rebuild.

Primary evidence base: `docs/FEATURE_INVENTORY.md` (owner-graded 3-column Built/Logic/Usable audit
across 12 families, 2026-07-02, updated 07-10) — this is the single authoritative "did it land"
document for this project and is cited throughout. Supporting: `summaries/INDEX.md`,
`summaries/docs/d-docs-root-1of2.md`, `summaries/docs/d-docs-root-2of2.md` (RUST_MIGRATION_ROADMAP
distillation), `summaries/commits/INDEX.md` (era timeline, Canvas arc), `summaries/code/src-core-
sessions-review-plugins.md`.

---

## Taxonomy — the distinct feature types, frequency/severity, evidence

### 1. Editor core (CM6 + tree-sitter + LSP + vim) — the ONE fully-usable tier
The only family the owner rated ✅ across the board: "Editor works, vim mode works, file nav
mostly works." (`FEATURE_INVENTORY.md` §1, owner quote at file top, 2026-07-02). Built ✅, logic ✅,
usable ✅ for CM6 edit/save/undo, vim mode, 22-language tree-sitter highlight with predicate
evaluation (`summaries/INDEX.md` "TreeSitter predicates FIXED" pattern). Even here, sub-features
regress to 🟡/✖ once you leave the core loop: snippets ✖, local history ✖, find-in-editor 🟡 —
i.e. even the best-built family has a long unusable tail once you get past the primary verb.
Evidence: `FEATURE_INVENTORY.md` §1; `summaries/code/src-small-targets-web.md` (CM6 plugin
architecture, drag-gating, queueMicrotask ordering fixes — real engineering depth here, matching
the usability payoff).

### 2. Lenses/viewers (rendered-MD, source, formatted, diff, hex, CSV, transcript) — 🟡, engine-strong / UX-thin
`FEATURE_INVENTORY.md` §3/§5: every lens is Built ✅ Logic ✅ but Usable 🟡 at best (rendered
markdown, JSON, hex, DOCX/RTF import); several are outright ✖ (mermaid diagrams, HTML rendering,
spreadsheet/formula — gated OFF, SQLite browser, archive/package explorer, notebook cells, log
patterns). The Rust engine layer for these is genuinely strong (`summaries/INDEX.md`: "Pure,
deterministic engines … shared across TUI/web/future tiers by construction" — src-rust-core-1of2),
but the view side stalls at "renders something" without a finished interaction loop (no
query→export for SQLite, no progress/error states, no click-to-line results).

### 3. MicroApps / data-format editors (image editor, audio editor, spreadsheet, DB viewer, archive
browser) — the deepest engineering, the worst usability gap
Owner's exact framing: image editor, audio editor, spreadsheet formula engine, SQLite browser are
all Built ✅ / Logic ✅ / Usable ✖ (`FEATURE_INVENTORY.md` §6/§5). The image/audio "immutable
source + replayable ops" architecture is independently flagged as "the crown jewel" of the entire
core codebase (`summaries/INDEX.md`, `src-core-media-terminal.md`) — i.e. the single best-designed
subsystem in the project shipped with near-zero end-user usability (paint persistence gated,
tool feedback missing, save-vs-copy unclear). This is the starkest built≠usable gap in the corpus:
maximum engineering investment, minimum realized value.

### 4. Agent-centric surfaces (git integration, code review, walkthroughs, Canvas, MCP/automation)
— the owner's stated PRIMARY differentiator, and the most unevenly realized
- **Automation/MCP** (§8): the one agent-facing surface graded 🟡 "agent-usable" rather than ✖ —
  160 script verbs, MCP stdio server, `--script` runner. Backend genuinely strong
  (`AUTOMATION.md` carry-forward: PORT nearly verbatim, `d-docs-root-1of2.md`). Human-facing
  discoverability still ✖ (palette UX, plugin lifecycle UI).
- **Code review / walkthroughs / git panel** (§7): Built ✅ Logic ✅, Usable ✖ across the board —
  review has comments/anchors/approve-reject but "no resolve flow… needs an end-to-end on-screen
  journey test"; walkthroughs ✖; git panel ✖ ("stage/unstage/commit/push visible + safe" not
  confirmed). These are literally the owner's headline asks (non-blackboxy AI interaction,
  reverse-review) and they are the LEAST usable tier in the whole inventory.
- **Canvas** (agent-incremental-UI-authoring, owner's named flagship feature): built M0–M6, then
  explicitly **PARKED for owner review, do not build further** (`FEATURE_INVENTORY.md` §11;
  `MEMORY.md` "Canvas — GREENLIT then PARKED"). The *build* of Canvas (once scoped) was healthy —
  "Rust-first, design-doc-locked, milestone×slice decomposition… shipped cleanly"
  (`summaries/commits/INDEX.md`, big-rework-arcs table) — but it got there only after a **~75-agent
  design-spike fanout burned roughly half a session's quota** researching the feature before any
  code (`summaries/commits/INDEX.md`, c-17 era: "costly 75-agent subagent-fanout lesson recorded").

### 5. Chrome / UX shell (settings, shortcuts, first-run, menus, palette) — 🟡, last-tier polish, discoverability sink
`FEATURE_INVENTORY.md` §12: session restore/File→Reset are usable 🟡; everything else (shortcuts
viewer ✖, help/first-run 🟡, Settings IA "currently a grab-bag") is unfinished. This is the
category where the **eight cross-cutting usability gaps** concentrate structurally — results-in-
alerts, no empty states, no progress/error surfacing, poor discoverability, feature-surface
overlap (cohesion), felt latency, unfinished core loops, on-screen-verification debt
(`FEATURE_INVENTORY.md` "cross-cutting usability gaps" section, listed once and cited by ~40 of the
43 gap tickets under TSK-1411).

### 6. Infra / dev-lane features (perf profiling, security/sanitizer layers, diagnostics) — the
only ✅-invisible-by-design category
Egress guard, HTML policy, sanitizer graded ✅ "(invisible)" — correctly not held to a usability
bar because they have no UI surface (`FEATURE_INVENTORY.md` §12). This is the one category where
"built = done" is the right bar, and the inventory correctly doesn't penalize it.

### Cross-cutting: dead / thin render tails (feature exists, view never reached)
- **Formula engine** — canonical case study cited three separate times in the corpus: "engine
  fully ported + FFI 100% + A/B-tested, but view never wired — ticket over-claimed it as shipped"
  (`summaries/docs/d-docs-root-2of2.md` line 44, RUST_MIGRATION_ROADMAP distillation); it even
  "shipped as done in CHANGELOG" despite zero UI caller (line 279).
- **FolderTreemapView, LocalHistoryStore** named explicitly as "built-but-unwired work" that cost
  agent time to discover because nothing surfaced their existence
  (`d-docs-root-1of2.md`, AGENT_PRODUCTIVITY_FEEDBACK summary: "A `find_unwired(symbol)` tool
  would unlock cheap high-value work").
- **RichText editor** — flag-gated WIP, Built 🟡/Logic ✅/Usable ✖(gated) — an owner
  finish-or-cut decision sitting unresolved (`FEATURE_INVENTORY.md` §9, TSK-1418).
- **Built-in browser epic (TSK-676)** — Built 🟡, Logic ➖ — explicitly an "owner finish-or-cut"
  (§10), i.e. investment continued into a feature nobody decided to keep.

---

## What worked — practices/designs that earned their keep

1. **Sans-IO Rust engine + thin adapter/gate pattern made the ENGINE side of every feature type
   uniformly strong**, independent of whether the UI ever got finished. Evidence: CSV/diff/hex/
   fuzzy/find/transcript/markdown/formula engines all "shared across TUI/web/future tiers by
   construction" (`summaries/INDEX.md` most-cited patterns; `ARCHITECTURE_LAYERS.md` distillation
   in `d-docs-root-1of2.md`). This decoupling meant a stalled UI never blocked or corrupted the
   reusable core — the formula engine is unusable but not broken.
2. **The 3-column Built/Logic/Usable audit itself.** Before it existed (up to 2026-07-02), the
   project had ~30 "built" feature families and the owner's honest read was "almost all
   unusable" — a genuine surprise despite thousands of green tests. After it existed, every
   subsequent feature had an explicit usable-bar acceptance criterion. This is the single highest-
   leverage PROCESS artifact this dimension produced (`FEATURE_INVENTORY.md` self-description;
   carry-forward "DISTILL + PORT" in `d-docs-root-1of2.md`).
2b. **Self-contained gap tickets** (CONTEXT/FILES/BUILD/VALIDATE/DONE-WHEN) under the TSK-1411
   umbrella let 43 usability children be picked up by fresh subagents with no re-discovery cost —
   directly reusable ticket template (`FEATURE_INVENTORY.md` "Gap-ticket hierarchy").
3. **Immutable-base + replayable-ops for image/audio** (`src-core-media-terminal.md`, "crown
   jewel") proves engine quality and usability are orthogonal — worth preserving the pattern even
   though the feature itself never got a usable front end; the win is architectural, not that
   specific feature's ship status.
4. **Canvas build-phase discipline once scoped** (Rust-first engine, design-doc-locked, milestone×
   slice M0–M6, "shipped cleanly", `summaries/commits/INDEX.md` big-rework-arcs) shows that a
   well-bounded feature-type epic executes fine — the failure mode was entirely in the *unbounded
   research* phase before scoping (see below), not the build.

## What hurt — costly failures, with root-cause mechanism

1. **"Consumption ≠ completion" — the single most costly systemic mechanism in this dimension.**
   Root cause: the migration/feature lifecycle silently conflated four distinct stages (engine
   ported → FFI wired → gate flipped/A-B tested → **view actually calls it**) into one "shipped"
   bucket. A ticket, a CHANGELOG entry, and a green test suite can all be true while stage 4 never
   happened. This isn't a testing gap (logic tests genuinely passed) — it's a **lifecycle-
   modeling gap**: "done" had no stage that specifically asserted a UI caller exists. Formula
   engine is the fullest documented case (`d-docs-root-2of2.md` lines 44, 279-280). Mechanism, not
   symptom: nothing in the ticket schema *required naming the consuming view* as an acceptance
   criterion, so an agent (or the owner) could mark it done from FFI-level evidence alone.
2. **Unbounded exploratory fanout before scope exists, for a genuinely novel feature type.** Canvas
   (a feature type with no established precedent to copy) triggered ~75 parallel design-spike
   agents before any milestone/slice plan existed — "~half a session's quota"
   (`summaries/commits/INDEX.md`, c-17). Root cause: research fanout was sized to the feature's
   *ambition* (agent-incremental-UI-authoring is genuinely hard to scope) rather than gated by a
   cheap sequential spike-first pass. Once M0–M6 slicing existed, the fanout collapsed and the
   build was clean — meaning the fanout itself, not the feature's difficulty, was the waste.
3. **The gap between "deepest engineering investment" and "usability" is systematically
   INVERTED, not incidental.** MicroApps (image/audio/spreadsheet/SQLite) and agent-centric
   surfaces (review/walkthroughs/git panel) — the two families that got the MOST architectural
   care (crown-jewel image/audio design; extensive review state-machine/ULID design in
   `src-core-sessions-review-plugins.md`) — are exactly the families graded most heavily ✖ usable.
   Mechanism: engineering effort was allocated to what was interesting/hard to build (immutable-
   ops architecture, review anchor model) rather than to closing the last-mile interaction loop
   (empty states, progress, click-to-line, resolve flow), because nothing in the workflow scored
   "closes the loop" as separately valuable from "engine is correct."
4. **Breadth-over-depth accumulation with no periodic usability check for 7 weeks.** ~30 feature
   families were opened across 8 weeks before the first Built/Logic/Usable audit
   (2026-07-02) — by then most had the identical shape (strong logic, alert-box or blank-screen
   UX). Root cause: the autonomous/board-driven loop's definition of "done" (headless-gate-green +
   `task_validate`) never included a usability gate, so the loop had no signal telling it to stop
   opening families and finish existing ones — an incentive-shape problem, not a diligence one
   (`FEATURE_INVENTORY.md` intro; `d-docs-root-1of2.md` Theme-3 "breadth over depth (~30 features,
   many spikes)").
5. **Eight identical usability defects recurring across every unusable feature** (results-in-
   modal-alerts, no empty states, no progress/error surfacing, poor discoverability, surface
   overlap, felt latency, unfinished core loop, on-screen-verification debt) — root cause is that
   these are cross-cutting UI infrastructure (one results-panel component, one empty-state
   pattern) that was never built as shared plumbing; each feature reinvented (or omitted) its own
   ad-hoc handling. This is a sequencing failure: infra-for-UX should have been built once, early,
   and required by every subsequent feature — instead it's now a 5-ticket retrofit
   (TSK-1434/1435/1436/1437/1449) applied across ~30 already-shipped families.

## Design implications for the rebuild

**From day one:**
- **Model "consumption" as an explicit lifecycle stage, not an inference from FFI-complete.**
  Every feature/engine ticket names its consuming view/route at creation time; "done" requires
  a passing UI-level test that actually calls the code path, not just a wired FFI method + a
  parity test. Adopt the RUST_MIGRATION_ROADMAP 5-stage model as the literal ticket template
  (engine → FFI → **consumption** → gate → bake-in) — `d-docs-root-2of2.md` line 380.
- **Build the shared UX plumbing (results panel, empty-state component, progress/error toast,
  keyboard-shortcut registry) BEFORE the third feature that needs it, not as a 43-ticket retrofit
  after 30 features exist.** Treat "does this feature use the shared results panel / empty state /
  progress pattern" as a review-gate item on every feature PR from the start.
- **Run a lightweight Built/Logic/Usable grading at the END of every feature, not after 7 weeks of
  accumulation.** A feature isn't "shipped" until it clears all three columns, not two.
- **For genuinely novel, unprecedented feature types (a Canvas-shaped ask): mandate a bounded,
   SEQUENTIAL spike (one agent, capped effort) that produces a milestone/slice plan BEFORE any
   parallel fanout is authorized.** Fanout is for executing an existing plan, never for
   discovering one.
- **Sequence feature types by how directly they serve the owner's stated top-1 differentiator, not
  by engineering interest.** The agent-centric surfaces (review, reverse-review/walkthrough, git
  integration) were the OWNER'S explicit headline ask and ended up the least usable tier of the
  project — invert that: build the differentiator's last-mile UX loop first, and treat "engine
  exists, it's architecturally elegant" as necessary but explicitly NOT sufficient signal to move
  on to the next feature.

**Accept as inherent cost (don't over-engineer against):**
- Engine-first buildout will always outpace UI polish somewhat — the sans-IO core pattern makes
  this efficient (the formula engine wasn't WASTED work, it's real and reusable once a view calls
  it). The fix is catching the gap with a lifecycle-stage discipline, not preventing engines from
  ever outrunning views.
- Some finish-or-cut decisions (RichText, browser, notebook, log-patterns, Canvas continuation)
  are genuinely product calls that can't be resolved by process — budget for periodic owner
  triage sessions rather than trying to design them away.

## Portable rules

1. **A feature is not "done" until a UI/route/CLI caller actually invokes it — name the consumer
   in the ticket at creation, and require a test that exercises that call path before closing.**
   (the consumption-≠-completion fix, `d-docs-root-2of2.md`)
2. **Run a 3-column Built / Logic-verified / Usable audit per feature at ship time, not as a
   7-week-deferred sweep.** Usable = a first-time user can discover, drive, and get value with no
   agent/owner hand-holding.
3. **Build shared UX infrastructure (results panel, empty state, progress/error surfacing,
   shortcut registry) before the third feature needs it — require its use as a PR-review gate.**
4. **For a genuinely novel feature type, cap exploratory research to a single bounded sequential
   spike before authorizing any parallel agent fanout.** Fanout executes plans; it doesn't safely
   discover them.
5. **Weight feature sequencing by how directly a feature serves the product's stated #1
   differentiator, not by which subsystem is most interesting to engineer.** Verify this by
   grading the differentiator features first at ship time, not last.
6. **Ship a `find_unwired(symbol)` / dead-caller-detection tool early** — this project explicitly
   flagged its absence as a repeated cost (`AGENT_PRODUCTIVITY_FEEDBACK_2026-06-20.md` via
   `d-docs-root-1of2.md`); it directly prevents both the consumption gap and the discoverability
   gap.
7. **Treat "engine is architecturally excellent" as a yellow flag for scrutiny, not a green
   light** — this project's two most over-engineered subsystems (image/audio ops, review state
   machine) were also its least usable; ask "what's the last-mile UI loop" whenever a design
   review gets excited about the engine.
8. **Keep a standing finish-or-cut queue for scoped-but-unfinished feature types** (RichText,
   browser, notebook-style viewers) and resolve it on a cadence — don't let partial features
   accumulate silently for weeks while new families keep opening.
