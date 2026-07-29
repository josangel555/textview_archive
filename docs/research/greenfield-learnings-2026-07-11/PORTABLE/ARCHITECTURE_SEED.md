# Architecture Seed — founding architecture doc

Copy this into the new repo on day 1 as `ARCHITECTURE.md` (or fold into `CLAUDE.md`). It is the
distilled architecture verdict from an 8-week, 3,733-commit prior build of a similar app (native
shell + Rust core + WebView-hosted rich content, agent-centric). Every claim below is evidence-
backed by that project's own post-mortems; the prior project's own name and paths are stripped —
only load-bearing facts survive, tagged `(learned: ...)` where a one-line pointer helps. Treat
this as the **founding decision set**, not background reading — the thesis of the source analysis
is that the prior architecture was mostly *right* and its *sequencing* was mostly *wrong*: nearly
every expensive rework arc was a correct decision reached in week 4–8 that was knowable in week 1.
Start this project at that end-state.

---

## 0. Product framing this doc assumes

- Native desktop shell (thin — chrome only: windows, menus, tab strips, palettes, sheets).
- A sans-IO, deterministic core in a systems language, designed to serve multiple front-ends
  (native shell, WebUI, TUI, and eventually a remote daemon over TCP/WS) from one protocol.
- A CodeMirror-class editor (or equivalent) hosted in a WebView — not a native text-view widget —
  because the native text-widget ecosystems for this problem are generally inferior once you need
  a real LSP/tree-sitter/vim-mode ecosystem (learned: a documented head-to-head comparison held for
  the entire life of the prior project; re-run your own comparison once, then stop re-litigating
  it).
- A plugin/MicroApp system where each MicroApp is a document type + a WebView renderer.
- Agent-centric: the app is built to be operated *by* and *observed by* an AI agent, not just a
  human — this shapes the protocol, the automation surface, and the security model from commit #1.
- A coupled project/task-tracking app that will store and enforce the evidence-class schema this
  doc defines (see §9).

If your product framing differs, the keep/change/avoid table still mostly applies — the layer
diagram and boundary contracts are the parts most coupled to "native shell + Rust core + WebView
content."

---

## 1. Keep / Change / Avoid — at a glance

| # | Decision | Verdict | One-line why |
|---|---|---|---|
| K1 | CM6-class editor hosted in a WebView, not a native text widget | **Keep** | LSP/tree-sitter/vim ecosystems are web-native; native text-widget frameworks (TextKit2-class) had independently-confirmed bugs (learned: 4 named engineers, cross-checked) |
| K2 | One highlight/find/fold/scroll/cache producer, N thin per-surface render adapters | **Keep** | The only instance of this pattern done right in the prior project — proof by counter-example (see C1) |
| K3 | Sans-IO, deterministic core (no clock/RNG/IO/panics; effects returned as data; caller-supplied `now`) | **Keep** | Purity → host-testability → agent-verifiable → agent velocity is the causal chain that made an autonomous agent loop viable at all |
| K4 | Interactive read path synchronous & in-process; async only at coarse seams (LSP, remote, subprocess) | **Keep** | The xi-editor lesson: "async is a complexity multiplier" — most-cited external validation in the whole corpus |
| K5 | Compiler-enforced 3-layer boundary (pure-values → logic-no-UI-imports → UI) | **Keep** | Single most important design decision in the prior project by its own account; ~80% of behavior ended up headlessly testable *because it physically could not import UI frameworks* |
| K6 | Thin-waist versioned wire envelope: one dispatch table by stable method id, forward-compat maps, ABI/capability negotiation | **Keep** | What makes "same core, N frontends, remote later" real, not aspirational |
| K7 | Engine-port ladder: pure fn → wire seam → shim → gated adapter (default-OFF) → parity corpus → soak → delete old twin (keep the seam) | **Keep** | 8/9 migrations, zero reverts, 5 silent parity bugs caught pre-ship in the prior project |
| K8 | Tier-as-type test architecture with runtime-enforced tier membership (heavy tiers self-skip outside their real environment) | **Keep** | Rated "single highest-ROI thing to transplant" by the prior project's own aspect analysis |
| K9 | Curated high-level protocol for automation/agent access (never the raw internal model) | **Keep** | Survived a 40-slice internal refactor with zero automation-surface breakage |
| K10 | DSL-first, agent-primary authoring for any agent-built-UI surface (a "Canvas" feature) | **Keep** | Measured 80%+ agent task-executability vs 2–11% for a raw-coordinate baseline — the strongest single validation in the corpus |
| K11 | Immutable-base + replayable-ops document model for anything with undo/history/agent-visible-diffing needs | **Keep** | Cheap dirty tracking, deterministic render, trivial undo, and the natural substrate for "agent can see what changed" |
| K12 | Dependency discipline: exact pins, minimal feature sets, no runtime dependency acquisition, dual size-cap ratchets | **Keep** | Kept the shipped binary lean and reproducible for the whole project life |
| K13 | Env-gated, zero-cost-when-off perf instrumentation with absolute (not ratio) per-interaction budgets | **Keep** | No recorded case in the whole corpus of intuition beating measurement |
| K14 | Evidence-artifact validation culture: a "done" claim is a pointer to a repeatable artifact, not a sentence | **Keep** | The connective tissue between the app's test harness and the companion tracker app |
| C1 | Module boundary drawn by *rendering technology* (native-vs-web) | **Change → draw by capability ownership** | Produced 5 duplicate find engines, 3 scroll-persistence channels, 2 highlight engines, 2 fold engines, 2 WebView caches — all within one native/web split |
| C2 | God-object coordinators (single `ObservableObject`/store absorbing a whole layer's state) | **Change → per-domain coordinators from commit 1, budget-tested** | One grew to 2,377 LOC / 71 published properties / 107 methods before anyone noticed; file-level extraction alone doesn't fix it — object-level (observation-surface) partitioning does |
| C3 | Wire boundary designed *after* the in-process model existed | **Change → contract-first, adversarial pre-freeze review** | A dedicated hardening pass caught 29 risks just before freeze, incl. classic one-way doors (see §4) — the project got lucky the pass ran in time; don't rely on luck |
| C4 | Trust/capability model accreted per-tool as the automation surface grew | **Change → capability-on-the-effect from tool #1** | Ended with an always-on unauthenticated socket, a jail some tools bypassed, no audit log |
| C5 | Feature "done" asserted by the author | **Change → evidence-derived status with a consumption gate** | The only P0-class findings in a later audit were dead, unwired feature tails reported as complete |
| C6 | Test-tier investment grew reactively | **Change → per-surface real-render minimum, cheap-path-first** | Ended 81% headless / 1.4% pixel while the costliest bug class lived exactly where only pixel tests can see it |
| C7 | Full-document-reload-per-render for WebView content | **Change → persistent surface + diff/patch is the default from surface #1** | A foreseeable reload-storm perf bug took ~40 days to fix because the fix required new architecture built after the fact |
| C8 | Data-safety (debounce flush, write-result handling) enforced by audit | **Change → by construction**: typed `Result` writes, flush-on-teardown hooks shipped in the same commit as any debounce | One mechanism (an unflushed boundary) produced ~8 separate P1 bugs |
| C9 | Docs as the primary substrate for tracking state/decisions | **Change → tracker-as-substrate**, docs fold into code commits | 36.5% of all commits were doc-only; a large share of agent tool-errors were "the doc says something the code doesn't" |
| C10 | Supply-chain/ship-path hygiene built but never wired to a schedule | **Change → every scanner/lane has a named executor (cron/CI) from week 1, and is rehearsed before feature 2** | Advisories accrued ~11 months unactioned; notarization was never once run in the whole project life |
| C11 | Native core linked as a raw static/dynamic library | **Change → link it as a proper tracked build artifact (e.g. an xcframework binaryTarget)** | Closed a whole class of stale-relink/enum-layout crashes that looked exactly like FFI bugs |
| A1 | Trusting `ImageRenderer`/`cacheDisplay`/in-tree-membership as proof of on-screen rendering | **Avoid entirely** | All are structurally blind to real compositor occlusion — false green by construction |
| A2 | `screencapture -x` (full-screen) as a render-proof mechanism | **Avoid** | Doesn't composite app-window content; use window-ID capture only |
| A3 | Any discardable `Bool`/ignored `Result` on a persistence write path | **Avoid** | Root cause of the silent-fail data-loss cluster |
| A4 | Raw POSIX fd reads/writes on a handle another thread can close; unbounded recursive-descent parsing on untrusted input | **Avoid** | Uncatchable native aborts — stack-overflow aborts can't be caught by any exception mechanism |
| A5 | Patching a timing/async bug stage-by-stage | **Avoid** | After 2 failed patches, collapse the chain to one pull-based source of truth instead |
| A6 | Two live, contradictory architecture docs with neither marked superseded | **Avoid** | Mark SUPERSEDED at the moment of decision, same commit |
| A7 | Unbounded exploratory agent fan-out | **Avoid** | One runaway spawned ~75 agents from a 3-agent delegation; hard-cap exploration, full fan-out only against a locked design |
| A8 | UTF-16/NSRange (or any platform-string-index unit) on any wire; bare `String` as wire "content" | **Avoid** | The single most expensive one-way door to retrofit if missed |

---

## 2. Layer diagram

```
┌───────────────────────────────────────────────────────────────────────────┐
│ FRONT-ENDS (thin, replaceable)                                            │
│  Native shell            WebUI            TUI              remote client  │
│  ├ native: app chrome only — windows, menus, tab strips, palettes, sheets │
│  └ web: ALL rich content — code editor, markdown, diff, spreadsheet/CSV,  │
│    PDF, image, DB viewer, Canvas (persistent WebViews, patch-not-reload)  │
├───────────────────────────────────────────────────────────────────────────┤
│ SURFACE ADAPTERS (per-frontend, thin, stateless)                          │
│  editor bridge │ MicroApp host │ Canvas host │ terminal │ automation layer│
│  each adapter = render + input forwarding; ZERO capability logic here     │
├──────────────────────────── THE THIN WAIST ───────────────────────────────┤
│ CORE PROTOCOL — versioned Command / Query / Event envelope                │
│  compact binary named-field maps · stable method ids · capability bitmap ·│
│  ABI skew guard · reserved: ver, clientSeq, siteId, corrId ·              │
│  positions = UTF-8 byte offsets · content = (bytes, encoding, eol) ·      │
│  level-triggered subscriptions (state-of-X, not delta-Y)                  │
│  transports: in-process FFI (sync fast path) │ unix socket │ TCP/WS       │
│  agent gate: capability-on-effect · conn token · audit log · identity     │
├───────────────────────────────────────────────────────────────────────────┤
│ CORE  (sans-IO, deterministic, unsafe forbidden outside the ffi crate)    │
│  document store (rope; (bytes,encoding,eol); op-log; content-based dirty) │
│  sessions/tabs domain model · single capability owners:                  │
│    find │ scroll-state │ fold │ syntax-highlight │ index/cache           │
│  engines: markdown │ diff │ csv │ hex │ fuzzy │ formula │ canvas-doc      │
│  large-file pager (windowed snapshots) · undo/redo (replayable ops)      │
├───────────────────────────────────────────────────────────────────────────┤
│ HOST PORTS (injected at core init; side effects live here, per host)     │
│  read/write fs │ watch │ subprocess │ clock │ rng                        │
└───────────────────────────────────────────────────────────────────────────┘
   beside the core, coarse async seams (never per-keystroke):
   LSP actor pool · git subprocess layer · terminal PTYs · remote daemon
```

Rationale for each layer, in one line:
- **Front-ends thin & replaceable**: the core owns behavior; a front-end owns rendering + input
  translation only. This is what makes "add a TUI" or "add remote" additive instead of a rewrite.
- **Surface adapters carry zero capability logic**: if an adapter needs to know "how does find
  work," the boundary is drawn wrong — push it into the core's single find owner.
- **Thin waist**: exactly one serialization/dispatch mechanism for everything crossing the
  process/language boundary, forward-compatible by construction (see §4).
- **Core is sans-IO**: this is not a style preference — it is the mechanism that makes the whole
  core host-testable and agent-verifiable without a GUI, a network, or a clock.
- **Host ports**: the *only* place real side effects happen; injected, never reached-into from
  inside the core.

---

## 3. Module/package boundary (compiler-enforced, not convention-enforced)

Three layers, each a distinct compilation unit:

1. **Values/Kit** — pure data types, zero framework imports. Shared vocabulary (spans, positions,
   IDs, error types).
2. **Core/logic** — all behavior, orchestration, state machines. **Zero UI-framework imports** —
   this is the rule with teeth. A CI import-grep (or equivalent static gate) fails the build if
   this layer imports a UI framework.
3. **UI** — may import both of the above plus the platform UI framework. This is the only layer
   allowed to know about windows, views, gestures.

Why this is worth doing as a *compiler-enforced* rule rather than a review convention: the prior
project's own account is that this was "the single most important design decision" it made, and it
independently produced ~80% headless testability *because a whole class of code physically could
not import AppKit/SwiftUI* — not because engineers remembered to keep it clean.

**Add on day 1** (the prior project didn't have this and paid for it): a CI gate that greps for
forbidden imports across the Core layer on every PR, not just a lint that can be silenced.

---

## 4. Boundary contract: UI ↔ Core

One serializable **Command / Query / Event** envelope, duplex from day 1 (a request/response-only
protocol that silently drops server-initiated notifications was the prior project's #1 boundary
gap). Two transport instantiations of the *same* contract:
- **In-process synchronous fast path** for the local shell (the xi lesson — never make the
  interactive read path async just because the transport eventually needs to be one).
- **Socket / TCP / WS** for remote — a transport swap, not an API change.

**Non-negotiable envelope fields, reserved before anything freezes** (this is the checklist a
14-agent adversarial pass produced *after* the prior project's core was already partially built —
do the pass before you build, not after):
- `version` (protocol/schema version, with an `unknown(...)` fallback path for open-tagged enums)
- `clientSeq` (per-client monotonic sequence — needed the moment you have >1 writer or a
  reconnect story)
- `siteId` (identifies the writer/session — needed for any future multi-writer story even if v1
  is single-writer)
- `correlationId` (request/response pairing over an async transport)
- **Positions are UTF-8 byte offsets** — never UTF-16 code units, never a platform-native
  "NSRange"-style unit. (learned: "LSP's most-regretted decision" was about to be repeated
  verbatim in the prior project; catch it before any position type ships.)
- **Content is `(bytes, encoding, eol)`**, never a bare `String`. A bare string on the wire
  silently corrupts non-UTF-8 or non-LF-terminated files on save.
- Every enum on the wire is open-tagged with an explicit `unknown(...)` variant, so an older
  client talking to a newer server degrades instead of failing to parse.

**Subscriptions are level-triggered** ("give me the current state of X, and tell me when it
changes"), not delta-only — deltas alone are how you lose sync on a dropped message.

**Single-writer-per-session** is what keeps an optimistic-local client tractable without
CRDT/OT-level complexity. If you want real multi-writer collaboration, decide that *now* — it
changes the op-log from "undo substrate" into "convergence substrate," and `siteId`/`clientSeq`
alone won't be enough.

**Freeze gate**: hold the wire contract as a draft until it has been through one adversarial
one-way-door review pass against this exact checklist. The prior project's core was retrofitted
about 2 weeks into a Swift-only prototype; the review caught 29 risks (19 of them one-way doors)
just before freeze — evidence the review works, not evidence you can skip it if you're careful.

**Codec choice**: prefer a self-describing, named-field binary format (e.g. MessagePack with named
maps, not positional arrays) with explicit unknown-key tolerance — generic serialization libraries
typically don't give you graceful forward-compat for free; you may need a thin hand-rolled codec
layer specifically for the unknown-key-tolerance property. Pin the wire format decision with a
measured comparison (the prior project reversed an earlier pick after benchmarking) rather than
picking on convention.

**ABI/version-skew guard**: a capability bitmap advertised per-connection, with every bit
explicitly asserted on both sides in tests; a "hello" handshake that hard-closes on version
mismatch; a graceful handover mechanism for a newer client talking to a stale daemon (e.g. "please
retire and let a newer instance take over").

---

## 5. Boundary contract: capability ownership (the single costliest mistake to repeat)

**The mistake**: drawing the native/web (or any dual-stack) module boundary along *rendering
technology* instead of *capability ownership*. In the prior project this produced, within one
app: five separate find-in-file implementations behind four different state bags, three different
scroll-position-persistence channels with three different keying schemes (five separate bug
tickets filed against what was, underneath, the same user complaint), two independent syntax-
highlight engines that classified tokens differently, two fold-region engines, two warm-WebView
caches — all because "which surface renders this" and "who owns this cross-cutting behavior" were
conflated.

**The fix, proven in the same codebase**: syntax highlighting was done correctly from early on —
one pure-data highlight-span producer, consumed by *both* the native-rendered surface and the
HTML/WebView-rendered surface as thin adapters. Same source of truth, two dumb consumers. That is
the template for every cross-cutting capability.

**The rule for this project**: before building a second surface (native or web) that needs
find / scroll-state / fold / syntax-highlight / cache / undo-history / any other cross-cutting
capability, name the ONE owner (in the core, not in either front-end) and give every surface a
thin, stateless adapter. Audit quarterly for "N implementations of the same capability" — this is
a grep-able smell (multiple modules independently implementing string search, multiple modules
independently tracking "where was the user scrolled").

**Decide the web-vs-native split as a written Day-1 policy, not an emergent one.** Given the
product framing in §0 (a WebView-hosted editor plus many WebView-hosted MicroApps: image editor,
markdown, PDF, spreadsheet, DB viewer, Canvas), the evidence leans toward: **web is the only path
for rich/text/document content; native is app chrome only** (window management, menus, tab strip,
command palette, sheets/dialogs). This is exactly where the prior project's own policy landed
— after 8 weeks of paying the duplication tax to get there. Write the policy down as one doc, and
the moment any later decision supersedes it, mark the old doc **SUPERSEDED** at the top in the same
commit — the prior project shipped two live, contradictory architecture docs simultaneously with
nothing telling a future reader (human or agent) which one was current.

---

## 6. Boundary contract: Plugin / MicroApp

A MicroApp = three parts:

1. **A document model in the core** — immutable base + replayable ops (see §8). This is not
   optional scaffolding; it is what gives you undo/redo, crash recovery, and agent-visible history
   for free, and it is the substrate the Canvas feature (§7) also depends on.
2. **A WebView renderer** speaking a versioned envelope (the same thin-waist protocol from §4,
   scoped to this MicroApp's methods). Unknown schema/envelope versions fail structured
   (explicit error), never silently.
3. **A manifest** declaring:
   - required capabilities (filesystem scopes, subprocess access, network access) — enforced at
     the same capability gate as the agent protocol (§9), not a separate ad-hoc check
   - its entry in the real-render coverage matrix (§10)
   - its threat-model entry (what untrusted input it parses, what it can cause to happen)

**Sequencing rule**: harden one MicroApp end-to-end (document model → renderer → manifest →
capability entries → real-render tests → threat-model review) before starting a second. Design the
plugin *contract* early (it's cheap to get right once, expensive to retrofit across N plugins), but
populate the plugin system serially.

---

## 7. Boundary contract: the agent-integration protocol

The core design bet for an agent-centric app: **the agent protocol is a view over the same core
protocol**, not a parallel API. Concretely: agent-callable verbs, a human command palette, and any
CLI flags should be generated from *one* catalog of "things this app can be asked to do" — never
three independently hand-maintained vocabularies that drift (the prior project ended with exactly
this drift: a scripting DSL, an agent tool catalog, and an editor-bridge command set that shared
zero code and diverged).

**Enforcement lives on the effect, not on the entry point.** Wrap dangerous capabilities (filesystem
writes outside a sandbox, subprocess execution) in a type that *cannot be constructed* outside the
authorization check — "forgot to check the jail" becomes a compile error, not a runtime bug. The
prior project's actual failure mode: the jail was applied per-tool, so one tool's file-write path
bypassed the very jail another tool's read path enforced. A capability-on-the-effect design makes
that class of bug structurally impossible rather than something a reviewer has to catch.

**Day-1 minimum, all cheap:**
- A connection-level auth token (v1 may auto-grant it — the point is the *protocol slot* exists;
  retrofitting auth into an already-stateless reconnect protocol proved structurally very hard in
  the prior project).
- A persisted, user-viewable audit log of every agent-invoked action.
- Server-identity verification on connect (don't let a local socket be squattable by another
  process).
- One generated catalog enumerating everything an agent can cause to happen (tool calls, verbs,
  UI-automation actions, any core-applied edits) — generated from the core protocol's method
  table, not hand-maintained.

**Agent-consumed artifacts freeze their context at creation** — e.g. a code-review comment should
snapshot the exact content/version it was made against (with staleness detection), so the agent
never has to re-derive "what did this comment originally point at."

**The "non-blackboxy" features** (review-share, code walkthrough, reverse-review) should be
DSL-first documents living in the core, agent-primary and human-editable second — same shape as
everything else in this doc: one owner, thin per-surface renderers.

---

## 8. Document model doctrine: immutable base + replayable ops

For any stateful document (the editor buffer, an image-edit buffer, the Canvas scene graph, a
MicroApp's document): model it as an **immutable base snapshot + an append-only, replayable op
log**, not a mutable in-place structure.

Payoffs, all realized in the prior project:
- Dirty tracking falls out for free (content-based, not a manually-toggled flag).
- Deterministic rendering (replay the ops, get the same result every time).
- Undo/redo is "replay fewer ops," not a parallel undo stack to keep in sync.
- The op log **is** the agent-visibility substrate — an agent (or a human reviewer) can literally
  read "what changed, in order," which is a first-class product requirement for this kind of app.
- Crash recovery: snapshot + ops on disk is a journal; hot-exit / crash-recovery and
  agent-visible history are the *same mechanism*, not two.

This is also the correct shape for the Canvas feature (§ below) — treat Canvas as the flagship
instance of this pattern, not a special case.

---

## 9. Canvas (or: the flagship agent-authored-UI MicroApp)

If the product includes a feature where an agent incrementally builds UI in a live surface rather
than emitting a top-down HTML/JS/CSS dump: this is not a special feature, it is the **proof case**
for the MicroApp contract (§6) and the ops doctrine (§8).

- The document is a diffable, replayable scene-graph, living in the core.
- Agents emit an incremental **DSL** (apply / lint / undo / timeline-style operations), not raw
  markup or raw pixel coordinates. This is the single strongest empirical result in the entire
  prior corpus: a DSL-first, intent-level authoring surface measured **80%+ task executability**
  by an agent, versus **2–11%** for a raw-coordinate baseline on the same tasks. Design the DSL
  grammar *before* the renderer.
- The renderer is a WebView that **patches** the live document, never full-reloads (see §11).
- The "basic components" ask ("provide all basic features, components etc.") is just DSL
  vocabulary — versioned like every other part of the wire protocol, extensible without breaking
  older agent-emitted documents.
- Day-1 hardening this pattern needs that the prior project's Canvas implementation lacked:
  a CSP + navigation policy on the hosting WebView, and its file I/O routed through the exact same
  capability gate as everything else in §7 (the prior project's security audit specifically
  couldn't fully trace Canvas's I/O path because it didn't share the gate).

---

## 10. State-management doctrine

- **Core owns domain state** (documents, content, edit state, VCS status, the session/tab set).
  **Client (each front-end) owns view/ephemeral state** (scroll position, cursor, focus, fold
  state, viewport). This split was *designed* in the prior project and then shipped inverted (view
  fields leaked into a core-owned session snapshot) — so don't just declare it, **enforce it**: a
  schema/contract test that rejects any view-state field appearing in a core-owned snapshot type,
  reviewed at every schema change. "Reconnecting shouldn't move your scroll position" needs to be
  true by construction, not by discipline.
- **Per-domain observable coordinators with narrow published-state surfaces, from the first commit
  that needs more than ~5 pieces of state on one coordinator.** Do not let one object become the
  union of "everything this layer knows." The prior project's canonical god-object grew to
  2,377 LOC / 71 published properties / 107 methods before anyone split it, and — this is the
  important nuance — splitting it into extension *files* did **not** fix the actual problem,
  because a single observable object still fires a whole-object change notification on any one
  property mutation. Splitting into files is file-level SRP; the real fix is object-level SRP
  (separate observable coordinators with their own independent change-notification channels).
  **Budget with teeth**: no coordinator exceeds ~500 LOC or ~15 published properties without a
  mandatory split review — treat this exactly like a byte-budget test on a config file: a red
  budget test blocks merge, bumping the budget is a deliberate decision, not a default.
  Prevention here measured roughly 10x cheaper than the eventual retrofit sprint.
- **Add a "republish invariant" test**: a mutation on one domain coordinator should only fire a
  change notification for that domain, never cascade to unrelated observers. This is the
  regression guard for the god-object class recurring.
- **Pull-based single source of truth for anything a render reads.** The single most recurrent bug
  *mechanism* in the prior project (not just symptom — three separately-named, separately-fixed
  bugs turned out to be the same mechanism) was: imperative state populated *around* a
  session/tab switch, raced by a declarative render that reads stale state. If a value can be read
  declaratively from one owner instead of imperatively seeded around an event, make it so —
  structurally, this removes the race instead of patching one more timing handoff.
- **Every debounce/coalesce ships its flush contract in the same commit.** Any boundary that
  buffers writes (a JS-side debounce before posting to the native side, a batched background
  flush) needs one canonical "flush and read current" entry point, and *every* reader of that
  state must go through it — not just the callers who happen to know the debounce exists. The
  prior project's canonical instance: an editor's JS-side buffer debounced saves 200ms; the
  explicit save paths (Cmd-S, `:w`) correctly flushed first, but every *other* caller reading "the
  current buffer" silently inherited a 200ms staleness window.

---

## 11. Rendering doctrine for WebView-hosted content

- **Persistent WebView surfaces + diff/patch is the default from the first surface**, not an
  optimization added later. Reloading a WebView's full document on every content change is a
  foreseeable perf disaster (the prior project's canonical instance: a 2–9 second reload storm on
  every render, which took roughly 40 days to fix once someone had perf infrastructure in place,
  *because the real fix required new architecture* — a differ producing a patch, applied via a
  small JS bridge function, with a live-DOM-alignment probe to catch drift). If this project plans
  multiple WebView-hosted surfaces (editor, markdown preview, Canvas, PDF, spreadsheet, DB viewer),
  each one is the *same* bug class waiting to happen — build the patch-not-reload primitive once,
  in the core (a block/structural differ), and require every WebView surface to use it.
- **Compositor occlusion is a distinct, invisible-to-most-test-tooling bug class.** Any opaque,
  layer-backed native view (a WebView, a terminal surface, any platform-native view embedded in a
  otherwise-declarative UI tree) *composites over* declaratively-drawn siblings that were painted
  earlier in the same container, regardless of intuitive z-order — and this is
  **position-in-the-tree-dependent**, not a logic bug: the sibling is fine if drawn *after* the
  native view, invisible if drawn *before*. This recurred four separate times in the prior
  project, each initially diagnosed with the wrong tool, before the mechanism (not just the
  symptom) was understood.
  - **Rule**: any declarative-UI container that mixes an opaque native view with declaratively-
    drawn siblings gets explicit, deliberate layer/z-ordering applied to every sibling, in every
    layout branch — as a PR checklist item, ideally backed by a lint or an automated check, not
    discovered per incident.
  - **False-green warning**: off-screen/isolated rendering mechanisms (anything that rasterizes
    the declarative tree in isolation, or a "does the element exist in the tree" check) give a
    **false green** for this entire bug class — they don't perform the real platform compositing
    step, so an occluded view renders perfectly under them. The *only* authoritative proof that
    on-screen compositing is correct is a real captured screenshot of the actual running window
    (window-ID-scoped capture, not full-screen capture — full-screen capture also doesn't reliably
    include composited window content).
  - **Size the real-render (pixel-level) test tier to match where the costly bugs actually live,
    not to match how cheap the tier is to write.** The prior project ended with roughly 81%
    headless-tier / 1% pixel-tier tests, while compositor bugs were its single costliest recurring
    class — invert that ratio deliberately, or at minimum guarantee every rendered surface has at
    least one real-render (pixel-level) regression test, with a coverage-matrix gate that treats an
    unmapped surface as a build failure.
  - **Prove every render-regression guard can actually fail**: for any pixel-level regression
    test, demonstrate it goes red against a deliberately-broken build once (a negative-control
    switch gated behind an env var is a reusable pattern for this — one shared helper, one
    consistent naming convention, so this is a repeatable proof rather than a one-off manual
    revert-and-check).

---

## 12. Persistence layout

- **One application-data directory**, not split across two by accident (the prior project split
  state across two OS-level app-support directories with no clear ownership rule, purely because
  of accretion — avoid this from the start with a single documented root).
- **Structured data → an embedded relational store** (e.g. SQLite via a minimal-feature binding),
  not ad-hoc JSON files, for anything with real query/index needs (session index, history,
  review/walkthrough documents). **Small preference-like blobs → versioned JSON** is fine.
- **Every store, regardless of format**: a schema-version field; lenient per-record decoding (one
  corrupt record must never wipe the whole store — strict-decode-or-fail-everything was a real
  data-loss bug in the prior project); every write returns a typed `Result` the caller is forced
  to handle (no discardable boolean / ignorable success flag anywhere on a persistence path); an
  atomic write pattern (write-temp-then-rename, never write-in-place for anything that matters).
- **Documents get an op-log/journal per open document** for hot-exit safety — this is the same
  mechanism as the undo substrate in §8, not a separate feature.
- **Sessions**: the core-owned domain snapshot (which files/tabs are open) and the client-owned
  view sidecar (scroll/cursor/fold state) should be **physically separate records**, not fields on
  one struct — so the core/client ownership split from §10 can't silently regress by someone
  adding "just one field" to the wrong side.
- **A recoverable reset mechanism** (clear app state to a backed-up, restorable snapshot) is cheap
  insurance worth building early.

---

## 13. Large-content strategy (files/documents above a comfortable in-memory size)

Rather than keeping a second, simpler engine alive indefinitely purely to handle oversized content
(the prior project kept an entire native text-widget stack alive for years solely as the
size-guard its primary WebView-hosted editor lacked — a permanent two-engine tax paid for one edge
case):

1. **Windowed snapshots in the core**: the core serves byte-range windows over the document (a
   rope or equivalent + a pager), so no front-end ever has to hold the entire file in memory.
2. **The primary engine gets a virtualized viewport** fed by those windows; above a measured size
   threshold, drop into a *scoped degraded mode of the same engine* (read-only first, then shed
   expensive features — full-file search-all, full highlighting, LSP — progressively). Never stand
   up a second engine as the large-file answer.
3. **Thresholds are measured, not guessed**, and enforced as explicit size guards at every engine
   entry point — any algorithm worse than roughly linear in input size needs a guard + a cheaper
   fallback path decided at authoring time, not discovered via a production incident (the prior
   project's canonical incident: an unbounded diff algorithm consumed tens of gigabytes of memory
   on a real input).
4. **Safe seek + buffered I/O in the host ports; no memory-mapping inside a `forbid(unsafe)`-style
   core** — mmap's failure mode (a `SIGBUS`-class hardware trap on truncated/unavailable file
   contents) cannot be caught by ordinary exception handling, and is incompatible with a
   safety-forbidden core; if mmap is ever needed for real profiled reasons, quarantine it in a
   dedicated, clearly-unsafe leaf module.
5. **Test harnesses for large-content code paths run under explicit memory/wall-clock ceilings**,
   so a runaway algorithm fails the *test*, not the developer's machine.

**Open question this doc can't settle for you**: how large is "large" for this project (100 MB?
1 GB? multi-GB logs?), and is read-only acceptable above some threshold? This sizes the pager
investment from "a checkbox" to "a subsystem" — decide it explicitly before building the pager.

---

## 14. Evidence-class / validation doctrine (the load-bearing link to the companion tracker app)

A feature is not "done" on the author's assertion. Define, in this project's tracker/process
tooling, a small fixed vocabulary of **evidence classes** — e.g. "unit-tested," "integration-
tested against the real wire protocol," "interacted with via a real input event (not a simulated
model call)," "confirmed via a real captured screenshot of the running app" — and:

- Every ticket/task names its **required** evidence classes at grooming/creation time, not at
  review time.
- The tracker (or equivalent gate) refuses to mark work "done" without artifacts satisfying the
  named classes — a claim is a *pointer to a repeatable artifact* (a screenshot file, a test
  report, a reproduction command), not a sentence in a commit message.
- Feature lifecycle is **engine → wire integration → actually wired into a consuming UI/surface →
  real-render evidence → considered baked-in.** The prior project's only P0-class findings from a
  later completeness audit were fully-built engines that were never wired to any consumer, and a
  fully-built UI with zero call sites — both had been reported "done." Refuse "done" before the
  consumption step is evidenced.
- This is explicitly a **shared schema** between the editor-class app and the companion
  project-management app: the tracker enforces the evidence-class vocabulary; the app's own test
  harness is what *produces* the artifacts that satisfy it. Decide up front how tightly coupled
  you want this (shared artifact store + schema vs. loose convention) — tight coupling paid off in
  the prior project's evidence but costs you co-evolution lockstep between two products.

---

## 15. Security/trust doctrine for the agent protocol

Restated compactly from §7 because it deserves its own checklist at implementation time:

- Every agent-callable capability is **annotated with what effect class it has** (read, write,
  execute, network) and enforced at **one shared point**, on the effect itself (an unforgeable
  "authorized" wrapper type), never re-implemented per call site.
- A connection-level token exists as a protocol *field* from v1, even if v1 auto-grants it.
- Every agent-invoked action is logged to a **user-viewable, persisted audit log** — this is not
  optional for a "non-blackboxy" product thesis; it is the mechanism that makes the thesis true.
- The local socket/IPC endpoint verifies server identity on connect and cannot be squatted by an
  unrelated process.
- One generated catalog is the single source of truth for "everything an agent can cause to
  happen" — never three independently maintained lists (a scripting DSL, a tool catalog, a
  UI-automation command set) that will silently drift the moment one gets a feature the others
  don't.

---

## 16. Build order (and why this order, specifically)

The extracted sequencing rule: **stand up every "lying-evidence killer" (the thing that would
otherwise let a broken feature look done) before the feature work that would trigger it**, and
make the authoritative feedback loop (real-render proof) *cheap* before you mandate people use it.

**Phase 0 — substrate (target: week 1).** Every item here was a documented "should have been week
1, was actually week N" regret in the prior project:
- Repo skeleton: the 3-layer module boundary (§3) with its CI import-grep gate; core-language
  workspace with lint-enforced purity (§ K3/K4) from the first commit.
- Wire envelope v1 with every reserved field from §4, run through the adversarial one-way-door
  checklist **before** anything freezes.
- The FFI/wire thin waist + ABI-skew detector + capability-bit negotiation + a forward-compat
  fuzz/negative-test suite for the codec — built alongside the *first* boundary-crossing commit,
  not after the first incident that needs it. Link the core as a proper tracked build artifact
  (§C11), not a raw static lib.
- **Ship-path rehearsal**: sign → notarize/equivalent → license/attribution generation *asserted
  present in the actually-assembled bundle* → install-on-a-clean-machine, run once before feature
  work accrues. The prior project's single most expensive deferred lane was exactly this one —
  built, never once exercised, and it became the pre-launch blocker cluster.
- Test harness: tier-as-type architecture (§K8) + a headless-gate script + hermetic per-test
  isolation + resource ceilings on any test exercising untrusted-size input.
- Perf instrumentation (§K13) — budget maybe 300-400 LOC total; the prior project waited weeks to
  build something this cheap.
- Agent-gate skeleton (§15) — before the first tool that needs it, not retrofitted onto it.
- Supply-chain lanes (dependency vulnerability scanning, vendored-asset advisory tracking,
  lockfile linting) **wired to an actual scheduled executor** (cron/CI trigger) from day 1 — "we
  built the scanner" without a scheduled trigger is equivalent to not having it.
- Process substrate: the tracker's evidence-class schema (§14); a rule that docs fold into their
  related code commit rather than existing as standalone doc-only commits; an explicit fan-out cap
  for any agent-spawns-agents mechanism (§A7).

**Phase 1 — first real-render proof (target: week 2).** Get the pixel/real-render test lane
operational, with a fast (well under a minute) path from "write a test" to "see a real captured
screenshot" — the prior project's own data point is that *adoption of the pixel tier jumped
immediately* the moment the fast path existed, having been neglected for weeks prior while it was
slow. Ship the first WebView-in-native-container surface with the compositor-occlusion convention
(§11) and a negative-control proof that the guard can fail. Start the per-surface real-render
coverage matrix from the *second* surface onward.

**Phase 2 — the document spine.** The core document store (rope/pager, op-log, windowed
snapshots, content-based dirty tracking), the persistence layer (§12) in full, and the
session/tab domain model with an automated test enforcing the core/client state-ownership split
(§10). Treat this as the least-retrofittable part of the whole system — everything else layers on
top of it, so get it right before building features on top of a shape you'll need to change later.

**Phase 3 — the primary editor, end-to-end and honest, before breadth.** The editor surface over
the spine: one find engine, one scroll-state owner, one fold engine, one highlight producer — each
core-owned with thin adapters (§5). Patch-not-reload (§11) from the first render, not added later.
The debounce/flush contract (§10) ships in the same commit as the debounce itself. **Exit
criterion for this phase**: open/edit/save/quit/crash-recover is proven correct at the real-render
+ end-to-end-journey level *before* moving on to breadth (more surfaces, more features). The prior
project's inverse choice — breadth before this exit criterion — is exactly how data-loss-class bugs
survived under a thousand-plus passing tests for weeks: the tests covered breadth, not this
specific depth-first spine.

**Phase 4 — the agent thesis.** VCS integration, review-share (frozen-context comments per §7),
walkthrough/reverse-review, the generated agent-tool catalog over the vocabulary from §7. Do this
while the app's surface area is still small enough to fully audit — it's both the product
differentiator and the natural forcing function to exercise the agent-gate built in Phase 0.

**Phase 5 — Canvas, then MicroApps one at a time.** Canvas first — it *is* the proof of the
MicroApp contract (§6/§9). Then exactly one more MicroApp, driven fully through the lifecycle
(document model → renderer → manifest → capability entries → real-render tests → threat-model
review) before starting a third.

**Phase 6 — the other front-ends.** TUI and WebUI-as-a-standalone-frontend against the
already-proven wire protocol; the remote daemon (TCP/WS) with the version-skew handover from §4.
Deferred deliberately, not neglected: the thin-waist protocol is specifically what makes these
*additive* once it exists, and testing the same protocol over a loopback transport before ever
opening a real network socket is how you prove local/remote transparency cheaply.

**Standing, from Phase 2 onward**: schedule periodic drain/convergence passes (roughly every
4–6 weeks) — a crash-class audit, a code-vs-tracker reconciliation pass, a "is everything marked
done actually consumed" sweep, and a ship-path re-rehearsal. Evidence from the prior project: this
is where the actual state of the project surfaces; schedule it as a standing practice rather than
waiting to discover the gap via a big one-off audit.

---

## 17. Open questions this doc deliberately does NOT answer

These are product/scope calls, not architecture facts — evidence from a prior build can't settle
them, but each one materially changes an earlier section of this doc, so answer them explicitly
before or during Phase 0 rather than letting them resolve by accretion:

1. **Is the shell app the product, or is the core the product?** Answering this sets how early the
   TUI/WebUI/remote front-ends deserve real investment, and whether "remote" is a Phase 2 concern
   or a genuinely deferrable Phase 6 one.
2. **How far does "web for all rich content" (§5) actually go?** Does every future content surface
   commit to WebView-hosting, or is there a short, explicit, fixed list of surfaces that stay
   native (e.g. for input-latency-sensitive editing)? An *undecided middle* is what produced the
   five-find-engines mess last time — either answer is fine, indecision is not.
3. **What large-content bar must actually be met** (§13) — is read-only acceptable above some
   size, and what's the actual target size class?
4. **Is multi-writer collaboration ever in scope** (§4)? This changes the op-log design from an
   undo substrate into a convergence substrate, and that's much cheaper to decide before the wire
   contract freezes than after.
5. **How much agent-trust friction do you actually want** (§15)? The audit-log + capability
   machinery is a "build it regardless" call; whether agent actions get silent auto-grant,
   per-capability consent prompts, or per-session scopes is a genuine product/UX decision.
6. **What's the review-throughput policy for agent-authored changes** — auto-validate low-risk
   lanes when evidence classes are satisfied, a hard work-in-progress cap that throttles the
   pipeline, or sampling-based human review? The tracker's design should encode whichever answer
   you pick.
7. **What's the actual distribution/shipping intent** (§16 Phase 0) — public-shipping from day 1
   (with all the signing/notarization/sandboxing ceremony that implies), or local-first for an
   extended period? Half-committing to this is exactly what produces a pre-launch pile-up of
   deferred ship-path work.
8. **What's the long-term real-render/pixel-test substrate** (§11)? A VM with a real display
   session, a second physical machine, a CI runner with a real compositor, or some reduced-scope
   compromise? Whichever you pick, it must exist by Phase 1 (week 2) and have a named owner for
   its ongoing health — every alternative that skips a *real* compositor pass is a false green for
   the occlusion bug class in §11.
9. **How tightly should this app and the companion tracker app actually couple** (§14)? Shared
   evidence-class schema and shared artifact store, or loose convention? Tight coupling is what
   the evidence favors, but it's a real cost (co-evolution lockstep) worth deciding on purpose.

---

*Distilled from an ~8-week, 3,733-commit prior build's full corpus (source + test + docs + commit
history) plus its own later post-mortems and audits. Every numbered claim in this doc traces to a
concrete artifact (a file, a commit, a measured LOC/property count, a named bug ticket) in that
prior project's research trail — this copy strips those internal references so the doc stands
alone in a new repo, but treat every "learned:" parenthetical and every specific number here as an
empirical finding, not a stylistic preference.*
