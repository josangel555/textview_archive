# Master Synthesis — greenfield learnings from `markdown_viewer`, for the rebuild

2026-07-11 · Opus, final read. Inputs: both `summaries/` INDEXes, all 15 `aspects/`, all 3
`holistic/` reports, the 7 `PORTABLE/` artifacts, and the prior studies (1.3 GB struggle
meta-analysis, repo/board archaeology, the unverified pre-launch audit, the v4 tracker design).
Verification note: pre-launch-audit findings were **gap-class evidence** at write time — the audit's
adversarial verify phase never ran, so individual bugs were "plausible, unconfirmed," though the
*classes* were corroborated across independent streams. **Update (2026-07-11):** a dedicated
verification pass has since checked all 12 cited findings against current `main` (be3b1008) —
10 CONFIRMED, 1 REFUTED (FormulaEngine dead-tail), 1 PARTIAL (the "every caller" overstatement on
`JSONFileStore.write`). Per-citation verdicts are tagged inline in the top-20 list below; full
evidence in `aspects/VERIFICATION_dataloss.md` and `aspects/VERIFICATION_security_packaging.md`.

This is the document to read first. It answers the owner's question — *"How can I approach
building it?"* — and ranks what actually cost and what actually paid, so the rebuild starts at the
prior project's end-state instead of re-earning it.

---

## The story of this project in one page

`markdown_viewer` started on 2026-05-14 as *"a native macOS file viewer + minimal editor —
plaintext and markdown."* Fifty-seven days later it was a 405,956-LOC IDE-plus-multimedia-platform
across **12 feature families**, built almost entirely by agents: **3,733 commits (~65/day),
1,474 board tickets (board-verified 2026-07-11; commit-trailer grep undercounted at ~1,168 —
see `aspects/board-ground-truth.md`), 9,988 test functions (more test LOC than product LOC), 150 context
compactions, one human owner as sole reviewer.** It is a genuinely impressive body of engineering
and, simultaneously, a precise map of how agent-driven development fails at the seams.

**What was built, and how it went** — five phases (from the 19 commit-era reports):

| Phase | Span | What a manager would have seen |
|---|---|---|
| **P1 Land-rush** | 05-14→06-03 | Skeleton→features in a day; the compositor bug already reworked twice in 36 h; first 47-agent/172-finding audit establishes the severity-triage ritual; Rust-core FFI debuts. Velocity looks spectacular; the false-green problem is present but undiagnosed as a *class*. |
| **P2 Hardening + logging plateau** | 06-03→06-14 | 80-finding deep audit; VM lane unblocked piecewise (TCC/ulimit/launchctl); staged Rust soaks. "Log every item" mandate pushes docs-to-code to its **1.5–1.7:1 peak** — ⅓ of all motion becomes process artifacts. |
| **P3 Platform wave** | 06-14→06-22 | Peak feature velocity (multi-window sessions, LSP rename, image editor, exporters); zero reverts for 6 days; ~30 feature families now open in parallel. |
| **P4 Production-readiness + Canvas** | 06-22→07-02 | The two great re-fix crises root-caused (scroll-restore ×24 commits, UAT env-delivery ×11); the one scheduled refactor sprint (DocumentModel, 40 slices, zero regression); formula port done with differential fuzzing; Canvas research fans out to **~75 agents and burns ~half a session quota** before M0–M6 slicing rescues the build. |
| **P5 Reckoning** | 07-02→07-10 | The owner's Built/Logic/**Usable** audit lands the verdict: *"almost all of them are unusable"* except the editor core. Board-vs-code reconciliation finds the board **understating** completion; a 37-tick drain surfaces 3 crash classes, 22 built-but-unshipped subsystems, ~40 dead render tails; the pre-launch audit finds the ~8-P1 data-loss cluster, an unauthenticated MCP socket, zero attribution shipped, notarization never once run [verified ✅ → `aspects/VERIFICATION_dataloss.md`, `aspects/VERIFICATION_security_packaging.md`]. |

**Where the cost actually went** (the honest accounting, from the commit ledger + transcript study):

- **Process/substrate: ~⅓ of all motion.** `docs:` commits (1,397 = 37%) *outnumber* `feat:` (988)
  and dwarf `fix:` (374). One file — `AUTONOMOUS_PROGRESS.md`, 1,031 touches / 14,987 lines — is
  **17% of the entire commit history**. This was compaction-survival insurance, not documentation.
- **Substrate friction: 56% of all tool errors** (260 post-compaction file-amnesia + 180
  tracker-lifecycle violations of 791) — none of it product work, **none of it ever improving over
  7.5 weeks** of rejection feedback.
- **Test volume as a broken proxy:** 9,988 test functions distributed **81% headless / 1.4%
  real-pixel** — the inverse of where the costliest bug class lived, and blind by construction to
  the data-loss/lifecycle/security cluster the week-8 audit found (24 real-render test functions for
  ~30 surfaces).
- **Duplicate engineering from one undeferred decision:** 5 find runtimes, 3 scroll-persistence
  channels, 2 highlight engines, 2 fold engines, 2 WebView caches — the native-vs-web split, never
  decided, paid for repeatedly (it *manufactured* the 5-ticket scroll-restore bug family).
- **Harness/infra: a permanent ~15–20% tax** — VM-lane bring-up recurs in nearly every era; 124 GB
  of worktree bloat at peak.

**Where the value actually came from** — and the PM-level irony: **effort correlated *inversely*
with realized user value.** The owner's own inventory grades exactly one family fully usable — the
**editor core** (CM6, vim, 22-language tree-sitter, file nav). The two most architecturally admired
subsystems (image/audio immutable-ops "crown jewel"; the review state machine) are among the least
usable; the stated #1 differentiator (agent-transparent review/walkthrough/git) ended the *least*
usable tier. The durable assets are almost all architectural and process artifacts, and they are
unambiguous: the **3-package module boundary** (~80% headless-testable by construction), the
**sans-IO Rust core + staged-migration playbook** (8/9 ports, zero reverts, differential fuzzing
caught 5 silent parity bugs pre-ship), the **tier-as-type test harness + evidence-class
vocabulary**, the **62-file `scripts/` layer** (each script a fossilized incident), and the
**Canvas DSL result: 80%+ agent-executability vs 2–11%** for a raw-coordinate baseline — the
empirical validation of the owner's whole product thesis.

**The one-sentence thesis** (from the greenfield-architecture holistic read): *the prior project's
architecture was mostly right and its sequencing was mostly wrong.* Nearly every expensive arc was a
correct decision arrived at in week 4–8 that was knowable — and in several cases already written down
in the project's own research docs — in week 1. **The rebuild's job is to start at the end-state.**

---

## The top 20 learnings — ranked by measured cost/value

Each is one line + an evidence pointer into this dir. Ranked by the measured size of the pathology it
fixes or the asset it captures, spanning **all** dimensions (process, architecture, testing,
security, perf, deps, bugs, agent-centric), not just process.

1. **Substrate starvation is the single largest hidden cost — the session transcript *was* the
   state.** 56% of all tool errors (260 amnesia + 180 lifecycle) never self-healed across 150
   compactions, and the same root shows up again as the 36.5%-doc-commit apparatus. Fix: a tracker
   that is the *execution substrate* (stateless short-lived workers rehydrating from ticket
   contracts), not a status mirror agents narrate into. → `holistic/PM_HOLISTIC.md` §1 (Substrate
   starvation); `holistic/CROSS_CORPUS_PATTERNS.md` S2.

2. **Real WindowServer pixels are the only authority for a UI claim; every cheaper tier is a rung on
   a *ladder of lying evidence*.** The compositor-occlusion bug recurred **4×** because
   `ImageRenderer`/`cacheDisplay`/in-process WebView each gave false greens; render-verification was
   the owner's #1 documented complaint for 6 weeks. → `holistic/CROSS_CORPUS_PATTERNS.md` M1;
   `aspects/bug-types.md` §3; `aspects/regression-types.md` §4.

3. **The architecture was right; the *sequencing* was wrong — start at the end-state.** Nearly every
   expensive arc (Rust core retrofitted week 2, dual-UI policy week 8, felt-perf day 56) was a
   decision knowable in week 1. → `holistic/GREENFIELD_ARCHITECTURE.md` (thesis + build order).

4. **"Consumption ≠ completion" — a green suite, a closed ticket, and a CHANGELOG line can all be
   true of a feature no user can reach.** The audit's *only* P0-class findings were dead render tails
   (FormulaEngine "done"/never wired [refuted ❌ → `aspects/VERIFICATION_security_packaging.md` §6a —
   the Swift evaluator was deleted and replaced by a live rust-core bridge wired into `CSVTableView`];
   3-pane merge UI with zero callers [verified ✅ → `aspects/VERIFICATION_security_packaging.md` §6b];
   notices file generated, never shipped [verified ✅ → `aspects/VERIFICATION_security_packaging.md`
   §3]). → `holistic/CROSS_CORPUS_PATTERNS.md` M3; `aspects/regression-types.md` §1;
   `summaries/docs/d-docs-root-2of2.md`.

5. **Sans-IO, deterministic Rust core behind a thin-waist versioned wire boundary is *the* enabler —
   purity → host-testability → agent-verifiable → agent velocity.** It is what made ~80% of logic
   testable and the autonomous loop viable at all; it is unretrofittable. → `holistic/CROSS_CORPUS_PATTERNS.md`
   M4 + conclusion 1; `aspects/architecture.md`; `summaries/docs/d-research-3of3.md`.

6. **God objects are 10× cheaper to prevent than to split; file-level SRP ≠ observation-surface
   SRP.** `DocumentModel` hit 2,377 LOC / 71 `@Published` / 107 methods; even after a 40-slice sprint
   it was ~10.7 KLOC / 90 `@Published`. Narrow per-domain channels killed ~249× republish
   amplification (~90% re-body cut). → `holistic/CROSS_CORPUS_PATTERNS.md` T4; `summaries/code/src-ui-root-1of4.md`.

7. **A lesson sticks only when mechanized; prose recurs.** Compositor 4×, `killall` at a second call
   site, CRLF-as-one-grapheme in a new subsystem — all documented, all recurred. *Every* mechanized
   rule (TierGateObserver, surface-coverage matrix, ABI-skew detector, byte budgets) held 100%.
   LESSONS.md (333 KB) is the intake queue for gates, not the defense. → `holistic/CROSS_CORPUS_PATTERNS.md`
   M2; `holistic/PM_HOLISTIC.md` §5.

8. **One human cannot serialize 65 commits/day — the review queue re-forms in front of the human no
   matter how much runs upstream.** 735 validated-awaiting-done + 284 review, 304 h median stall,
   39.8% of task-state time stalled. Make the human a *decider* (30 s accept), not a *stage*. →
   `holistic/PM_HOLISTIC.md` §"human as serializer"; `aspects/unprimed-explorer-2.md` trap 3.

9. **The costliest bug *cluster* is one mechanism: a debounce/mirror never flushed at the moment
   that matters, or a write failure silently swallowed.** ~8 P1s: CM6 200 ms mirror vs ⌘S
   [verified ✅ → `aspects/VERIFICATION_dataloss.md` §1]; `JSONFileStore.write` Bool discarded by
   every caller [verified ✅ with nuance → `aspects/VERIFICATION_dataloss.md` §4 — true for the
   cited `SessionStore` hot path, but "every caller" overstates it: `ReviewStore.save` does check
   the result]; one bad record wiping all bookmarks [verified ✅ → `aspects/VERIFICATION_dataloss.md`
   §5]; a "Merge…" button that acts as Keep-Mine [verified ✅ → `aspects/VERIFICATION_dataloss.md`
   §6]. Fix structurally (typed-Result writes, flush-on-teardown in the same commit, lenient
   decode). → `aspects/bug-types.md` §5; `aspects/unprimed-explorer-2.md` trap 2.

10. **Boundaries drawn by *rendering technology* instead of *capability* produce N implementations of
    one semantic.** The undeferred native-vs-web split cost 5 find runtimes / 3 scroll channels / 2
    highlight+fold engines; declare the rendering-stack policy and one capability-owner-per-concern on
    day 1. → `holistic/GREENFIELD_ARCHITECTURE.md` Change #1; `holistic/CROSS_CORPUS_PATTERNS.md` S3.

11. **After two failed patches on a timing bug, stop sequencing the async handoff — eliminate it
    (single pull-based source of truth); and hold ≥2 hypotheses until a discriminating check splits
    them.** The 24-commit scroll-restore and 11-commit env-delivery arcs both ended the day the
    handoff was removed, not re-sequenced. → `holistic/CROSS_CORPUS_PATTERNS.md` M5;
    `aspects/bug-types.md` §1.

12. **Stage every risky migration/replacement: default-OFF gate + fallback → A/B parity corpus +
    differential fuzzing → named soak → deleted twin with the adapter seam kept.** 8/9 engine ports,
    **zero reverts, 5 silent parity bugs caught pre-ship.** → `summaries/docs/d-lessons-2of2.md`;
    `holistic/CROSS_CORPUS_PATTERNS.md` conclusion 7.

13. **Status must be *derived from attached evidence*, never asserted — the board understated AND the
    CHANGELOG overstated in the same repo.** No textual record tracked ground truth in either
    direction. Tickets name required evidence classes at grooming; the gate refuses "done" without
    them; run code-first reconciliation on a cadence. → `holistic/CROSS_CORPUS_PATTERNS.md` N1;
    `holistic/PM_HOLISTIC.md` R3.

14. **Coverage follows the *feedback-cost gradient*, not the risk gradient — mandates only work when
    the mandated action is cheap.** Exhortation never changed the inverted pyramid; making pixel-proof
    a ≤30 s operation (scene registry + window-id capture) drove adoption immediately. Make the
    authoritative tier cheap *first*. → `holistic/CROSS_CORPUS_PATTERNS.md` S1.

15. **The one lane the project never once exercised is the one it needed to launch.** Notarization
    never ran (0 Developer ID identities) [verified ✅ → `aspects/VERIFICATION_security_packaging.md`
    §4]; `THIRD_PARTY_NOTICES.md` generated but never copied into the bundle [verified ✅ →
    `aspects/VERIFICATION_security_packaging.md` §3]; 6 Mermaid CVEs accrued over ~11 months because
    three well-built scanners had no executor [unverified — vendored version 11.4.1 itself is
    confirmed (`aspects/VERIFICATION_security_packaging.md` §5), but the "6 CVEs" count needs an
    external CVE-database lookup this read-only pass did not perform]. Rehearse
    sign→notarize→attribute→install-on-clean-machine in week 1; every scanner gets a clock. →
    `aspects/deps-tooling.md`; `PORTABLE/DAY_ONE_CHECKLIST.md` §1,§3.

16. **The agent trust model accreted instead of being designed — capability on the *effect*, from
    commit #1.** An always-on unauthenticated same-uid socket grew to serve `run_task` (exec) +
    file-writes [verified ✅ → `aspects/VERIFICATION_security_packaging.md` §1]; the jail was drawn
    per-tool so `run_verb`'s file ops bypassed it [verified ✅ → `aspects/VERIFICATION_security_packaging.md`
    §2]; a deliberate no-audit stance left zero forensic trail [unverified — not covered by the
    verification pass]. All fixes are cheap and day-1. → `aspects/agent-centric-features.md`
    §What hurt F1–F7.

17. **Perf instrumentation is ~320 LOC, zero-cost-when-off, and was retrofitted catastrophically
    late (PerfSignpost day 18, InteractionProfiler day 56); measurement reversed intuition every
    single time.** Port the converged budget table verbatim: keystroke/scroll/nav **16.7 ms**,
    tab-switch/re-render **33.3 ms**, open-file **50 ms** (p95). No recorded case of intuition beating
    measurement in the corpus. → `aspects/perf-journey.md`; `holistic/CROSS_CORPUS_PATTERNS.md` S6.

18. **Unbounded agent fan-out is a quota bomb — cap the *capability*, not one tool.** A 3→75-agent
    Canvas research runaway burned ~half a session; two workflow deaths at session limits lost ~2M
    tokens (once the whole synthesis stage, twice). Exploration = single-pass read-only agents that
    cannot spawn; full fan-out only against a locked design; per-stage checkpointing; reap worktrees.
    → `holistic/CROSS_CORPUS_PATTERNS.md` T5; `aspects/struggle-automation.md`.

19. **DSL-first, agent-primary authoring is the validated product thesis: 80%+ executability vs
    2–11% for raw coordinates — design the grammar before the renderer.** Corollaries that earned
    their keep: frozen-context review comments (snapshot + `blobSha`), pure-logic walkthrough engine,
    versioned envelopes that fail loud on skew. → `aspects/agent-centric-features.md` §What worked 6;
    `summaries/docs/d-docs-root-2of2.md`.

20. **Every generative habit ran unbounded until a retrofit cap — pair each with its limiting habit
    on day 1.** Scope (12 families, usability first checked week 7), tickets (over-decomposition
    corrected week 8), docs (fold-in week 6), fan-out (75-agent runaway), caches (caps on acute paths
    but not cumulative ones). The counterweight always arrived after the bill. → `aspects/unprimed-explorer-1.md`
    (the unifying finding); `aspects/regression-types.md` §5.

---

## How to approach the rebuild

The direct answer to *"How can I approach building it?"* The evidence is unusually decisive about
sequencing, so this is opinionated. Full detail: `holistic/GREENFIELD_ARCHITECTURE.md` (build order +
layer diagram + boundary contracts) and `PORTABLE/DAY_ONE_CHECKLIST.md`.

### The three day-1 commitments that decide the outcome

Everything else is compounding interest on these:

1. **A tracker-as-substrate + evidence-derived status (build the PM app as a *peer* of the editor,
   not after it).** Short-lived contract-fed worker sessions that rehydrate from tickets; the runner
   walks the state machine (agents never self-transition); status is derived from posted evidence
   classes, never asserted. This deletes the top two error classes (amnesia + lifecycle = 56% of all)
   by construction and removes the *reason* the 36.5%-doc apparatus existed. The v4 tracker design is
   validated by this corpus — adopt it; `holistic/PM_HOLISTIC.md` R1–R10 ranks its requirements by
   measured cost.

2. **The gate lattice, cheapest-first — mechanize every rule that matters, because prose doesn't
   police.** Compiler-enforced module boundaries (Kit/Core/UI + import-grep CI) → headless merge gate
   + tier-as-type + TierGateObserver → grep/lint gates (zero-caller views, compositingGroup/zIndex on
   representable-siblings, no-discarded-Result writes, gitignored-lockfile) → budget tests with teeth
   (coordinator ≤500 LOC/15 `@Published`, bundle dual-cap, doc byte caps, the perf budget table) →
   per-surface real-render coverage matrix (shrink-only exemptions) + negative-control switches → **a
   ≤30 s pixel-proof path operational by week 2**. Set every budget *before* the thing exists, not at
   3× target.

3. **Sequencing: differentiator-first, depth-first — with the ship path rehearsed in week 1.** The
   editor core + ONE MicroApp + the agent-review loop must be *end-to-end usable* before family #3
   opens. "New top-level feature family" is an event that displaces something, not a free action.

### Phase order (and why)

The rule: **stand up every "lying-evidence killer" before the feature work that would otherwise lie**,
and make the authoritative feedback loop cheap before mandating it.

- **Phase 0 — substrate (week 1).** Kit/Core/UI + import gate; Rust workspace from the playbook
  (forbid-unsafe outside `ffi`, `deny.toml`, lints); **wire envelope v1 with an adversarial
  one-way-door review before anything freezes** — reserved fields (`ver`/`clientSeq`/`siteId`/`corrId`),
  **UTF-8 byte-offset positions**, content as `(bytes, encoding, eol)` never bare `String`; thin-waist
  FFI + ABI-skew detector + MessagePack named-maps; Rust core as an xcframework `binaryTarget` (kills
  the SwiftPM staleness class); tier-as-type harness; PerfSignpost + InteractionProfiler with the
  budget table; bundle dual-cap; agent gate skeleton (capability-on-effect + token slot + audit log +
  socket identity); supply-chain scanners **wired to a clock**; ship-path rehearsal
  (sign→notarize→attribute→clean-install).
- **Phase 1 — first pixel truth (week 2).** Pixel lane live with the ≤30 s scene+window-id capture;
  first WebView-hosting SwiftUI container ships with the compositor sniff test + `.compositingGroup().zIndex()`
  convention + negative-control teeth proof; the coverage matrix starts enforcing from the *second*
  surface.
- **Phase 2 — the document spine.** Rust document store (rope, op-log, windowed snapshots,
  content-based dirty) + persistence (typed-Result writes, lenient decode, flush contracts, hot-exit
  journal) + session/tab model with the **core-owns-domain / client-owns-view** ownership-split schema
  test. Unretrofittable; everything layers on it.
- **Phase 3 — the editor, end-to-end and honest.** CM6 over the spine: *one* find engine, *one*
  scroll-state owner, *one* fold engine, one tree-sitter producer, each core-owned with thin adapters;
  patch-not-reload from the first render; the CM6 mirror ships with its flush contract; LSP as a
  separate async actor pool. **Exit criterion: open/edit/save/quit/crash-recover proven at T5 +
  journey level before breadth begins** — breadth-first is exactly why data-loss bugs survived 8 weeks
  under 1,227 test files.
- **Phase 4 — the agent thesis.** Git integration, review-share (frozen-context comments), walkthrough
  engine, MCP catalog over a *generated* verb vocabulary (one catalog → MCP tools + palette + CLI,
  never three hand-maintained ones). This is the differentiator; build it while the surface is still
  small enough to audit completely.
- **Phase 5 — Canvas, then MicroApps one at a time.** Canvas first (it *is* the plugin-contract
  proof: a diffable replayable scene-graph doc in core + a DSL agents emit + a patching WebView
  renderer); then ONE MicroApp driven to hardened/end-to-end through the full lifecycle including its
  threat-model and matrix entries; only then the next.
- **Phase 6 — other frontends.** TUI + WebUI against the already-proven protocol; remote daemon
  (TCP/WS) with version-skew handover; optimistic-local confined to the remote adapter. The thin waist
  makes these additive; loopback A/B tests prove local/remote transparency before any network exists.
- **Standing from Phase 2:** scheduled drain/convergence phases (~every 4–6 weeks) — crash-class
  audit, code-first board reconciliation, consumption-gap sweep, ship-path re-rehearsal. *The drain is
  where truth surfaces; schedule it, don't discover it.*

### Operating model

- **Work loop:** batch 5–15 related tickets → one gate → one commit; vertical (input-to-output)
  slices as the default epic shape; docs folded into code commits from commit #1.
- **Autonomy tiers:** auto (anything with an automatable evidence class — host/WV-DOM/T4/most-T5/perf
  budgets/merge-queue closure); default-with-veto + SLA (two-way doors); human-only (one-way doors,
  dep approvals, "feels slow"/aesthetic calls, AX-interaction tier, finish-or-cut). Fan-out:
  exploration = single-pass read-only; execution fan-out only against a locked design; hard
  max-in-flight + per-stage checkpointing + worktree reaping.
- **Human-attention budget: design the owner's day (~15–30 min, inbox-only).** 30-second accepts,
  decision briefs with proposals attached, aged-item batching. Report progress as a burn-up of
  *accepted* — never merged/closed counts (this project's closed counts were fiction in both directions).

### Port these nearly verbatim

`PORTABLE/ARCHITECTURE_SEED.md` + `TESTING_STRATEGY_SEED.md` + `CLAUDE_MD_SEED.md` +
`PROCESS_PLAYBOOK.md` + `PM_APP_LEARNINGS.md` + `RISK_REGISTER.md`, and the specific `scripts/`
patterns named in `aspects/deps-tooling.md` §Portable rules 6 (`build-app.sh` xattr-safe staging,
`build-rust-core.sh` content-hash staleness guard, `check-bundle-size.sh` dual-cap, `test-in-vm.sh`
GUI-session bridge, `sign-and-notarize.sh` inside-out order, `restage-header.sh`).

---

## Where the analyses disagree — for the owner to adjudicate

These are genuine tensions between reports, not noise. The owner should settle them explicitly.

- **Test-pyramid shape: flip it, or keep the mass?** `summaries/code/t-ui-root-6of6.md` calls the
  81%-headless distribution "inverted — the rebuild should go pixel-first"; `t-ui-root-5of6.md`
  defends the lean 70/20/5/2 shape as "scalable, pixel is correctly a last-resort top layer."
  **Adjudication (I side with the majority + the project's own 07-04 MANDATES):** don't flip to
  pixel-heavy (T5 is expensive, serial, VM-bound); keep the headless mass AND enforce a **per-surface
  real-render *minimum*** via the matrix guard so no surface has zero authoritative coverage. The
  failure was zero-coverage *surfaces*, not the ratio. → `holistic/CROSS_CORPUS_PATTERNS.md` N4.

- **"Docs discipline" vs "process tax" — both narratives are in the corpus and both are true at
  different scales.** The c-01 analyst praises early bundled doc discipline (~25% sustainable); the
  meta-analysis condemns the aggregate (36.5% doc-only, one file = 17% of history). **Adjudication:**
  *bundled, feature-paired* docs are cheap and good; *append-only progress narration* is the disease.
  Delete the reason for the apparatus (tracker-as-substrate), don't optimize the apparatus. →
  `holistic/CROSS_CORPUS_PATTERNS.md` N2.

- **The KEEP verdicts read as a hall of fame — but per-file quality ≠ system correctness.** The code
  batches say "production-grade / crown jewel / zero false-green findings"; the same repo has ~8 P1
  data-loss bugs, an unauthenticated exec socket, and a ship path that never ran. **Adjudication:** the
  Haiku per-file summarizers grade what code *looks like* (seams, caps, guards) and structurally
  cannot see cross-file wiring gaps, silent error sinks, unflushed debounces, or ship-path omissions.
  **Do not read the KEEP scoreboard as a correctness certificate**; the defects cluster exactly where
  no file owns (lifecycle boundaries, result-surfacing, last-mile wiring, release). → `holistic/CROSS_CORPUS_PATTERNS.md`
  N3.

- **Revert count discrepancy (a data-quality flag, not a real disagreement to resolve):** the commit
  INDEX reports **2** reverts in 3,733; `aspects/unprimed-explorer-2.md` reports **12** ("fix" in
  subject inflates a broader count). The forward-fix posture holds either way (~1 in 5 commits is a
  fix-commit — a churn rate), but treat single-number claims in the corpus with mild suspicion; several
  were later corrected by measurement (S6).

- **Open product questions evidence cannot settle** (from `holistic/GREENFIELD_ARCHITECTURE.md`
  §Open questions — the owner must answer these because they set wire-freeze timing and investment
  order): (1) **Is the product the Mac app, or the core?** — the requirement statement implies "core
  is a product," which front-loads the protocol work. (2) **How far does "web for all rich content"
  go** — everything-web, or grandfather a short native list? The un-decided middle is what cost five
  find engines. (3) **Large-file bar** — 100 MB / 1 GB / 10 GB logs, and is read-only acceptable above
  a threshold? This sizes the pager investment. (4) **Collaboration/multi-writer ever?** — changes the
  op-log from undo-substrate to convergence-substrate. (5) **Agent-trust UX friction** — silent
  auto-grant-with-audit vs consent prompts. (6) **Review-throughput policy** — risk-tiered
  auto-validation vs hard WIP cap vs sampling; which failure do you prefer, slower delivery or thinner
  oversight? (7) **Distribution intent** — public-shipping (Developer ID/notarized/sandboxed) from the
  start, or local-first? (8) **The pixel-truth substrate** — UTM VM again, a second Mac/CI runner, or
  a reduced-scope compromise. (9) **PM-app coupling depth** — one shared evidence-class schema +
  artifact store, or loosely coupled by convention?

---

## Map of this analysis dir — what to read for what

| If you want… | Read |
|---|---|
| **The one document** | this file (`MASTER_SYNTHESIS.md`) |
| **How to build it (architecture, layer diagram, build order, boundary contracts, open questions)** | `holistic/GREENFIELD_ARCHITECTURE.md` |
| **The management view (phases, where effort vs value went, systemic forces, operating model)** | `holistic/PM_HOLISTIC.md` |
| **Cross-cutting patterns/trends/contradictions + the 10 conclusions the rebuild must not lose** | `holistic/CROSS_CORPUS_PATTERNS.md` |
| **Copy-into-the-new-repo artifacts** | `PORTABLE/` — `DAY_ONE_CHECKLIST.md`, `ARCHITECTURE_SEED.md`, `TESTING_STRATEGY_SEED.md`, `CLAUDE_MD_SEED.md`, `PROCESS_PLAYBOOK.md`, `PM_APP_LEARNINGS.md`, `RISK_REGISTER.md` |
| **Per-dimension deep dives** | `aspects/` — `architecture`, `bug-types`, `regression-types`, `perf-journey`, `test-types`, `deps-tooling`, `feature-types`, `inefficiency-types`, `work-task-types`, `agent-centric-features`, `struggle-walls` (platform/OS walls), `struggle-taskmgmt` (board/tracker friction), `struggle-automation` (fan-out/orchestration), `unprimed-explorer-1` + `-2` (fresh-eyes, unprimed) |
| **Per-file KEEP/REDO/AVOID verdicts (every source/test/script/doc)** | `summaries/INDEX.md` → `summaries/code/*.md`, `summaries/docs/*.md` (note: `t-ui-root-5of6.md` exists on disk but is missing from the INDEX tallies — include it) |
| **Commit-history archaeology (eras, taxonomy, rework arcs, process evolution)** | `summaries/commits/INDEX.md` → `summaries/commits/c-01..c-19of19.md` |
| **The requirement statement (owner's verbatim ask) + method** | `README.md` |
| **Prior studies treated as input** | `../project-meta-analysis-2026-07-04/SYNTHESIS.md`, `../prelaunch-audit-2026-07-09/`, the 1.3 GB struggle meta-analysis + v4 tracker design (paths in `README.md`) |

**Reading-trust caveat carried through the whole dir:** pre-launch-audit findings cited in this
synthesis have since been individually verified against current `main` — see the inline
`[verified ✅ / refuted ❌ / unverified]` tags in the top-20 list and
`aspects/VERIFICATION_dataloss.md` + `aspects/VERIFICATION_security_packaging.md` for full
evidence; any pre-launch-audit finding cited elsewhere in this corpus WITHOUT such a tag remains
gap-class (unverified). Per-file KEEP verdicts grade craftsmanship, not system correctness; single
numeric claims were sometimes later corrected by measurement. The holistic layer and this synthesis
have triangulated these against independent streams (commit ledger, transcript study, board
archaeology) wherever a claim is load-bearing.

---

*Written by the master-synthesis agent (Opus), 2026-07-11. Companions: `holistic/` (3 Fable
syntheses), `aspects/` (15 dimension analyses), `PORTABLE/` (7 day-1 artifacts), `summaries/`
(~54 batch reports over every file + all 3,733 commits).*
