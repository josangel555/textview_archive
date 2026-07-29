# Greenfield Architecture — how to build it this time

2026-07-11 · Fable holistic agent (W2). The architecture-learnings answer to the owner's
requirement statement (`../README.md`): native Swift macOS shell, Rust core serving WebUI/TUI/
remote (TCP/WS), CM6 + tree-sitter + LSP, multi-session nested tabs, plugin/MicroApp system,
agent-centric "non-blackboxy" philosophy (git/review/walkthrough/Canvas/terminal).

Inputs: `CROSS_CORPUS_PATTERNS.md` (sibling), aspect reports (`../aspects/architecture.md`,
`deps-tooling.md`, `test-types.md`, `perf-journey.md`, `bug-types.md`,
`agent-centric-features.md`, `unprimed-explorer-2.md`), the decision archive
(`../summaries/docs/d-archive-decisions.md`), `../summaries/INDEX.md`, and the prior studies.
Claims cite those; audit-derived findings are gap-class evidence (the audit's verify phase never
ran).

The one-sentence thesis: **the prior project's architecture was mostly right and its
*sequencing* was mostly wrong** — nearly every expensive arc was a correct decision arrived at
in week 4–8 that was knowable (and in several cases already written down in its own research
docs) in week 1. The rebuild's job is to start at the end-state.

---

## Keep — decisions that proved right

1. **CM6-in-WKWebView as the editor.** The 2026-05-23 head-to-head (CM6 vs Scintilla vs the
   whole NSTextView/TextKit2 family) held for the project's entire life: LSP ecosystem, Lezer,
   markdown ecosystem, MarkEdit precedent; vim mode shipped via `@replit/codemirror-vim` exactly
   as designed (`d-archive-decisions.md`, decisions table — both "Held"). TextKit 2 was
   independently confirmed buggy by four named engineers; `SwiftUI.TextEditor` is not viable.
   The flagged risk — JS-bridge per-message latency — is real: batch mutations, never
   one-message-per-keystroke. The owner has already re-validated this by prototype; done.

2. **Tree-sitter as the one highlight producer, N thin render surfaces.** `HighlightSpan` as
   pure `Sendable` data consumed by both native and HTML renderers is the *correct* instance of
   the capability-ownership axis (`architecture.md` §What worked) — and the Rust highlight
   engine evaluates `#match?`/`#eq?` predicates end-to-end (MEMORY). Keep exactly this shape;
   it is the template for every other cross-surface capability (see Change #1).

3. **Sans-IO, deterministic Rust core — the unanimous verdict.** No clock/RNG/IO/panics in
   core; caller-supplied `now_ms`; effects returned as data; `#![forbid(unsafe_code)]` +
   no-panic/no-unwrap/no-slicing workspace lints everywhere except the `ffi` crate; validated
   against quinn-proto, Crux, Firezone and the xi-editor post-mortem
   (`RUST_CORE_PLAYBOOK_2026-05-30`, adopted as-built). Purity → host-testability →
   agent-verifiable → agent velocity is the causal chain that made the autonomous loop viable at
   all (CROSS_CORPUS M4). The playbook (workspace layout, lint config, `deny.toml`, dependency
   shortlist with measured verdicts) is near drop-in; port it.

4. **The xi lesson, applied correctly: interactive read path synchronous and in-process; async
   only at coarse seams.** "Async is a complexity multiplier" is the most-cited external
   evidence in the corpus (`d-archive-decisions.md` key learning #1). The shipped `serve` crate
   honors it (hot path dispatches to `*_wire` fns directly); LSP stays a separate async actor
   pool. Remote is a *transport* concern (level-triggered snapshot+delta, optimistic-local in
   the client adapter), never an async core API.

5. **The compiler-enforced 3-package boundary** (`Kit` pure values → `Core` no-UI-imports →
   `UI`): "the single most important design decision" (DESIGN.md), top-cited pattern in the
   whole corpus, and the mechanism behind ~80% headless testability. It's a structural
   guarantee — you cannot violate it without a compile error. Keep, plus a CI import-grep gate.

6. **Thin-waist versioned FFI/wire envelope.** One dispatch table by stable method id;
   MessagePack named-field maps (`to_vec_named` — the array-default trap is documented);
   unknown-key tolerance (the hand-rolled codec exists *because* generic serde can't do this);
   ABI version-skew detector + capability bitmap with every bit asserted on both sides;
   version-skew handover (`daemon.retire`). Cited as foundational by 6+ reports
   (`INDEX.md` scoreboard). This is what makes "same core, N frontends, remote later" real.

7. **The engine-port/migration template** — pure fn → wire seam → FFI shim → Swift bridge →
   gated adapter (default-OFF + fallback) → A/B byte-equality parity corpus + differential
   fuzzing → named soak → Deleted Twin with the adapter seam kept. 8/9 engines, **zero
   reverts, 5 silent parity bugs caught pre-ship** (CROSS_CORPUS §5.7). In the rebuild there is
   no Swift twin to migrate from, but the same ladder applies to every risky replacement
   (engine v2, renderer swap, protocol bump).

8. **Tier-as-type test architecture with runtime enforcement.** `HeadlessUITestCase` /
   `LiveAppTestCase` / `PixelTestCase` + `TierGateObserver` sentinel (tier membership is
   machine-checked, heavy tiers self-skip outside the VM lane), the dual-path harness (same JSON
   dump schema + Page Objects at T1m and T4), negative-control switches
   (`isBroken("<NAME>")`) proving every guard can go red, and the per-surface real-render
   coverage matrix with a shrink-only exemption ratchet. Called "the single highest-ROI thing to
   transplant" (`t-ui-harness`). All of it arrived reactively; ship it in week 1.

9. **Curated protocol boundary for automation.** `AutomationHost` — a high-level `@MainActor`
   protocol, never the raw model — survived the 40-slice DocumentModel decomposition with
   **zero automation-surface breakage** (`agent-centric-features.md` §1). Same for hand-rolled
   minimal MCP wire types (~150 LOC vs an SDK's 10×; `Int(exactly:)` decode discipline).

10. **DSL-first, agent-primary authoring surfaces.** The Canvas decision record — "LLMs are bad
    at raw coordinates, good at intent" — measured **80%+ agent executability vs 2–11%** for a
    raw-coordinate baseline (`d-docs-root-2of2`). The strongest design-philosophy validation in
    the corpus, and it's the owner's product thesis. Corollaries that also earned their keep:
    frozen-context review comments (snapshot + `blobSha` staleness detection — the agent never
    re-derives "what did this point at"); the pure-logic Walkthrough engine + delegate pattern;
    versioned envelopes with graceful unknown-version failure on every agent-crossed boundary.

11. **Immutable-base + replayable-ops document models** (EditorBuffer, HexEditBuffer,
    image/audio ops) — cheap dirty tracking, deterministic render, trivial undo/redo, and the
    natural substrate for agent-visible incremental change ("crown jewel",
    `src-core-media-terminal`). This is also what the Canvas is.

12. **Dependency discipline as practiced.** Exact pins + `default-features=false` + explicit
    feature lists + `--locked` load-bearing in every gate; `deny.toml` genuinely tightened;
    no runtime dependency acquisition anywhere (LSP servers PATH-discovered, assets vendored);
    `default-members` scoping keeping the TUI/wasm trees out of the shipping graph (187 lock
    packages, ~35 shipped); dev-machine surface counted (cargo-mutants rejection); static-link
    Rust core with dual size caps (total + exec) catching static-link regressions. Measured
    facts worth reusing: rmp-serde over postcard (reversed by `cargo tree`), comrak
    `default-features=false` (13 deps, zero C), full core dylib = 441 KB — the app's weight is
    grammars + JS, not core logic.

13. **Perf discipline end-state.** Env-gated zero-when-off instrumentation (`PerfSignpost`);
    per-interaction absolute p95 budgets (`InteractionProfiler`: keystroke/scroll/nav 16.7 ms,
    tab-switch/re-render 33.3 ms, open-file 50 ms) — port the table verbatim; slice-and-prove
    for high-stakes render fixes (the DOM-patch fix's 6 proven layers incl. the live-body
    alignment probe); absolute-budget asserts (ratio asserts are noise under a parallel gate);
    `phys_footprint` never RSS/VSZ; audits as bounded phases driving single-commit measured
    fixes. There is **no recorded case of intuition beating measurement in this corpus**
    (CROSS_CORPUS S6).

14. **Evidence-artifact validation culture.** A claim is a pointer to a repeatable artifact:
    scene code + pixel PNG + reproduction command in the commit message; tickets name required
    evidence classes at grooming; the evidence-class vocabulary (WV-DOM / AX-press / T5-pixel /
    T6-journey) is the connective tissue with the PM app — port it as a schema, not prose.

15. **The `scripts/` layer.** ~62 files, near-unanimous KEEP, each mapping to a real incident:
    `build-app.sh` (xattr-safe staging), `build-rust-core.sh` (content-hash staleness guard),
    `check-bundle-size.sh`, `test-in-vm.sh` (GUI-session bridge, fd limits),
    `test-headless-gate.sh`, `sign-and-notarize.sh` (inside-out signing order). Port nearly
    verbatim; budget for accreting new incident classes on a new machine anyway.

---

## Change — decisions that proved wrong or drifted, and what to do instead

1. **Three text engines / boundaries drawn by rendering technology → one capability owner, and
   the web-vs-native policy on day 1.** The costliest structural drift: the native-vs-web split
   was drawn per-surface, so every cross-cutting capability was reimplemented per side — **five
   find runtimes, three scroll-persistence channels (five tickets for one user complaint:
   TSK-821/1037/1041/1046/1047), two highlight engines, two fold engines, two warm-WebView
   caches** (`architecture.md` taxonomy #4; prelaunch `dual-ui-refactor.md`). The unifying
   policy ("web for content, native for chrome", TSK-1524) arrived in week ~8, *after* the
   duplication tax was paid, gated OFF, with no parity checklist — and a live doc arguing the
   opposite direction was never marked superseded.
   **Instead:** declare the rendering-stack policy in the founding architecture doc — *CM6/web
   is the only text path; all rich content surfaces are WebView-hosted; native is app chrome
   only* — and extend it explicitly to every planned surface (markdown, diff, hex, CSV/
   spreadsheet, PDF, image, DB viewer, Canvas) before building the first one. Every
   cross-surface capability (find, scroll state, fold, highlight, cache) gets ONE named owner in
   core with thin per-surface adapters. Large files become a scoped degraded mode of the primary
   engine, not a second engine kept alive indefinitely (`unprimed-explorer-2` §2, trap #4).

2. **God objects → domain partition from commit 1, with a budget that has teeth.**
   `DocumentModel`: 2,377 LOC / 71 `@Published` / 107 methods at post-mortem; still ~10.7 KLOC
   across 74 files with ~90 `@Published` after a deliberate 40-slice SRP sprint;
   `main.swift`/AppDelegate at 4.4 KLOC. Extraction-by-extension organizes a god object but
   does not decompose it — file-level SRP ≠ observation-surface SRP, because one `@Published`
   mutation still re-fires `objectWillChange` for the whole object (`architecture.md` §What
   hurt). The coordinator split + narrow channels (~90% re-body reduction, ~249× republish
   amplification killed) was the actual fix. **Instead:** per-domain observable coordinators
   (tabs, find, editor, sessions, git, terminal) from the first commit needing >5 properties;
   a budget test with teeth — *no coordinator exceeds ~500 LOC or ~15 `@Published` without a
   split review* (same mechanism as the HANDOFF byte-budget test); a republish-invariant test
   (a domain mutation fires `objectWillChange` on itself only). Prevention is ~10× cheaper than
   the sprint (CROSS_CORPUS T4).

3. **Wire boundary designed after the Swift model → contract-first with an adversarial
   one-way-door review before freeze.** The Rust core was retrofitted at ~week 2; the
   14-agent hardening pass then caught the classics *just* before the freeze: no
   `clientSeq`/version/`siteId` reserved in the envelope, UTF-16/NSRange about to be baked into
   wire positions ("LSP's most-regretted decision"), content as `String` not
   `(bytes, encoding, eol)` (`CORE_DESIGN_HARDENING`, 29 risks, 19 one-way doors). The project
   got lucky the pass ran in time. **Instead:** copy the one-way-doors table as a mandatory
   pre-freeze checklist: reserved envelope fields (version, clientSeq, siteId, correlation-id);
   UTF-8 byte offsets as the wire-native position unit; content modeled as
   `(bytes, encoding, eol)`; open-tagged enums with `unknown(...)` fallbacks; the FFI zero-copy
   story decided before doc-text hot paths depend on it (hand-written `extern "C"` + cbindgen —
   uniffi double-serializes, swift-bridge is bus-factor-1).

4. **Accreted trust model → capability system on the *effect*, from commit #1.** The MCP
   surface grew from read-only inspectors to `run_task` (exec) and file writes while the
   security model stayed "same-uid, v1, no token" — always-on unauthenticated socket, jail
   applied per-tool so `run_verb`'s file ops bypassed the very jail `open_path` used, allowlist
   gating the task *id* not the *body*, a deliberate no-audit-log stance, statelessness that
   foreclosed any auth point, squattable socket path (`agent-centric-features.md` F1–F7).
   **Instead (all cheap, all day-1):** capabilities annotated per tool and enforced at a single
   shared point on the effect (an `AuthorizedPath`-style type you cannot construct outside the
   jail — "forgot to check" becomes a compile error); a connection-level token (auto-granted in
   v1, but the *slot* exists) decided before the reconnect contract; a persisted user-viewable
   audit log of every `tools/call` (rated "Fix size S / safe"); server-identity verification on
   connect; one catalog enumerating everything an agent can cause to happen (MCP tools + verbs
   + AX actions + LSP-applied edits) — generated, not three hand-maintained vocabularies
   (the ScriptRunner-DSL / MCP-catalog / CM6-bridge "zero shared code" drift).

5. **Asserted status → evidence-derived status with a consumption gate.** The board understated
   AND the CHANGELOG overstated completion in the same repo (CROSS_CORPUS N1); the audit's only
   P0-class findings were dead render tails (FormulaEngine "done", never wired to a view;
   3-pane merge UI with zero callers). **Instead:** feature lifecycle = *engine → FFI →
   consumption/wiring → real-render evidence → bake-in*, with "done" refused before consumption
   lands; tickets carry required evidence classes at grooming; standing code-first board
   reconciliation. (This is the load-bearing requirement handed to the coupled PM app — the
   tracker stores and enforces evidence classes; the editor's harness produces them.)

6. **Reactive test-tier investment → per-surface real-render minimum, and make the
   authoritative tier cheap first.** The pyramid ended 81% headless / 1.4% pixel while the
   costliest bug class lived exactly where only pixels can see (24 real-render test fns for ~30
   surfaces). Don't flip to pixel-heavy (T5 is expensive, serial, VM-bound — `t-ui-root-5of6`
   is right that the lean scales); the correct resolution is the project's own 07-04 MANDATES:
   keep the headless mass AND enforce ≥1 real-render evidence class per surface via the matrix
   guard (CROSS_CORPUS N4). And obey the cost-gradient law: coverage follows feedback cost —
   the ≤30 s pixel-proof path (scene registry + window-id capture) produced adoption
   *immediately* when it landed in week 8 (S1). Stand it up in week 2.

7. **Reload-per-render → persistent surface + diff/patch as the architectural default.** The
   2–9 s reload storm was a foreseeable consequence of `loadHTMLString`-per-render and took ~40
   days from perf-infra-exists to default-ON fix, because the fix required new architecture
   (Rust block differ → JS apply → live-body alignment probe) (`perf-journey.md`). The rebuild
   plans *many* WebView surfaces (markdown, Canvas, PDF, spreadsheet, DB viewer) — each is the
   same bug class waiting. Patch-not-reload is policy from the first WebView surface.

8. **Lifecycle-boundary data safety by audit → by construction.** The audit's biggest cluster
   (~8 P1s) is one mechanism: *a debounce/mirror never flushed at the moment that matters, or a
   write failure silently swallowed* — CM6's 200 ms mirror vs ⌘S; `JSONFileStore.write`'s Bool
   discarded by every caller; strict-decode wiping all bookmarks on one bad record; a "Merge…"
   button that acts as Keep-Mine (`bug-types.md` §5). **Instead, structural rules:** every
   persistence write returns a typed `Result` the compiler forces callers to handle; every
   debounce ships its flush-on-teardown hook (save/close/blur/quit) *in the same commit*; every
   async-buffered boundary gets one canonical "flush and read current" entry point all readers
   must use; lenient/partial decode for any store that must survive one corrupt record; UI copy
   must match the code path it triggers. Plus: adversarial acceptance criteria (crash
   mid-write, unflushed debounce, malformed persisted state) named at grooming — the happy-path
   evidence bar is exactly what let these ship (`unprimed-explorer-2` trap #2).

9. **Docs-as-substrate → tracker-as-substrate.** 36.5% of all commits were doc-only; 17% of the
   entire history was appends to one file; 56% of tool errors were substrate (compaction
   amnesia + tracker lifecycle), not work (CROSS_CORPUS N2, S2). **Instead:** fold docs into
   code commits from day 1; short-lived contract-fed worker sessions rehydrating from tickets;
   LESSONS.md as the *intake queue for gates*, not the defense — every lesson is unfinished
   until it exists as a structural prohibition, lint, or red-able test (M2: prose lessons
   recurred — compositor 4×, killall at a second call site, CRLF in a new subsystem; mechanized
   rules held 100%).

10. **Supply-chain/ship-path deferred → wired to a clock and rehearsed in week 1.** Three
    well-built audit lanes with no executor (no remote → nightly workflows never ran once) let
    6 Mermaid advisories accrue ~11 months in the untrusted-input path; the attribution
    generator existed but the bundle-copy step never did, and no test checked the *assembled
    bundle*; notarization was never once run (`deps-tooling.md`). **Instead:** every scanner has
    a named executor (launchd/cron/loop-tick) or it doesn't count as built; vendored assets are
    first-class dependencies (VENDOR.md + hash test + advisory entry, same commit); attribution
    generation and shipping are one ticket with a bundle-content assertion; run
    sign → notarize → attribute → install-on-clean-machine before the second feature lands;
    gitignored lockfiles are a lint failure.

11. **Raw `.a` linking → the native core as a tracked build input** (xcframework
    `binaryTarget`), closing the SwiftPM staleness class (stale relinks, enum-layout SIGSEGVs
    that masquerade as FFI bugs) structurally instead of via compare-and-touch scripts.

---

## Avoid — traps to design out entirely

The false-green ladder (memorize it — every rung was mistaken for the one above, each mistake a
multi-round rework arc):

```
model-green              → proves the model, not that any view reaches it
element-in-tree          → proves layout membership, not visibility
ImageRenderer/cacheDisplay → placeholder for representables; blind to occlusion — NEVER render proof
in-process WKWebView     → real-ish WebKit; window-hosting bugs don't reproduce
T4 live-app model dump   → proves state, not pixels
T5 WindowServer capture  → the only authority for "did it composite"
```

- **Compositor occlusion:** an opaque layer-backed `NSViewRepresentable` composites OVER
  earlier-painted SwiftUI siblings, position-dependently. `.compositingGroup().zIndex()` on
  every sibling in every layout branch the moment such a pairing exists; T5 quadrant-color
  sniff test with a negative-control switch; never NSRulerView on the hosted scroll view.
- **`screencapture -x`** (full-screen) doesn't composite app-window content — window-ID capture
  (`-l<id>`) only. **`layoutManager.numberOfGlyphs`** lies for TextKit-2 (use
  `textStorage.length`).
- **Silent-fail writes:** no discardable `Bool`/ignored-Result persistence API anywhere.
- **Uncatchable native aborts:** never `NSFileHandle.availableData`/`.fileDescriptor` on a
  handle another thread can close (raw POSIX `read`/`write` on a cached fd); every
  recursive-descent parser over untrusted input gets a depth cap (~128) in the same commit —
  `catch_unwind` cannot catch a stack-overflow abort.
- **Async-chain stage-patching:** after two failed patches on a timing bug, collapse the chain
  to a single pull-based source of truth; hold ≥2 candidate causes until a discriminating check
  splits them (the 24-commit and 11-commit arcs both ended the day the handoff was eliminated).
- **CRLF/grapheme traps:** never scan line endings by Swift `Character` (CRLF is one grapheme);
  never claim Swift/Rust index parity on non-ASCII without grapheme segmentation. Fix as a
  shared utility + lint, not a LESSONS entry — the documented lesson recurred anyway.
- **Process-identity ordering:** never touch `NSApplication.shared` (or any order-sensitive
  global) before branching on process mode (`--mcp-connect` zombie-registration made the app
  un-openable; TSK-1566).
- **`killall` by exec name** — a class fix needs a grep sweep across scripts/tests, not a
  point fix.
- **Ratio wall-clock asserts under a parallel gate** — absolute budgets with margin only.
- **Unbounded algorithms on user-sized input:** size-guard + cheaper fallback AND a
  resource-bounded test harness (the 77 GB LCS incident needed both).
- **mmap inside the `forbid(unsafe)` core** — safe seek+buffered reads; quarantine mmap in a
  leaf crate only if profiling demands it.
- **Two live contradictory design docs** — mark SUPERSEDED at the moment of decision.
- **Unbounded exploratory agent fan-out** (the 75-agent Canvas runaway) — hard caps for
  exploration; full fan-out only against a locked design.
- **UTF-16/NSRange on any wire. Bare `String` as content on any wire.**

---

## The rebuild's proposed shape

### Layer diagram

```
┌───────────────────────────────────────────────────────────────────────────┐
│ FRONT-ENDS (thin, replaceable)                                            │
│  macOS Swift shell        WebUI            TUI (ratatui)    remote client │
│  ├ native: app chrome only — windows, menus, tab strips, palettes, sheets │
│  └ web: ALL rich content — CM6 editor, markdown, diff, CSV/spreadsheet,   │
│    PDF, image, DB viewer, Canvas (persistent WebViews, patch-not-reload)  │
├───────────────────────────────────────────────────────────────────────────┤
│ SURFACE ADAPTERS (per-frontend, thin, stateless)                          │
│  CM6 bridge │ MicroApp host │ Canvas host │ terminal │ AX/automation layer│
│  each adapter = render + input forwarding; ZERO capability logic here     │
├──────────────────────────── THE THIN WAIST ───────────────────────────────┤
│ CORE PROTOCOL  —  versioned Command / Query / Event envelope              │
│  MessagePack named maps · stable method ids · capability bitmap ·         │
│  ABI skew guard · reserved: ver, clientSeq, siteId, corrId ·              │
│  positions = UTF-8 byte offsets · content = (bytes, encoding, eol) ·      │
│  level-triggered subscriptions (state-of-X, not delta-Y)                  │
│  transports: in-process FFI (sync fast path) │ unix socket │ TCP/WS       │
│  agent gate: capability-on-effect · conn token · audit log · identity     │
├───────────────────────────────────────────────────────────────────────────┤
│ RUST CORE  (sans-IO, deterministic, forbid(unsafe) outside ffi crate)     │
│  document store (rope; (bytes,encoding,eol); op-log; content-based dirty) │
│  sessions/tabs domain model · single capability owners:                   │
│    find │ scroll-state │ fold │ tree-sitter highlight │ index/cache       │
│  engines: markdown │ diff │ csv │ hex │ fuzzy │ formula │ canvas-doc      │
│  large-file pager (windowed snapshots) · undo/redo (replayable ops)       │
├───────────────────────────────────────────────────────────────────────────┤
│ HOST PORTS (injected at core init; side effects live here, per host)      │
│  read/write fs │ watch │ subprocess │ clock │ rng                         │
└───────────────────────────────────────────────────────────────────────────┘
   beside the core, coarse async seams (never per-keystroke):
   LSP actor pool · git subprocess layer · terminal PTYs · remote daemon
```

### Core boundary contracts

**UI ↔ core.** One serializable Command/Query/Event protocol ("Option C" from the boundary
audit), with an in-process synchronous fast path for the local shell (xi lesson) and the same
contract over socket/TCP/WS for remote — a transport swap, not an API change. Duplex from day 1:
the prior project's #1 boundary gap was a request/response-only surface that *dropped*
notifications. Level-triggered subscriptions; single-writer-per-session (what makes
optimistic-local tractable without CRDT/OT); optimistic-local apply confined to the remote
transport adapter — it never leaks into the core API or the local path. Freeze nothing before
the one-way-doors checklist review.

**Plugin / MicroApp contract.** A MicroApp = (a) a document model in core — immutable base +
replayable ops, exactly the EditorBuffer/image-ops/Canvas shape — plus (b) a WebView renderer
speaking a versioned envelope, plus (c) a manifest declaring: required capabilities (fs scopes,
subprocess, network), its surface entry in the real-render coverage matrix, and its
threat-model entry (S4: security audits harden a snapshot; a surface-registration gate installs
the reflex). Ops are the undo/history/agent-visibility substrate for free. Unknown
schema/envelope versions fail structured, never silent. One MicroApp hardened end-to-end before
a second is started.

**Agent-integration protocol.** MCP is a *view* over the same core protocol — agent verbs and
human palette verbs and CLI flags are generated from one catalog, never three hand-maintained
vocabularies. Enforcement lives on the effect (unforgeable jailed-path/capability types), so
every entry point inherits the same wall. Connection token + persisted audit log + socket
identity from commit #1 (v1 may auto-grant the token; the protocol slot is what matters —
retrofitting auth into a stateless-reconnect protocol proved structurally impossible).
Agent-consumed artifacts freeze their context at creation (review-comment pattern). The
"non-blackboxy" features — review-share, walkthrough, reverse-review — are DSL-first documents
in core, agent-primary, human-editable second.

**Canvas.** Not a special feature: the flagship MicroApp, and the proof of the ops contract. A
diffable, replayable scene-graph document in core; a DSL agents emit incrementally
(apply/lint/undo/timeline — the shipped `canvas_*` tool family shape); a WebView renderer that
patches. The 80% vs 2–11% executability result says: design the DSL grammar before the renderer.
The component kit ("all basic features, components") is vocabulary in the DSL, versioned like
everything else. Day-1 hardening the prior Canvas lacked: CSP + navigation policy on the
WebView, and its file I/O routed through the same capability gate (the one surface the security
audit couldn't trace).

### State-management doctrine

- **Core owns domain state** (documents, content, edit state, git status, session/tab set);
  **client owns view/ephemeral state** (scroll, cursor, focus, folds, viewport). The prior
  project *designed* this and shipped the opposite (`SessionSnapshot` persisting view fields) —
  so enforce it: a wire-schema test that rejects view-state fields in core-owned snapshots,
  reviewed at every schema change. "Reconnect can't move your scroll" must be true by
  construction.
- **Per-domain observable coordinators, narrow `@Published` channels**, budget-tested
  (~500 LOC / ~15 published max), republish-invariant tests. No god ViewModel, ever.
- **Pull-based single source of truth for anything a render reads.** Imperative
  seeding-around-a-switch is the project's most recurrent bug mechanism; if a value can be read
  declaratively from one owner, it is.
- **Every debounce/coalesce ships its flush contract in the same commit**; every buffered
  boundary has one canonical flush-and-read entry point.

### Persistence layout

- **One Application Support directory** (bundle-id keyed) — the prior app split state across
  two dirs by accident; don't.
- **Stores:** rusqlite (`default-features=false`, system libsqlite3) for structured data
  (sessions index, history, review/walkthrough docs); versioned JSON only for small
  preference-like blobs. Every store: schema-version field, lenient per-record decode (one
  corrupt record never wipes a store), typed-Result writes surfaced to the user on failure,
  atomic write-temp-then-rename.
- **Documents:** op-log/journal per open document (hot-exit safety); snapshot + ops = crash
  recovery and agent-visible history in one mechanism; content-based dirty tracking.
- **Sessions:** core-owned domain snapshot (which files/tabs), client-owned view sidecar
  (scroll/cursor/folds) — physically separate records so the ownership split can't silently
  regress.
- **Recoverable reset** (`_reset-backups` pattern) kept.

### Large-file strategy

The prior project kept NSTextView alive solely as the >512 MiB guard CM6 lacked — the dual-engine
tax paid indefinitely for one edge case. Instead, solve it inside the one-engine architecture:

1. **Windowed snapshots in the Rust core** (the designed-but-never-built Phase-1 contract item):
   the core serves byte-range windows over a rope/pager; no frontend ever holds the whole file.
2. **CM6 virtualized viewport** fed by windows; above a threshold, a *scoped degraded mode of
   the same engine* — read-only first, heavy features (LSP, full-file highlight, find-all
   preview) shed progressively — never a second engine.
3. **Thresholds are measured, not vibed**, and enforced as size-guards at every engine entry
   (the ≥1 MiB diff bypass pattern); any O(n×m)+ algorithm gets a guard + fallback at authoring
   time.
4. **Safe seek+buffered IO in host ports; no mmap in core** (SIGBUS vs `forbid(unsafe)`).
5. Test harness runs with memory/wall-clock ceilings so a runaway fails the test, not the host.

---

## Build order — and why

The ordering rule extracted from 8 weeks of evidence: **stand up every "lying-evidence killer"
before the feature work that would otherwise lie**, and make the authoritative feedback loop
cheap before mandating its use (S1). Concretely:

**Phase 0 — the substrate (week 1).** Everything here was a documented regret at "should have
been week 1":
- Repo skeleton: `Kit`/`Core`/`UI` packages + CI import-grep gate; Rust workspace from the
  playbook (lints, `deny.toml`, flat `crates/`, ffi-only unsafe).
- Wire envelope v1 with reserved fields, byte-offset positions, `(bytes,encoding,eol)` content;
  **adversarial one-way-door review before anything freezes** (the checklist is pre-written).
- FFI thin waist + ABI skew detector + capability-bit pinning + MessagePack negative/fuzz suite
  (`to_vec_named` documented) — alongside the first boundary commit, not after the first
  incident. Rust core linked as an xcframework `binaryTarget`.
- **Ship-path rehearsal:** sign → notarize → third-party-notices generated *and asserted
  present in the assembled bundle* → install on a clean machine. The one lane the prior project
  never exercised became its ship-blocker cluster (10th conclusion, CROSS_CORPUS).
- Test harness: tier-as-type + `TierGateObserver` + headless gate script + hermetic isolation
  (UUID temp dirs, per-suite defaults) + test resource ceilings.
- Perf: `PerfSignpost` + `InteractionProfiler` with the budget table (~320 LOC total; the prior
  project waited 18 and 56 days respectively); bundle-size dual-cap ratchet with the first
  packaged build.
- Agent gate skeleton: MCP framing + capability-on-effect types + token slot + audit log +
  socket identity — before the first tool that needs them.
- Supply-chain lanes **wired to a clock** (launchd/loop-tick; no phantom CI): cargo-deny/audit,
  vendored-asset advisory list, lockfile lint.
- Process substrate: tracker with evidence-class schema; fold-docs-into-code-commits; fan-out
  caps; worktree reaping SOP. (The PM app is a build-order *peer* of the editor — S2 says the
  substrate gap cost ~⅓ of all motion.)

**Phase 1 — first pixel truth (week 2).** VM (or equivalent) pixel lane operational with the
≤30 s pixel-proof path (scene registry + window-id capture) — a permanent tax with a week-2
bring-up deadline, not a one-time setup (T3). First WebView-hosting SwiftUI container ships
with the compositor sniff test + `.compositingGroup().zIndex()` convention + a negative-control
teeth proof, and the per-surface coverage matrix starts enforcing (from the *second* surface).

**Phase 2 — the document spine.** Rust document store (rope, op-log, windowed snapshots,
dirty tracking) + persistence layer (typed writes, lenient decode, flush contracts, hot-exit
journal) + session/tab domain model with the ownership-split schema test. This is the
unretrofittable cluster (conclusion #1); everything else layers on it.

**Phase 3 — the editor, end-to-end and honest.** CM6 surface over the spine: one find engine,
one scroll-state owner, one fold engine, tree-sitter producer — each core-owned with thin
adapters. Patch-not-reload from the first render. The CM6 mirror ships with its flush contract.
LSP as the separate async actor pool. Exit criterion: open/edit/save/quit/crash-recover proven
at T5 + journey level — *before* breadth begins. (Breadth-first is why data-loss bugs survived
8 weeks under 1,227 test files.)

**Phase 4 — the agent thesis.** Git integration, review-share (frozen-context comments),
walkthrough engine, MCP catalog over the generated vocabulary. This is the product
differentiator and it exercises the agent gate built in Phase 0 while the surface is still
small enough to audit completely.

**Phase 5 — Canvas, then MicroApps one at a time.** Canvas first (it *is* the plugin-contract
proof); then ONE MicroApp (owner's pick) driven to hardened/end-to-end through the full
lifecycle including its threat-model and matrix entries; only then the next. Populate the
plugin system serially; design it early.

**Phase 6 — the other frontends.** TUI and WebUI against the already-proven protocol; remote
daemon (TCP/WS) with version-skew handover; optimistic-local in the remote adapter. Deferred
deliberately: the thin waist makes these additive, and the loopback A/B tests prove
local/remote transparency before any network exists.

**Standing, from Phase 2 onward:** scheduled drain/convergence phases (~every 4–6 weeks, ~1–3
weeks each) — crash-class audit, code-first board reconciliation, consumption-gap sweep,
ship-path re-rehearsal. The drain is where truth surfaces; schedule it, don't discover it (S5).

---

## Open questions for the owner — evidence can't settle these

1. **Product identity: is the Mac app the product, or is the core?** The 2026-05-30 hardening
   pass flagged this as *the* gating question and it was never explicitly answered. It sets the
   wire-freeze timing, how early TUI/WebUI get real investment, and whether remote (TCP/WS) is
   Phase 6 or Phase 2. The requirement statement implies "core is a product" — worth saying out
   loud, because it makes the protocol work front-loaded and non-negotiable.

2. **How far does "web for all rich content" go?** The evidence supports web-for-content as the
   default posture, but the prior project's *native* diff/hex/CSV/formatted surfaces were solid
   and cheap, and native won on IME/latency at the margins. Does the rebuild commit to
   eventually-everything-web (one stack, one test story), or grandfather a short fixed list of
   native content surfaces? Either is defensible; the un-decided middle is what cost five find
   engines.

3. **Large-file bar.** What must actually open well — 100 MB? 1 GB? 10 GB logs? And is
   read-only acceptable above a threshold? This sizes the pager/virtualization investment
   (weeks, not days) and is the difference between "degraded mode" being a checkbox or a
   subsystem.

4. **Collaboration / multi-writer: ever?** Single-writer-per-session is what keeps
   optimistic-local tractable without CRDT/OT, and the prior design *deliberately* deferred
   collab. If shared sessions are ever wanted, `siteId`/`clientSeq` reservations aren't enough —
   say so now, because it changes the op-log design from "undo substrate" to "convergence
   substrate."

5. **Agent trust UX.** The evidence says build the capability/token/audit machinery day 1; it
   cannot say how much *friction* you want: silent auto-grant with an audit trail, per-capability
   consent prompts, or per-session scopes. Your "non-blackboxy" goal cuts both ways — visibility
   argues for the audit log (settled), but consent ergonomics is a product call.

6. **Review-throughput policy.** 65 commits/day vs one human reviewer produced a ~40-ticket
   review queue that was effectively abandonment (`unprimed-explorer-2` trap #3). Options:
   risk-tiered auto-validation (evidence-classes green ⇒ auto-done for low-risk lanes), a hard
   WIP-at-review cap that throttles the loop, or sampling review. Which failure do you prefer —
   slower delivery or thinner human oversight? The tracker design should encode the answer.

7. **Distribution intent.** Local-dev signing sufficed last time and notarization never ran.
   Is the rebuild public-shipping from the start (Developer ID, notarized, sandboxed?,
   auto-update story) — which the week-1 ship rehearsal should then match exactly — or
   local-first for months? Half-committing produces exactly the pre-launch pile-up the audit
   found.

8. **The pixel-truth substrate.** A UTM VM again (known, working, permanently fiddly: TCC,
   toolchains, stale dist), a second Mac / CI runner with a real WindowServer, or a
   reduced-scope hosted-WebView + screenshot-on-host compromise? The evidence only says: it
   must exist by week 2, someone must own its health as a standing line item, and every
   alternative that skips real WindowServer pixels is a false green for the compositor class.

9. **PM-app coupling depth.** Should the editor and the tracker share one evidence-class
   schema and one artifact store (screenshots, junit, perf runs) — the tracker enforcing what
   the harness produces — or stay loosely coupled via conventions? The S2/S7 evidence argues
   for tight coupling; the cost is co-evolution lockstep between two products. Your call on how
   much you want the editor project to *depend* on the PM app being good.

---

*Written by the greenfield-architecture holistic agent, 2026-07-11. Companion:
`CROSS_CORPUS_PATTERNS.md` (sibling), `../aspects/` per-dimension reports,
`../summaries/INDEX.md` scoreboard. Audit-derived findings cited here are gap-class evidence —
the pre-launch audit's verify phase never ran.*
