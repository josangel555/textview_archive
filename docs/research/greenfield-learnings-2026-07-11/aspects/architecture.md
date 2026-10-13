# Architecture & Boundaries — greenfield learnings

Dimension: module structure (ViewerKit/ViewerCore/ViewerUI/MarkdownViewer), god-objects, the
Rust-core FFI boundary, the three text engines and WebView-vs-native policy, state management,
persistence layout. Evidence-first; every claim cites a report, file, or commit in
`/Users/me/Documents/workspaces/claude/markdown_viewer`.

---

## Taxonomy — the distinct types in this dimension

### 1. God-object coordinators (HIGH frequency, HIGH severity — the single most-cited anti-pattern)
Two independent instances, same shape: a single file absorbing all state/orchestration for its
layer until it became unmaintainable, then requiring a multi-week incremental extraction.
- `DocumentModel.swift` — grew to **2,377 LOC / 71 `@Published` / 107 methods** at its post-mortem
  point (`DESIGN.md`, cited in
  `docs/research/greenfield-learnings-2026-07-11/summaries/docs/d-root-md.md`), and the *current*
  tree still totals **10,721 LOC across 74 `DocumentModel*.swift` files** (measured
  `wc -l Sources/ViewerUI/DocumentModel*.swift` — 2026-07-11) with ~90 `@Published` properties
  distributed across them. The extraction was TSK-1110, a 15+ slice campaign (commits `e49f9979`,
  `566c820a`, `4697e19f`, `824ffab4`, `758596d2`, `40ba79ed`, `41cccf6f`, `23ab806c`, `ccd0ab8b`,
  `e4a39e8f` … each one "extract X from DocumentModel → DocumentModel+X").
- `Sources/MarkdownViewer/main.swift` — **4,435 LOC**, AppDelegate-equivalent imperative
  NSMenu/NSApplication wiring (measured `wc -l`). Cited as anti-pattern #2 alongside DocumentModel
  in `summaries/INDEX.md` §"Most-cited anti-patterns" ("AppDelegate 4.4 KLOC").
- Root cause per `summaries/docs/d-root-md.md` (DESIGN.md excerpt): the split into extension files
  (`DocumentModel+ViewModeControl.swift` etc.) is a real SRP win at the *file* level but does
  **not** reduce the `@ObservableObject`'s *observation surface* — every `@Published` on the
  aggregate still fires `objectWillChange` for the whole object, which is why the coordinator-split
  (see #2 below) was the actual fix, not the extension-file split alone.

### 2. Republish-storm / imperative-around-declarative races (HIGH frequency, MEDIUM-HIGH severity)
A distinct but related type: even *after* god-object decomposition, one `@Published` mutation on a
shared aggregate re-fires SwiftUI `body` for every observer, and imperative state populated
*around* a session/tab switch races the declarative render that reads it.
- `summaries/code/src-ui-other-subdirs.md`: "narrow-observation pattern prevents ~249× baseline
  republish cascade on every keystroke/scroll/caret move."
- CLAUDE.md's own root-cause-discipline section names the SAME mechanism recurring three times:
  "the session-switch scroll reset, the footer-stats blank-on-switch (TSK-1120), and 'loading…'
  flashes are the SAME class: imperative state populated AROUND a switch, raced by the declarative
  render that reads it" (`/Users/me/Documents/workspaces/claude/markdown_viewer/CLAUDE.md`
  §Root-cause discipline).
- Fix pattern that held: per-domain independent `@Published`/observation channels instead of one
  god ViewModel — cited by 6 separate batch reports (`src-ui-root-1of4/2of4/3of4/4of4`,
  `src-ui-git-walkthrough-terminal`, `t-ui-root-6of6`) per `summaries/INDEX.md`.

### 3. Compositor-occlusion boundary violation (MEDIUM frequency, but the single costliest
recurring instance — 4 confirmed recurrences)
An opaque, layer-backed `NSViewRepresentable` (WKWebView/CM6, terminal surface) sharing a SwiftUI
container with sibling SwiftUI content composites OVER earlier-painted siblings regardless of
z-order intuition — a **position-in-the-view-tree-dependent** occlusion bug, not a logic bug.
- `CLAUDE.md` §"Compositor occlusion + the ImageRenderer false-green trap (TSK-488, 2026-06-07)":
  "recurred FOUR times because the symptom (no tabs) was diagnosed with the wrong tool."
- `Sources/ViewerUI/DiskConflictBanner.swift` (54 LOC) is cited by
  `summaries/code/src-ui-root-1of4.md` as the textbook fix instance: "Load-bearing
  `compositingGroup().zIndex(1)`: opaque NSViewRepresentable (CM6 editor) composites over
  earlier-painted SwiftUI siblings … (TSK-960, LESSONS.md compositor-occlusion rule)."
- The corollary false-green: `ImageRenderer`/`cacheDisplay`/headless frame-walks all give a FALSE
  GREEN for this class because they rasterize SwiftUI's own tree in isolation or don't composite
  CA layers at all — only WindowServer-pixel capture (T5) is authoritative (CLAUDE.md, same
  section; also `summaries/docs/d-lessons-1of2.md`, `t-ui-root-4of6.md`).

### 4. Fragmented/duplicated engines across the module boundary (MEDIUM frequency, MEDIUM severity)
The inverse of the FFI-thin-waist win (§"What worked" below): where a subsystem was NOT
consolidated behind one owner, it forked into parallel implementations that silently diverged.
- `docs/research/prelaunch-audit-2026-07-09/dual-ui-refactor.md`: **five find runtimes** behind
  four state bags, **three scroll-persistence channels** with three different keyings (the
  recurring "position lost on switch" family — TSK-821/1037/1041/1046/1047), **two syntax-highlight
  engines** classifying tokens differently, **two fold-region engines**, **two warm-WebView
  caches** — all within the single native-vs-web split.
- `summaries/INDEX.md` anti-pattern list: "Split/fragmented engines across Swift and Rust (CSV
  split, transcript readers fragmented, scroll channels split)."
- Root mechanism: the module boundary (native `.source` NSTextView stack vs web `.editor` CM6
  stack) was drawn along a *rendering-technology* axis rather than a *capability-ownership* axis,
  so every cross-cutting capability (find, scroll, fold, highlight, cache) had to be reimplemented
  on both sides of that axis instead of once behind a shared owner.

### 5. FFI/wire-boundary one-way-doors not reserved up front (LOW frequency of actual damage in
THIS project since Rust-core was retrofitted late, but HIGH latent severity — documented as the
single most expensive class to retrofit)
- `archive/CORE_DESIGN_HARDENING_2026-05-30.md` (per
  `summaries/docs/d-archive-decisions.md`): 29 named risks, the worst being *"no per-doc
  version/`clientSeq`/`siteId` in the wire envelope (retrofitting after freeze = flag-day
  migration)"*, *"UTF-16/NSRange baked into wire position types (LSP's most-regretted decision,
  about to be repeated)"*, *"content modeled as `String` not `(bytes, encoding, eol)` (silently
  corrupts non-UTF-8/non-LF files on save)"*.
- This project's actual shipped `serve` protocol (see #6 below) DID adopt several of these
  mitigations (hand-rolled MessagePack with unknown-key tolerance, capability bitmap,
  version-skew handover) — evidence the hardening pass's recommendations were followed once
  written down, which is itself the lesson: catch these BEFORE the freeze, not after.

### 6. Rust-core sans-IO / thin-waist FFI boundary (HIGH frequency of correct application once
adopted — this is a "what worked" type structurally, but it's also a distinct architectural TYPE
worth naming for the taxonomy)
- `rust-core/Cargo.toml` (~167 LOC): workspace lints enforce `#![forbid(unsafe_code)]` /
  no-panic/no-unwrap/no-slicing in `core`; only the `ffi` crate opts back into unsafe
  (`summaries/code/src-rust-other-crates.md`).
- `rust-core/crates/serve/src/envelope.rs` (~554 LOC): hand-rolled MessagePack codec specifically
  because generic serde doesn't give unknown-key tolerance for forward-compat — a boundary
  decision made *for* future-evolution reasons, not convenience.
- `rust-core/crates/serve/src/serve.rs` (~839 LOC): "hello first (version check hard-close) …
  version skew handover (TSK-1555): newer client can send `daemon.retire` to trigger respawn.
  Capabilities mask advertised per-connection."

### 7. Three text-engine split with no single canonical answer to "what renders this content"
(MEDIUM frequency of confusion, MEDIUM-HIGH cost — a whole pre-launch audit dimension was spent
mapping it)
- `docs/research/prelaunch-audit-2026-07-09/dual-ui-refactor.md` surface inventory: `.source`
  (native NSTextView), `.editor` (web CM6), `.source` behind `MDV_WEB_SOURCE` gate (web, OFF),
  `.rendered` markdown (web), `.rendered` raw HTML (web), Canvas (web), `.formatted` (native),
  `.table`/CSV (native), `.diff`/`.hex`/`.preview` (native), Split pane (own fork) — **11 distinct
  surface/stack pairings**, several duplicated.
- `LESSONS.md` 2026-07-10 entry (`summaries/docs/d-lessons-1of2.md`): "doc comments rot — the
  `.editor` mode's doc comment said NSTextView; it had been CM6 for a while … Don't delete an old
  rendering path (NSTextView) just because it 'should' be replaced — check what invariant it
  silently protects (here: the only path with a real large-file guard)."
- The endpoint policy: `TSK-1524` "rendering-stack policy epic captured — web for content, native
  for chrome" (commit `96616583`), with `TSK-1530` shipping a gated (OFF by default) web route for
  `.source` (commit `8719863d`). As of the 2026-07-09 audit, the migration was **directional but
  incomplete and un-checklisted** ("the gated M6 web-source route is far from feature parity and
  the parity gap is not written down as a checklist anywhere" — `dual-ui-refactor.md` executive
  summary).

---

## What worked — practices/designs that earned their keep

- **The 3-package module boundary (`ViewerKit` → `ViewerCore` → `ViewerUI` → app target), zero UI
  imports in Core.** Called "the single most important design decision" in `DESIGN.md`
  (`summaries/docs/d-root-md.md`), independently corroborated as the top most-cited pattern across
  the whole corpus (`summaries/INDEX.md` §"Most-cited patterns worth porting", first bullet, cited
  by 6+ batch reports). Concrete payoff: **~80% of app behavior ended up headlessly testable**
  because it physically could not import AppKit/SwiftUI. This is a structural guarantee, not a
  discipline — you cannot accidentally violate it without a compile error.
- **Sans-IO synchronous Rust core, effects returned as data, time/RNG injected.** Validated against
  three external reference systems (quinn-proto, Crux, Firezone) beyond the project's own xi-editor
  citation (`archive/RUST_CORE_PLAYBOOK_2026-05-30.md`, `d-archive-decisions.md`). Enforced
  mechanically via workspace lints (`#![forbid(unsafe_code)]`, no-panic/no-unwrap/no-slicing) in
  `rust-core/Cargo.toml` — again, a compiler-enforced boundary, not a code-review convention.
- **The xi-editor lesson, applied correctly**: keep the interactive READ path
  (UI querying text/cursor/layout) synchronous and in-process; confine async to genuinely coarse,
  remote, or crash-prone seams (LSP, the `serve` daemon's duplex protocol). The project's own
  `serve` crate honors this — `method_fn` dispatch "routes to core `*_wire` functions directly (no
  FFI hop)" for the hot path (`summaries/code/src-rust-other-crates.md`), while LSP stays a
  separate async actor-pool subsystem (`summaries/INDEX.md`: "LSP subsystem exemplary actor-based
  pool + client architecture").
- **Tier-as-explicit-type-hierarchy for tests, mapped 1:1 onto the render-boundary risk.**
  `HeadlessUITestCase`/`LiveAppTestCase`/`PixelTestCase` with a `TierGateObserver` sentinel that
  makes heavy-tier skip/run machine-verifiable, not a convention (`CLAUDE.md` Testing rules;
  `summaries/code/t-ui-harness.md`). This is the boundary-discipline pattern applied to test
  *placement*, and it's what let the compositor-occlusion class eventually get a real regression
  guard (T5 pixel, with a negative-control switch `MDVNegativeControl.isBroken` proving the guard
  can actually go red — `CLAUDE.md` same section).
- **The Rust-migration slice template**: pure fn → wire seam → FFI shim → Swift bridge → gated
  adapter → A/B byte-equality parity test → Deleted-Twin. Cited as directly portable by 4 batch
  reports (`src-core-root-1of5`, `src-core-root-4of5`, `d-lessons-2of2`, `t-rust-kit-support`) and
  is the *only* pattern in this dimension with an unambiguous, repeatable execution record (CSV,
  diff, find, fuzzy, hex engines all ported this way per `summaries/INDEX.md`).
- **Thin-waist FFI envelope / dispatch-by-method-id with an ABI version-skew guard and capability
  bitmap.** `summaries/code/t-rust-kit-support.md`: "ABI version skew detector + capability-bits
  constant pinning are foundational gates; every bit position explicitly asserted on both sides."
  This consolidated what would otherwise have been N hand-maintained Swift↔Rust call surfaces into
  one dispatch table (`d-progress-3of3.md`: "Thin-waist FFI envelope (TSK-580) consolidated all
  Rust methods into one dispatch call").
- **One producer, two render surfaces for highlighting**: TreeSitter spans are pure `Sendable` data
  (`HighlightSpan`) consumed by both the `NSTextView` renderer and the HTML `<span>` renderer for
  WKWebView (`DESIGN.md`, `summaries/docs/d-root-md.md`). This is the *correct* version of the
  pattern that #4 in the taxonomy got wrong elsewhere (find, scroll, fold, cache) — one owner,
  multiple thin render adapters, instead of two independent re-implementations.

---

## What hurt — the costly failures, with root-cause mechanism

- **God-object growth was not prevented by the module boundary — the boundary only stops
  UI-logic leaking into Core; it does nothing to stop a single `ObservableObject` inside
  ViewerUI from absorbing everything.** `DocumentModel` grew to 2,377 LOC / 71 `@Published` before
  the first extraction pass, and the extraction itself (TSK-1110, 15+ slices) shows the cost of
  retrofitting: each slice is a distinct commit choosing one of three encapsulation strategies
  (vend an accessor / widen `private`→`internal` / move the exclusive-caller group — LESSONS.md
  2026-06-28 entry, `summaries/docs/d-lessons-1of2.md`), and even then the *extension-file* split
  didn't fix the *observation-surface* problem — a further coordinator split (`FindCoordinator`,
  `TabCoordinator`, `EditorCoordinator`) with a forwarder-discipline pattern was needed on top
  (`DESIGN.md` DocumentModel post-mortem, `d-root-md.md`). **Mechanism**: SwiftUI's
  `@Published`/`ObservableObject` re-fires `objectWillChange` for the *whole* object on any one
  property mutation; splitting a monolith into extension files (file-level SRP) does not create
  new observation channels (object-level SRP) — those are two different axes and the project
  conflated them for months before the coordinator-split fixed the actual republish-storm.
- **Drawing the native/web module boundary along "which rendering technology" rather than "who
  owns this capability" produced N-way duplication of every cross-cutting concern.** Five find
  runtimes, three scroll-persistence channels, two highlight engines, two fold engines, two
  WebView caches (`dual-ui-refactor.md`). **Mechanism**: when a boundary is drawn per-surface
  instead of per-capability, every capability that needs to work identically on both sides of the
  surface boundary gets reimplemented independently by whoever builds that surface, and the two
  implementations drift the moment either side gets a bugfix the other doesn't. This produced a
  *specific, quantified* recurring bug family — the scroll-position-lost-on-switch bugs
  (TSK-821/1037/1041/1046/1047) are five tickets for the SAME user complaint because the
  underlying state lived in three different places with three different keys.
- **The rendering-stack boundary question ("web vs native, and where") was never resolved as a
  day-1 architecture decision — it was arrived at through 8 weeks of incremental surface-by-surface
  choices, then retrofitted into a policy (`TSK-1524`, 2026-07-ish) after the duplication had
  already accrued.** `dual-ui-refactor.md` finds the policy epic exists but the actual migration
  (`TSK-1530`) is gated OFF and has no written parity checklist — i.e. the fragmentation cost (§4
  above) was paid BEFORE the unifying decision was made, not avoided by it. There is also a
  **stale, contradicting design doc still live** (`docs/WEBKIT_MARKDOWN_ELIMINATION.md`, opposite
  direction from the adopted `TSK-1524` policy, "no superseded marker" — `dual-ui-refactor.md`
  finding #2), meaning two conflicting architecture decisions coexist in the docs tree with nothing
  telling a future agent which one is current.
- **Save-path staleness at the native/web seam**: CM6 debounces edits 200ms in JS before posting to
  Swift; JS-initiated saves (⌘S, vim `:w`) correctly flush first, but Swift-initiated reads of the
  buffer do not — up to 200ms of typed text can miss a save (`dual-ui-refactor.md` finding F1, P1
  severity, cites `codemirror.html:888`, `main.swift:994-1000`, `ContentView.swift:1011-1015`,
  `CodeMirrorEditorView.swift:938-947`). **Mechanism**: a boundary crossing (native→web) that is
  *usually* synchronous-feeling (a debounced JS event loop) was treated as if it always flushes on
  request, when only the JS-side callers that explicitly know about the debounce actually flush it
  — every OTHER caller of "read the current buffer" inherited a silent staleness window. This is
  the FFI-boundary discipline problem (see taxonomy #5) recurring at the WebView bridge instead of
  the Rust FFI.
- **Compositor occlusion is a class of bug that is invisible to the test tooling that would
  normally catch it, and it took FOUR live recurrences before the mechanism (not just the symptom)
  was understood and codified as a rule applied to EVERY layout branch.** `ImageRenderer` and
  `cacheDisplay` both give false greens for exactly this class because neither actually performs
  real AppKit/WindowServer compositing (`CLAUDE.md` §"Compositor occlusion…", `d-lessons-1of2.md`).
  **Mechanism**: the boundary between "a SwiftUI-drawn sibling" and "an opaque AppKit
  `NSViewRepresentable`" is a compositing-layer boundary, not a data or logic boundary — so
  logic-level or even declared-view-tree-level tests structurally cannot observe it; only actual
  WindowServer pixel capture can, and the team's default test tooling until this was formalized
  (T5, `PixelTestCase`) was logic/tree-level.
- **Retrofitting the Rust core after ~2 weeks of Swift-only development meant the wire boundary was
  designed AFTER a working Swift model existed, not before — several one-way-door risks
  (UTF-16/NSRange position units, `String`-not-`(bytes,encoding,eol)` content model, no
  `clientSeq`/version/`siteId` reserved fields) were identified only by a dedicated 14-agent
  hardening pass, not by initial design** (`archive/CORE_DESIGN_HARDENING_2026-05-30.md`,
  `d-archive-decisions.md`). The project's own risk register names this pattern explicitly: "R1/R4/
  R6/R16/R18… retrofitting after freeze = flag-day migration." This didn't fully bite in THIS
  project because the hardening pass caught it before the wire froze — but the near-miss is the
  evidence: a from-scratch Rust-core project that skips an equivalent pre-freeze adversarial pass
  is gambling on getting the same lucky catch.

---

## Design implications for the rebuild

**Do differently from day 1** (these are cheap now, expensive later — this project's own evidence):

1. **Draw the module boundary compiler-enforced, not convention-enforced, and pick the AXIS
   deliberately.** Keep the `ViewerKit`→`ViewerCore`(sans-UI)→`ViewerUI` shape (it worked, ~80%
   headless testability) — but for the native/web split specifically, draw the boundary by
   **capability ownership** (one find engine, one scroll-position store, one fold engine, one
   highlight producer — each with thin render adapters per surface), not by **rendering
   technology**. The five-find-runtimes/three-scroll-channels mess in this project is direct
   proof the per-surface axis produces N-way duplication; the highlight-engine's
   one-producer/two-render-surfaces pattern is the proof the per-capability axis doesn't.
2. **Decide "how much native UI vs WebView" as a Day-1 architecture call, not an emergent one.**
   The owner's rebuild brief already states CM6-in-WebView won for the editor; extend that
   decision explicitly to *every* content surface (markdown render, diff, hex, CSV/spreadsheet,
   PDF, image, DB viewer MicroApps) BEFORE building the first one, with a single written policy
   doc that is the one and only source of truth (delete/mark-superseded any earlier doc the moment
   a new one supersedes it — this project shipped two live, contradictory docs simultaneously).
   Given CM6 already won and the owner wants many WebView-hosted MicroApps (Canvas, image editor,
   spreadsheet, DB viewer), the evidence in this project leans toward "web for ALL rich content
   surfaces, native only for app chrome" as the default posture from commit #1 — that is exactly
   where this project's own TSK-1524 policy landed after 8 weeks of paying the duplication tax to
   get there.
3. **Never let a single `ObservableObject`/coordinator become the union of all UI-domain state.**
   Partition by domain (tabs, find, editor, sessions, git, terminal) into independent observable
   objects with narrow `@Published` surfaces from the FIRST commit that needs more than ~5
   properties on one coordinator — do not wait for a 2,000+ LOC crisis. The forwarder-discipline +
   republish-invariant-test pattern (assert a domain mutation fires `objectWillChange` on itself
   only, never the parent) from this project's post-mortem should be the *starting* shape, not the
   fix applied after the fact.
4. **Any WKWebView/NSViewRepresentable-hosting SwiftUI container gets `.compositingGroup().zIndex()`
   on every sibling in every layout branch as a checklist item at PR time**, not discovered per
   incident. Consider a lint/test helper that flags a SwiftUI container mixing a representable with
   bare SwiftUI siblings and no explicit z-order — this bug class recurred 4 times in one project
   despite being "fixed" each time, which means the fix was applied per-instance rather than
   structurally.
5. **Freeze the Rust-core wire contract only after an adversarial hardening pass**, using this
   project's own risk register as the starting checklist (reserve `clientSeq`/version/`siteId`/
   correlation-id in every envelope; UTF-8 byte offsets never UTF-16/NSRange; content as
   `(bytes, encoding, eol)` never bare `String`; open-tagged enums with an `unknown(...)` fallback
   for forward-compat). This project got lucky that the hardening pass ran BEFORE the freeze — the
   rebuild should treat that pass as mandatory sequencing, not optional insurance.
6. **Every native↔web (or native↔Rust) boundary that has an async debounce/buffer on one side needs
   an explicit, tested "flush" contract that ALL boundary-crossing readers use** — not just the
   callers who happen to know about the debounce. The 200ms CM6 save-flush gap is a boundary-
   discipline bug of the exact same shape as an un-reserved FFI wire field: an implicit assumption
   ("the buffer is current") that only some callers correctly discharge.

**Accept as inherent cost** (not worth over-engineering away):

- Some amount of incremental god-object growth before a domain naturally splits — the rebuild
  should set a LOC/`@Published`-count threshold that triggers a mandatory split review (e.g. "any
  coordinator over 500 LOC or 15 `@Published` gets split before more features land on it") rather
  than trying to design the final coordinator graph up front; this project's own state-architecture
  research doc treats "Core owns domain state, client owns view/ephemeral state" as an aspirational
  target requiring "deliberate schema discipline, not something that falls out for free"
  (`archive/STATE_ARCHITECTURE_2026-05-30.md`, `d-archive-decisions.md`) — expect to actively
  defend this split, not assume it holds by construction.
- Some real render/compositor bugs will only be caught by VM/pixel-tier tests, which are
  inherently slower and more infrastructure-heavy than unit tests — this is a structural property
  of native+WebView compositing, not a process failure, and the answer is investing in the T5/pixel
  tier early (this project under-invested: "tier pyramid is inverted — 81% headless-unit / 9
  webview / 1 T5 pixel file" despite compositor bugs being the costliest recurring class,
  `t-ui-root-6of6.md`), not eliminating the need for it.

---

## Portable rules — candidate directives for the next project's CLAUDE.md / architecture doc

1. **Module boundary is compiler-enforced from commit #1**: a pure-value package with zero
   framework imports (`Kit`), a logic package with zero UI-framework imports (`Core`), a UI package
   that may import both (`UI`) — verified by a CI import-grep gate, not a review convention.
2. **Draw cross-surface boundaries by capability ownership, never by rendering technology.** Before
   building a second surface (native or web) that needs find/scroll/highlight/fold/cache, name the
   ONE owner of that capability and give every surface a thin adapter — audit-grep for "N
   implementations of the same capability" quarterly.
3. **No `ObservableObject`/coordinator exceeds ~500 LOC or ~15 `@Published` properties without a
   mandatory domain-split review** — treat this as a budget test with teeth (à la the existing
   `HANDOFF.md`/`CLAUDE.md` 12 KB/40 KB budget tests), not a code-review nicety.
4. **Any SwiftUI container mixing an opaque platform-native view (WKWebView, terminal surface,
   any `NSViewRepresentable`) with bare SwiftUI siblings requires `.compositingGroup().zIndex()`
   on every branch, checked by a lint or a WindowServer-pixel regression test** — never trust
   `ImageRenderer`/`cacheDisplay`/headless view-tree assertions as proof of on-screen compositing.
5. **Freeze no FFI/wire contract before an adversarial one-way-door review** covering: reserved
   envelope fields (version, client/session id, correlation id), position units (byte offsets, not
   UTF-16/NSRange), content model (`(bytes, encoding, eol)`, not bare `String`), and open-tagged
   enums with an `unknown` fallback for forward-compat.
6. **Every async-buffered boundary crossing (debounce, batched post, background flush) gets one
   canonical "flush and read current" entry point that every reader is required to use** — audit
   for boundary readers that bypass it whenever a new debounce is introduced.
7. **One written, current rendering-stack policy doc per app** (which surfaces are native vs web,
   and why) with superseded docs explicitly marked SUPERSEDED at the top the moment a new decision
   replaces them — never let two contradictory architecture docs coexist un-flagged.
8. **Real-render (pixel/VM) test-tier investment should be sized to match where the costliest bug
   class actually lives, not to match how cheap the tier is to write** — if compositor/render bugs
   are the historically expensive class (as they were here), the pixel-tier test count should not
   be the smallest slice of the pyramid.
