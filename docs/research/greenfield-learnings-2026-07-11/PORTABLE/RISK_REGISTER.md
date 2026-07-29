# Risk Register — portable, day-1 artifact for a new agent-built project

Copy this into the new repo's root or `docs/` on day 1. It is a standing register, not a
one-time read: revisit it at every major milestone (first release candidate, first
notarization/signing pass, first multi-agent fan-out, first god-object smell) and check
whether an early-warning signal has fired.

Each entry: **Likelihood / Impact** (grounded in what actually happened on the prior
project — see the parenthetical "(learned: ...)" evidence), the **early-warning signal**
that should make you stop and act, and the **pre-committed mitigation** to apply before
the risk materializes, not after.

Likelihood/Impact scale: Certain / High / Medium / Low — calibrated against a project of
comparable scope (a multi-surface native+web app, agent-built, 8+ weeks, thousands of
commits). A "Certain" risk is one that recurred multiple times independently on the prior
project despite active mitigation attempts.

---

## A. Platform walls (macOS/native — adapt list if targeting a different platform)

### 1. Ad-hoc code signing → TCC re-prompt churn on every rebuild
**Likelihood: Certain (if ad-hoc signing is used at all) · Impact: Medium** (dev-loop
friction, not a ship-blocker, but compounds daily) *(learned: ad-hoc signing keys TCC
grants on `cdhash`, which changes every rebuild — every protected-folder grant
re-prompted on every build for weeks)*.
- **Early-warning signal:** any permission dialog (Documents/Downloads/Screen-Recording/
  Full-Disk) reappearing after a rebuild that didn't change entitlements.
- **Mitigation (pre-committed):** sign with a real identity (self-signed cert with a
  stable leaf hash, or a paid Developer ID) from the very first build — dev, CI, and VM
  lanes all use the same signing recipe. Never take the ad-hoc path "just for now."

### 2. Fixing one signing/entitlement problem silently breaks another (hardened runtime + no Team ID → dlopen denial)
**Likelihood: Medium · Impact: High** (silently degrades shipped functionality with zero
visible error) *(learned: switching to hardened-runtime signing to fix TCC churn silently
broke dlopen of lazy-loaded plugin dylibs because a self-signed cert has no Team ID —
every automated lane signed ad-hoc and never exercised the failing configuration, so it
was invisible to CI for an unknown duration)*.
- **Early-warning signal:** any feature that lazy-loads a dylib/plugin/library at runtime
  and swallows the load failure into a log line instead of surfacing it.
- **Mitigation:** whenever a signing/entitlement/hardened-runtime flag changes, write and
  run an empirical probe of the *new combined configuration* before trusting it — never
  reason "should be equivalent." Make at least one CI/dev lane sign with the exact
  ship-path recipe, not a cheaper ad-hoc substitute.

### 3. Notarization pipeline never rehearsed until launch is imminent
**Likelihood: High (if deferred) · Impact: High** — multiple independent failure modes
surface serially at the worst possible time *(learned: zero notarization runs across 8
weeks of development; when finally audited, found no Developer ID identity, an in-place
signing race with the same iCloud-xattr bug already paid for once, no post-staple
Gatekeeper check, unasserted notarytool exit status — all discovered by inspection, none
by execution)* **[verified against source repo 2026-07-11: the sign-and-notarize script is
complete but has never once been exercised — 0 codesigning identities installed, no notary
keychain profile, not wired into CI]**.
- **Early-warning signal:** "we'll notarize when we're ready to ship" as a stated plan;
  zero notarization dry-runs in the project timeline.
- **Mitigation:** schedule a full sign → notarize → staple → quarantine-launch dry run as
  its own early milestone (week 1-2), independent of feature completeness — not gated on
  "launch-ready."

### 4. WebView/embedded-process surfaces have process-model failure modes invisible to naive tests
**Likelihood: High (any app embedding a WebView, PTY, or subprocess UI) · Impact: High**
(multi-day rabbit holes) *(learned: WebView content process idle-killed under background
test sessions; async JS-evaluation APIs flaky under one call variant but not another;
full-screen capture doesn't composite WebView content even though the window reports
healthy; synthesized input events don't reach WebView text insertion)*.
- **Early-warning signal:** a UI test that "should" be trivial (read a value, click a
  button) intermittently times out or throws only inside a spawned-app/VM context, never
  in isolation.
- **Mitigation:** design an in-process, headless-hostable mount seam for every
  WebView/PTY/subprocess-UI surface from day one — this is the DEFAULT test vehicle.
  Reserve spawned-app/real-window validation strictly for the narrow slice that needs
  true window compositing.

### 5. Cross-module / cross-toolchain / cross-language staleness silently ships or crashes
**Likelihood: High (any FFI boundary or multi-toolchain build) · Impact: High** (SIGSEGV
that looks exactly like a boundary bug, wastes root-cause time) *(learned: adding an enum
case to an FFI-adjacent type recompiled non-test consumers but left stale Test-target
object files that segfaulted on a pure-language `throw` with zero FFI involved; a bare
build on a secondary toolchain silently reused a `.swiftmodule` compiled by a different
toolchain version; a linked native-core static archive was not tracked as a build input
at all, so SwiftPM's incremental build could silently ship stale native code)*.
- **Early-warning signal:** a crash "that shouldn't be possible given the diff that just
  landed"; any FFI-boundary type change reviewed without a corresponding "touch every
  consumer including Test targets" step.
- **Mitigation:** treat any FFI-boundary type-layout change as touching every consumer,
  Test targets included — wire this into the build graph/CI, don't rely on memory. Treat
  a linked native-core artifact as a tracked build input (e.g. a binary framework target)
  from day one, not a raw linker flag.

### 6. Some interactions are structurally not synthesizable by automation
**Likelihood: Medium · Impact: Medium** (defines a permanent validation gap, wastes
diagnostic time if not accepted early) *(learned: faithful pointer-drag gestures could not
be synthesized in-process after 4 dedicated VM rounds; this had to become an accepted,
named, permanent human/owner-gated tier rather than a solvable harness problem)*.
- **Early-warning signal:** a third round of "let's try a different synthesis approach"
  for the same interaction class.
- **Mitigation:** name the non-synthesizable-interaction tier explicitly and permanently
  in the test-pyramid design from day one (drag gestures, multi-touch, native
  drag-and-drop between windows are the known members of this class). Don't re-litigate
  per feature.

### 7. Platform-specific shell/tooling friction is a permanent small tax
**Likelihood: Certain · Impact: Low per-incident, moderate cumulative** *(learned: ~29
distinct shell-portability errors — missing GNU tools, quoting/glob differences, argument
incompatibilities — recurred across many sessions before being compiled into a single
reference list)*.
- **Early-warning signal:** the same class of shell error recurring across sessions
  without a standing reference.
- **Mitigation:** seed the new project's agent instructions with a known-gotcha list for
  the target shell/OS on day one; don't let it re-accrete error-by-error.

---

## B. Data-loss classes

### 8. Debounced/coalesced writes never flushed at the moment that actually matters
**Likelihood: High (any app with autosave/debounced persistence) · Impact: Critical**
(user data loss) *(learned: a 200ms debounce mirroring editor content to the persistence
layer was never flushed on save/close/blur/quit — an explicit save could persist a stale
mirror; this is the single largest cluster in a dedicated pre-launch audit, ~8 P1 findings,
all variations on "a cache/mirror/debounce is not flushed at teardown, or a write's
failure is silently swallowed")* **[verified against source repo 2026-07-11: confirmed —
menu Save, tab-close, and quit all bypass the flush path; there is no application-quit
override that even prompts for dirty tabs before teardown]**.
- **Early-warning signal:** any `Task.sleep`/debounce/coalescing timer guarding a write
  path with no explicit flush call wired into save/close/blur/quit/crash-handler paths.
- **Mitigation:** every debounced/coalesced write ships its flush-on-teardown hook in the
  SAME commit that introduces the debounce — treat "debounce with no flush contract" as a
  code-review-blocking pattern, same severity as a resource leak.

### 9. Discarded write-failure signals (silent `Bool`/optional returns on persistence APIs)
**Likelihood: High · Impact: Critical** *(learned: a JSON store's `write` returned a
discardable `Bool` that every call site ignored — a disk-full condition during quit
silently lost sessions and in-flight edits with zero user-visible signal)* **[verified
against source repo 2026-07-11, with nuance: true for the primary session-persistence hot
path (the async coalesced write queue) — but "every call site" overstates it; one store's
save path does check and act on the returned Bool, so the risk is about a pattern that
CAN silently regress per-caller, not an absolute]**.
- **Early-warning signal:** any persistence API whose return value is a `Bool`/optional
  rather than a typed, must-handle `Result`/throwing signature.
- **Mitigation:** no flag-return persistence APIs, anywhere, from commit #1. Every
  write/save API returns a typed result the compiler forces callers to acknowledge.

### 10. Strict decoding of a shared store wipes the whole store on one bad record
**Likelihood: Medium · Impact: High** *(learned: a bookmarks store strict-decoded an
array — one malformed entry wiped ALL bookmarks, and the next toggle then clobbered the
on-disk file with the emptied state; the project already had a lenient-array-decode
pattern in use elsewhere that simply wasn't applied to this store)* **[verified against
source repo 2026-07-11: confirmed — the lenient-array helper exists and is used by three
sibling stores, but the bookmarks store was never migrated to it despite the helper's own
doc comment naming bookmarks as the case it exists to protect]**.
- **Early-warning signal:** any `Codable`/deserialize call on a collection-shaped
  persisted file using strict (all-or-nothing) decoding.
- **Mitigation:** use lenient/partial decoding for any store that must survive one corrupt
  record, as a standing pattern — and grep new stores against it at review time, since a
  documented pattern does not self-propagate to new call sites.

### 11. Ordering bugs in drain/cleanup paths delete state before the guard that protects it runs
**Likelihood: Medium · Impact: High** *(learned: a hot-exit spill was deleted by a drain
routine before the "is this drain legitimate" guard was checked — two async-adjacent
steps assumed ordered that weren't)* **[verified against source repo 2026-07-11: confirmed
— the destructive delete call sits three lines before the guard that was supposed to skip
it for this exact drain path, contradicting the guard's own inline comment]**.
- **Early-warning signal:** any cleanup/drain routine with a guard condition checked
  anywhere other than immediately before the destructive call.
- **Mitigation:** treat any destructive cleanup path (delete/overwrite/drain) as requiring
  its guard check and the destructive action to be inseparable (same function, guard
  first, no intervening await/yield) — flag any that aren't at review.

### 12. UI affordance semantics silently diverge from the code path it triggers
**Likelihood: Low-Medium · Impact: High** (user believes a safe action was taken)
*(learned: a conflict-resolution "Merge…" button silently behaved as "Keep Mine,"
clobbering an external edit on next save — the label lied about the actual code path)*
**[verified against source repo 2026-07-11: confirmed — "Merge…" and "Keep Mine" still
route to the identical outcome, though a real three-way-merge engine has since been built
in-tree and simply isn't wired to this button yet]**.
- **Early-warning signal:** any destructive-adjacent action whose label uses a softer verb
  than its implementation actually performs.
- **Mitigation:** a copy/behavior parity check for any button on a data-loss-adjacent path
  — the acceptance test asserts the LABELED behavior, not just "a save happened."

---

## C. False-green verification (the single most expensive class on the prior project)

### 13. The "model-green" and "on-screen" ladder gets conflated — repeatedly, at every rung
**Likelihood: Certain · Impact: Critical** (recurring multi-day rework arcs; the owner's
single most-quoted complaint on the prior project) *(learned: a single bug class — an
opaque native view compositing over a reactive-framework sibling — recurred 4 times
because each verification tool used to "prove it fixed" was structurally blind to the
actual defect: in-tree snapshot renderers rasterize the reactive framework's own tree in
isolation and draw a placeholder for the native view, so there is no occlusion to see;
frame-cache dumps are blind to the native compositing layer entirely; only real
window-server pixel capture is authoritative)*.
- **Early-warning signal:** a UI-rendering bug fix reported "verified" using anything
  other than a real compositor pixel capture (screenshot of the actual window, not a
  reactive-framework-only snapshot render).
- **Mitigation:** maintain and consult an explicit ladder of evidence tiers from day one —
  model-green < element-in-tree < in-framework snapshot < in-process embedded-surface
  test < live-app state dump < real compositor pixel capture — and require the tier
  appropriate to the claim. Encode the riskiest sub-case (an opaque native view sharing a
  container with a reactive-framework-drawn sibling) as a **structural, statically
  greppable rule** (explicit z-order/compositing-group treatment in every layout branch)
  from the first time that pattern appears — cheaper and stronger than any pixel test,
  because the static rule runs on every diff, not just nightly.

### 14. A regression guard that has never been shown to fail is not a guard
**Likelihood: High if not made a standing practice · Impact: High** (silent false
confidence) *(learned: this bug class recurred 4 times specifically because the "test"
protecting against it had never been proven capable of going red — it wasn't shown to
fail until a dedicated negative-control mechanism was mandated)*.
- **Early-warning signal:** any test/gate added as "the fix for X" without a companion
  demonstration that it fails on the pre-fix code.
- **Mitigation:** for every real-render/compositing/timing regression guard: revert the
  fix (or flip a codified negative-control switch), confirm the guard goes red, then
  restore. Make this a committed, repeatable check (a deliberate-break switch gated by an
  env var), not a one-time hand-revert.

### 15. Async/timing races get "fixed" by patching stages instead of collapsing the chain
**Likelihood: High (any multi-hop async handoff: callback → framework re-render → task
hop → paint) · Impact: High** (velocity — one class of bug cost double-digit commits
across multiple independent arcs) *(learned: two separate multi-stage async races each
took 11-24 commits and multiple failed sequencing patches before resolving — both
resolved permanently only when the fix collapsed the handoff to a single, pull-based
source of truth instead of sequencing the existing stages more carefully)*.
- **Early-warning signal:** a timing/race bug survives a second patch attempt and reappears
  at a different stage of the same chain.
- **Mitigation:** after 2 failed patches on a timing bug, stop patching stages — redesign
  so the value is read declaratively from one owning source (pull-based), removing the
  race by construction. Procedurally: hold at least 2 candidate root causes until a
  runtime-observed check (not code-order inference) discriminates between them before
  committing to "the real bug."

### 16. A verification claim ("restore runs after X, so it's too late") stated from code-order inference, not runtime observation
**Likelihood: Medium · Impact: High** (wrong fixes land with confidence) *(learned: an
explicit rule had to be codified — "VERIFY the mechanism end-to-end, do NOT infer from
code order" — after a reactive framework's asynchronous, coalesced re-render behavior
made a plausible-sounding sequencing claim provably wrong)*.
- **Early-warning signal:** a root-cause explanation phrased purely in terms of statement
  order in source, for an asynchronous/reactive system.
- **Mitigation:** for any timing bug in an async/reactive system, instrument and observe
  at runtime before proposing a fix — never trust "A happens before B because A is
  written above B in the source."

---

## D. Scope / shelf-ware risk ("built ≠ usable")

### 17. Model/engine work ships and closes as "done" while its UI mount point is never wired
**Likelihood: Certain (systemic pattern, recurred repeatedly in the final stretch of the
prior project) · Impact: Medium-High** (features reported shipped in the changelog that a
user cannot actually reach) *(learned: at least 4 confirmed instances in a single project
— a conflict-resolution view with zero callers, a dynamic menu model with zero UI
consumers, a network-consent core with no grant UI, a fully-ported computation engine
never wired to any view and marked done in the changelog — because the team's own
host-testing discipline is fully satisfiable without ever touching the UI mount point,
and the render tail got deferred as a prose comment instead of a tracked, blocking child
ticket)*. **[verified against source repo 2026-07-11, mixed: the conflict-resolution
view and the dynamic menu model are both confirmed dead — a fully built, tested model
layer with zero non-test callers of its presentation entry point. The "fully-ported
computation engine never wired to any view" claim is REFUTED as of this check — that
engine's Swift implementation was deliberately deleted and replaced by a live bridge to a
faster reimplementation that IS wired into its consuming view and on by default; treat
that specific example as stale, not the general pattern, which the other two instances
still support. The "network-consent core with no grant UI" instance was not independently
re-checked in this pass — unverified claim from source-repo audit]**.
- **Early-warning signal:** a ticket/PR that adds a new public type/view/accessor with
  zero callers outside its own defining file, closed as "done" or "fixed."
- **Mitigation:** treat "render tail" as a first-class ticket-typing rule: a change that
  ships a model/data layer with the UI mount point deferred MUST spawn a separate, linked,
  BLOCKING child ticket for the mount — never a prose note. Add an automated
  zero-external-caller check as a merge-time gate, not a periodic audit. Define the
  lifecycle explicitly: engine → boundary/FFI → consumption/wiring → real-render evidence
  → bake-in, and refuse "done" before the consumption stage lands.

### 18. Default-flip of a perf optimization ships ahead of its own documented safety contract
**Likelihood: Medium · Impact: High** (flips into the default hot path for every user)
*(learned: a perf-motivated flag flip to default-ON was justified by a code comment
promising a safe fallback on failure; the actual caller discarded the completion handler
that would have triggered that fallback — the contract was prose, never asserted by a
test, and silently diverged from the implementation)*.
- **Early-warning signal:** a default-flip commit whose safety argument is a code comment,
  with no test that exercises the failure path and asserts the fallback actually fires.
- **Mitigation:** any documented fallback/safety contract backing a default-flip ships as
  an assertion in the SAME commit as the flip (inject the failure condition, assert the
  fallback path was invoked) — a prose comment is never sufficient enforcement.

### 19. Breadth-first, feature-by-feature growth defers integration truth to a late "drain" phase
**Likelihood: High (any project prioritizing throughput/coverage over integration checks)
· Impact: Medium-High** (a late convergence phase surfaces a cluster of crash classes,
unshipped subsystems, and dead render tails all at once) *(learned: a dedicated
integration-drain pass — run only after "all features done" — surfaced 3 production crash
classes, ~22 built-but-unshipped subsystems, and ~40 dead render tails in one pass; a
subsequent pre-launch audit found more)*.
- **Early-warning signal:** no scheduled integration/drain/reconciliation phase on the
  roadmap; status tracked only by ticket state, never re-derived from a code-first sweep.
- **Mitigation:** put a drain/hardening/convergence phase on the roadmap from day one
  (budget ~2-3 weeks for a project of this scale), not as a reaction to schedule pressure.
  Run periodic code-first reconciliation against the tracker, not just at the end.

---

## E. God-object / architecture drift

### 20. A single coordinator/model object accretes cross-cutting responsibility until it dominates the codebase
**Likelihood: Certain absent an early domain split · Impact: High** (10x more expensive
to split later than to design correctly from the start) *(learned: a scheduled,
deliberately-gated refactor sprint successfully split a ~7,500-line god object into 40
slices with zero render regression — proving mid-flight extraction CAN be done safely —
but the residue was still ~10,700 lines across dozens of files with ~90 observable-state
properties by the time of a later audit; extraction-by-extension organizes a god object,
it does not decompose it)*.
- **Early-warning signal:** any single file/type crossing roughly 800 lines, or acquiring
  a second unrelated responsibility (e.g. both session lifecycle AND UI-visible state).
- **Mitigation:** partition state/logic by domain from day one — per-domain coordinators,
  narrow observable-state channels scoped to what a given view actually needs (not one
  giant shared publisher). If a debt-paydown sprint later becomes necessary, schedule it
  as a planned, gated, slice-by-slice refactor (not opportunistic cleanup) — but the goal
  is to never need it.

### 21. Duplicate parallel implementations of the same capability accrete because no single consolidation decision was made
**Likelihood: High (any project spanning two UI toolkits, two language runtimes, or two
storage formats) · Impact: High** (directly manufactures a recurring bug family, not just
maintenance cost) *(learned: a project that grew both a native and a web rendering stack
for the same content, feature by feature, ended up with five parallel search
implementations behind four divergent state models, three independently-keyed
scroll-persistence channels, two syntax-highlighting engines that classified tokens
differently, and two fold-region engines — the fragmentation directly caused a recurring,
expensive scroll-restore bug family across at least 5 tickets)*.
- **Early-warning signal:** the same user-facing capability (search, highlighting, scroll
  position, undo) being implemented against two different underlying frameworks/stacks
  because each was "locally convenient" for whichever surface needed it that week.
- **Mitigation:** any architectural fork that would duplicate a subsystem across two
  stacks gets an explicit, written, single decision BEFORE the second instance is built —
  not resolved by whichever surface happens to need it next. Where a migration is
  underway, follow a staged playbook (capability gate + fallback → parity corpus +
  differential testing → soak → delete the twin, keep the adapter seam) rather than
  letting both live indefinitely.

---

## F. Licensing / dependency debt

### 22. Shipped bundle redistributes third-party dependencies with no attribution
**Likelihood: High (any app bundling compiled dependencies) · Impact: Medium-High** (legal/
compliance exposure that scales with dependency count, discovered only by a dedicated
audit) *(learned: a pre-launch audit found the shipped bundle redistributing on the order
of 45 dependencies with zero license attribution anywhere in the product or its
distribution)*. **[verified against source repo 2026-07-11: the core claim is
confirmed — the curated third-party-notices file exists in the repo but the build script
never references it and it is absent from the installed app bundle; the specific "~45
dependencies" count was not independently re-tallied in this pass — unverified claim from
source-repo audit]**.
- **Early-warning signal:** no `NOTICE`/about-box/attribution file exists, or exists but
  hasn't been regenerated since the dependency list last changed.
- **Mitigation:** wire license-attribution generation into the build pipeline from the
  point the dependency count exceeds a handful (e.g. auto-generate a NOTICE file from the
  lockfile/manifest on every release build, fail the release build if it's stale) — don't
  defer to a pre-launch audit to discover the gap.

### 23. Security hardening is applied per-surface at audit time and does not generalize to surfaces added afterward
**Likelihood: High · Impact: High** (new attack surfaces ship soft by default) *(learned:
surfaces hardened during an early security-audit wave — archive extraction path-traversal
checks, subprocess environment allowlists, database attach denial — were genuinely solid;
surfaces added AFTER that audit wave (a WebView with no content-security-policy, an
always-on control socket with no authentication, a task runner with unscrubbed
environment) shipped without equivalent treatment because no reflex existed for "adding
this class of surface requires a threat-model entry")*. **[verified against source repo
2026-07-11: the always-on unauthenticated control socket is confirmed — it accepts every
local connection with no handshake or token by explicit design comment, and one
path-taking tool on that socket was independently confirmed to bypass the sandbox fence
applied to the other 7 comparable tools. The WebView-CSP and task-runner-environment
instances were not independently re-checked in this pass — unverified claims from
source-repo audit]**.
- **Early-warning signal:** a new WebView, socket, subprocess-spawn, or file-system-write
  call site added without a corresponding entry in a threat-model/security checklist.
- **Mitigation:** make security review a registration gate, not an audit event — adding a
  WebView/socket/subprocess call site requires a named threat-model entry the same way
  adding a UI surface requires a test-coverage matrix entry. Re-run the audit playbook
  periodically (it becomes cheap to repeat once established as a ritual), not once.

---

## G. Quota / compaction / multi-agent operational risks

### 24. Post-compaction context loss causes the agent to act on stale file-state assumptions
**Likelihood: Certain over any long-running agent session · Impact: Medium** (pure
friction, but the single largest error class measured on the prior project — roughly a
third of all tool-call errors) *(learned: every context compaction wiped the agent's
"files I've read" tracking while its plan/intentions survived in the re-injected summary,
so it repeatedly issued edits against untracked file state, got rejected, and re-read —
this pattern never self-healed across 150 compactions on the prior project)*.
- **Early-warning signal:** "file has not been read yet" or equivalent staleness
  rejections clustering immediately after a compaction boundary.
- **Mitigation:** design the task/tracker substrate so working units are short-lived and
  externally rehydratable — a fresh agent session for a unit of work reads its full
  context (contract, curated references, current state) from durable storage rather than
  depending on an in-memory read-set surviving compaction. Don't rely on a prompt-level
  "re-read defensively" rule; it demonstrably does not close this gap by itself.

### 25. Structural/procedural rule violations (illegal state transitions, tracker misuse) never improve from repeated rejection feedback alone
**Likelihood: Certain if the tracker's state machine is agent-driven rather than
enforced · Impact: Medium** (second-largest measured error class) *(learned: illegal
task-lifecycle transitions were the #2 error class on the prior project and stayed flat
in frequency across 7.5 weeks despite constant rejection feedback — each rejection was a
dead-end retry, not a state the agent could learn from)*.
- **Early-warning signal:** the same category of tool/tracker-usage error recurring at a
  constant rate across many sessions with no downward trend.
- **Mitigation:** give the tracker/workflow tool a state machine that the RUNNER enforces
  mechanically — agents only emit data-plane verbs (record evidence, request transition);
  they never directly set illegal states. A rule that depends on the agent "learning
  better" from an error message does not work at this error volume.

### 26. Unbounded exploratory subagent/workflow fan-out burns quota with no circuit breaker
**Likelihood: Medium-High (any open-ended "explore/research X" delegation) · Impact:
High** (single incidents burned roughly half a session's token budget) *(learned: an
open-ended research spike recursively expanded from an intended handful of agents to
~75 before being reined in; contrast a separately bounded, severity-triaged audit fanout
of similar size that stayed healthy specifically because it had a defined scope and kill
criteria from the start)*.
- **Early-warning signal:** a delegation instruction phrased as "explore this broadly" or
  "research X" without an explicit agent-count ceiling or a defined stopping condition.
- **Mitigation:** cap exploratory/research fan-out with a hard ceiling enforced by the
  orchestration layer, not by prompt instruction alone. Prefer a single-pass or fixed-
  agent-count default for open-ended research; reserve larger fan-outs for well-scoped,
  severity-triaged, kill-criteria-bounded work (the pattern that stayed healthy).

### 27. Parallel-agent worktree/build isolation accumulates disk usage with no automatic reap
**Likelihood: High (any workflow using git worktrees for agent isolation) · Impact:
Medium** (pure hygiene/disk-pressure risk, not correctness — but can silently exhaust
disk) *(learned: a crashed or interrupted parallel-agent run left worktrees locked
forever, each carrying its own multi-gigabyte build directory; one measured incident hit
~124 GB across 60 worktrees while the actual git object database was ~36 MB — committed
work was never at risk, it was pure unmonitored waste)*.
- **Early-warning signal:** disk-pressure warnings, or any worktree directory older than
  the workflow run that created it.
- **Mitigation:** automate worktree/build-artifact reaping (unlock → remove → prune) as
  part of every parallel-agent workflow's normal completion path AND its crash-recovery
  path. Default build output outside the worktree from the first parallel-agent workflow
  (point native build caches at a shared, non-worktree location). Treat "check for stale
  worktrees" as a scheduled maintenance step, not an incident response.

### 28. Doc-churn / progress-narration commits become a standing process tax
**Likelihood: High absent an explicit rule · Impact: Medium** (measured at up to ~1.5-1.7
standalone-doc-commits per code commit during the worst stretch) *(learned: an autonomous-
run mandate to "log every landed item" produced a multi-week stretch where roughly half
of all commits were standalone documentation/progress-log commits; a mid-project directive
to fold doc updates into the code commit they describe measurably cut this ratio by more
than half within 1-2 weeks and it held for the rest of the project)*.
- **Early-warning signal:** any standalone commit whose diff touches only a progress-log/
  handoff/changelog file with no accompanying code change.
- **Mitigation:** land the "fold process documentation into the code commit it describes;
  no standalone doc-churn commits" rule in the agent instructions before commit #1 — this
  is a rule with a measured before/after on the prior project, don't wait to rediscover
  it.

---

## How to use this register

1. **On day 1**, read section A (platform walls) and section G (operational risks) in
   full — these are the ones that bite before any product code exists.
2. **Before the first release-candidate build**, revisit sections A.3 (notarization),
   F (licensing), and C (verification ladder) — these are the ones that are cheap to
   fix early and expensive to discover late.
3. **At every "feature complete" milestone**, revisit section D (scope/shelf-ware) and
   run a code-first reconciliation sweep (does every merged ticket have a real,
   reachable UI caller?) before believing the tracker's status.
4. **Whenever architecture decisions are being made** (a second UI stack, a second
   storage format, a growing coordinator object), revisit section E before writing the
   second instance of anything.
5. Treat every entry's "early-warning signal" as a thing worth a periodic grep/query,
   not just something to remember. Where a signal is mechanically detectable (zero
   external callers, discarded `Bool` return, missing flush hook, doc-only commit),
   wire it into CI rather than relying on review discipline — the evidence above is
   consistent that prose rules and reviewer discipline do not hold at scale, but
   mechanized checks do.
