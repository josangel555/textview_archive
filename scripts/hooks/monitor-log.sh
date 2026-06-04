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
#   a bounded envelope: event/tool/cwd/timing, a 200-char prompt PREVIEW, a
#   500-char error preview, and the *sizes* of tool_input/tool_response —
#   enough to monitor, not enough to leak.
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

# Cap the payload before doing anything with it. A truncated/pathological/huge
# payload must not be able to grow the logs without bound (a local DoS via the
# .errors base64 path). 256 KB is far above any real hook envelope.
if [ "${#input}" -gt 262144 ]; then
  printf '%s oversized=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${#input}" \
    >> "$LOG_DIR/oversized.log" 2>/dev/null
  exit 0
fi

sid=$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null)
[ -z "$sid" ] && sid="unknown"
# Sanitize to filename-safe chars (blocks path traversal via session_id) and cap
# the length — an over-long session_id would push the filename past the 255-byte
# limit, making mkdir/append fail silently and drop the whole session's records.
sid_safe=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-128)
[ -z "$sid_safe" ] && sid_safe="unknown"
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
# macOS). Bounded ~1s spin; the trap fires on INT/TERM too (a hook runs under a
# `timeout`, which sends SIGTERM) so an interrupted run still frees the lock. A
# SIGKILL can't be trapped and would orphan the lock, so on spin-exhaustion we
# steal the presumed-stale lock ONCE and retry. We only ever append while
# holding the lock — if we can't get it, we DROP this record (a passive monitor
# missing one event is cheaper than a torn JSONL line). (Residual: two writers
# both stealing the same stale lock in the same microsecond can both proceed —
# rare and doubly-conditional; acceptable for an opt-in local monitor.)
lock="$logfile.lock"
acquired=
for _ in $(seq 1 100); do
  if mkdir "$lock" 2>/dev/null; then
    acquired=1; trap 'rmdir "$lock" 2>/dev/null' EXIT INT TERM; break
  fi
  sleep 0.01
done
if [ -z "$acquired" ] && rmdir "$lock" 2>/dev/null && mkdir "$lock" 2>/dev/null; then
  acquired=1; trap 'rmdir "$lock" 2>/dev/null' EXIT INT TERM
fi
[ -z "$acquired" ] && exit 0
printf '%s\n' "$record" >> "$logfile" 2>/dev/null
exit 0
