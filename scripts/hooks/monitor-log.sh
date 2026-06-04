#!/usr/bin/env bash
# Passive Claude Code session monitor (TSK-112 deliverable).
#
# Reads the hook JSON on stdin, appends ONE enriched JSON-Lines record to a
# per-session log, and ALWAYS exits 0 without emitting stdout — it never blocks
# or influences the agent. Per-session filename (keyed by session_id) avoids
# cross-session interleave; writes are append-only.
#
# In-app reader: ViewerCore/ClaudeMonitorLog.swift parses these records.
#
# ── Opt-in (the owner registers this; it is NOT auto-wired) ──────────────────
# 1. Copy / symlink this script somewhere stable, e.g.:
#       ln -s "$PWD/scripts/hooks/monitor-log.sh" ~/.claude/hooks/monitor-log.sh
# 2. Add a `hooks` block to ~/.claude/settings.json (top level, alongside
#    `permissions`). The same script handles every event — it self-describes
#    via hook_event_name. Minimal high-value set:
#       "hooks": {
#         "SessionStart":       [ { "hooks": [ { "type": "command", "command": "bash ~/.claude/hooks/monitor-log.sh", "timeout": 10 } ] } ],
#         "SessionEnd":         [ { "hooks": [ { "type": "command", "command": "bash ~/.claude/hooks/monitor-log.sh", "timeout": 10 } ] } ],
#         "UserPromptSubmit":   [ { "hooks": [ { "type": "command", "command": "bash ~/.claude/hooks/monitor-log.sh", "timeout": 10 } ] } ],
#         "PostToolUse":        [ { "matcher": "*", "hooks": [ { "type": "command", "command": "bash ~/.claude/hooks/monitor-log.sh", "timeout": 10 } ] } ],
#         "PostToolUseFailure": [ { "matcher": "*", "hooks": [ { "type": "command", "command": "bash ~/.claude/hooks/monitor-log.sh", "timeout": 10 } ] } ],
#         "Notification":       [ { "matcher": "*", "hooks": [ { "type": "command", "command": "bash ~/.claude/hooks/monitor-log.sh", "timeout": 10 } ] } ],
#         "Stop":               [ { "hooks": [ { "type": "command", "command": "bash ~/.claude/hooks/monitor-log.sh", "timeout": 10 } ] } ],
#         "SubagentStop":       [ { "matcher": "*", "hooks": [ { "type": "command", "command": "bash ~/.claude/hooks/monitor-log.sh", "timeout": 10 } ] } ]
#       }
# 3. Start a NEW `claude` session — hooks are read at session start (no hot reload).
#
# Privacy: `raw` re-injects the full hook payload (incl. tool_input/prompt),
# which may contain secrets. The log is LOCAL-ONLY under $LOG_DIR; nothing is
# sent anywhere. If you'd rather not retain full payloads, drop `--argjson raw`
# below and cherry-pick fields.
set -uo pipefail

# Tests override the destination so they never touch the real ~/.claude.
LOG_DIR="${MDV_MONITOR_LOG_DIR:-$HOME/.claude/monitor}"
mkdir -p "$LOG_DIR" 2>/dev/null || exit 0

input=$(cat)

# session_id drives the filename; fall back to "unknown" if absent.
sid=$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null)
[ -z "$sid" ] && sid="unknown"
# Sanitize to filename-safe chars (defends against a hostile/odd session_id).
sid_safe=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_.-' '_')
logfile="$LOG_DIR/${sid_safe}.jsonl"

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Build one record: our envelope (ts/host/pid + a few hoisted fields) wrapping
# the full raw payload. `jq -n` reads no stdin — the payload comes in via
# --argjson from the already-captured variable. A single jq line ≤ PIPE_BUF
# (4096B on macOS) appended with >> is atomic; larger lines can interleave
# across concurrent sessions — the per-session filename keeps each writer alone.
# If $input isn't valid JSON (truncated pipe), --argjson fails: bail without
# writing a malformed line.
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
