# `tasked` project-tracker — gaps to fix for a smoother agent experience

Friction observed while an autonomous agent dogfooded the `tasked` board
(`http://localhost:8787`, MCP `mcp__tasked__task_*`). Ordered by impact. Each
item: **symptom → why it hurts → suggested fix.**

> Scope note: this is about the **owner's `tasked` app** (the in-app PM feature,
> harness task #216), NOT the built-in `TaskCreate`/`TaskList` tools.

## A. Correctness / API-consistency (cheap, high-value)

1. **No `task_delete` (human or agent).**
   - *Symptom:* a stray/test task (e.g. `TSK-107`) can never be removed; it
     pollutes every `task_list` forever.
   - *Why it hurts:* the board accretes noise; agents can't self-clean after a
     mistaken `task_create`.
   - *Fix:* add `task_delete(id, actor)` — human-only, or agent-allowed for
     tasks it created that are still in `reported`. Soft-delete (archive) is
     fine; just get them out of the default list.

2. **Field-name inconsistency: `task_comment` takes `body`, not `text`.**
   - *Symptom:* the obvious `{"text": ...}` fails with "missing required
     'body'"; every other content-ish call uses different keys.
   - *Why it hurts:* wasted round-trips guessing the schema.
   - *Fix:* accept `text` as an alias for `body` (and document the canonical
     one). Generally: align field names across `task_create` / `task_comment` /
     `task_record` (`summary` vs `note` vs `body` are currently a guessing game).

3. **curl helper needs `--data-binary @-`, not `-d`.**
   - *Symptom:* `-d '{...}'` mangles braces → JSON parse error at the server.
   - *Why it hurts:* every shell-based caller hits this once and loses time.
   - *Fix:* tolerate `-d`-style bodies server-side (trim/normalize), or document
     the exact curl incantation in the tool description.

## B. Reliability

4. **Rapid back-to-back `task_record` swallows responses (lock/lease race).**
   - *Symptom:* two `task_record` calls in quick succession — the second
     occasionally returns nothing / a transient lock or lease error.
   - *Why it hurts:* the agent can't tell if the transition landed; it must
     re-`task_get` to confirm, or risks double-applying.
   - *Fix:* serialize writes per task with a short queue (not a hard lock that
     drops the call), and make transitions idempotent (re-applying the same
     target state is a no-op, not an error).

5. **Mid-session `claude mcp add tasked` doesn't hot-load the tools.**
   - *Symptom:* registering the MCP server during a session doesn't surface the
     `task_*` tools until a full reconnect; the agent falls back to a curl
     helper.
   - *Why it hurts:* the agent can't start using the board the moment it's wired.
   - *Fix:* (this may be a Claude-Code/MCP limitation, not `tasked`'s) — at
     minimum document "reconnect required"; ideally support hot tool refresh.

## C. Discoverability of the lifecycle (the big one)

6. **The `confirmed` flag *looks* like a gate but isn't — and it's undocumented.**
   - *Symptom:* `confirmed` is checked NOWHERE in `canTransition`/triage/claim/
     record; it's a human advisory ("yes, you understood") only. Agents assume
     it blocks transitions and stall waiting for it.
   - *Why it hurts:* an agent can self-drive `reported → ack → triaged →
     progress → fixed → review` with zero human input, but mistakes `confirmed`
     for a hard stop and parks unnecessarily.
   - *Fix:* rename it (`acknowledged_by_human`?) and/or surface its true meaning
     in `task_get` output and the tool docs. State plainly which transitions are
     agent-reachable vs human-only.

7. **Transitions must be SEQUENTIAL but the error doesn't say the path.**
   - *Symptom:* `reported → triaged` fails with "transition not allowed for
     actor_kind 'agent'" — the real cause is you must `restate` first
     (`reported → ack`), then `triage` (`ack → triaged`), then `record`.
   - *Why it hurts:* agents journal progress via `task_comment` (which always
     works) instead of advancing state, so tasks *look* stuck while work
     happens. This is exactly what stalled a prior run.
   - *Fix:* the rejection error should name the **next legal transition(s)** and
     the tool to call (`"from 'reported', call task_restate to reach 'ack'"`).
     Consider a `task_advance(id, to)` that walks the intermediate states
     automatically when they're all agent-legal.

8. **No first-class "this needs a human" surfacing in the common flow.**
   - *Symptom:* `task_park(... waiting:"human")` exists but is easy to miss; the
     agent's only always-works verb is `task_comment`, so decisions get buried
     in comment threads.
   - *Fix:* make "needs-owner-decision" a prominent, filterable state, and have
     `task_list` default-surface it (a "Decisions waiting on you" bucket).

## D. Missing features that make agent use smoother

9. **No confidence / hesitancy field.** *(owner explicitly wants this)*
   - *Want:* a per-task `confidence` (high/medium/low) + `blocker`
     (none/owner-decision/dep-approval/live-validation/supervised) so the board
     shows at a glance what's solid vs speculative vs gated — without parsing
     prose. The agent is currently encoding this in subject prefixes
     (`[BLOCKED:…]`) and free-text because there's no field.
   - *Fix:* add structured `confidence` + `blocker` enums; let `task_list`
     filter/sort on them.

10. **No batch ops.** Filing N findings = N round-trips.
    - *Fix:* `task_create_many` / `task_record_many` for bulk filing after a
      review or a fan-out run.

11. **`task_list` has no filters/sort.** Returns everything; the agent must
    scan a long flat list every call (the built-in board is at ~250 items).
    - *Fix:* filter by `state` / `area` / `owner` / `blocker`, sort by priority
      or recency, and paginate.

12. **No dependency edges (`blocks` / `blocked_by`).**
    - *Want:* express "slice #9 blocked by `regex` dep approval", "monitor
      content-search UI blocked by the redaction fix (now done)".
    - *Fix:* add dependency edges so the board can compute the ready-to-work set
      automatically (don't surface a task whose blockers are open).

13. **No link from a task to its commits / artifacts as structured data.**
    - *Symptom:* commit SHAs live in free-text summaries.
    - *Fix:* a `commits: [sha]` / `artifacts: [path]` field on `task_record` so
      the board can render "what shipped" and link to the diff.

## Quick wins to do first
B4 (idempotent transitions), C6 + C7 (lifecycle discoverability — the error
messages), and D9 (confidence/blocker fields) would remove the bulk of the
agent friction. A1 (`task_delete`) and C11 (`task_list` filters) are the next
cheapest.
