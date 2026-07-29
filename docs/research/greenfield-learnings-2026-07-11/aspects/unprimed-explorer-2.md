# Unprimed explorer 2 — what to get right, what traps await

Method: no prior analyst findings read. Investigated the previous attempt (`markdown_viewer`
repo) cold — git history, LESSONS.md, HANDOFF.md, BACKLOG.md, CHANGELOG.md, CLAUDE.md, board
state — against only the owner's one-paragraph requirement statement.

## The raw numbers, because they're the loudest signal

- **3,733 commits in ~57 days** (2026-05-14 → 2026-07-10) — roughly 65 commits/day, sustained.
- **405,956 lines** of Swift/Rust/TS/JS source. 2,009 Swift files, 85 Rust files, 1,227 test files.
- **336 markdown docs** in `docs/`; `LESSONS.md` alone is **333 KB / 4,055 lines**; `CLAUDE.md`
  (the project-instructions file re-read every session) is **39.8 KB**.
- **703 commits with "fix" in the subject, 12 explicit reverts** out of 3,733 — about 1 in 5
  commits is a fix-commit. That's a churn rate, not a delivery rate.
- At the most recent handoff: **~40+ tickets sitting at `review`**, all waiting on the owner to
  `task_validate` — a queue the single human reviewer cannot plausibly keep up with at the rate
  the agent produces "done" work.
- A pre-launch audit (owner-triggered, still unfinished when work paused) found, in its first
  pass, a cluster of **silent data-loss bugs** in a project that had been "shipping" features for
  weeks: CM6→Swift debounce never flushed on save, session-switch deleting the hot-exit spill it
  just wrote, no conflict guard on the hex editor, silent persistence-write failures, a strict
  bookmark decode that wipes ALL bookmarks on one bad entry, and a "Merge…" button that silently
  behaves as Keep-Mine and clobbers the other side. None of these had been caught by the extensive
  test pyramid described below.

That combination — enormous commit/test volume, a large fraction of it self-correcting, and
data-loss bugs still present after 8 weeks — is the single most important thing to internalize
before starting the next attempt.

## What matters most to get right

**1. Decide, on day one, what "done" means for a UI behavior, and make the test pyramid match
the RENDERING TECHNOLOGY, not the framework's promises.** The single most expensive recurring bug
class in this codebase was a WindowServer-compositor bug (`NSTextView` inside a SwiftUI tree via
`NSViewRepresentable`, killed by attaching an `NSRulerView`) that was **invisible to every headless
test** — `xctest` view-tree walks pass, `cacheDisplay`/`ImageRenderer` redraw fresh and lie about
composition. It recurred *four times* before the team wrote it down as a **structural prohibition**
("never attach an NSRulerView to this scroll view") rather than trusting tests to catch it. The
lesson generalizes hard for a native-Swift-host + WebView-hybrid app: any time you mix a
GPU-compositing native element (WKWebView, NSTextView, a terminal surface) with SwiftUI siblings in
the same z-stack, get the compositing/z-order model right *by construction* before writing a single
feature on top of it, because no amount of unit/integration testing will catch a regression there —
only real WindowServer pixel capture does, and that's expensive enough that it can't gate every
commit.

**2. Pick ONE rendering technology per "kind of surface" and commit — don't let two engines coexist
"temporarily."** The final HANDOFF found the app was still carrying **two text-rendering engines**
(NSTextView and CM6-via-WebView) months in, with CM6 handling everything except files >512 MiB,
which NSTextView still owned because CM6 had no large-file guard. That kind of "we'll migrate later"
duality is exactly what the owner's requirement (CM6 as the *chosen* editor) is trying to avoid
paying for twice — every feature (find, folding, gutter, LSP hookup) had to be built/tested against
both engines for a long stretch. Given the owner has *already prototyped and picked CM6*, the next
project should make CM6-via-WebView the only text-rendering path from day one and solve the
large-file case (virtualized viewport, chunked load) as part of that architecture rather than
keeping a native fallback alive indefinitely.

**3. Design the agent-review/transparency loop as a first-class primitive, not a bolt-on feature.**
The owner's stated core motivation — "make my interactions with AI non-blackboxy," git-integrated
review, reverse-review/walkthrough, and the Canvas (agent builds UI incrementally in a WebView,
not top-down HTML dump) — is the actual *product thesis*, not one feature among many. In this repo
that thesis shows up late and diffusely: a `Code Review v2` design, an `AGENT_SERVICES_DESIGN`, a
merge-conflict-resolution UI, and the Canvas milestones (M0–M6) were all built as separate,
sequentially-designed subsystems rather than one coherent "agent transparency" architecture
decided up front. Concretely: the Canvas's own incremental-build primitive (a diffable, replayable
scene graph with undo/timeline — see this repo's `mcp__textview__canvas_*` tool family) is the kind
of thing that should be a *foundational* API surface (how any plugin/MicroApp talks to the shell),
not a plugin-specific afterthought — decide the "how do agents make incremental, reviewable,
undoable changes to anything" contract before building the first MicroApp.

**4. Scope the MicroApp/plugin ambition explicitly, and sequence it — the last project effectively
tried to build all of it simultaneously.** The requirement list itself is enormous (image editor,
markdown, PDF viewer, spreadsheet, DB viewer, terminal, LSP, git, canvas, walkthroughs...) and the
previous attempt visibly tried to make progress on most of them in parallel (the CHANGELOG shows
paint-tool curve/polygon/text additions, spreadsheet fill, git staging, spelling-as-a-driveable-verb,
and LSP status — all landing within the same week). That breadth is *why* the review queue backed
up and why data-safety bugs went unnoticed: attention was spread across a dozen concurrently-moving
surfaces instead of hardening the core editor + one MicroApp end-to-end first. Get the requirement's
own ordering hint right — "text editor" first, "extensible plugin system" designed early but
populated with ONE well-tested MicroApp before a second is started.

## Traps the new project will walk into if nobody warns it

- **The "host-testable ≠ actually visible" trap.** Any layer that composites (SwiftUI + WebView,
  SwiftUI + AppKit, or — if the web-UI target is taken seriously — any DOM+canvas hybrid) needs a
  *real pixel-capture* validation tier from the start, and everyone touching that layer needs to
  know headless-green is not proof. Don't rediscover this after four recurrences.
- **The "agent self-reports fixed" trap.** The prior project's board had ~40 tickets stuck at
  `review` and a policy that agents could self-validate only with hard automated evidence — yet
  serious data-loss bugs shipped anyway, because the automated evidence existed for the *feature*
  ("save works") but not for the *edge case* ("save works when the debounce hasn't flushed yet").
  Write acceptance criteria that name adversarial/edge scenarios (crash mid-write, conflicting
  concurrent edits, malformed persisted state) up front, not just the happy path — and treat
  "silent data loss" as a P0 test category from commit one, not something an audit discovers in
  week 8.
- **The velocity-vs-review-throughput mismatch.** 65 commits/day sustained for 8 weeks vastly
  outpaces what a single human owner can meaningfully review. If the new project again uses
  heavy agent-driven autonomy, build the review/validation *capacity* into the plan explicitly
  (sampling strategy, risk-tiered auto-approval for low-risk changes, a hard cap on WIP-at-review)
  rather than letting the backlog grow until it's abandoned. A queue nobody reviews is equivalent
  to no review.
- **The "two engines, two test suites, indefinitely" trap.** Every dual-implementation decision
  ("keep the old one around for X case") that isn't explicitly time-boxed or scoped tends to become
  permanent scope-multiplication — every future feature must be re-verified against both paths.
  Decide up front whether large files, legacy formats, etc. get a *fallback engine* or a *scoped
  degraded mode of the primary engine*, and default to the latter.
- **Docs-as-a-second-codebase.** 336 markdown files and a 333 KB `LESSONS.md` is itself a
  maintenance burden — the CLAUDE.md instructions in this repo already had to impose hard *byte
  budgets* on `HANDOFF.md`/`CLAUDE.md` because context-reinjection cost was becoming a tax on every
  session, and `LESSONS.md` still grew unbounded past 300 KB regardless. If the next project again
  leans on long-running autonomous/agent-driven development, decide the durable-knowledge storage
  strategy (size caps, pruning cadence, what's a "lesson" vs a "one-off war story") before the first
  1,000 commits, not after.
- **Infrastructure-for-agent-development competing with product time.** A large fraction of the
  effort visible in this repo (VM validation lane, tiered test pyramid T1–T6, board/ticket tooling,
  workflow orchestration scripts, bundle-size gates, xattr/TCC/codesigning workarounds) is *meta*:
  infrastructure to make agent-driven development itself trustworthy, not the editor's own features.
  Some of that is genuinely necessary given the owner's agent-centric goals, but it's worth budgeting
  and naming explicitly as its own workstream rather than discovering, 8 weeks in, that a third of
  all commits were about testing infrastructure and process rather than the product surface the
  owner described wanting.
- **License/notarization/security debt deferred to "later."** The audit (unfinished) already flagged
  an unauthenticated MCP socket, unbundled third-party notices for ~30 Rust crates + ~15 grammars,
  no notarization run, and known-CVE dependencies (Mermaid) still in use at week 8. If the new
  project again defers "ship-blocker" hygiene (licensing, signing, dependency CVEs, auth on any
  local network/IPC surface) until a pre-launch audit finds it, expect the same last-minute pile-up.
  Bake these into the CI/gate from day one instead of treating them as a pre-launch checklist item.
