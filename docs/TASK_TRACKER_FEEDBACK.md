# `tasked` — experiential feedback from heavy autonomous dogfooding

**Companion to `docs/TASK_TRACKER_GAPS.md`.** That doc is the itemized gap list
(symptom → why it hurts → fix). This one is the narrative: what an autonomous
agent's *workflow* actually looked like while leaning on the board hard across a
multi-wave unsupervised session, and which gaps cost the most in practice. Where
this references a numbered gap, it's `GAPS#n`.

> Scope: the owner's `tasked` PM app (harness task #216), NOT the built-in
> `TaskCreate`/`TaskList` tools. But the single most telling symptom shows up in
> *both*: see "The prefix-encoding tell" below.

## The headline ask: native `confidence` + `blocker` fields (GAPS#9)

The owner explicitly asked me to tag tasks with hesitancy/confidence. I did — but
because there's no field for it, **every signal ended up smuggled into the subject
line as a prefix**: `[BLOCKED:owner-decision]`, `[BLOCKED:owner-dep]`,
`[BLOCKED:live]`, `[BLOCKED:live+supervised]`, `[WONT-DO]`, `[WONT-DO unless
asked]`, `[DONE]`, `[NEXT]`, `[TRIAGE]`, `[RUNNING]`.

### The prefix-encoding tell
That list above is verbatim from this session's actual task subjects. When an
agent is forced to invent a **string taxonomy in the title** to express state the
schema doesn't model, that's the schema telling you what fields it's missing.
Each prefix maps cleanly to a structured field:

| Prefix I had to invent          | The field it should have been          |
|---------------------------------|----------------------------------------|
| `[BLOCKED:owner-decision]`      | `blocker = owner-decision`             |
| `[BLOCKED:owner-dep]`           | `blocker = dep-approval`               |
| `[BLOCKED:live]`                | `blocker = live-validation`            |
| `[BLOCKED:live+supervised]`     | `blocker = supervised`                 |
| `[WONT-DO]` / `[WONT-DO unless asked]` | a `wont-do` state + reason     |
| `[DONE]` / `[RUNNING]` / `[NEXT]` | the lifecycle state itself           |

Concretely, the two enums that would have absorbed nearly all of it:
- `confidence: high | medium | low` — "this is solid" vs "best-guess, verify."
- `blocker: none | owner-decision | dep-approval | live-validation | supervised`

With those, `task_list` could answer the only two questions the owner actually
asks an autonomous run — **"what's ready to work?"** (blocker=none) and **"what's
waiting on ME?"** (blocker=owner-decision) — without anyone parsing prose. Today
those answers require reading every subject line. This is the #1 fix.

## What worked well
- **`task_comment` always succeeds**, regardless of state. It was my reliable
  journal. But that's also a trap (see below) — because it always works, it
  becomes the path of least resistance and real *state* never advances.
- **`task_park(... waiting:"human")`** is the right primitive for surfacing owner
  decisions. It just needs to be more discoverable and default-surfaced (GAPS#8).
- The board survived ~250 items without falling over.

## What cost the most time (ranked by real friction this session)

1. **The lifecycle is sequential but undiscoverable (GAPS#6 + GAPS#7).** This is
   the big one. `reported → triaged` fails with a generic "transition not allowed
   for actor_kind 'agent'", and the real cause — you must `restate` to `ack`
   first, then `triage` — is nowhere in the error. The `confirmed` flag *looks*
   like a gate but isn't checked anywhere. **Net behavioral effect:** I (and per
   the gaps doc, a prior run) defaulted to journaling via `task_comment` instead
   of advancing state, so tasks *looked* stuck while work was actively happening.
   The board's state stopped reflecting reality. Fix = error messages that name
   the next legal transition + tool, and a `task_advance(id, to)` that walks
   agent-legal intermediate states automatically.

2. **No `task_delete` (GAPS#1).** A stray test task pollutes every `task_list`
   forever. An agent that mis-files (and at filing-generously scale, it will)
   cannot self-clean. Soft-delete/archive is fine — just get it out of the
   default list.

3. **`task_list` has no filters/sort/pagination (GAPS#11).** At ~250 items every
   `task_list` returns the whole flat list and the agent re-scans it each call.
   This compounds #1: noise you can't delete + no way to filter past it. With the
   confidence/blocker fields, the highest-value filters write themselves:
   `blocker=owner-decision`, `blocker=none && confidence>=medium`.

4. **Filing N findings = N round-trips (GAPS#10).** After a fan-out review or an
   audit, I have a *batch* of findings to file at once. `task_create_many` /
   `task_record_many` would turn "80 audit findings" from 80 calls into 1.

5. **Idempotent transitions (GAPS#4).** Rapid back-to-back writes occasionally
   swallow a response; I can't tell if the transition landed without a re-`get`.
   Make re-applying the same target state a no-op, not an error.

## A workflow pattern the board doesn't model yet: dependency edges (GAPS#12)

This session had a recurring shape: **work gated on an owner decision or a
dependency approval.** E.g. "Rust slice #9 blocked by `regex` approval", "monitor
content-search blocked by the redaction fix (now done)". I expressed these as
`[BLOCKED:...]` prefixes + prose, but they're really **edges**: `blocked_by`.

With dependency edges the board could compute the *ready-to-work set*
automatically — don't surface a task whose blockers are still open, and the
moment a blocker closes, its dependents light up. For an autonomous run that's
the difference between "agent re-derives the ready set by reading 250 subjects
every wake" and "agent asks the board for ready work and gets it."

## Smaller things that each cost one round-trip to learn
- `task_comment` takes `body`, not the obvious `text` (GAPS#2). Field names drift
  across `task_create`/`task_comment`/`task_record` (`summary` vs `note` vs
  `body`) — guessing-game.
- The curl path needs `--data-binary @-`, not `-d` (which mangles braces into a
  JSON parse error) (GAPS#3). Worth one line in the tool description.
- Mid-session `claude mcp add tasked` doesn't hot-load the `task_*` tools — needs
  a reconnect (GAPS#5). Likely a Claude-Code/MCP limitation, not `tasked`'s, but
  document "reconnect required."

## If you fix only three things
1. **`confidence` + `blocker` enum fields** (GAPS#9) + let `task_list` filter on
   them. Kills the prefix-encoding hack and answers the owner's two real
   questions directly.
2. **Lifecycle discoverability** (GAPS#6 + GAPS#7): errors that name the next
   transition, and/or `task_advance`. Stops agents from silently degrading to
   comment-journaling while state rots.
3. **`task_delete` + `task_list` filters** (GAPS#1 + GAPS#11). Keeps the board
   usable as it grows past a couple hundred items.

Everything else is real but secondary. These three are what turned "the board
reflects what the agent is doing" from true into aspirational this session.
