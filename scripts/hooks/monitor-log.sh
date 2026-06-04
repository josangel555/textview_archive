#!/usr/bin/env bash
# Passive Claude Code session monitor (TSK-112 deliverable).
#
# Reads the hook JSON on stdin, appends ONE compact JSON-Lines record to a
# per-session log, and ALWAYS exits 0 without emitting stdout — it never blocks
# or influences the agent. In-app reader: ViewerCore/ClaudeMonitorLog.swift.
#
# ── Design notes (hardened after review) ─────────────────────────────────────
# • PRIVACY: we do NOT persist the full hook payload. tool_input/tool_response
#   (file contents, code, command output) and the full prompt can carry secrets;
#   storing them indefinitely in a grep-able local log is a leak. Instead we log
#   a bounded envelope: event/tool/cwd/timing, a 200-char prompt PREVIEW, and the
#   *sizes* of tool_input/tool_response — enough to monitor, not enough to leak.
# • ATOMICITY: POSIX only guarantees atomic O_APPEND for writes ≤ PIPE_BUF
#   (512 B on macOS). Concurrent hooks (parallel subagents sharing a session id)
#   could interleave a larger line and corrupt JSONL. We (a) keep lines small via
#   the bounded envelope and (b) serialize writers with an atomic mkdir lock
#   (no flock dependency on stock macOS), trap-released so a crash frees it.
# • OBSERVABILITY: a malformed/truncated payload (jq fails) is recorded to
#   <logfile>.errors (base64) instead of being silently dropped.
#
# ── Opt-in (the owner registers this; it is NOT auto-wired) ──────────────────
# 1. ln -s "$PWD/scripts/hooks/monitor-log.sh" ~/.claude/hooks/monitor-log.sh
# 2. Add a `hooks` block to ~/.claude/settings.json (top level, alongside
#    `permissions`); the same script handles every event. High-value set:
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
set -uo pipefail

# Tests override the destination so they never touch the real ~/.claude.
LOG_DIR="${MDV_MONITOR_LOG_DIR:-$HOME/.claude/monitor}"
mkdir -p "$LOG_DIR" 2>/dev/null || exit 0

input=$(cat)

sid=$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null)
[ -z "$sid" ] && sid="unknown"
# Sanitize to filename-safe chars (also blocks path traversal via session_id).
sid_safe=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_.-' '_')
logfile="$LOG_DIR/${sid_safe}.jsonl"

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
host=$(hostname -s 2>/dev/null || echo '?')

# Compact, bounded, privacy-conscious envelope — flat (no nested raw payload).
record=$(jq -cn \
  --arg ts "$ts" --arg host "$host" --arg pid "$$" \
  --argjson raw "$input" \
  '{
     ts:    $ts,
     host:  $host,
     pid:   ($pid | tonumber),
     event: ($raw.hook_event_name // "unknown"),
     session_id: ($raw.session_id // null),
     tool:  ($raw.tool_name // null),
     cwd:   ($raw.cwd // null),
     prompt: (($raw.prompt // null) | if . == null then null else (tostring | .[0:200]) end),
     prompt_len: (($raw.prompt // "") | tostring | length),
     error: (($raw.error // null) | if . == null then null else (tostring | .[0:500]) end),
     reason: ($raw.reason // null),
     source: ($raw.source // null),
     notification_type: ($raw.notification_type // null),
     tool_input_bytes: (if ($raw.tool_input // null) == null then null else ($raw.tool_input | tostring | length) end),
     tool_succeeded: ($raw.tool_response.success // null)
   }' 2>/dev/null)

# jq failed (malformed/truncated payload): record it instead of dropping silently.
if [ -z "$record" ]; then
  printf '%s' "$input" | base64 >> "$logfile.errors" 2>/dev/null
  exit 0
fi

# Serialize concurrent writers with an atomic mkdir lock (no flock on stock
# macOS). Bounded ~1s spin; trap-released so a crash frees the lock. If the lock
# can't be acquired (heavy contention / stale after SIGKILL), fall through to a
# best-effort append — the record is small, so the append is very likely atomic.
lock="$logfile.lock"
for _ in $(seq 1 100); do
  if mkdir "$lock" 2>/dev/null; then
    trap 'rmdir "$lock" 2>/dev/null' EXIT
    break
  fi
  sleep 0.01
done
printf '%s\n' "$record" >> "$logfile" 2>/dev/null
exit 0
