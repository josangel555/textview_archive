# Canvas · 06 — Milestones, validations, and UAT scripts

> How the epic is built and **proven**. Each milestone = a board ticket under TSK-1342, lands
> independently, gate-green, with its validation ladder run and its UAT executable before the
> milestone closes. UATs below are authored NOW as acceptance criteria (run-uat style journeys);
> they become the durable smoke catalog entries when each milestone ships.
> ⛔ **No milestone starts until the owner answers the Q-list** (`05-ROADMAP.md`) — minimally
> Q11 (engine placement), Q4 (zero-dep), Q2 (format), Q1 (first mode).

## Build approach (how, concretely)

Risk-first, inline, one slice at a time (house SOP): **M0 proves the two riskiest unknowns**
(core↔WebView patch loop over binary FFI; op→paint latency) *before* any schema freeze. Then
the engine grows bottom-up (M1 core → M2 agent surface → M3 WYSIWYG → M4 design system →
M5 first mode), each milestone shipping something usable and independently validated. Rust
work runs on the host (cargo gate; VM has no Rust toolchain — existing host-built
`libmdvcore_ffi.a` rsync flow); render work builds AND validates on the VM (webview / T5 / T6
lanes). Every render guard demonstrates teeth (negative-control switch) before it's trusted.

## Validation ladder (applies to every milestone)

1. `cargo` gate — canvas-core unit + **proptest invariants** + fence **fuzz** (host).
2. `swift build` + host headless gate — bridge envelope, Codable mirrors, MCP tools over fake
   host, persistence (host, window-free).
3. Webview lane (`MDV_RUN_WEBVIEW_TESTS=1`, VM) — patch applier, measurement, player.
4. T5 pixel (VM, GUI lane) — visibility/interaction pixels, each with `MDVNegativeControl`.
5. T6 UAT (VM, run-uat) — the journey scripts below, driven via the `canvas` script-verb group.

---

## M0 — Risk spike: the patch loop lives (P0)

**Scope:** minimal `canvas.html` + applier; hardcoded record set in a canvas-core skeleton;
op → binary FFI → patch plan → DOM patch → geometry query returns; warm-cache park/re-attach;
PerfSignpost on op→paint.

**Exit validations:**
- E2E: `update(text)` op mutates exactly one DOM node (no reload; webview-lane assert on
  `data-cv-id`).
- Perf: op→paint p50 < 16ms, p95 < 50ms on a 200-node doc (measured, recorded in the ticket).
- Park/re-attach: tab switch away/back preserves DOM + runtime state (TSK-1046 class).
- Kill criterion (explicit): if the patch loop can't hit budget, STOP and redesign the
  boundary before M1 — that's the point of the spike.

**UAT-M0 (smoke, agent-driven):** *not user-facing; validation IS the UAT here.*

## M1 — Document core: a real `.canvas` document (P1)

**Scope:** canvas-core crate — records/`place`/fractional index; type schemas + defaults +
fence; ops + inverses + revisions; migrations skeleton; DTCG token store; static lint v1;
deterministic lowering + patch plans; `hole` + `embed`; canonical `.canvas` I/O; `source`
ViewMode (JSON in CM6).

**Exit validations:**
- proptest: `apply∘inverse = id` · idempotent supplied-ID inserts · fence atomicity (a bad op
  in a batch applies nothing) · order stable under insert/move storms · lowering
  byte-deterministic. Fuzz: op batches + document files (no panics, typed errors only).
- Golden lowering fixtures (doc → HTML text snapshots).
- Migration: a v0 fixture file loads, migrates, re-saves canonically.
- Host: open/save/autosave/hot-exit; `source` mode shows canonical JSON; git diff of an edit
  touches only the edited records (diffability proof).

**UAT-M1 "the document survives everything" (T6):**
1. Create `demo.canvas` via a fixture; open in app → renders (static preview).
2. Switch to `source` ViewMode → canonical JSON visible; edit a `text` prop in CM6; save →
   canvas view reflects it (round-trip through the fence).
3. Quit + relaunch → document restores in session, same content.
4. Corrupt one record in the file externally → open shows a typed load error naming the
   record (fail-loud, no crash, no silent drop).

## M2 — Agent surface: an agent builds a page end-to-end (P2) ← first payoff

**Scope:** MCP `canvas_create/open/list/apply/query/lint/events/export(HTML)` + script-verb
group `canvas` + `textview://canvas`; compact query wire form; plan-then-emit guidance;
audit trail + "agent editing" tab indicator.

**Exit validations:**
- MCP tools green over fake `AutomationHost` (host gate); path-jail + caps rejections typed.
- `apply` returns `{rev, staticLint[]}`; stale `baseRev` returns the structured conflict.
- Export: standalone HTML is self-contained (zero network fetches — assert no external URLs).

**UAT-M2 "agent builds a status page" (T6, fully scripted — the epic's first demo):**
1. Via verbs: `canvas.create` → `canvas.apply` (title, a 3-card `row`, one `hole`) →
   `canvas.query` returns ids/types + resolved boxes; **assert the 3 cards' x-coordinates are
   monotonically increasing and non-overlapping** (flow guarantee, no pixels needed).
2. `canvas.lint` → reports the `hole` + a deliberately-inserted raw hex literal (token nag).
3. Fix both via `canvas.apply`; lint returns clean.
4. `canvas.export` → open the HTML in the app's HTML viewer → title + 3 cards render.
5. Teeth: run once with `MDV_ENABLE_BROKEN_CANVAS_APPLY=1` (fence bypass stub) → UAT must go RED.

## M3 — WYSIWYG: the human is a peer (P3)

**Scope:** selection/handles/drag/resize/inline text → ops; snap/guides; native inspector +
layers + palette; shared undo with author labels; rev-conflict + locks.

**Exit validations:**
- Webview lane: drag emits a `move`/`update` op through the fence (assert op log, not DOM).
- T5 + negative controls: handles visible; drag moves pixels; inspector-over-WebView occlusion
  (`compositingGroup().zIndex(1)` guard demonstrably RED when broken).
- Host: undo stack interleaves human/agent batches correctly (labels preserved).

**UAT-M3 "co-editing" (T6, the co-edit demo from the success criteria):**
1. Agent builds the M2 page. Human drags card 2 to position 3; types into the title inline.
2. `canvas.events` shows the two human ops with author=human; agent `query` sees new order.
3. Agent applies a styling op against the *old* rev → gets the structured conflict → re-queries
   → retries → succeeds (the read-modify-write loop proven).
4. ⌘Z twice → both human edits revert; agent's styling survives (batch-scoped undo).
5. Human locks the title node; agent op against it is rejected with the lock reason.

## M4 — Design system + data: kits and live data (P4)

**Scope:** components/instances + report & KPI kits; `table`/`chart`(VL-subset)/`code`/
`diagram` nodes; data blocks + `bind` + `conditional`/`repeat`; measured lint; CSV-engine +
FileWatcher feeds.

**Exit validations:**
- cargo: component def-update re-expands instances as ONE invertible op; binding resolution;
  `repeat` over a data block produces N instances with stable derived ids.
- Webview: chart SVG marks match data fixture (bar heights ∝ values); measured lint flags a
  deliberate overflow; contrast check flags a deliberate low-contrast token pair.
- **The Claude-Design gauntlet (epic kill-switch — see 05-ROADMAP §Q1-rationale):** agent
  replicates a real marketing landing page, a settings screen, and a dashboard shell through
  the escape-hatch ladder. Measure: styling rung distribution (L0/L1/L2 vs L3/L4), op/token
  cost per design, lint noise. **Pivot criterion: >~30% of styling pressure escaping to
  embed/code-components ⇒ redesign the ladder before M5 ships.**

**UAT-M4 "live infographic" (T6):**
1. Agent creates an infographic bound to `perf.csv` (3 KPI tiles via `repeat` + a bar chart).
2. Append a row to `perf.csv` on disk → within the watcher tick, the canvas shows a 4th tile
   and the chart re-renders (assert via query + webview DOM count).
3. Swap theme dark↔light → tiles/chart recolor via tokens; **zero document ops in the event
   log** (proves value-swap theming).
4. Export PNG → non-empty, size-capped.

## M5 — UI-Design mode, Tier 1: the assumption validator (P5)

**Scope (owner criterion Q1 — validate assumptions earliest):** UI component kit
(buttons/inputs/nav/cards/forms), device-frame presets, prototype navigation + interactions,
shared style rules (ladder L2 — `:hover`, breakpoint variants). **No code export** (later
tier, Q10). The Claude-Design gauntlet (M4) is the entry bar; this milestone productizes it.

**Exit validations:**
- cargo: shared-style-rule resolution (one rule edit restyles all referents as one invertible
  op); breakpoint-variant lowering deterministic.
- Webview: prototype navigation (`gotoPage` on click) works; `:hover` rule applies; a
  breakpoint variant switches at the device-frame width.
- T5 + negative control: hover styling actually renders; device-frame chrome not occluded.
- Gauntlet re-run on the productized kit: rung distribution within the pivot criterion.

**UAT-M5 "design a real app screen" (T6 — the assumption demo):**
1. Agent builds a settings screen from the kit (nav sidebar, form sections, toggles, save bar)
   via DSL ops — **zero raw HTML** — inside a phone AND a desktop device frame.
2. Query proves the same document renders both frames (breakpoint variants, not duplicates).
3. Human drags a form section to reorder; agent adds a field to it afterward (co-edit on real
   UI content).
4. Wire "Save" → `gotoPage(confirmation)`; click in preview navigates (clickable prototype).
5. One deliberately-exotic styling ask ("frosted-glass header") lands at ladder L1/L2 (raw-CSS
   passthrough / shared rule), is lint-flagged but renders — and the node stays
   addressable/editable afterward (the model-owned invariant proven).
6. Teeth: negative-control switch breaks hover-rule application → T5/UAT goes RED.

## M6 — Presentation: the first content mode (P6)

**Scope:** `kind:deck`; steps/fragments; timing tree + beats; **identity-morph**; player;
`timeline_state`; presenter window; deck export (standalone player + PDF); walkthrough verbs.

**Exit validations:**
- cargo: morph plan = exact set-diff partition (matched/enter/leave) on fixture pairs;
  `morphKey` forces a cross-node match; `timeline_state(step)` truth-table green.
- Webview: fragment stepping toggles visibility in DOM order; FLIP transforms applied and
  removed cleanly; exported player navigates via keyboard.
- T5 + negative control: a fragment past its reveal index is genuinely invisible ON SCREEN
  (the render-tail proof).

**UAT-M6 "the deck journey" (T6 — the release demo):**
1. Agent builds a 3-slide deck: slide 1 title; slide 2 = same title node id smaller +
  3 bullets as fragments; slide 3 = a chart whose `morphKey` matches slide 2's third bullet.
2. `canvas.timeline_state(slide2, step1)` → bullet 1 visible, 2–3 not (declarative check
   BEFORE pixels).
3. Play: arrows step fragments; slide 1→2 morphs the title (same id — no fade); 2→3 morphs
   bullet→chart (via `morphKey`); everything else fades (partition semantics).
4. Presenter window: current+next+notes+timer; main display follows.
5. Export standalone HTML → open in the HTML viewer → keyboard nav + fragments + morphs work
   offline (no network).
6. PDF export → 3 pages, fragments flattened to final state.

## M7+ — Tracks (umbrella; sequenced by owner priority after M6)

Code-export tier (Q10) → live dashboards → markdown inline figures → `kind:board` →
state-machine INTERACT → plugin kits. Each gets its own milestone doc + UAT when scheduled.
