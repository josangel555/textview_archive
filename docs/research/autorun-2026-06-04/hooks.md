I have everything I need. The official docs gave the canonical event/payload/output reference, the plugin SKILL gave authoring conventions, and the two existing local hooks show Jos's established patterns (PreToolUse `command` hooks, `jq` stdin parsing, `set -uo pipefail`). Note the existing settings.json has **no `hooks` block** — both scripts exist on disk but aren't currently wired in. I'll flag that and align my example to the established conventions.

---

# Claude Code Hooks — Findings for an Agent-Session Monitoring Tool

## TL;DR

- Hooks are shell commands / HTTP calls / MCP-tool invocations that Claude Code fires at lifecycle points. For **monitoring**, you want the post-action / passive events (`PostToolUse`, `Notification`, `SessionStart`, `SessionEnd`, `Stop`, `SubagentStop`, `UserPromptSubmit`) — all of which can observe-and-log without ever blocking.
- Config lives in `hooks` (top-level key) inside `settings.json`. Structure: `event → [ {matcher, hooks:[{type,command,...}]} ]`.
- Each hook gets a **JSON object on stdin**; common fields are `session_id`, `transcript_path`, `cwd`, `hook_event_name`, plus event-specific fields (`tool_name`, `tool_input`, `tool_response`, `prompt`, `message`, `reason`, `source`).
- For pure logging: read stdin, append a structured line to a file, **`exit 0` with no stdout** (or `{"continue":true}`). Never use `exit 2` in a monitor — that blocks the agent.

> **Note on your current setup:** your `~/.claude/settings.json` (read just now) has **no `hooks` key at all**. The two scripts in `~/.claude/hooks/` (`backup-on-write.sh`, `block-edit-fullfile-rewrite.sh`) exist on disk but are **not registered** anywhere — so they're currently dormant. If you thought they were active, they aren't. The monitoring config below is what actually wires hooks in.

---

## 1. Hook events (the full set)

Events cluster by cadence. The ones relevant to a monitor are bolded.

| Cadence | Events |
|---|---|
| Once per session | **`SessionStart`**, **`SessionEnd`**, `Setup`, `PreCompact`, `PostCompact` |
| Once per turn | **`UserPromptSubmit`**, `UserPromptExpansion`, **`Stop`**, `StopFailure`, **`Notification`**, `MessageDisplay` |
| Per tool call | `PreToolUse`, **`PostToolUse`**, `PostToolUseFailure`, `PostToolBatch`, `PermissionRequest`, `PermissionDenied` |
| Subagents | `SubagentStart`, **`SubagentStop`** |
| Tasks / teams | `TaskCreated`, `TaskCompleted`, `TeammateIdle` |
| Env / config | `CwdChanged`, `FileChanged`, `ConfigChange`, `InstructionsLoaded`, `WorktreeCreate`, `WorktreeRemove` |
| MCP | `Elicitation`, `ElicitationResult` |

For richest session telemetry with the least surface, the high-value seven: **`SessionStart` / `SessionEnd`** (session boundaries + reason), **`UserPromptSubmit`** (what the human asked), **`PostToolUse` + `PostToolUseFailure`** (every tool call w/ inputs and outputs/errors), **`Stop` / `SubagentStop`** (turn boundaries + final response text), **`Notification`** (idle / permission prompts).

---

## 2. Where hooks are configured

| Location | Scope | Committed? |
|---|---|---|
| `~/.claude/settings.json` | All your projects | No (per-machine) — **best for a global monitor** |
| `<repo>/.claude/settings.json` | One project | Yes |
| `<repo>/.claude/settings.local.json` | One project | No (gitignore) |
| Managed policy settings | Org-wide | Admin only |
| Plugin `hooks/hooks.json`; skill/agent YAML frontmatter | Component lifetime | Yes |

`hooks` sits at the same top level as `permissions` / `statusLine` in your settings file. Browse the merged active set with `/hooks`.

> **Gotcha — no hot reload:** hooks are read at session start. Edits to `settings.json` require a new `claude` session to take effect. Also, the captured hook *config* is snapshotted at startup; mid-session edits won't apply to the running session.

---

## 3. The stdin payload

Every hook receives a single JSON object on **stdin**. Common fields on all events:

```json
{
  "session_id":      "abc123",
  "transcript_path": "/Users/me/.claude/projects/<slug>/<uuid>.jsonl",
  "cwd":             "/Users/me/Documents/workspaces/claude/markdown_viewer",
  "permission_mode": "default|plan|acceptEdits|auto|bypassPermissions",
  "hook_event_name": "PostToolUse"
}
```

`transcript_path` is gold for a monitor — it points at the full session `.jsonl`, so your sink can cross-reference or tail it. Event-specific additions:

| Event | Extra fields |
|---|---|
| `SessionStart` | `source` (`startup`/`resume`/`clear`/`compact`), `model`, `agent_type`, `session_title` |
| `SessionEnd` | `reason` (`clear`/`resume`/`logout`/`prompt_input_exit`/`bypass_permissions_disabled`/`other`) |
| `UserPromptSubmit` | `prompt` (raw user text) |
| `PreToolUse` | `tool_name`, `tool_input` (object), `effort.level` |
| `PostToolUse` | `tool_name`, `tool_input`, `tool_response` (object) |
| `PostToolUseFailure` | `tool_name`, `tool_input`, `error` (string) |
| `Stop` | `response_text` (Claude's final message) |
| `SubagentStart` | `agent_type`, `agent_id` |
| `SubagentStop` | `agent_type`, `agent_id`, `subagent_response` |
| `Notification` | `notification_type` (`permission_prompt`/`idle_prompt`/`auth_success`/…), `message` |
| `PreCompact`/`PostCompact` | matcher is `manual`/`auto` |

> **Field-name caveat:** the canonical Anthropic reference uses `tool_response` and (for Stop) `response_text`. Some third-party guides say `tool_result` / `reason` — those are stale or simplified. Trust `tool_response`. The defensive move is `jq -r '.tool_response // .tool_result // empty'` so you survive either.

---

## 4. Config structure & matchers

```jsonc
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "*",                 // tool-name filter (see below)
        "hooks": [
          {
            "type": "command",          // command | http | mcp_tool | prompt | agent
            "command": "bash /abs/path/to/hook.sh",
            "timeout": 10               // seconds; command default 600
          }
        ]
      }
    ]
  }
}
```

**Matcher semantics** (case-sensitive):
- `"*"`, `""`, or omitted → match everything.
- Plain tokens / pipe lists (only `[A-Za-z0-9_|]`) → exact match or alternation: `"Edit|Write"`, `"Bash"`.
- Anything with other chars → treated as a **JavaScript regex**: `"mcp__.*"`, `"^Notebook"`.
- What the matcher matches depends on the event: tool events → `tool_name`; `SessionStart` → source; `Notification` → notification type; `SubagentStop` → agent type; `PreCompact` → `manual`/`auto`. Events like `UserPromptSubmit`, `Stop`, `SessionEnd` (in practice) take no meaningful matcher — use `"*"`.

**Useful env vars / placeholders inside `command`:** `${CLAUDE_PROJECT_DIR}` (repo root), `${CLAUDE_PLUGIN_ROOT}`, `$CLAUDE_EFFORT`, and in `SessionStart`/`CwdChanged` only, `$CLAUDE_ENV_FILE` (append `export FOO=bar` to persist env into the session's Bash).

---

## 5. Exit codes & output contract

| Exit | Effect |
|---|---|
| `0` | Success. stdout parsed as JSON if it's a JSON object; otherwise (on some events) added as context. **For a monitor: exit 0, emit nothing.** |
| `2` | **Blocking error.** stderr is fed back to Claude; the action is blocked/redirected (tool prevented, prompt erased, stop prevented, etc.). **Never use this in a monitor.** |
| other | Non-blocking error; stderr surfaces as a `<hook> hook error` notice, execution continues. |

Optional JSON stdout fields (all events): `{"continue":bool, "stopReason":str, "suppressOutput":bool, "systemMessage":str}`. A monitor wants none of these except possibly `suppressOutput:true` — easiest is to print nothing.

---

## 6. Limits & gotchas

- **Don't block from a monitor.** Stick to `PostToolUse`/`Notification`/`Session*`/`Stop` and always `exit 0`. `exit 2` on `PreToolUse`/`Stop`/`UserPromptSubmit` will actively interfere with the agent.
- **Hooks run in parallel** and can't see each other's output — design each independently; no ordering guarantees. Identical command-string+args hooks are de-duped.
- **Output cap ~10,000 chars** for context-bearing strings (`additionalContext`, `systemMessage`, plain stdout). Irrelevant if you log to a file and stay silent on stdout.
- **Performance:** every `PostToolUse` with `matcher:"*"` runs your script on *every* tool call — heavy for chatty sessions. Keep it `jq`-light, append-only, set a short `timeout` (e.g. 10s), and consider `async:true` if the sink (e.g. an HTTP POST) could be slow. With `async`, you can't return a decision (fine for a monitor).
- **`tool_input`/`tool_response` can be large** (a big file Read/Write, a long Bash output). Decide whether to log full payloads or sizes/hashes. Full payloads can leak secrets — see next point.
- **Secrets / PII:** `tool_input` for `Bash`, `Write`, env dumps, etc. may contain tokens. If logs leave the machine (HTTP sink), redact. Quote all shell vars (`"$path"`) — never interpolate `tool_input` into a shell command unquoted; that's an injection vector.
- **Concurrent writers:** multiple sessions (and parallel subagents) hit the same log file simultaneously. A single `printf`/`jq` line ≤ `PIPE_BUF` (4096 B on macOS) appended with `>>` to an `O_APPEND` fd is atomic; lines longer than that can interleave. For safety with large payloads, write one file per `session_id` (shown below) or use `flock` (not on stock macOS — would need `util-linux`/`brew`, which per your deps rule I'm *not* pulling in).
- **No hot reload** (restart session after editing config).
- **`http` hook type** exists if you'd rather POST events straight to a collector: `{"type":"http","url":"...","headers":{"Authorization":"Bearer $TOK"},"allowedEnvVars":["TOK"]}`. Non-2xx = non-blocking error. Good for a remote monitoring service; the command+file approach below is better for local-first.

---

## 7. Concrete example — a structured JSONL session logger

Drop-in monitor: one append-only **JSON Lines** file per session under `~/.claude/monitor/`. Each line is one event with a timestamp — trivially `jq`-queryable / tailable by your tool. Mirrors your existing hooks' conventions (`set -uo pipefail`, `input=$(cat)`, `jq` parsing).

### Script: `~/.claude/hooks/monitor-log.sh`

```bash
#!/usr/bin/env bash
# Passive session monitor. Reads the hook JSON on stdin, appends one
# enriched JSONL record to a per-session log, and ALWAYS exits 0 without
# emitting stdout — it never blocks or influences the agent.
#
# Per-session file (keyed by session_id) avoids cross-session interleave;
# writes stay append-only.
set -uo pipefail

LOG_DIR="$HOME/.claude/monitor"
mkdir -p "$LOG_DIR"

input=$(cat)

# session_id drives the filename; fall back to "unknown" if absent.
sid=$(jq -r '.session_id // "unknown"' <<<"$input")
# Sanitize: keep only filename-safe chars.
sid_safe=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_.-' '_')
logfile="$LOG_DIR/${sid_safe}.jsonl"

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Build one record: wrap the raw hook payload, add our own ts + host/pid.
# `--argjson raw` re-injects the full payload so nothing is lost; downstream
# can pick fields (.raw.tool_name, .raw.tool_response, .raw.prompt, ...).
jq -cn \
  --arg ts "$ts" \
  --arg host "$(hostname -s 2>/dev/null || echo '?')" \
  --arg pid "$$" \
  --argjson raw "$input" \
  '{
     ts:    $ts,
     host:  $host,
     pid:   ($pid | tonumber),
     event: ($raw.hook_event_name // "unknown"),
     tool:  ($raw.tool_name // null),
     cwd:   ($raw.cwd // null),
     raw:   $raw
   }' >> "$logfile" 2>/dev/null

exit 0
```

`chmod +x ~/.claude/hooks/monitor-log.sh` after creating it.

### Config: add this `hooks` block to `~/.claude/settings.json`

(Place it at top level, alongside `permissions`. The same script handles every event — it self-describes via `hook_event_name`.)

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "bash /Users/me/.claude/hooks/monitor-log.sh", "timeout": 10 } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "bash /Users/me/.claude/hooks/monitor-log.sh", "timeout": 10 } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "bash /Users/me/.claude/hooks/monitor-log.sh", "timeout": 10 } ] }
    ],
    "PostToolUse": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "bash /Users/me/.claude/hooks/monitor-log.sh", "timeout": 10 } ] }
    ],
    "PostToolUseFailure": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "bash /Users/me/.claude/hooks/monitor-log.sh", "timeout": 10 } ] }
    ],
    "Notification": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "bash /Users/me/.claude/hooks/monitor-log.sh", "timeout": 10 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "bash /Users/me/.claude/hooks/monitor-log.sh", "timeout": 10 } ] }
    ],
    "SubagentStop": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "bash /Users/me/.claude/hooks/monitor-log.sh", "timeout": 10 } ] }
    ]
  }
}
```

### Sample output (`~/.claude/monitor/<session_id>.jsonl`)

```json
{"ts":"2026-06-04T07:15:02Z","host":"mac","pid":40231,"event":"UserPromptSubmit","tool":null,"cwd":"/Users/me/.../markdown_viewer","raw":{"hook_event_name":"UserPromptSubmit","session_id":"abc123","prompt":"refactor the sidebar"}}
{"ts":"2026-06-04T07:15:09Z","host":"mac","pid":40231,"event":"PostToolUse","tool":"Edit","cwd":"/Users/me/.../markdown_viewer","raw":{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"/.../DocumentModel.swift"},"tool_response":{"success":true}}}
```

Query examples for the monitoring tool: tool-call frequency `jq -r 'select(.event=="PostToolUse").tool' *.jsonl | sort | uniq -c`; failures `jq 'select(.event=="PostToolUseFailure")' *.jsonl`; turn latency by diffing `UserPromptSubmit`→`Stop` timestamps.

If you'd rather not re-inject full `raw` payloads (size/secrets), drop `--argjson raw $input` and cherry-pick fields (e.g. `tool_input_bytes: ($raw.tool_input|tostring|length)`).

---

## Sources

- [Hooks reference — Claude Code Docs](https://code.claude.com/docs/en/hooks) (canonical event/payload/output table)
- [Automate actions with hooks — Claude Code Docs (guide)](https://code.claude.com/docs/en/hooks-guide)
- [anthropics/claude-code — plugin-dev hook-development SKILL.md](https://github.com/anthropics/claude-code/blob/main/plugins/plugin-dev/skills/hook-development/SKILL.md) (authoring conventions, logging-hook example)
- [Claude Code Hooks: Complete Guide to All 12 Lifecycle Events — claudefa.st](https://claudefa.st/blog/tools/hooks/hooks-guide)
- Local: `/Users/me/.claude/settings.json` (no `hooks` key present), `/Users/me/.claude/hooks/backup-on-write.sh`, `/Users/me/.claude/hooks/block-edit-fullfile-rewrite.sh` (existing PreToolUse patterns, currently unregistered)