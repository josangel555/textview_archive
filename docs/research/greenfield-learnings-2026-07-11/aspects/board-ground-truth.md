# Board ground truth (tasked MCP, 2026-07-11)

Queried live via `mcp__tasked__*` against `http://localhost:8787/mcp` on 2026-07-11.
Hard cap of 12 board calls was honored (used 11 of 12: 1 `project_list` + 1
one-row schema probe + 9 per-state `task_list` calls, all `quiet:true`).

## Method

1. `project_list` → found the project this repo files tickets under: key
   `tasked`, label "Tasked", **prefix `TSK`**, `taskCount: 1474`. (Note: despite
   the project *key* being "tasked", this is the actual markdown_viewer /
   TextView board — not the meta "Internal · tasked issues" project, which is a
   separate `internal`/`INT` project for bugs in the tracker tool itself.)
2. One `task_list(project:"tasked", state:"reported", limit:1)` call to confirm
   response shape (no aggregate/count field exists on this MCP surface — only
   row-level data + a `next_offset` pagination cursor).
3. Nine `task_list(project:"tasked", state:<lane>, limit:200, quiet:true)` calls,
   one per lifecycle lane (`reported, ack, triaged, progress, fixed, review,
   validated, done, wontdo`).

**Caveat on the per-lane counts:** `task_list` is byte-budgeted (~20KB
serialized) independent of `limit` — several lanes hit that budget cap before
200 rows and returned a `next_offset`, i.e. the true lane count is *higher*
than what's shown. Getting exact per-lane totals would require paginating each
truncated lane to exhaustion, which blows the 12-call budget for this task.
The **total ticket count (1,474) is exact** (from `project_list`, a single
aggregate field) — the per-lane breakdown below is a mix of exact and
lower-bound numbers.

## Per-lane counts (2026-07-11)

| Lane | Count | Exact? |
|---|---|---|
| `reported` | ≥85 | **lower bound** — page hit byte cap, `next_offset:85` |
| `ack` | 32 | exact (page completed, no `next_offset`) |
| `triaged` | 12 | exact |
| `progress` | 0 | exact |
| `fixed` | ≥65 | **lower bound** — `next_offset:65` |
| `review` | ≥75 | **lower bound** — `next_offset:75` |
| `validated` | ≥68 | **lower bound** — `next_offset:68` |
| `done` | 49 | exact |
| `wontdo` | 57 | exact |
| **Total (all lanes, this project)** | **1,474** | **exact** (`project_list.taskCount`) |

Sum of the counts above (using lower bounds where truncated) = at least 443;
the remaining ~1,031 tickets sit in the four truncated lanes (`reported`,
`fixed`, `review`, `validated`) — consistent with those being the largest,
most heavily-populated lanes (bulk WISH/BACKLOG/PARTIAL items and the long tail
of `fixed`/`review`/`validated` audit + usability tickets from the 2026-06/07
drain campaigns).

## Important caveat: the `TSK` prefix is NOT markdown_viewer-exclusive

The `tasked`/`TSK` project's 1,474-ticket count is **contaminated with
foreign-project tickets**. Concretely, in the `wontdo` lane sample:
`TSK-856` through `TSK-880` ("Globe: geo boundaries...", "Globe timeline: add
day and hour tick markers...", etc.) are **wx_weather_app / Globe renderer**
work, dismissed by `agent:claude-wx-session` and `agent:audit-port` — not
markdown_viewer agents. `wx_weather_app` has its own project/prefix (`wxa`/
`WXA`, `taskCount: 235`) per `project_list`, yet these tickets were filed
under the shared `TSK` sequence instead. This means **1,474 overstates
markdown_viewer's true ticket count** by some unquantified amount (not
determined within the 12-call budget — would need either a full-lane grep for
non-`claude-mdv`/non-`claude` actors, or a `q`/`regex` sweep for `Globe`/
weather-specific vocabulary across all lanes). Reports quoting "1,474 board
tickets" for markdown_viewer specifically should carry this caveat.

## Resolving the 1,168 vs 1,500 discrepancy

Two prior figures appear in the corpus/PM docs:

- **1,168** — produced by `grep`-ing commit trailers (e.g. `[CH-*: TSK-####]`
  style tags) across `git log`. This is a **strict undercount**: it only
  counts tickets that (a) actually shipped an implementing commit AND (b) had
  that commit tagged with a trailer referencing the ticket ID. It structurally
  excludes every ticket still in `reported`/`ack`/`triaged` (no code landed
  yet — confirmed ≥129 tickets across just those three lanes above),
  every `wontdo` (57, no code by definition), and any commit that landed
  without a trailer (a known, if discouraged, gap in commit hygiene).
- **1,500** — appears to be an **ID-range estimate** (eyeballing the highest
  observed `TSK-####` id, e.g. `TSK-1585`/`TSK-1568`/`TSK-1583` seen in
  memory/handoff notes, and assuming a roughly dense sequence from `TSK-1`).
  This over-estimates in one direction (assumes no gaps in the numbering) and
  is contaminated in the same way as the 1,474 figure (foreign-project IDs
  like the `TSK-856..880` Globe tickets consume numbers in the same sequence
  without being markdown_viewer work).

**Resolution: the board total, 1,474, is the authoritative ticket count** for
the shared `tasked`/`TSK` project as of 2026-07-11 — it's a direct aggregate
read from the system of record, not a derived/indirect proxy like either prior
figure. It sits between 1,168 (undercounts — commit-trailer coverage is
partial) and 1,500 (overcounts — assumes a dense ID range). Neither 1,168 nor
1,500 should be cited as "the ticket count" going forward; cite **1,474
(board-verified 2026-07-11)**, with the foreign-project-contamination caveat
above attached whenever the figure is used to characterize markdown_viewer's
scope specifically.

## Blocker-type counts

Not captured — the per-lane row samples above are non-exhaustive for 4 of 9
lanes (see caveat), so a `blocker` tally over partial data would be
misleading; not worth spending the 1 remaining call budget on a partial
number. Skipped per the "if cheap" qualifier in the task — it isn't, given the
pagination truncation already eating the budget.
