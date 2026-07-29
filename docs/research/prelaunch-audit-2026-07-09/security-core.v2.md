# Pre-Launch Security Review — Core Surfaces (v2)

**Dimension:** Security (input validation, WebView CSP/JS bridges, file-URL fencing,
path traversal, symlink handling, quarantine, secret handling, MCP/socket auth)
**Repo:** `/Users/me/Documents/workspaces/claude/markdown_viewer`
**Date:** 2026-07-09
**Reviewer:** automated pre-launch audit (static analysis, read-only)

> Note: a `security-core.md` already existed at this path (concurrent run); this v2 is
> written as a sibling to avoid clobbering it. The two should be reconciled.

---

## Executive summary

The codebase is, on the whole, **security-mature for a v1 native app**: there is a
real, documented threat model behind the WebView layer (layered CSP + navigation-policy
delegate + allowlist sanitizer), a well-fenced MCP path-jail with physical symlink
resolution, an LSP spawn path with both an allowlist *and* a code-injection env denylist,
consistent `git … -- <path>` argument-injection discipline, shell-free `run_task` spawns,
and a Rust FFI panic boundary (`catch_unwind` + `panic=unwind` shipping profile). Many
of the classic footguns for this class of app are already closed and regression-tested.

The **single most important finding** is architectural, not a coding bug: the running GUI
app **unconditionally opens an unauthenticated MCP control socket** (`mcp.sock`) on every
launch (`main.swift:225`). Its only access boundary is unix `0600` / same-user. Through it,
*any* process running as the same user can drive the live editor with **no token, no consent
prompt, and no opt-in** — including `run_task` (executes repo-defined commands),
`move_file`/`rename_symbol` (writes files), `snapshot_window` (exfiltrates the app's window
content), and `search_files`/`visible_text` (reads user content). The app is **not
sandboxed**. On macOS the same-user boundary is weaker than it looks (a compromised npm
dev-dependency, a downloaded helper, any unsandboxed same-user malware), and this socket
hands such code a turnkey automation + command-execution channel. This is filed **P1** —
it is an intentional feature (TSK-1544) whose trust model deserves an explicit owner
decision before public launch.

Everything else found is P2/P3 (a secret-inheritance inconsistency in `run_task`, the
`<meta>`-based CSP's known enforcement gap, one missing JS-embedding sanitize on the Canvas
bridge, and an archive-extraction memory ceiling). No P0 was found in the surfaces examined.

---

## Methodology

Static read of the security-relevant surfaces (no UI tests, no window-opening runs):

- **MCP / socket surface** — `MCPSocketListener`, `MCPServer`, `MCPFraming`,
  `MCPToolCatalog` (all 38 tools), `MCPSocketBridge`, startup wiring in `main.swift`.
- **WebView CSP / JS bridges** — `HTMLDocumentPolicy`, `HTMLRenderer`, `HTMLSanitizer`,
  `HtmlExport`, `BrowserNavigationPolicy`, `MarkdownRenderedView` (nav delegate),
  `CodeMirrorEditorView` + `CodeMirrorBridge`, `CanvasWebViewHost` + `CanvasBridge`,
  `JSStringEmbedding`, the two `WKScriptMessageHandler` registrations (`mdvEditor`,
  `mdvCanvas`), and every `evaluateJavaScript` call site.
- **File-URL fencing / path traversal / symlink** — `MCPToolCatalog.validatedExistingURL`,
  `loadFileURL(allowingReadAccessTo:)` sites, `LSPLanguageRegistry.isOverrideCommandTrusted`
  / `isPath(inSubtreeOf:)`, `PluginSubprocessHost` containment, `ArchiveCatalog`.
- **Process-spawn surfaces** — `LSPClient`/`LSPDiscovery`, `PluginSubprocessHost`,
  `GitClient`, `ArchiveCatalog`, `ProcessRunner`, `TaskRunnerViewModel`, `run_task`.
- **Secret / env handling** — `LSPWorkspaceOverrides.dangerousEnvNames` +
  `scrubbedLaunchEnvironment`, `run_task` env construction.
- **Quarantine** — `HTMLTrustPolicy`.
- **Rust FFI / daemon** — `ffi/src/guard.rs` panic boundary, `Cargo.toml` profiles,
  `serve` bind path.

Not exercised: the Rust engine parsers' fuzz/proptest lanes (they exist per `CLAUDE.md`
but were not run here), terminal/PTY, feed-fetch networking, image editing, `pm` SQLite —
see Coverage gaps.

---

## Findings

### P1 — Always-on, unauthenticated in-app MCP control socket

- **Severity:** P1
- **File:** `Sources/MarkdownViewer/main.swift:225` (start site);
  `Sources/ViewerCore/Automation/MCPSocketListener.swift:69-110` (bind);
  `Sources/ViewerCore/Automation/MCPToolCatalog.swift` (tool surface)
- **Evidence:** `startMCPSocketListener()` is called **unconditionally** in the app's
  launch path (no env gate, no preference, no CLI flag). `MCPSocketListener.start()` binds
  `~/Library/Application Support/MarkdownViewer/mcp.sock`, `chmod 0600`, and serves the
  full `MCPToolCatalog` per connection. The listener's own doc comment states the design:
  *"Security model: same-user only … there is no TCP, no remote surface, **no auth token in
  v1**"* (`MCPSocketListener.swift:13-16`). The app ships **unsandboxed** (no
  `*.entitlements` with `com.apple.security.app-sandbox` in the source tree). The served
  catalog includes high-impact verbs: `run_task` (command execution — see next finding),
  `move_file` / `rename_symbol` (filesystem writes to open tabs), `snapshot_window`
  (returns a PNG of the app window's content), `open_path`, `search_files`, `visible_text`,
  `git_status`, `run_verb` (~60 script verbs).
- **Impact:** The `0600` socket blocks *cross-user* access but not *same-user* access. On
  an unsandboxed macOS app, any same-user process — a malicious postinstall script, a
  compromised dev dependency in a terminal, a downloaded "helper" — can connect and drive
  the running editor with no user interaction or consent. Concretely it gains: arbitrary
  command execution (via `run_task` on a planted manifest, next finding), silent file
  writes, and a screen-content read of whatever document the user has open (`snapshot_window`,
  which uses in-process `cacheDisplay` and therefore needs **no** Screen-Recording TCC grant
  — it is a TCC-independent capture of the app's own window). There is no rate limit, no
  audit surface the user sees, and the endpoint is up for the entire app lifetime.
- **Suggested fix:** Gate the listener behind an explicit opt-in (a preference toggle
  and/or an env flag like the stdio server has), OFF by default. When enabled, require a
  per-launch capability token: write a random token to a `0600` file readable only by the
  user's trusted MCP client config and require it in the MCP `initialize` handshake, so a
  blind same-user connector cannot drive the app. At minimum, put the high-impact verbs
  (`run_task`, `move_file`, `snapshot_window`) behind a separate consent tier.
- **Fix size:** M
- **Fix risk:** careful (changes the agent-integration UX; coordinate with the
  `--mcp-connect` bridge)

---

### P2 — `run_task` executes repo-defined commands and inherits the app's full (unscrubbed) environment

- **Severity:** P2
- **File:** `Sources/ViewerCore/Automation/MCPToolCatalog.swift:453-491`
- **Evidence:** `run_task` resolves an id against `RunnableTaskDiscovery.discover(...)` and
  spawns it shell-free via `/usr/bin/env` + tokenized argv (good). But "the allowlist is
  discovery itself" (per the descriptor at `:297`) is a **weak** trust boundary: discovered
  tasks include `package.json` scripts and `Makefile` targets, which are **arbitrary
  commands defined by whatever directory is named in the `path` arg** — any dir under
  `$HOME`. So the effective policy is "run any command an attacker can write into a manifest
  somewhere under the user's home." Combined with the authless socket (previous finding), a
  same-user attacker plants a `package.json` with a hostile `scripts.test`, connects, calls
  `list_runnable_tasks` then `run_task` → code execution. Separately, the child environment
  is built as `ProcessInfo.processInfo.environment.merging(spec.environment)`
  (`MCPToolCatalog.swift:476-478`) — the spawned task inherits the app's **entire**
  environment, including any `*_TOKEN` / `*_SECRET` / cloud creds the app was launched with.
  This is inconsistent with the LSP path (`LSPLanguage.swift:522` `scrubbedLaunchEnvironment`)
  and the plugin path (`PluginSubprocessHost.scrubbedEnvironment`), both of which scrub
  credential-shaped vars before spawning a child.
- **Impact:** A discovered task exfiltrates the app's secrets to the child, and (via the
  socket) becomes an arbitrary-code-execution primitive rather than a curated action.
- **Suggested fix:** Reuse the LSP `scrubbedLaunchEnvironment` allowlist for `run_task`
  children so app secrets don't flow into task processes. Gate `run_task` behind the socket
  consent tier (previous finding). Consider requiring the task's project root to be an
  *open workspace* rather than any path under `$HOME`.
- **Fix size:** S (env scrub) / M (consent tier)
- **Fix risk:** safe (env scrub); careful (consent tier)

---

### P2 — Rendered-HTML XSS defense leans on `<meta>`-injected CSP with a self-documented enforcement gap

- **Severity:** P2
- **File:** `Sources/ViewerCore/HTMLSanitizer.swift:35-41`;
  `Sources/ViewerCore/HTMLDocumentPolicy.swift:112-145`;
  `Sources/ViewerCore/HTMLRenderer.swift:79-91`
- **Evidence:** `HTMLSanitizer` is a hand-rolled regex/tokenizer pass that itself states it
  is **"NOT a security boundary against rich HTML attack patterns … a sufficiently clever
  payload could survive the regex pass"** and is *"defense-in-depth atop the CSP, not a
  replacement for it."* The actual security fence is therefore the `default-src 'none'` CSP —
  delivered as an injected `<meta http-equiv="Content-Security-Policy">` tag. The sanitizer's
  own header notes the known weakness of `<meta>` CSP: *"`<meta http-equiv>` CSP enforcement
  differs subtly from header-CSP across WebKit versions, and `<script>` payloads embedded in
  HTML blocks parse *before* the CSP can take effect in some race windows"*
  (`HTMLSanitizer.swift:10-14`). So the primary boundary is delivered by the mechanism the
  code documents as the weaker of the two. The sanitizer is genuinely good (quote-aware
  tokenizer, entity-decoded scheme checks, event-handler stripping) and the CSP directives
  are tight, but a single missed construct + a `<meta>`-CSP race is the residual XSS path.
- **Impact:** Authored/opened markdown or raw-HTML with a crafted payload could, in a WebKit
  version where the `<meta>` CSP applies late, execute script in the rendered pane. Bounded
  by the nav-policy delegate (blocks off-origin nav / `file:` escape) and `connect-src 'none'`
  (no exfil), so the practical blast radius is UI-confusion / local-content read rather than
  remote exfil — but it is script execution the design intends to prevent.
- **Suggested fix:** Deliver the CSP as a real HTTP header via a `WKURLSchemeHandler`
  (serve rendered content over a custom app scheme) or a `WKContentRuleList`, so enforcement
  is header-grade and not subject to the `<meta>` parse race. Keep the sanitizer as
  defense-in-depth.
- **Fix size:** L (custom scheme handler is a real re-plumb of the render load path)
- **Fix risk:** careful (touches the core render pipeline; VM-validate)

---

### P3 — Canvas JS bridge omits the `U+2028`/`U+2029` embedding sanitize the CM6 bridge applies

- **Severity:** P3
- **File:** `Sources/ViewerCore/Canvas/CanvasBridge.swift:195-197`
  (`CVBridgeCodec.encode` returns raw `JSONSerialization` output);
  `Sources/ViewerUI/CanvasWebViewHost.swift:83` (`window.cvDispatch(\(json))`)
- **Evidence:** The CM6 outbound path routes JSON through
  `JSStringEmbedding.sanitize` (`CodeMirrorBridge.swift:737`) precisely because
  `JSONSerialization` does **not** escape `U+2028`/`U+2029`, which are JS source line
  terminators. The Canvas codec (`CVBridgeCodec.encode`) returns the bare
  `JSONSerialization` string and `CanvasWebViewHost.send` interpolates it directly into
  `window.cvDispatch(\(json))` with **no** `JSStringEmbedding.sanitize`. Canvas content
  (`setContent(html)`, text nodes) can carry those code points (agent-authored `.canvas`
  docs, pasted content).
- **Impact:** Not an injection escalation (`JSONSerialization` still escapes quotes,
  backslashes, and `<`; the two line-separators can only *break* the statement, yielding a
  JS `SyntaxError` and a dropped dispatch, not attacker code execution). Effect is a
  robustness bug — a canvas op silently no-ops on content containing those runes. Filed here
  because it is the exact hazard `JSStringEmbedding` exists to close and the fix is trivial.
- **Suggested fix:** Wrap the `CVBridgeCodec.encode` result (or the interpolation in
  `send`) in `JSStringEmbedding.sanitize`, matching the CM6 path.
- **Fix size:** S
- **Fix risk:** safe

---

### P3 — `ArchiveCatalog` extraction drains member stdout to EOF without a hard in-memory ceiling at the read loop

- **Severity:** P3
- **File:** `Sources/ViewerCore/Archive/ArchiveCatalog.swift:109-131,196-225`
- **Evidence:** Argument construction is correctly hardened (`--` before archive paths and
  member names, fixed `/usr/bin/unzip` + `/usr/bin/tar`, wall-clock `toolTimeout`). Member
  extraction reads `stdout.fileHandleForReading.readDataToEndOfFile()` on a background thread;
  a per-entry `entryTooLarge` cap exists but the streaming read itself drains to EOF, so a
  crafted archive whose single member decompresses to many GB relies on that cap firing
  *before* the full `readDataToEndOfFile` materializes. The timeout bounds wall-clock, not
  memory.
- **Impact:** A crafted archive (zip bomb / oversized tar member) opened in the archive
  browser could spike memory during extraction. Requires the user to open a hostile archive;
  bounded by the timeout. Low likelihood, low blast radius.
- **Suggested fix:** Cap the `readData` loop itself (chunked read that aborts past the byte
  cap), not just a post-hoc size check.
- **Fix size:** S
- **Fix risk:** safe

---

## Positive observations

These are genuinely well-built and worth preserving:

- **MCP path-jail with physical symlink resolution** — `validatedExistingURL`
  (`MCPToolCatalog.swift:1153-1187`) resolves symlinks on *both* the candidate and the home/
  temp anchors before an anchored-prefix containment check (`home + "/"`, `temp + "/"` — not
  a bare `hasPrefix` that would admit `/var/folders/.../T-attacker/...`), and checks
  containment *before* existence to avoid an existence oracle.
- **LSP spawn hardening** — dual-layer: `isOverrideCommandTrusted` refuses a `command`
  inside the workspace subtree or in a group/world-writable dir
  (`LSPLanguage.swift:450-463`); `dangerousEnvNames` denylist strips `NODE_OPTIONS` /
  `DYLD_*` / `LD_*` / `PYTHONSTARTUP` / `RUBYOPT` / `JAVA_TOOL_OPTIONS` from repo-supplied
  env (`LSPWorkspaceOverrides.swift:248-278`); `scrubbedLaunchEnvironment` is an
  **allowlist** with the injection denylist as a hard floor over the allowlist
  (`LSPLanguage.swift:522-547`).
- **Git argument-injection discipline** — every path-bearing `git` invocation uses a
  `-- <path>` terminator, and ref/branch/path args are guarded against leading `-`
  (`GitClient.swift:681,728,739,742,763,789,908,1249`). Hooks/pager/editor neutralized.
- **Browser-tab loopback fence** — `BrowserNavigationPolicy` is a pure, testable allowlist:
  top-level nav restricted to loopback HTTP(S)/WS(S), segment-aware `127.0.0.0/8` matcher
  that rejects `127.0.0.1.evil.com`, `file:` always cancelled.
- **Rendered-markdown nav delegate** — cancels `javascript:`/`vbscript:` for *any* nav
  type, blocks post-load `.other` navigations to `file:`/`data:` (in-page script-escape
  guard, WV-4), routes only `http(s)`/`mailto` link clicks externally
  (`MarkdownRenderedView.swift:1064-1128`).
- **Rust FFI panic boundary** — every FFI entry point wraps `catch_unwind`
  (`ffi/src/guard.rs`), and the **shipping** dylib links the `dist` profile
  (`panic = "unwind"`), with `build-rust-core.sh` actively refusing to link the
  `panic=abort` `release` profile.
- **`mdv-serve` daemon binds only a filesystem unix socket** (or a launchd fd) — no TCP.
- **MCP framing has a 16 MiB body cap** (`MCPFraming.swift:35`) — no unbounded-alloc DoS.
- **Quarantine-aware HTML trust** — `HTMLTrustPolicy` only lets a *local, non-quarantined,
  user-opted-in* document keep its own scripts, and even then keeps `connect-src 'none'`.
- **HTMLSanitizer scheme check decodes entities + strips control chars** before comparing
  the scheme, catching `&#x6a;avascript:`, `jav\tascript:`, `&Tab;javascript:`.

---

## Coverage gaps (not examined in depth)

- **Rust engine parsers** (`core`: markdown, csv, json, hex, formula, diff, nav, canvas DSL)
  — widest input-validation surface; proptest (TSK-585) + cargo-fuzz (TSK-584) lanes exist
  but were not run here. A fuzz pass on the canvas DSL and formula engine is the
  highest-value follow-up.
- **`PluginURLTemplate` / `PluginGrantStore`** — plugin URL-template expansion + grant model
  (SSRF / template-injection) not read in detail.
- **Terminal / PTY** (`TerminalModel`, `PTYProcess`, `TmuxCommand`) — only glanced at.
- **Feed reader networking** (`FeedRefreshScheduler`, `FeedReaderView`) — SSRF / XML-parse
  surface not audited.
- **`pm` SQLite store** (`rusqlite`) — query construction not reviewed.
- **Image editing** (`ImageDocument`, `VectorOverlay`) — image-decode surface not reviewed.
- **AX driver** — owner-off-limits tier per project policy; not exercised.
- **Deep dynamic verification** — static analysis only; no PoC exploit was built for the
  P1 socket finding.
