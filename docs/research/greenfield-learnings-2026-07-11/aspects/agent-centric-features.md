# Agent-Centric Features — Learnings for the Rebuild

**Dimension:** the "non-blackboxy" surfaces built to make the app agent-collaborative —
MCP automation socket/verbs, code review + share-to-agent, walkthroughs, Canvas
incremental UI authoring, AX-driven UAT, Claude-adjacent tooling (transcript/session
plumbing) — and the trust model around all of it.

**Evidence base:** `docs/research/greenfield-learnings-2026-07-11/summaries/code/src-core-automation-infra.md`,
`.../src-core-sessions-review-plugins.md`, `.../t-ui-harness.md`; commit-era report
`.../summaries/commits/c-17of19.md`; docs synthesis `.../summaries/docs/d-docs-root-2of2.md`
(+ `d-claude-dir.md`, `d-root-md.md`, `d-progress-1of3.md`); the dedicated security audit
`docs/research/prelaunch-audit-2026-07-09/automation-control-surface.md`; `BACKLOG.md`
THEME 3; commit history (`git log`, TSK-1342/1360 Canvas epic).

---

## Taxonomy — the distinct agent-centric surfaces

| Surface | What it is | Maturity / frequency | Evidence |
|---|---|---|---|
| **MCP transport** (stdio + unix-socket) | `MCPServer`/`MCPFraming`/`MCPSocketListener`/`MCPSocketBridge` — JSON-RPC 2.0 + MCP 2024-11-05, hand-rolled, zero external SDK deps (~150 LOC vs 10× with a package) | Production-grade engineering (fd-caching, deadline recovery, dual framing); always-on for every GUI launch | `src-core-automation-infra.md:107-131`; `automation-control-surface.md` F1 |
| **Tool catalog** (~40 MCP tools) | `MCPToolCatalog.swift` (1,622 LOC): file ops, view state, find, code nav, canvas (14 ops), git, etc. | Centralized dispatch, but security enforcement inconsistent across tools (see "What hurt") | `src-core-automation-infra.md:132-135` |
| **Script-verb bus** (~60 verbs) | `ScriptVerbCatalog` + `ScriptVerbDispatch` — data-mirror of a dispatcher switch, drift-guarded by a test that parses the dispatcher source | Reused by MCP `run_verb`, palette, and `--script` CLI — one vocabulary, three entry points (a design smell: MCP inherits the *local-actor* verb set unfiltered) | `src-core-automation-infra.md:137-140`; `automation-control-surface.md` F3 |
| **Code Review module** (agent-export) | `Review.swift`/`ReviewComment.swift`/`ReviewStore.swift` — scoped diffs (workingTree/commit/range/branch), frozen hunk context, state machine, ULID ids, exports to a Claude-Code-readable format | Mature, "KEEP" across the board; 13 files, ~2,200 LOC | `src-core-sessions-review-plugins.md:62-77, 225-238` |
| **Walkthroughs** (agent-authored guided tours) | `WalkthroughScript`/`WalkthroughEngine` — versioned JSON schema (v1/v2), pure-logic state machine, delegate pattern to UI, ~13 verbs (openFile, revealLine, highlightRange, runDiff, awaitUser, flash, diagram, …) | Mature; agent-authoring proven; reentrancy-guarded | `src-core-sessions-review-plugins.md:147-176, 256-267` |
| **Canvas** (agent-primary incremental UI authoring) | `CanvasBridge` (versioned Swift⇄JS envelope), `CanvasDocumentStore`, `CanvasDocAdapter` (Rust engine facade), DSL with round-trip law | Giga-epic (TSK-1342); after a costly 75-agent research runaway, replanned Rust-first with M0–M6 milestones, shipped in ~4 days/80 commits with multi-tier validation | `src-core-sessions-review-plugins.md:179-205`; commit era `c-17of19.md` |
| **AX-driven automation / UAT** | `AXIdentifierCatalog` (~60 curated `mdv.*` ids, drift-guarded), `ElementRef` (5-scheme URI, `mdv://` refs for agent copy/paste), `AXDrivePlan`/`AXDriverCore`, `ClickTargetRegistry` | First-class design (curated catalog, not raw AX tree walk); AX *interaction* remains the one tier the *worker* agent cannot self-validate (TCC-gated) — human/owner exception, not a default | `src-core-automation-infra.md:141-156`; `CLAUDE.md` §Testing rules |
| **Diagnostics / observability** | `DiagnosticSnapshot` (curated, no raw file bytes, no MCP exposure by design), `PerfSignpost`, `Obs` ring buffer | Deliberately narrow — explicitly documented as "the single most dangerous instrumentation surface" if done wrong | `src-core-automation-infra.md:52-55, 179` |
| **Trust/consent model** | Same-uid unix socket, `chmod 0600`, no peer-credential check, no token, no consent UI, no audit log | The one systemically under-built surface — every other agent surface assumes a trusted operator sits on the other end of the socket | `automation-control-surface.md` F1–F7 |

---

## What worked — practices that earned their keep

1. **Curated protocol boundary over raw model access.** `AutomationHost` is a
   deliberately high-level `@MainActor` protocol (open path, select tab, find, run
   verb, code nav) — never the raw `DocumentModel`. This kept the automation surface
   reviewable and stable even as the UI model churned underneath it (`DocumentModel`
   itself went through a 40-slice SRP decomposition, TSK series in c-16, with **zero
   automation-surface breakage** because callers only ever touched the protocol).
   `src-core-automation-infra.md:107-110`.

2. **Hand-rolled MCP wire types over an SDK.** ~150 LOC of JSON-RPC + MCP types vs an
   order of magnitude more with a dependency; the safe-numeric-decode discipline
   (`Int(exactly:)` instead of trapping conversions) turned a supply-chain-risk
   decision into a *better* security story than the SDK default would likely have
   given for free. `src-core-automation-infra.md:112-115`.

3. **Centralizing the security model in one dispatch switch.** `MCPToolCatalog`
   puts validation/clamping/limits in one place so the whole security posture is
   reviewable without hunting across files — this is *why* the F3 gap (see below)
   was findable and fixable in one place rather than a scattered hunt.
   `src-core-automation-infra.md:134-135, 200`.

4. **Frozen context for code review comments.** `ReviewComment` snapshots 3
   lines pre/post + the anchored line(s) *at creation time*, with `blobSha`
   staleness detection — an agent consuming the export never needs to re-derive
   "what did this comment actually point at," eliminating the classic
   "source moved" fragility of line-number-only review tools.
   `src-core-sessions-review-plugins.md:70-72, 231, 237`.

5. **Pure-logic engine + delegate pattern for Walkthrough.** The step-sequencing
   state machine has zero UI dependency and a reentrancy guard against recursive
   `next/jumpTo/restart` calls from mid-step handlers — this is the same seam
   discipline that made the rest of the core headlessly testable, applied to an
   agent-drivable feature specifically. `src-core-sessions-review-plugins.md:154-157`.

6. **Canvas as agent-primary, not agent-secondary.** The owner's decision record:
   "LLM models are bad at raw coordinates, good at intent; high-level API → high
   executability," empirically borne out at **80%+ agent-executability vs 2–11%**
   for a raw-coordinate/WYSIWYG baseline (`d-docs-root-2of2.md:354`). This is the
   single strongest *design-philosophy* validation in the whole corpus: build the
   authoring surface as a DSL an agent can emit correctly, and let humans edit the
   same document secondarily — not the other way around.

7. **Versioned envelopes everywhere an agent crosses a process/language boundary.**
   `CanvasBridge` (v1, object-literal not string-wrapped JSON, matching CM6's
   production shape per a prior lesson), `WalkthroughScript` (v1/v2 schema
   discriminator, unknown versions fail structured not silent), MCP's own framing —
   the pattern of "version the envelope, fail loud on skew" recurs across every
   agent-facing wire boundary and is credited repeatedly as preventing "an older
   binary handed a newer script crashes or misbehaves." `src-core-sessions-review-plugins.md:182-184, 348-352`.

8. **Agent-driven UAT over human checklists, once it matured.** The 2026-07-04
   mandate (human gates breed overclaiming) replaced human screenshot checklists
   with machine-executed evidence; 97 tests were auto-verified against the real app
   under this model. `d-docs-root-2of2.md:356`. The AX-structural vs AX-interaction
   split (TCC blocks *interaction* — press/type — not element *existence* checks)
   let a large fraction of "VM-only" work get staged host-first after all, once the
   team stopped conflating "needs a screen" with "needs TCC." `d-progress-1of3.md:71-76`.

---

## What hurt — costly failures and root-cause mechanism

1. **The automation trust model was never actually designed — it accreted.**
   `automation-control-surface.md` F1: an **always-on, unauthenticated, same-uid
   unix socket** serves the entire ~40-tool catalog to *any process running as the
   user*, not just the intended agent. Root-cause mechanism: the header comment in
   `MCPSocketListener` states the whole security model as "same-user only... no
   auth token in v1" — i.e., the v1 placeholder was never revisited as the tool
   catalog grew from a handful of read-only inspectors to `run_task` (arbitrary
   code exec) and file-write verbs. **The trust model didn't fail to scale — it was
   never re-evaluated against what the surface had grown into.** This is a
   scope-creep-without-a-re-audit failure mode, not a one-time oversight.

2. **A security fence built once, applied inconsistently.** F3: `open_path`,
   `search_files`, `move_file`, `run_task` all route through `validatedExistingURL`
   (a real, well-engineered home/temp jail with physical symlink resolution). But
   `run_verb`'s `open`/`save-copy`/`session-open-folder` — the **same class of file
   operation**, reachable through a **different entry point into the same tool
   catalog** — bypass the jail entirely because `runVerb` only validates that the
   verb token exists, never that its argument is in-jail. Root-cause mechanism:
   **the security boundary was drawn per-tool, not per-capability.** Two code paths
   ("call the MCP file-op tool directly" vs "call `run_verb` which happens to open
   a file") reach the same effect through different validation, and only one was
   remembered when the jail was added. This is the textbook argument for a
   capability check that lives on the *effect* (open/write/exec a path), not on
   the *call site*.

3. **`run_task`'s allowlist gates the wrong layer.** F2: the tool description
   claims "arbitrary commands are not expressible," but the allowlist only gates
   the task **id** — the *body* a discovered `npm run <name>` / `make <target>`
   executes is fully author-controlled shell in whatever `package.json`/`Makefile`
   the client points at. Root-cause: conflating "the surface I built only exposes
   named tasks" with "the surface I built only exposes safe commands" — the
   allowlist secures the *menu*, not the *kitchen*.

4. **No audit trail was a deliberate design choice, not an oversight — and it was
   the wrong call.** F5: `MCPServer.log` explicitly documents "per the security
   model the MCP host must NEVER read that buffer back out (no audit/consent)."
   This reads as a considered privacy stance (don't let the app snoop on the
   agent), but it also means a compromised or misdirected client leaves **zero
   forensic trail** for the exact class of actions (file writes, process spawns,
   secret-adjacent reads) that most need one. The lesson isn't "always audit
   everything" — it's that a privacy-motivated no-audit decision needs to be
   revisited once the surface can also *execute code and exfiltrate files*, which
   is a materially different threat model than "read view state."

5. **Statelessness (a legitimate reconnect design) accidentally closed off the
   only natural place to put auth.** F6: `tools/call` doesn't require `initialize`
   first, by design, so a self-healing bridge can reconnect mid-session without
   re-handshaking. That's a reasonable *availability* choice — but it means there
   is structurally no point in the protocol where a capability token could be
   checked without also redesigning the reconnect contract. This is a case of one
   good decision (stateless reconnect) silently foreclosing a different good
   decision (auth) because they were made independently, at different times,
   without the second decision-maker seeing the first one's consequence.

6. **Socket-path squatting: no identity check on either end.** F7: the socket
   `unlink`s and rebinds unconditionally on the "single-instance app" assumption —
   an *availability* assumption repurposed as a *security* one. A same-uid
   attacker can win the bind race or preempt it, and the agent's bridge — which
   re-dials the *path* forever on reconnect — has no way to notice it's now
   talking to an impostor. This is the most agent-specific finding in the whole
   audit: it's not "the app is insecure," it's "the *agent* can be silently
   MITM'd and fed forged tool results / prompt injection with no signal."

7. **The Canvas epic's research phase was a ~75-agent runaway that burned ~half a
   session's quota** before the owner intervened and re-scoped it. Root-cause
   mechanism (per the project's own retrospective, now a standing lesson):
   unbounded "explore this epic" delegation to general-purpose subagents
   recursively expands — there was no ceiling on fan-out depth or agent count.
   The *rebuild* that followed (Rust-first, design-doc-locked, M0–M6
   milestone×slice decomposition) was healthy and shipped in ~4 days — the
   contrast is the lesson: **exploratory research needs a hard cap or
   single-pass/read-only framing; execution against a locked design can fan out
   safely.** `c-17of19.md:5-9, 136-139`.

8. **`.claude/` — the one place a rebuild should look for "how did this project
   configure agent tooling" — is empty**, and `CLAUDE.md` references a skill
   (`.claude/skills/run-uat`) that was never created; the actual UAT harness lives
   scattered across `docs/research/agent-uat-framework-2026-06-20/` and
   `scripts/vm-*`. This is a documentation/discoverability failure specific to
   agent-tooling: the policies that govern how *agents* should drive the app live
   entirely in prose (`CLAUDE.md`), not in any machine-readable or
   skill-registered form — so a fresh agent session has to re-derive "what am I
   allowed to do here" from narrative text every time, rather than from an
   enforced manifest. `d-claude-dir.md:38-58`.

9. **Coverage gaps in the audit itself are evidence of the surface's blast
   radius.** The automation-control-surface audit explicitly could not fully
   trace `canvas_*` tool file I/O, the AX driver's own reachable action set, or
   whether `rename_symbol`'s LSP-applied edits are jailed — because the agent
   surface had grown organically across MCP tools, script verbs, AX actions, and
   LSP-backed code-nav, each added independently, with no single place that
   enumerates "everything an agent can cause to happen to the filesystem."
   `automation-control-surface.md:308-329`.

---

## Design implications for the rebuild

**Design the trust model on day one — do not let it be "same-uid, v1, TODO."**

- Treat the agent-control surface as a **capability system from the start**: every
  effect (open/read/write/exec/screenshot) gets a capability, tools are annotated
  with which capabilities they require, and *the jail/validation lives on the
  capability*, not duplicated per call-site. This directly prevents the F3 class
  (same effect, two code paths, one checked). Concretely: a single
  `AuthorizedFileAccess` (or similar) type that every path-taking operation must
  go through to even *construct* a valid path argument, so "forgot to jail this
  one call site" becomes a compile-time impossibility, not a code-review miss.
- Ship a **connection-level capability token** from day one, even if v1 auto-grants
  it with no UI friction — so the *protocol* has a slot for auth before any tool
  gets built that needs one, avoiding the F6 trap (statelessness painted into a
  corner with no auth point). Decide the reconnect story (token cached + re-sent)
  *before* building the reconnect bridge, not after.
- **Audit every `tools/call`** to a persisted, user-viewable log from the first
  commit — cheap, non-behavioral, and the single highest ROI/effort fix in the
  whole corpus (F5 was rated "Fix size: S, Fix risk: safe"). Don't relitigate
  "should we audit" once the catalog includes exec/write tools; decide it once,
  upfront, for the whole surface.
- **Verify server identity on connect** (a per-launch secret sibling file, or a
  signed nonce at `initialize`) so a same-uid squatter can't MITM the agent
  bridge. This is cheap infrastructure that has no legitimate reason to be
  deferred to "v2."
- Draw an explicit line between **"local script/palette actor" and "MCP remote
  actor."** The same verb vocabulary being reachable from both was the mechanism
  behind F3 — a verb that's safe for the user driving the palette (open anything
  they can see) is not safe for an unauthenticated same-uid peer. Either give MCP
  its own jailed subset of verbs, or make every verb capability-checked
  regardless of caller (see above) so there's no "trusted caller" special case to
  forget.

**Keep doing, unmodified:**

- Curated `AutomationHost`-style protocol boundary between the UI/document model
  and everything agent-facing — proven to survive a 40-slice internal refactor
  with zero automation breakage.
- Hand-rolled, minimal MCP wire types over pulling in an SDK — this held up fine
  at production scale and kept the dependency surface honest.
- Versioned envelopes + graceful unknown-case handling on every agent-facing wire
  boundary (Canvas bridge, Walkthrough schema, review export format).
- Canvas/Walkthrough-style **DSL-first, agent-primary authoring** for any new
  agent-authorable surface — the 80%+ vs 2–11% executability gap is too large to
  treat as a nice-to-have; design the DSL grammar before the UI that renders it.
- Frozen-context capture (review comments) for anything an agent will consume
  asynchronously from when it was created — never make the agent re-derive "what
  did this point at."
- Agent-driven UAT as the default validation ladder, with the AX-structural
  (existence/wiring) vs AX-interaction (press/type, TCC-gated) split made
  explicit from day one — this unblocked a large fraction of work that used to
  get mis-parked as "VM-only."

**Accept as inherent, ongoing cost — budget for it, don't expect a one-time fix:**

- VM/AX/pixel test-harness investment recurs every time a new agent-facing
  render surface ships (webview, T4, T5, AX each needed their own multi-commit
  unblock over the project's life). Budget it as permanent infrastructure tax.
- Exploratory agent-authoring epics (a Canvas-scale feature) will always tempt an
  unbounded research fan-out; the mitigation is a hard cap on subagent
  delegation depth/count for *exploration*, not a promise that it won't be
  tempting again.
- A living, growing tool/verb/AX-action catalog will always need a periodic
  "enumerate everything an agent can cause to happen" audit — the coverage gaps
  in the one audit that got run (`canvas_*` I/O untraced, AX driver's own
  reachable surface untraced) show this doesn't self-report; it has to be
  scheduled.

---

## Portable rules — candidate directives for the next project

1. **No agent-facing capability (file I/O, process exec, screenshot, network) may
   be added to the tool catalog without an explicit capability annotation and a
   single shared enforcement point** — never re-implement path validation per
   call-site. A verb that reaches the filesystem through a different entry point
   than the "official" file-op tool must go through the *same* jail, not a
   parallel one.
2. **Every agent-facing socket/transport ships with a connection-level auth
   token and a persisted, user-viewable audit log from commit #1** — treat "v1,
   same-uid only, no token" as a red flag to fix before merge, not a placeholder
   to revisit "later" (later never came in this project).
3. **Design the auth point before the reconnect/statelessness contract**, not
   after — deciding both independently produces a protocol with no valid place
   to put a token.
4. **Verify peer identity on any local socket a same-uid attacker could squat**
   (a signed nonce, a sibling secret file, or `flock`-guard the bind) — "the app
   is single-instance" is an availability assumption, never a security one.
5. **Build new agent-authorable surfaces DSL-first, agent-primary** — write the
   grammar an agent can reliably emit before building the human-facing WYSIWYG
   editor for the same document; measure executability, don't assume it.
6. **Cap subagent/research fan-out explicitly for exploratory work** (a hard
   agent-count or single-pass/read-only ceiling); allow full fan-out only against
   a design that's already locked (spike → design doc → then fan out to build).
7. **Every wire boundary an agent crosses gets a version discriminator with
   graceful-fail on unknown values** (structured error, not a crash or silent
   corruption) — apply this uniformly to MCP framing, DSL schemas, and any
   future protocol, not case-by-case.
8. **Periodically run a "what can an agent cause to happen" enumeration audit**
   across MCP tools + script verbs + AX actions + LSP-backed code-nav as one
   list, not siloed per subsystem — this project's own security audit couldn't
   fully trace three of its own surfaces (Canvas I/O, AX driver reach,
   rename-symbol edit confinement) because no single catalog enumerated them
   together.
