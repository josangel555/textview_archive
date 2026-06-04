I have a complete picture. Here is the documentation.

---

# `~/.claude` On-Disk Layout — Agent Monitoring Viewer Reference

> Scanned live on host. Claude Code CLI versions `2.1.104`–`2.1.156`. ~1.0 GB total; the data you care about lives in `~/.claude/projects/` (906 MB, 1349 `.jsonl` transcripts across 30 project dirs).

## TL;DR for the viewer

- **One session = one `<sessionId>.jsonl` file**, append-only, one JSON object per line.
- **Session lives under a per-project dir** named from the cwd: `/Users/me/x` → `-Users-me-x`.
- **Session list**: enumerate `projects/*/*.jsonl` (top level only — skip the sibling `<uuid>/` dirs). Title comes from sidecar `custom-title`/`ai-title` records *inside* the file; timestamps from first/last `timestamp` field.
- **Transcript view**: filter to `type in {user, assistant, system}`; render `message.content` blocks (`text`, `thinking`, `tool_use`, `tool_result`, `image`).
- **Search**: grep the `.jsonl` directly, or use `~/.claude/history.jsonl` as a pre-built prompt index (3023 user prompts with `{display, project, sessionId, timestamp}`).

---

## 1. Top-level `~/.claude/` directory

| Path | Type | Relevance to viewer |
|---|---|---|
| `projects/` | dir | **PRIMARY** — all session transcripts. See §2. |
| `history.jsonl` | 1.1 MB, 3023 lines | **Global user-prompt index** — fast search/recents. See §6. |
| `sessions/` | dir | `<PID>.json` (e.g. `28050.json`) — live-process → session map, ephemeral. Minor. |
| `session-env/` | dir | `<sessionId>/` env snapshots per session. Optional enrichment. |
| `file-history/` | 82 MB | File-backup blobs referenced by `file-history-snapshot` records (diff/restore feature). |
| `tasks/` | 1.9 MB | Task-tool (TaskCreate/Update) state. |
| `plans/`, `jobs/`, `worktrees/` | dirs | Plan-mode, background jobs, worktree state. |
| `shell-snapshots/` | dir | Shell env captured per session. |
| `CLAUDE.md`, `settings.json`, `keybindings.json`, `*.sh` | files | User config. Not transcripts. |
| `.credentials.json`, `.last-update-result.json`, `stats-cache.json`, `mcp-needs-auth-cache.json` | files | **Contains secrets** (OAuth tokens). Viewer must never read/display. |
| `backups/`, `cache/`, `downloads/`, `paste-cache/`, `telemetry/`, `usage-data/`, `skills/`, `plugins/`, `hooks/`, `ide/`, `daemon/`, `debug/` | dirs | Out of scope. |

---

## 2. `projects/` structure

```
projects/
  -Users-me-Documents-workspaces-claude-markdown-viewer/   ← project dir (cwd with / → -)
    80ad52ff-c401-4cd4-9a0a-7558a3ded7c4.jsonl               ← the session transcript (29197 lines, 123 MB)
    80ad52ff-c401-4cd4-9a0a-7558a3ded7c4/                    ← sidecar dir, same UUID stem
      subagents/
        agent-a3dc1da55ef66b6bf.jsonl                        ← subagent (sidechain) transcript
        agent-a3dc1da55ef66b6bf.meta.json                    ← {agentType, description, toolUseId}
      tool-results/
        bf255xppq.txt                                        ← spilled large tool outputs
      workflows/
        wf_76fc7b34-20f.json                                 ← Workflow-tool run state
    memory/                                                  ← per-project auto-memory (MEMORY.md + *.md)
```

### Project-dir naming

`cwd` with every `/` replaced by `-` (leading `/` → leading `-`). `/Users/me/Documents/workspaces/claude/markdown_viewer` → `-Users-me-Documents-workspaces-claude-markdown-viewer`. Note `_` in the path is preserved (not converted). This is **lossy** — you cannot reliably reverse it to the original path (a literal `-` in a dir name is indistinguishable from a `/`). **Always read the real `cwd` from inside the records** (every `user`/`assistant`/`system` record carries an absolute `cwd` field); use the dir name only as a grouping key.

Special cases seen: `-private-tmp` (cwd `/private/tmp`), `-Users-me` (home).

### File naming

- Transcript: `<sessionId-uuid>.jsonl`. Filename stem **usually** equals the `sessionId` inside the records — but **not always**: on resume/fork the file keeps its own UUID while records carry the original `sessionId` (1 of 41 top-level files showed this; filename `d84466a2…` vs record `sessionId 320e598a…`). **Treat filename stem as the canonical session key**; the in-record `sessionId` can be shared across multiple files.
- Sidecar dir: same UUID stem, no extension.
- Subagent files: `subagents/agent-<17hex>.jsonl` + `.meta.json`. These are `isSidechain: true` transcripts and carry an extra `agentId` field. Exclude from the main session list; surface as children of the parent session.

### Counts & sizes (this host)

- 30 project dirs, 1349 `.jsonl` files (top-level transcripts + subagent files).
- Largest single transcript: **123 MB / 29197 lines**. **Stream line-by-line — never `JSON.parse` the whole file.** Build an index (byte offsets per line) for the detail view; lazy-load on scroll.

---

## 3. JSONL record model

Each line is one JSON object discriminated by `type`. Two families:

**A. Conversation records** (carry the full envelope: `uuid`, `parentUuid`, `timestamp`, `sessionId`, `cwd`, `gitBranch`, `version`, `entrypoint`, `userType`, `isSidechain`):

| `type` | What it is |
|---|---|
| `user` | User prompt **or** tool results being fed back to the model |
| `assistant` | Model turn (text / thinking / tool_use blocks) |
| `system` | Lifecycle/meta events, discriminated further by `subtype` |
| `attachment` | Context injected into a turn (deferred-tool deltas, etc.) |

**B. Sidecar/state records** (tiny, `{type, sessionId, ...}`, no envelope — appended to update mutable session metadata; **last-wins**):

| `type` | Fields | Use |
|---|---|---|
| `ai-title` | `aiTitle` | Auto-generated session title |
| `custom-title` | `customTitle` | User-set title (overrides ai-title) |
| `agent-name` | `agentName` | Named agent/session label |
| `last-prompt` | `leafUuid` | UUID of the last user prompt (resume anchor) |
| `permission-mode` | `permissionMode` | Current mode (`auto`/`acceptEdits`/`plan`/`default`) |
| `bridge-session` | `bridgeSessionId`, `lastSequenceNum` | Remote-control / web bridge link |
| `file-history-snapshot` | `messageId`, `snapshot{trackedFileBackups,timestamp}`, `isSnapshotUpdate` | File-backup checkpoint tied to a message |

> For the session list, scan each file for the **last** `custom-title` (fallback `ai-title`, fallback first user prompt text). These are scattered through the file, not just at the head.

### The envelope (shared by user/assistant/system/attachment)

```jsonc
{
  "uuid": "5f0ecbea-…",            // unique record id
  "parentUuid": "fb689f19-…",      // previous record's uuid — linked list / tree
  "isSidechain": false,            // true = inside a subagent transcript
  "sessionId": "320e598a-…",       // logical session (may != filename)
  "timestamp": "2026-05-15T05:21:17.845Z",  // ISO-8601 UTC
  "cwd": "/Users/me/Documents/workspaces/claude/blog",
  "gitBranch": "main",
  "version": "2.1.139",            // CLI version
  "entrypoint": "cli",             // only value seen
  "userType": "external",          // only value seen
  "slug": "staged-drifting-duckling" // optional human-readable session slug (newer records)
}
```

`parentUuid` chains records into a thread. Mostly linear, but **branches**: subagents (`isSidechain:true`), and `compact_boundary` records reset `parentUuid:null` and use `logicalParentUuid` to point across the compaction gap. Build the thread by `parentUuid`, and fall back to file order when a chain breaks.

---

## 4. Concrete records (redacted)

### `user` — text prompt
```json
{
  "parentUuid": "fb689f19-742e-40fe-96ef-eec758f869f1",
  "isSidechain": false,
  "promptId": "57c41cbe-856b-4169-bd50-e223a388e194",
  "type": "user",
  "message": { "role": "user", "content": "can you add couple of things to CLAUDE.md…" },
  "uuid": "5f0ecbea-9a89-4ea2-9249-819dd0b45aed",
  "timestamp": "2026-05-15T05:21:17.845Z",
  "permissionMode": "auto",
  "cwd": "/Users/me/Documents/workspaces/claude/blog",
  "sessionId": "320e598a-d3d6-4ca6-b703-8d251493c137",
  "version": "2.1.139", "gitBranch": "main", "userType": "external", "entrypoint": "cli"
}
```
`message.content` is **either a string** (plain prompt) **or an array of blocks** (when carrying `tool_result`s). Handle both.

### `assistant` — text + usage
```jsonc
{
  "parentUuid": "6bcb78ae-…",
  "message": {
    "model": "claude-opus-4-7",
    "id": "msg_01U27SPJ54g1ADBWsoJFokvf",
    "role": "assistant",
    "content": [ { "type": "text", "text": "Reading the current CLAUDE.md…" } ],
    "stop_reason": "tool_use",
    "usage": {
      "input_tokens": 6, "output_tokens": 169,
      "cache_creation_input_tokens": 10721, "cache_read_input_tokens": 16960,
      "service_tier": "standard", "speed": "standard"
      // + server_tool_use, cache_creation, iterations[]
    }
  },
  "requestId": "req_011Cb3nwuZ6xUDjCjkFYn7Kg",
  "type": "assistant",
  "uuid": "4a2ac3d7-…", "timestamp": "…", "sessionId": "…", "cwd": "…", "version": "…"
}
```
`message.usage` gives per-turn token accounting — useful for a cost/usage column. `requestId` correlates to API logs / `api_error` records.

### `tool_use` block (inside `assistant.message.content[]`)
```json
{ "type": "tool_use", "id": "toolu_01LXcPP…", "name": "Read",
  "input": { "file_path": "/Users/me/.claude/CLAUDE.md" },
  "caller": { "type": "direct" } }
```
`caller.type` is `direct` or (for subagent-issued calls) identifies the agent. `input` is the tool's full argument object.

### `tool_result` — a `user` record whose `content[]` holds the result
```jsonc
{
  "type": "user",
  "message": { "role": "user", "content": [
    { "type": "tool_result", "tool_use_id": "toolu_01LXcPP…",
      "content": "1\t# Bash command style\n2\t…" }   // string OR array of blocks; may carry is_error:true
  ]},
  "toolUseResult": {                                  // ← parsed/structured mirror, varies by tool
    "type": "text",
    "file": { "filePath": "…", "content": "…", "numLines": 16, "startLine": 1, "totalLines": 16 }
  },
  "sourceToolAssistantUUID": "c19b9698-…",            // links back to the assistant turn that called it
  "uuid": "bf0012a2-…", "timestamp": "…", "sessionId": "…"
}
```
Pair `tool_use.id` ↔ `tool_result.tool_use_id` to render call/response side-by-side. `toolUseResult` is a tool-specific structured object (Read→`file`, Bash→stdout/exit, etc.) — convenient for rich rendering; the raw block `content` is the fallback. Very large outputs are spilled to `<sidecar>/tool-results/*.txt`.

### `thinking` block (extended thinking)
```json
{ "type": "thinking", "thinking": "…reasoning text…", "signature": "<REDACTED-signature-blob>" }
```
12121 of these across the corpus. The `signature` is an opaque crypto blob — render `thinking`, drop `signature`.

### `image` block
```json
{ "type": "image", "source": "<REDACTED-base64-or-ref>" }
```
Rare (12 total). `source` can be large base64 — lazy-load / skip in list view.

### `system` records — by `subtype` (counts across corpus)
| subtype | n | shape / use |
|---|---|---|
| `turn_duration` | 3009 | `durationMs`, `messageCount` — per-turn latency for monitoring |
| `scheduled_task_fire` | 593 | `content` — `/loop`/cron wakeups |
| `away_summary` | 860 | `content` — summary written when user is away (great for a feed) |
| `api_error` | 268 | `error{status,error{type,message}…}`, `retryAttempt`, `maxRetries` — **surface as health signal** (529/overloaded etc.) |
| `local_command` | 150 | `content` — `<command-name>/resume</command-name>` slash-command invocations |
| `compact_boundary` | 94 | `compactMetadata{trigger,preTokens,preCompactDiscoveredTools}`, `logicalParentUuid` — context-window compactions |
| `informational` | 30 | `content`, `level` — UI notices |
| `bridge_status` | 58 | `content`, `url` — remote-control link active |

All carry `level` (`info`/`warning`/`error`) where relevant.

> ⚠️ `api_error` records embed **HTTP response headers including `set-cookie` (`_cfuvid=…`)**. Redact `error.headers` before display.

### `attachment`
```jsonc
{ "type": "attachment", "parentUuid": "…",
  "attachment": { "type": "deferred_tools_delta",
    "addedNames": ["WebSearch", "mcp__…"], "removedNames": [], "pendingMcpServers": [] },
  "uuid": "…", "sessionId": "…" }
```
Context-injection events (tool availability deltas, etc.). Usually skippable in the main thread; useful for "what tools were live at turn N".

---

## 5. Subagent transcripts

`<sidecar>/subagents/agent-<hex>.jsonl` — a full mini-transcript (`user`/`assistant`/`attachment`), every record `isSidechain:true` and carrying an extra `agentId`. The `.meta.json` sibling:
```json
{"agentType":"Explore","description":"Summarize crash file","toolUseId":"toolu_01Qvgn4yYe7CbZxarq42AVkW"}
```
`toolUseId` links the subagent to the `Agent`/`Task` tool_use in the **parent** transcript — render them as expandable children under that call.

---

## 6. `history.jsonl` — global prompt index (search shortcut)

3023 lines, one per submitted user prompt, newest appended:
```json
{"display": "explain the workspace", "pastedContents": {}, "timestamp": 1770625601829,
 "project": "/Users/me/Documents/workspaces/scripts/chv_automation2",
 "sessionId": "ddb52a73-310a-49e6-82f4-92faa819e255"}
```
- `display` — the prompt text (truncated with `…` for long ones; slash-commands appear verbatim, e.g. `/rate-limit-options`).
- `timestamp` — **epoch milliseconds** (note: transcripts use ISO-8601 strings — different format).
- `project` — the **real absolute cwd** (un-mangled — useful to reverse-map the lossy project-dir name).
- `sessionId` — links to the transcript.
- `pastedContents` — map of pasted blobs (usually empty).

This is the cheapest backing store for a cross-session prompt search + recents list. For full-text over assistant output/tool results you still need to index the `.jsonl` files.

---

## 7. Enumerated value domains (for filters/columns)

- **models**: `claude-opus-4-7` (43635), `claude-opus-4-8` (5579), `claude-opus-4-6` (4900), `<synthetic>` (79, system-injected turns).
- **permissionMode**: `auto`, `acceptEdits`, `default`, `plan`.
- **entrypoint**: `cli` (only value). **userType**: `external` (only value).
- **versions**: `2.1.104` … `2.1.156`.
- **top tools**: `Bash` (14534), `Edit` (4819), `Read` (3694), `TaskUpdate`, `Write`, `TaskCreate`, `mcp__blender__execute_blender_code`, `Grep`, `Agent`, `ToolSearch`, `ScheduleWakeup`, `WebSearch`, `SendUserFile`, `Monitor`, `WebFetch`, `Workflow`, `AskUserQuestion` …

---

## 8. Implementation notes / gotchas

1. **Stream, don't slurp.** 123 MB / 29K-line files exist. Parse line-by-line; build a per-line byte-offset index for random access in the detail view.
2. **`message.content` is polymorphic** — string OR block-array, for both `user` and `assistant`. Branch on `Array.isArray`.
3. **Two timestamp formats**: ISO-8601 strings in transcripts; epoch-ms in `history.jsonl`.
4. **Session metadata is append-and-last-wins** (`custom-title`, `permission-mode`, etc.) — scan the whole file, keep the last occurrence.
5. **Filename stem is the session key, not the in-record `sessionId`** (they diverge on resume/fork; multiple files can share one `sessionId`).
6. **Project-dir name is lossy** — read `cwd` from records (or `project` from `history.jsonl`) for the true path.
7. **Thread via `parentUuid`**, with `logicalParentUuid` bridging `compact_boundary` gaps and `isSidechain` flagging subagent threads. Fall back to file order on broken chains.
8. **Pair tools** via `tool_use.id` ↔ `tool_result.tool_use_id`; `sourceToolAssistantUUID` links a result back to its assistant turn.
9. **Read-only & redaction**: open files read-only. Never touch `.credentials.json`/`stats-cache.json`. When rendering records, **strip `thinking.signature`, `system.api_error.error.headers` (set-cookie!), and large `image.source` blobs**. Tool inputs/outputs can contain absolute paths and arbitrary file contents — treat as sensitive.
10. **File watching**: transcripts are append-only — `tail`/fs-watch for a live monitoring view; new sessions appear as new files under `projects/*/`.

Reference files inspected: `/Users/me/.claude/projects/-private-tmp/d84466a2-23df-43fd-a1b3-3f60e961c768.jsonl` (all record types), `/Users/me/.claude/projects/-private-tmp/408fe5f5-…/subagents/` (subagent shape), `/Users/me/.claude/history.jsonl` (prompt index).