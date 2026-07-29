# Batch: DOCS — repo-root `*.md` load-bearing docs

Scope: all repo-root `*.md` except `LESSONS.md` (covered by another agent). Enumerated via
`find <repo> -maxdepth 1 -name '*.md' ! -name 'LESSONS.md'` — 23 files (~14K lines total; 3 files
added post-hoc by gap-closure pass: OVERNIGHT_REPORT, TESTS_AUDIT, VM-SETUP).

---

**`CLAUDE.md`** — the accumulated owner-directive rulebook for the project; 570 lines of process
law built up over ~8 weeks · status: current (actively enforced, dated entries through 2026-07-10)
- learnings:
  - The single densest artifact in the repo for "how NOT to get burned by an agent." Encodes real
    incidents as rules: render/on-screen claims require actual pixel confirmation (T6 partial-UAT,
    not host-green); root-cause-before-fix discipline (5-point checklist: is it a class of bugs,
    what's the mechanism, verify don't infer, collapse the chain not patch a stage); every change
    ships tests across ALL applicable tiers, not just unit; a test that's never been shown to fail
    is not a guard ("teeth" doctrine — negative-control switches via `MDVNegativeControl.isBroken`).
  - UI/render testing has a hard **VM-only** rule (never spawn windows on the host) plus a
    heavy-tier auto-skip guard (`TierGateObserver`) so a bare `swift test` on a host with a built
    bundle can't accidentally open a window on the owner's screen — this was a real footgun that
    got closed with a structural fix, not a policy reminder.
  - Bundle-identity, TCC-grant, and signing invariants are called out explicitly as "never change
    this" (bundle id tied to TCC grants; changing it invalidates every user's existing permission).
  - Task-tracking discipline evolved live: "file generously" got walked back to "avoid
    over-decomposition" once ticket-swarm pathology was observed (a ticket = one PR/commit, not
    each edit/step) — a real course-correction worth reading in full.
  - Compositor occlusion class bug (opaque NSViewRepresentable siblings drawn before/after a
    SwiftUI view occlude it) recurred FOUR times before being codified as a structural rule
    (z-index every branch) — a concrete "the same bug keeps coming back because it was patched at
    the wrong layer" case study.
- carry-forward: DISTILL — the *policies* (root-cause discipline, teeth-doctrine, VM-only UI
  testing, per-surface evidence-class mandates, over-decomposition guard) are directly portable
  process design for the next project's CLAUDE.md, even though the project-specific tool names
  (tasked board, VM hostnames, bundle ids) are not.

**`BACKLOG.md`** — the pre-sorted, owner-curated CHUNK worklist selector on top of the `tasked`
board · status: current (reorganized 2026-07-09, live)
- learnings:
  - "CHUNK" work model: group 3-5 related tickets, implement the whole chunk in one pass, ONE gate
    + ONE commit at the end — a deliberate anti-fragmentation unit of work that trades per-ticket
    granularity for shared context and fewer gate/commit cycles.
  - A full pre-launch audit workflow (104 agents) died TWICE on account session limits, got 39/104
    agents done both times, and left ~30 raw dimension reports with **zero synthesis** — the owner's
    fallback was 3 manual read-only Explore passes to triage/dedupe into 6 themes by hand. Real
    example of large-fanout workflow fragility and the recovery pattern when it partially fails.
  - The dedupe of ~30 raw reports into 6 THEMES (data-safety/silent-loss, crash/stability,
    security/control-surface, ship-blocker licensing, dead-render-tails, perf/UX/architecture) is
    itself a good taxonomy for a pre-launch audit checklist on the next build.
  - "PURE AUTONOMY — NO INLINE QUESTIONS" + task_park-as-Need-me-gate is the concrete mechanism
    that operationalizes "don't ask, do the homework and recommend."
- carry-forward: DISTILL — the CHUNK work-loop mandate and the 6-theme pre-launch audit taxonomy
  are reusable playbooks; the specific 40+ tickets are not.

**`HANDOFF.md`** — CURRENT-STATE re-orientation doc, re-injected into context after every
compaction · status: current (but is explicitly SNAPSHOT-state, will look stale by the time it's
read later)
- learnings: Explicitly NOT a session log — the project enforces this with a host-gated size
  budget test (12 KB cap) that fails red if it bloats, forcing pruning discipline rather than
  accumulation. The failure mode being guarded against (per-session token tax compounding across
  compactions) is a real cost worth budgeting for explicitly in the next project too.
- carry-forward: PORT — the HANDOFF.md pattern (current-state-not-log, size-budget-enforced,
  reinjected on compaction) is a near-verbatim reusable mechanism.

**`DESIGN.md`** — the original top-level architecture plan, later grown with living
architecture notes appended at the bottom · status: mixed — §1-13 are the ORIGINAL phased plan
(now superseded/completed, historical), the tail sections (DocumentModel coordinator split, CM6
architecture, security model, multi-agent dispatch) are CURRENT and load-bearing
- learnings:
  - Original stack decision matrix (Swift+AppKit+SwiftUI vs pure SwiftUI vs Catalyst vs Electron)
    with an explicit "$0 deps, Apple-shipped only" bias — chose AppKit shell + SwiftUI content,
    `swift-markdown` for CommonMark/GFM, SwiftTreeSitter (later, first-party fork) for highlighting,
    shell-out to `/usr/bin/git` instead of libgit2 (deliberately rejected, revisit only on perf
    regression — never regretted per later docs).
  - **3-package module boundary was called the single most important design decision**:
    `ViewerKit` (types, zero UI imports) → `ViewerCore` (pure logic, no AppKit/SwiftUI, fully
    unit-testable) → `ViewerUI` (SwiftUI + AppKit glue) → app target (thin @main wiring). ~80% of
    behavior ended up living in the UI-free `ViewerCore`, which is what made the whole headless
    test pyramid possible later.
  - 5-tier testing strategy was planned UP FRONT (manual smoke → unit → main-actor unit → snapshot
    → headless ViewInspector → VM E2E) with an explicit, reasoned DEFERRAL of snapshot/ViewInspector
    tiers ("would have caught zero/one of the bugs we've actually seen") — a good example of
    evidence-based test-tier prioritization instead of cargo-culting a pyramid.
  - "One producer, two render surfaces" highlighting architecture: TreeSitter spans are pure data
    (`HighlightSpan`, Sendable) consumed by BOTH an `NSTextView` renderer and an HTML `<span>`
    renderer for WKWebView — a genuinely reusable idea for any app with both a native-text and a
    web-rendered view of the same content.
  - DocumentModel god-object post-mortem: 2377 LOC / 71 `@Published` / 107 methods → split into 3
    domain coordinators (`FindCoordinator`, `TabCoordinator`, `EditorCoordinator`) with a
    forwarder-discipline pattern (thin passthroughs kept on the aggregate) and a
    republish-invariant test pattern (assert a coordinator mutation fires `objectWillChange` on
    itself only, never on the parent) — this caught 3 real regressions and is a strong template for
    avoiding the same god-object growth from day one in the rebuild.
  - CM6-in-WKWebView bridge protocol: versioned JSON envelope (`{v, type, replyId?}`), unknown
    types decode to `.unknown` for forward-compat instead of crashing, incremental ChangeSet replay
    Swift-side with a v1 full-text fallback on drift — a solid pattern for any native-shell +
    web-editor bridge.
  - Security model section: URL-scheme path containment, HTML sanitizer allowlist, regex
    complexity guard (ReDoS), symlink-refuse on atomic writes (TOCTOU), LSP binary
    ownership-permission checks — a compact checklist of the security surfaces a viewer/editor app
    actually needs to defend.
- carry-forward: PORT for the module-boundary principle, the highlighting one-producer/two-surface
  architecture, the coordinator-split + forwarder + republish-invariant-test pattern, and the
  security-model checklist. DISTILL the phased roadmap and stack-decision table (good reference,
  but project-specific choices need re-litigating for the new stack, e.g. Rust core this time).

**`CHANGELOG.md`** — owner-facing dated log split into user-facing (Added/Changed/Fixed/Perf) vs
`### System work` roll-up · status: current (through 2026-07-09)
- learnings: The explicit two-audience split (a plain-language line the owner can SEE/FEEL vs a
  terse per-area roll-up of the "other 144 commits") is the concrete answer to "how do you keep a
  changelog useful when 95% of commits are non-user-facing infra/tests/refactors on an
  agent-driven project." Directly solves the otherwise-common failure of either (a) polluting the
  changelog with commit-noise or (b) hiding the bulk of actual effort.
- carry-forward: PORT — the two-section changelog convention is directly reusable.

**`MANUAL_TESTING.md`** — Tier-0 manual smoke checklist (~5 min), explicitly for things automation
can't see · status: current, well-maintained (references live env vars, VM workflow, security
policy verification steps)
- learnings:
  - Tight scope discipline: an explicit "What is NOT on this checklist" section pointing bug-finders
    back to writing an automated Tier-1/1m test instead of adding a manual-only regression check —
    prevents the checklist from growing unboundedly.
  - Concrete regression-annotated checklist items ("Regression: previously WKWebView reloaded on
    every body tick...") turn the checklist into a living memory of what actually broke, not just a
    generic feature list.
  - Two-tier large-file read strategy (full read ≤512 MiB, `isLargeReadOnly` flag above 64 MiB to
    skip O(N) per-interaction overlays) with a fully separate VM-only verification section (RSS
    bound, scroll frame pacing, huge-single-line edge case) — a good template for how to test
    "doesn't visibly regress with scale" behavior that headless tests can't observe.
- carry-forward: DISTILL — the checklist STRUCTURE (scope discipline, regression annotations,
  explicit "not covered here → write a test instead") is portable; the specific 12 sections are
  project-specific.

**`OwnerWishlist.md`** (read-only, never modify) — raw, chronologically-appended owner brain-dump
of feature asks, bugs, and "far future" ideas, spanning the whole project lifetime · status:
messy/unstructured but historically valuable — large sections marked DONE at the bottom prove most
early asks got built
- learnings:
  - This is effectively the unfiltered voice-of-the-customer transcript for the whole 8-week build.
    Recurring THEMES across the whole document, useful as direct signal for what the next app's
    owner will care about again: (1) perf/laziness complaints are the single most repeated
    category — "very laggy," "extremely slow," multiple instances of app hangs on file open — a
    strong signal that perf work should be front-loaded, not deferred; (2) a persistent "unify
    the N different search/palette/goto surfaces into one" ask that never fully resolved; (3)
    session/workspace independence (every session should have fully independent tabs, tool-window
    state, scroll state) came up many separate times before landing; (4) "everything feels dead" —
    repeated asks for hover/press feedback on buttons/dropdowns that look inert; (5) data-loss
    fear is a running thread (crash-then-lose-state, autosave confusion, "why prompting to save
    when we switch sessions") — this rhymes directly with the pre-launch-audit THEME 1
    (data-safety) findings in BACKLOG.md, i.e. the owner's early instinct about fragility was later
    independently confirmed by an agent audit months later.
  - A dense gap-analysis table appears mid-file (multi-cursor, autocomplete, print/PDF-export,
    unified goto-anything, project-wide replace, LSP rename, prose spellcheck, local history,
    markdown outline, git gutter/blame) tagged with rough cost signals (near-free/S/M) — nearly all
    of these items later show up as "DONE" or as board tickets, i.e. this list was a good early
    predictor of the actual roadmap.
  - "Applications" / MicroApp framing recurs explicitly ("Everything is tabs or tool windows...
    Basically toolwindows that show up as tabs... How feasible is [a plugin-contained web app]?")
    — this is early scaffolding for exactly the "plugin/MicroApp system" ask in the new project.
  - Explicit "Need my input" sections show the owner delegating design docs to the agent (Mermaid
    animation approach, Walkthrough JSON format + MCP transport, MCP automation surface) rather
    than deciding himself — matches the "spike + design auto-approved" policy that CLAUDE.md
    later codifies.
- carry-forward: DISTILL — mine this for a prioritized feature list AND as a perf/reliability
  early-warning signal (perf and data-safety complaints recur across the whole document, meaning
  they were under-addressed relative to volume of complaint — front-load them in the rebuild
  rather than treating them as post-launch polish).

**`README.md`** — user-facing quick-start (build/run/test, project layout, scripts reference, env
vars, distribution/signing) · status: current
- learnings: Small but concrete gotchas worth preserving: `open -a` resolves names via Launch
  Services not filesystem paths (use absolute path or registered app name); bundle id / signing
  cert are TCC-grant-keyed and must never change; a documented scripts-reference table
  (build/install/verify/bundle-size-check/notices-gen/visual-smoke/icon-pack) as the canonical
  list of what tooling a macOS app project needs day one.
- carry-forward: DISTILL — the scripts-reference-table idea and the signing/TCC gotchas are
  directly useful; the rest is standard README boilerplate.

**`AUDIT_BUGS.md`** — maintainable register of verified security/perf/correctness audit findings
(S1/S2 severity, file:line, evidence, suggested fix) · status: current, substantial (653 lines)
- learnings:
  - A genuinely rich catalog of concrete bug CLASSES that a Swift+Rust+WebView macOS app hits:
    unauthenticated localhost HTTP servers vulnerable to DNS-rebinding + missing Host-header
    validation (mdv-web crate); path-containment checks applied only at the "default" call site and
    silently bypassable via a `?path=` query param (the `root` confinement was "purely cosmetic");
    unanchored prefix-match containment (`hasPrefix(temp)` without the trailing slash) allowing a
    sibling-directory bypass — the EXACT bug class the correctly-anchored HOME check next to it
    avoids, i.e. one inconsistent helper regressed a fix that existed elsewhere in the same file;
    PTYProcess never resetting a pid sentinel so "restart shell" permanently no-ops after the first
    death; O(n²) hot paths from recomputing `.unicodeScalars.count` per appended character (CSV
    parser) and from full-buffer attribute repaint on every "next match" step (hex viewer); a
    dead-code ReDoS wall-clock guard that never fires because `NSRegularExpression.enumerateMatches`
    only invokes its stop-closure on a MATCH, so a catastrophic-backtracking non-match never reaches
    the timeout check at all; a "guard applied at the wrong layer" bug where a recursion-depth cap
    on the HTML-AST visitor doesn't protect against the underlying C parser (cmark-gfm) blowing the
    native stack BEFORE the visitor ever runs (~6000 nested blockquotes = hard SIGSEGV, not
    gracefully caught); CRLF-vs-Character-grapheme-cluster bugs recurring across TWO independent
    modules (IndentDetector, LSPPositionConverter) because Swift treats `\r\n` as one Character.
  - Pattern worth internalizing: several of these are "the fence exists in the codebase somewhere,
    but a NEW entry point doesn't route through it" — a chokepoint-discipline lesson (funnel every
    caller through ONE validated helper, don't let each new endpoint re-implement its own
    containment check).
- carry-forward: PORT — this is a genuinely reusable pre-flight security/perf checklist for the
  next build (localhost-server Host validation, path-containment chokepoints, CRLF-safe string
  scanning, ReDoS wall-clock-outside-the-match-loop, native-parser recursion limits BEFORE the
  managed-language guard). Recommend copying the concrete bug classes (not the file:line specifics)
  into the new project's security checklist / code-review rubric.

**`CODE_REVIEW.md`** — synthesis of 7 parallel-agent code reviews (security, concurrency/perf,
quality, UX/a11y, behavior, tests) from an early phase (2026-05-14) · status: superseded (explicitly
says "round 1 fixed; this supersedes it" and the ticket-level status here has itself long since
been absorbed into the board) — historical reference only
- learnings: Multi-agent parallel code review along orthogonal dimensions (security /
  concurrency-memory / perf / quality / UX-a11y / behavior-edge-cases / test-quality) as a
  structured technique, with a "Notable strengths (no action)" section that explicitly calls out
  what was done RIGHT (FileWatcher reattach/backoff discipline, tight WKWebView nav allowlist,
  TCC-protected-root auto-restore opt-out) — worth preserving reviews that record positives, not
  just findings, so good patterns get intentionally repeated.
- carry-forward: DISTILL — the 7-dimension parallel-review structure is a reusable review
  methodology; the specific findings are resolved/stale.

**`FINDINGS.md`** — single incident post-mortem: a SwiftUI+AppKit compositor bug where an
`NSScrollView.verticalRulerView` (containing a hidden `NSVisualEffectView`) silently killed
layer-content commits for EVERY sibling SwiftUI hosting layer in the window · status: resolved
(fixed in a cited commit), kept as a documented incident
- learnings: A genuinely subtle, hard-to-diagnose AppKit/SwiftUI interop bug class — installing an
  `NSRulerView` on a scroll view's ruler slot silently propagated invisibility to unrelated sibling
  SwiftUI-hosted views elsewhere in the window (not even inside the same NSScrollView). Root cause:
  the ruler-installation path inserts a private `_NSScrollViewContentBackgroundView`
  (NSVisualEffectView) that broke the PARENT NSHostingView's layer-commit path. Fix: never attach
  via `NSScrollView.verticalRulerView`; use a plain sibling NSView container instead. Also documents
  a real test-harness limitation: spawning an app from a non-foreground bash leaves the window
  occluded, so `CGWindowListCreateImage` returns blank even though the view tree is correct — tests
  must assert on structural dumps (JSON), not screenshots, unless run in a VM where the spawned
  window is actually foregrounded. This exact incident is why the CLAUDE.md "compositor occlusion"
  rule and the whole VM-only UI testing policy exist — traces a policy back to its origin bug.
- carry-forward: PORT — the specific "never use NSRulerView / verticalRulerView with SwiftUI
  siblings" rule is directly applicable if the rebuild ever touches AppKit NSScrollView + SwiftUI
  again. DISTILL the general lesson: AppKit private compositing side-effects can silently break
  unrelated SwiftUI siblings; test via structural dumps in a VM, never screenshot-from-a-backgrounded-terminal.

**`HACKABILITY.md`** — extension-point map: "how to add X in under 30 minutes," one recipe per
extension type (new highlighted language, new view mode, new sidebar section, new menu command, new
file format, new theme, new formatter) · status: current
- learnings: A genuinely well-designed "extension recipe" doc format — each entry names the exact
  files to touch, in order, ending with "which test to add." This is the single clearest artifact
  of what made the 3-package module boundary (ViewerKit/ViewerCore/ViewerUI) pay off: every
  extension point has a small, bounded footprint because logic and UI are already separated. Worth
  emulating as a living doc in the rebuild — write it EARLY (not after the fact) since it also
  functions as a design-boundary enforcement tool (if an extension recipe requires touching 10
  files instead of 5, that's a signal the module boundary has eroded).
- carry-forward: PORT — the doc FORMAT (recipe-per-extension-point, ends in "which test") should
  be started on day one of the rebuild, seeded with placeholder recipes as each subsystem lands.

**`PLUGINS.md`** — DRAFT design brainstorm for a plugin/extensibility system; never implemented as
described · status: superseded (design draft, not the actual PLUGINS-v2 system that later shipped
per CLAUDE.md references) — historical/ideation value only
- learnings: A clean comparison of plugin packaging options (native Swift bundle vs WKWebView-JS vs
  external-process JSON-RPC/LSP-style vs WASM vs AppleScript vs URL-scheme-only) with pros/cons and
  a recommended HYBRID (native for hot-path extension points like highlighters/viewers, JS-bridge
  for UI-light commands/widgets, URL-scheme for "send to X" integrations) — directly relevant
  groundwork for the new project's stated "plugin/MicroApp system" goal, especially since the new
  project is explicitly Rust-core + WebUI-capable, which changes the calculus (a Rust-core-hosted
  plugin ABI or WASM plugin sandbox becomes much more attractive than it was when this doc was
  written for a pure-Swift-with-WKWebView app).
- carry-forward: DISTILL — re-evaluate the packaging-option comparison against the NEW project's
  Rust-core + multi-transport architecture; WASM (rejected here as "immature on macOS, can't touch
  AppKit") may now be the right default given the new project explicitly wants a portable/remote
  core, and Rust core already has a stated wasm32 target validated elsewhere in the org's tooling.

**`STATE.md`** — audit of where state lives (DocumentModel @Published fields, UserDefaults,
JSON-file stores, per-tab structs, view-local @State) + a proposed unification with explicit
persistence tiers · status: superseded (this was the design for what became the later
Sessions/Workspaces system; specifics are historical, the state-inventory technique is not)
- learnings: The proposed `PersistenceTier` enum (ephemeral / per-launch / persistent-until-changed
  / persistent-workspace-scoped, roughly) as an explicit TAG on every piece of app state is a good
  idea that seems to have generalized into the later Sessions/Workspaces architecture. The
  "what's broken today" list (tabs vanish on quit, sidebar-expanded-state lost, theme override not
  persisted, no crash-recovery snapshot, no cross-window shared-state story) reads as an accurate
  prediction of exactly the kinds of THEME-1 data-safety bugs the 2026-07 pre-launch audit later
  found in a much more mature codebase — i.e. these state-persistence gaps were flagged as a design
  risk on day ~5 and resurfaced as real production bugs 8 weeks later. Strong argument for treating
  persistence-tier design as a first-class up-front architecture decision, not something to
  retrofit.
- carry-forward: DISTILL — do the state-inventory-with-explicit-persistence-tier exercise EARLY in
  the rebuild, before DocumentModel-equivalent sprawl happens, specifically because this project's
  own history shows the gaps identified early were never fully closed and directly caused
  data-safety findings near the end.

**`TESTING.md`** — the "running view" of the test pyramid (companion to DESIGN.md §7): what tiers
exist today, how to run them, current coverage counts · status: superseded by
`docs/TEST_PYRAMID.md` (per CLAUDE.md pointer) but historically shows the EARLY test pyramid
(509 cases, 85s) vs. the eventual scale (5,266 tests referenced elsewhere) — good before/after data
point
- learnings: The "what each bug class is caught by which tier" table (pure-logic regression → T1;
  @MainActor state-machine drift → T1m; views structurally present but visually empty → pixel
  tier; real-app off-screen/wrong-size → live-app tier) is a clean, reusable mental model for
  designing a test pyramid around ACTUAL bug classes observed, rather than generic industry-pyramid
  advice. Explicitly ties the pixel + live-app tiers' existence to one specific regression ("source
  view shows only line numbers") — another example of a policy/tier traced back to a real incident.
- carry-forward: DISTILL — the bug-class-to-tier mapping table is a good starting scaffold; rebuild
  it against the new project's actual early bugs rather than copying verbatim.

**`THIRD_PARTY_NOTICES.md`** — generated (`scripts/gen-third-party-notices.sh`) license-notice
bundle for SwiftPM deps + vendored JS bundles (Mermaid, CodeMirror 6) · status: current as a
generated artifact, but per BACKLOG.md THEME 4 it is **NOT actually copied into the shipped
bundle** — a real ship-blocker gap between "the generator exists" and "the generator's output
reaches the user"
- learnings: The gap between "we generate compliance docs" and "we actually ship them" is exactly
  the kind of thing that only surfaces in a pre-launch audit — worth wiring a build-time assertion
  (fail the release build if `THIRD_PARTY_NOTICES.md` isn't present in `Contents/Resources/`) rather
  than trusting a comment claiming a `cp` step exists.
- carry-forward: DISTILL — automate-and-verify license-notice bundling from day one of the release
  pipeline (a CI check that the generated notices file is present inside the assembled bundle), not
  as a late-stage manual step.

**`UAT_BUGS.md`** — maintainable register of UNFIXED bugs found via agent-driven UAT smoke sweeps
(severity/kind/status legend, repro/expected/actual/root-cause/evidence per entry) · status: current
- learnings: Concrete example of the T6-agent-driven-UAT tier finding REAL bugs that headless model
  tests missed: a dirty-dot indicator whose underlying model state (`Tab.isDirty`) was correctly
  true but never triggered a SwiftUI re-render because a prior perf-motivated refactor severed an
  `objectWillChange` forwarding path — the coordinator-split "republish invariant" pattern
  (DESIGN.md) exists specifically to catch this class, and this bug shows a REGRESSION of that
  exact invariant slipping through anyway (worth noting the invariant test alone wasn't sufficient
  — model correctness and view re-render are two separate things to test). Also documents a harness
  limitation as its own tracked bug: the `--script` runner's `delay SECS` verb silently ignores its
  argument and always sleeps a fixed 300ms, capping the max expressible async-settle window for
  every T4 smoke test — a good example of "the test harness itself needs test coverage / audit."
- carry-forward: DISTILL — the UAT-bug-entry schema (severity/kind/status/repro/expected/actual/
  root-cause/evidence/why-not-fixed) is a clean, reusable bug-report template for agent-driven UAT
  in the next project.

**`UI_CATALOG.md`** — living component-by-component spec (window, TabBar, ModeBar, sidebar, etc.)
with expected geometry/behavior tables and pointers to the specific tests that cover each — "when
in doubt, the test is the spec" · status: current
- learnings: A genuinely strong documentation pattern: instead of prose describing UI behavior, each
  component gets a property/expected table PLUS an explicit test-file pointer per tier (L1 model /
  L3 hosting / L3+ diagnostic / L4 interaction), making the catalog literally executable — anyone
  can verify a claim in the doc by running the named test. This is the doc-form of "the acceptance
  criterion IS the pixels the test asserts on."
- carry-forward: PORT — the "component table + per-tier test pointer, test-is-the-spec" format is
  directly reusable for the rebuild's UI documentation.

**`ICON_GUIDE.md`** — app-icon design + regeneration guide (geometry constants, Core-Graphics
source of truth, regen script chain) · status: current
- learnings: Notable minimal-deps choice: the icon is generated from a checked-in Swift/Core
  Graphics script rather than an SVG→PNG toolchain (rsvg-convert/ImageMagick/Inkscape), specifically
  to avoid an extra install per the project's "minimal deps" rule — and it's framed as also more
  precise (no intermediate raster scaling step). A small but real example of the minimal-deps
  principle extending even to design/asset tooling, not just runtime libraries.
- carry-forward: DISTILL — the "generate icons via a checked-in native script, not a design-tool
  dependency" approach is worth repeating if minimal-deps is again a hard constraint.

**`PHASE_5B_TREESITTER.md`** — the design spike doc that decided/justified adopting TreeSitter for
syntax highlighting over regex/Splash/Highlightr/Runestone/Neon · status: superseded (implementation
landed long ago; decisions here are historical but the reasoning is still valid) — kept as design
rationale
- learnings: Concrete package-selection reasoning worth reusing verbatim as a technique: enumerated
  every real alternative (ChimeHQ/Neon rejected because it's an NSTextView-coupled flicker-free
  layer and this app's source view was pure SwiftUI at the time; Runestone rejected as "full editor
  framework, we're a viewer, too much surface + duplicate C runtime"; Splash rejected as Swift-only
  = quality ceiling; Highlightr rejected because running highlight.js in a JSContext puts a JS
  engine on the hot path of a native viewer — "works, but wrong"). Also flags the specific technical
  primitive that matters most for a markdown-plus-code-fences use case: TreeSitter's "injection"
  mechanism for nested-language parsing (block+inline markdown grammars chained to per-fence-language
  grammars) — this is the reusable insight, not just "we picked tree-sitter."
- carry-forward: PORT — since the new project explicitly wants tree-sitter again (per the request
  framing), this doc's dependency-selection reasoning and specifically the "vendor `.scm` query
  files in-repo" decision (Decision C referenced) are worth re-adopting near-verbatim, re-verified
  against current tree-sitter-org package state.

**`OVERNIGHT_REPORT.md`** — session handoff report documenting 13 major commits (line-number gutter,
native previews, search sidebar, SQLite browser, mode normalization, git module, workspace restore,
etc.) plus test additions (+46 unit tests), known regressions, and a manual sanity checklist · status:
superseded/historical (one-time session snapshot, dated implicitly by commit 24b64d4)
- learnings:
  - The structured **commit-by-commit table** format (Commit SHA | What) + test-count summary is a
    compact way to communicate a large batch landing — allows the owner to eyeball what shipped
    without reading 13 separate commit messages, and pairs with a TEST STATUS section that quotes the
    passing gate count and a specific prior-commit anchor. Portable pattern.
  - **Known-issue honesty**: explicitly surfaces (a) a test regression with a diagnosis hypothesis
    and repro steps, (b) intentionally-skipped work with rationale (E2E dedup audit, distribution
    phase, split-view), (c) known limitations ("Workspace restore skips missing files," "SQLite
    read-only," "Claude timeline caps at 200 events"), and (d) a "if something breaks" troubleshooting
    section with repro env-vars (e.g. `MDV_ENABLE_BROKEN_RULER=1`). The last section is especially
    valuable — it encodes common-failure gotchas with exact reproduction steps, a real aid for
    unblocking the owner's subsequent manual testing.
  - The manual sanity checklist, though explicitly not a substitute for automated testing, is
    conscientious in its scope (testing modality combinations, file-type-specific behaviors, round-trip
    persistence) and explicitly calls out which tests are DEFERRED (Tier 4 CI image, split-view, "wrap-mode gutter accuracy").
- carry-forward: DISTILL — the commit-table + test-summary + manual-checklist + troubleshooting
  structure is a reusable pattern for any autonomous overnight/weekend run landing multiple features.
  The troubleshooting section in particular (reproduce-via-env-var-flag) is worth emulating as part
  of any work that touches known-fragile subsystems.

**`TESTS_AUDIT.md`** — E2E test-suite overlap analysis identifying concrete wall-clock-time savings
(~33%, ~25s off a 75s suite) through dedup and consolidation, with specific tests named and rationale
given · status: current (awaiting owner approval before implementation per the doc's final section)
- learnings:
  - A principled **wall-clock-tier breakdown** (file-by-file test counts + wall-clock per test type +
    clear highlighting of app-spawning tests that dominate suite time) makes test-dedup decisions data-driven
    instead of gut-feel. The analysis correctly identifies that 18 app-spawning tests ≈ 50s of 75s total,
    making ~3 spawned tests each worth ~2.8s — anything that eliminates one full spawn saves real time.
  - **Three concrete overlap patterns are identified and categorized:**
    1. Pure-property assertions tested via app-spawn when they could move to unit tests (zoom
       persistence, toggling);
    2. Strictly-weaker tests in the same scenario space (one test does "open + zoom," another does
       the same thing as a sub-step of a larger scenario — keep the larger one);
    3. Complementary app-spawn tests that could merge into one multi-step script (4 separate tests
       doing "open + toggle + zoom" could become one script asserting at each step).
  - Critically, the audit **explicitly PRESERVES high-confidence unique tests** (SourceViewVisualRegression,
    the "day in the life" 15-interaction smoke, FileWatcher), recognizing that test speed must not come
    at the cost of losing a regression class — a disciplined "don't trade safety for speed" stance.
- carry-forward: DISTILL — the wall-clock-tier breakdown and overlap-categorization methodology are
  directly reusable for the next project's test suite as it grows. IMPORTANT: the principle "move
  pure-logic assertions out of app-spawning tiers" is a general architectural lesson (tests should be
  tiered by their actual dependency surface, not by historical convenience). The specific audit
  recommendations (3x 9s savings, 1x 3s saving) are project-specific and don't port, but the
  methodology does.

**`VM-SETUP.md`** — detailed how-to guide for running the test suite inside a UTM macOS guest,
covering image specs, one-time setup, permissions needed, run modes, and explicit rationale for why
the VM solves the "occlusion bug" class · status: current (practical, actively referenced per earlier
CLAUDE.md VM directives)
- learnings:
  - The **minimal permission set** is carefully delineated: `Files and Folders → /tmp` is mandatory
    (tests write fixtures there); `Screen Recording` and `Accessibility` are optional (only needed if
    you want PNG snapshots non-blank or ad-hoc osascript poking). The doc explicitly calls out what's
    NOT needed (Notifications, Contacts, Camera, etc.), a form of permission-hygiene discipline that
    clarifies what the test harness ACTUALLY requires vs. what it _could_ ask for.
  - **The occlusion-bug explanation is crucial**: when the script runner spawns the app from a
    non-foreground bash on the host, the spawned window stays occluded, AppKit suspends drawing, and
    PNG snapshots come back blank — this is the origin of the VM-only UI testing policy documented in
    CLAUDE.md. By contrast, in a VM where the test bash IS foreground and nothing else is competing,
    the spawned window comes to the front naturally, and PNG captures work. The explanation ties a
    testing policy back to a concrete macOS/AppKit behavior, not just "run tests in a VM because it's
    cleaner."
  - Explicit mention that "the script runner drives the model directly, not via Accessibility events"
    (a contrast to the optional Accessibility grant) clarifies the test harness's architecture:
    L4 tests spawn the app and exercise it via script (model manipulation), not via synthesized AX
    events — the harness is BEHAVIORAL, not structural-accessibility-based.
  - The "expected result" section gives a concrete baseline: "Executed 359 tests, with 0 failures" on
    a fresh VM, anchors expected wall-clock (~75s on 4-vCPU), and explicitly handles the TCC
    permission prompt ("if /tmp isn't granted, you'll see a dialog the first time; grant it, re-run").
- carry-forward: DISTILL — the permission-auditing discipline and the explicit occlusion-bug
  rationale are generalizable. The concrete specs (4 vCPU, 8 GB RAM recommended; VirtIO shared
  folder preferred over git clone) are project-infrastructure-specific, but the PATTERN
  (encapsulate heavy tiers in a separate GUI session, clarify what permissions are actually needed,
  explain why the VM solves a real host-side behavioral problem, give a concrete expected-result
  baseline) is reusable for the next project's VM testing infrastructure if heavy tiers are adopted
  there too.

---

## Key learnings from this batch

1. **The module-boundary decision (ViewerKit/ViewerCore/ViewerUI, "zero UI in Core") is called out
   repeatedly, independently, across DESIGN.md, HACKABILITY.md, and TESTING.md as THE decision that
   made everything else possible** — ~80% of behavior ended up unit-testable headless, extension
   recipes stay small, and the test pyramid could be built bug-class-first instead of
   generic-industry-pyramid. This is the single highest-confidence "keep doing this" signal in the
   whole batch.
2. **Policies in CLAUDE.md are not abstract rules — nearly every one traces back to a specific,
   named incident** (compositor occlusion → FINDINGS.md; VM-only UI testing → the same incident's
   harness-occlusion discovery; teeth-doctrine negative-control switches → false-green ImageRenderer
   traps; root-cause-discipline 5-point checklist → a specific TSK-1046 re-diagnosis miss). The
   rebuild should keep this "policy ⇄ incident" traceability discipline rather than starting from a
   generic best-practices list.
3. **State-persistence gaps flagged on day ~5 (STATE.md) reappeared as real data-safety bugs in the
   week-8 pre-launch audit (BACKLOG.md THEME 1).** An explicit `PersistenceTier` design exercise,
   done early and enforced, would likely have prevented a cluster of the audit's highest-severity
   findings (debounce-never-flushed, hot-exit-spill-deleted-during-drain, silent write-failure
   discards). Do this exercise in week 1 of the rebuild, not as a retrofit.
4. **Perf and data-loss are the two most-repeated complaint categories across the entire
   OwnerWishlist.md timeline** (spanning the whole 8-week project) — both categories recur late into
   the project despite active work, suggesting they were systematically under-prioritized relative
   to feature breadth. Front-load performance budgets (not just correctness tests) and
   persistence/data-safety invariant tests as first-class, continuously-gated concerns.
5. **Multi-agent fan-out has a real, repeated failure mode at scale**: a 104-agent pre-launch-audit
   workflow died TWICE on account/session limits with zero synthesis both times, salvaged only by
   manual triage of raw partial output. Design large audits with checkpointed, resumable synthesis
   (not "verify everything, then synthesize at the very end") so a mid-run death doesn't discard the
   work already done.
6. **AUDIT_BUGS.md's "chokepoint" pattern** — several S1/S2 findings are cases where a correct
   validation helper exists somewhere in the codebase but a NEW call site bypasses it (unanchored
   prefix match, `?path=` query param skipping the `root` containment, ReDoS guard placed at the
   wrong point in the call chain) — is a generalizable code-review heuristic: for every security/
   safety invariant, grep for ALL call sites, not just the "main" one, and route them through a
   single funnel function.

## Decision records found — decision + rationale + (how it played out)

- **Swift + AppKit shell + SwiftUI content, ~$0 deps** (DESIGN.md §2) — rationale: native Mac
  feel, NSDocument gives history free, avoids Electron's "100s MB, violates minimize-deps."
  Played out: held for the whole project; the later Rust-core migration was layered underneath
  without disturbing this choice.
- **Shell out to `/usr/bin/git`, reject libgit2/SwiftGit2** (DESIGN.md §2) — rationale: avoid a
  heavy native dep; revisit only if perf regression demands. Played out: never revisited — still
  the approach per README.md.
- **3-package module split (ViewerKit/ViewerCore/ViewerUI)** (DESIGN.md §3) — rationale: enables
  headless testing of ~80% of logic. Played out: validated repeatedly as the single best structural
  decision (see Key Learnings #1).
- **Defer snapshot-testing (Tier 2) and ViewInspector (Tier 3)** (DESIGN.md §7) — rationale:
  evidence-based, "these tiers would have caught zero/one of our actual bugs so far." Played out:
  per TESTING.md, deferred tiers were later replaced by a different, more effective combination
  (pixel-sampling `ImageRenderer` tests + live-app `.app`-spawn tests) rather than the originally
  planned snapshot/ViewInspector tiers — the deferred plan was correctly abandoned rather than
  eventually adopted, validating the "defer until it pays off" call.
- **VM-only UI/live-tier testing, host stays window-free** (CLAUDE.md, owner directive 2026-06-06)
  — rationale: a bare `swift test` on a host with a built bundle used to spawn a T4 LiveAppTestCase
  window on the owner's screen mid-work. Played out: closed structurally via `TierGateObserver`
  self-skip guard, not just a documented rule — a good example of fixing a policy violation with a
  code mechanism instead of relying on agent compliance.
- **Reject cargo-mutants for Rust mutation testing, DIY instead** (CLAUDE.md dep-hygiene rider) —
  rationale: `cargo install <tool>` compiles the tool's full transitive tree locally, so even
  "external dev tooling" is in-scope for the dependency-hygiene rule. Played out: recorded as a
  standing decision; DIY replacement tracked in BACKLOG.md.
- **THIRD_PARTY_NOTICES.md generator exists but was never wired into the actual bundle-copy step**
  — not a deliberate decision, but a discovered gap (BACKLOG.md THEME 4) — the generator's own
  header comment CLAIMED `build-app.sh` copies it; it didn't. Lesson: verify claims like this with
  a build-time assertion, not a code comment.

## Portable-artifact candidates — docs or sections that should be copied into the next project

1. **HACKABILITY.md format** (recipe-per-extension-point, files-in-order, ends in "which test to
   add") — start this doc on day one, seeded incrementally as each subsystem lands, and use it as a
   module-boundary-erosion detector (recipe getting longer over time = boundary eroding).
2. **UI_CATALOG.md format** (property/expected table + per-test-tier pointer per component,
   "the test is the spec") — directly reusable UI documentation convention.
3. **CHANGELOG.md's two-section split** (user-facing narrative + terse `### System work` roll-up
   per area) — solves the "95% of commits aren't user-facing, but the owner wants to see where the
   effort went" problem cleanly.
4. **HANDOFF.md's current-state-not-log convention + enforced size budget** — a concrete, testable
   mechanism (not just a policy statement) for keeping context-injection costs bounded across
   compactions.
5. **AUDIT_BUGS.md's bug-class catalog** — copy the CONCRETE classes (localhost-server Host
   validation, containment-chokepoint discipline, CRLF/grapheme-cluster traps, ReDoS guard
   placement, native-parser-recursion-before-managed-guard) into the new project's security/
   code-review checklist as a pre-flight list, verified fresh against the new stack rather than
   assumed to still apply.
6. **DESIGN.md's "one producer, two render surfaces" highlighting architecture** and the
   coordinator-split + forwarder + republish-invariant-test pattern — both are concrete, working
   architectural templates worth reproducing rather than rediscovering.
7. **PHASE_5B_TREESITTER.md's dependency-selection reasoning** — since tree-sitter is explicitly
   wanted again, re-verify the same alternatives (first-party `tree-sitter/swift-tree-sitter` fork
   status, injection-based nested-language handling for markdown+fences) against current package
   state rather than re-deriving from scratch.
