# Tracker (tasked) — consumer feedback from the claude-mdv loop

Consolidated dogfooding feedback on the `tasked` project tracker (http://localhost:8787/) from
the markdown_viewer autonomous loop, as of 2026-06-09. The live channel for this feedback is the
board's own **`internal` project ("Internal · tasked issues", prefix INT)** — agents file there,
the tracker builder picks up. This doc is the durable consolidated record.

## Already reported AND fixed (the loop works)

- **INT-101** — artifact schemas were opaque (`items: object`); the `checks`/`code`/`diff` shapes
  were only discoverable via runtime rejections. Fixed: shapes now in the tool JSONSchema.
- **INT-102** — file-and-fix agents had a 4-call ceremony (reported→ack→triaged→progress) before
  recording work. Fixed: `task_create {claim:true}` lands directly in progress for the creator.
- **INT-103** — unbounded `task_list` overflowed the MCP token cap on a 109-task board. Fixed:
  limit clamp + docs steer (its "fix D", foreign-task scoping, spawned INT-106 below).
- **INT-104** — `validated_by` went stale on human revoke (projection lied about provenance). Fixed.
- **INT-105** — agent self-retraction of its own bogus validation (backward-only, same-author,
  reasoned). Fixed — motivated by our TSK-262 id-collision incident.

## Newly filed (2026-06-09)

- **INT-106** — `task_next` has no project filter; the ranked head repeatedly wedged on a foreign
  project's task (forge TSK-104), forcing agents to route around the tool. Ask: optional `project`
  key on `task_next`.
- **INT-107** — `validated→done` is human-only (correct) but one-at-a-time; ~40 tasks pooled at
  `validated`. Ask: bulk-approve UI and/or owner-configurable auto-close-after-N-days policy.
- **INT-108** — lifecycle legality is learned one rejection at a time (`reported→fixed` denied,
  `task_validate` from `progress` denied, agent ceiling at `validated`). Ask: publish the
  from→to legality matrix (per actor kind) in the tool descriptions, like INT-101 did for artifacts.

## What works well (keep)

- **The honesty gate** — evidence-gated `task_validate`, hard agent ceiling, human revoke. It has
  repeatedly forced honest holds (e.g. render-path items held at `fixed` until VM evidence exists).
- **`task_park`** — owner-gated blockers ping the human and unblock the loop. Exactly right.
- **`task_advance` auto-walk** — one call walks the legal lanes with a single honest note.
- **Append-only event log + rebuildable projection** — made every dispute auditable.
- **Shared-board tags auto-extending vocabulary** — zero-ceremony labeling (e.g. `rust-core-audit`).

## Known consumer-side traps (ours, not the tracker's)

- Board `TSK-NNN` ≠ Claude Code TaskList `#NNN` (different systems; always `task_get` first).
- The board is shared across projects — grep the repo before acting on any board task.
