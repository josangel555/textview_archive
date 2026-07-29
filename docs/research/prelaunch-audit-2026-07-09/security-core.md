# Pre-launch Security Review — Core / IO / Bridges

**Dimension:** Security (input validation on untrusted-bytes parsers, WebView CSP/JS
bridges, file-URL fencing, path traversal, symlink handling, quarantine handling,
secret handling, MCP/socket surface auth).
**Date:** 2026-07-09 · **Scope:** `Sources/ViewerCore`, `Sources/ViewerUI` (render/bridge
files), `rust-core/crates/serve`, `rust-core/crates/web`, `Sources/MarkdownViewer` shell.
**Method:** static read of the security-relevant surfaces (no code modified, no
window-opening tests run).

---

## Executive summary

The security posture of this codebase is **well above the bar for a pre-launch v1**.
The WebView fencing, custom-URL-scheme containment, and MCP tool-path jail are
layered, explicitly threat-modeled in the source, fail-closed, and backed by
host-testable pure-function kernels. The Rust `serve`/`web` daemons canonicalize +
contain every path, cap frame sizes (16 MiB), cap output/listings, and shell out to
`git` via argv (never a shell). I found **no P0/P1 issues** in this dimension — no
data-loss, crash-on-untrusted-input, or broken-core-flow security defect.

What remains is a handful of **defense-in-depth / hardening gaps**, all P2–P3:

- `fs.read` on the serve daemon loads the **entire file into memory** before applying
  the 4 MiB window — a memory-amplification vector (root-fenced, same-user).
- The `mdv-serve` **self-bind** code path does not `chmod 0600` the unix socket (only
  the production launchd plist does). Dev/CLI/Linux runs leave a world-connectable
  socket that bypasses the "ssh tunnel is the auth boundary" model.
- Rendered-markdown enables JS with the CSP delivered only via a `<meta http-equiv>`
  tag (the sanitizer's own docstring flags meta-CSP as race-prone), with no
  `WKContentRuleList` backstop.
- Two low-severity information-shape leaks (git worktree `gitdir:` not root-contained;
  `mdv-web` treats an empty `Host` header as allowed).

Positive observations are extensive (see below) — this is clearly a codebase where
security review has already happened repeatedly and left durable, tested artifacts.

---

## Methodology (what I examined)

Read in full or in the relevant part:

- **WebView layer:** `HTMLDocumentPolicy.swift`, `HTMLTrustPolicy.swift`,
  `BrowserNavigationPolicy.swift`, `HTMLSanitizer.swift`, `HTMLRenderer.swift`
  (CSP), `MarkdownRenderedView.swift` (JS-enable + find injection),
  `HTMLRenderedView.swift`, `CodeMirrorEditorView.swift` (bootstrap `loadFileURL`
  read-access scope + message handler), `CodeMirrorBridge.swift` (JSON→JS escaping).
- **File-URL / path fencing:** `Security/URLSchemePolicy.swift`,
  `Automation/MCPToolCatalog.swift` (`validatedExistingURL` jail), the
  `isWithinDocumentTree` sub-resource fence.
- **MCP/socket surface:** `Automation/MCPSocketListener.swift`,
  `Automation/MCPSocketBridge.swift`.
- **Rust daemons:** `serve/src/{main,serve,fs,git,transport,transcript_list,watch,
  lifecycle}.rs`, `web/src/main.rs`, frame limits in `core/src/wire.rs` +
  `serve/src/lib.rs`, `scripts/com.markdownviewer.mdv-serve.plist.template`.
- **Secret handling:** `HistoryContentFilter.swift`, grep for secret logging across
  ViewerCore/Git/LSP.

Not a dynamic test; no fuzzing run (the repo already carries proptest/cargo-fuzz
lanes for the core parsers). Grammar/markdown/CSV/hex parser internals were sampled,
not exhaustively audited — see Coverage gaps.

---

## Findings

### F1 — `fs.read` loads the whole file into memory before windowing (memory amplification)
- **Severity:** P2
- **File:** `rust-core/crates/serve/src/fs.rs:155` (`std::fs::read(&p)`), window logic
  `:148-159`; ceiling constant `MAX_READ_WINDOW` `:18`.
- **Evidence:** The request carries `{path, offset, len}`; `len` is checked against
  `MAX_READ_WINDOW` (4 MiB) at `:149`, but the read itself is
  `let data = std::fs::read(&p)…` — the **entire file** is slurped, then sliced to the
  window at `:157-159`. The 4 MiB cap bounds the *returned* window, not the *read*.
- **Impact:** A request for `offset:0, len:1` against a 5 GB file inside the served
  root allocates ~5 GB in the daemon. Repeated across the 8-connection cap this is a
  cheap RAM-exhaustion / OOM-kill vector. Fenced to same-user + `--root`, so not a
  remote or cross-user primitive, but it defeats the point of a "windowed-only, no
  whole-file convenience by design" API (the module docstring at `:4-6` explicitly
  claims windowed-only).
- **Suggested fix:** Seek + bounded read — `File::open` → `seek(SeekFrom::Start(offset))`
  → `take(want).read_to_end` — and obtain `total` from `metadata().len()` rather than
  the buffer length. Keeps the `{total, data}` response shape.
- **Fix size:** S · **Fix risk:** safe

### F2 — `mdv-serve` self-bind path does not `chmod 0600` the socket (auth-boundary divergence)
- **Severity:** P2
- **File:** `rust-core/crates/serve/src/main.rs:59-70` (self-bind closure calls
  `UnixListener::bind(&socket_path)` with no permission set); contrast the Swift
  sibling `Sources/ViewerCore/Automation/MCPSocketListener.swift:96`
  (`chmod(path, 0o600)`), and the production plist
  `scripts/com.markdownviewer.mdv-serve.plist.template:28-29`
  (`SockPathMode 384` = `0600`).
- **Evidence:** Two code paths bind the daemon socket. Under launchd activation the
  socket is launchd-owned at `0600` (plist) — protected. The **fallback self-bind**
  (`select_listener` when activation yields nothing: dev runs, `mdv-serve --socket …`
  invoked directly, Linux) binds with the process umask and never restricts the mode,
  so the socket node is typically group/other-connectable.
- **Impact:** The stated threat model is "the ssh tunnel is the auth/confidentiality
  boundary" (`main.rs:1-6`). But the socket is a **filesystem path** — a second local
  user (or any process on a multi-user host) can `connect()` directly, bypassing ssh
  entirely, and then drive `fs.read`/`fs.readdir`/`git.*`/`transcript.list` for
  everything under `--root` plus `~/.claude/projects` transcripts (which routinely
  contain sensitive content). The Swift MCP listener got this right; the Rust daemon's
  non-launchd path did not. Defense-in-depth: even under ssh-only deployment, the
  socket should be owner-only.
- **Suggested fix:** After a self-bind, `std::fs::set_permissions(&socket_path,
  Permissions::from_mode(0o600))` (unix-gated), mirroring the Swift listener. Optionally
  assert `SO_PEERCRED`/`LOCAL_PEERCRED` same-uid on accept for a hard check.
- **Fix size:** S · **Fix risk:** safe

### F3 — Rendered-markdown runs with JS enabled behind a `<meta>`-only CSP (no rule-list backstop)
- **Severity:** P2
- **File:** `Sources/ViewerUI/MarkdownRenderedView.swift:222`
  (`prefs.allowsContentJavaScript = true`); CSP delivery
  `Sources/ViewerCore/HTMLRenderer.swift:79,91` (`<meta http-equiv="Content-Security-
  Policy" …>`); the sanitizer's own caveat
  `Sources/ViewerCore/HTMLSanitizer.swift:10-14, 35-41`.
- **Evidence:** The rendered-markdown WebView enables the JS engine (so the API-injected
  find/mermaid runtime can run) and relies on `script-src 'none'` to block the
  *document's* scripts. That CSP is injected as a `<meta http-equiv>` tag, and the
  document's raw-HTML `<script>` tags are stripped by the hand-rolled, non-DOM
  `HTMLSanitizer`. The sanitizer docstring itself warns: "`<meta http-equiv>` CSP
  enforcement differs subtly from header-CSP across WebKit versions, and `<script>`
  payloads embedded in HTML blocks parse *before* the CSP can take effect in some race
  windows," and declares itself "NOT a security boundary against rich HTML attack
  patterns."
- **Impact:** With JS on, the sole robust script barrier for hostile markdown is the
  regex-family sanitizer + a meta-CSP. If a payload survives the non-DOM sanitizer
  (the residual it explicitly accepts) the meta-CSP is the only backstop, and it is the
  weaker of the two CSP delivery mechanisms. This is a *layered* defense that is
  honestly documented, not an open hole — hence P2 not P1 — but it is the most
  attackable seam in the render stack for a shipping product.
- **Suggested fix:** Add a compiled `WKContentRuleList` that blocks `script` resource
  loads on the render WebView as a WebKit-enforced backstop independent of the
  in-document meta tag (rule lists are enforced pre-parse, closing the race the
  docstring names). Keep the meta-CSP and sanitizer as-is. Longer term, a real
  DOM-based sanitizer (or the WebUI parse path) would retire the "clever payload
  survives the regex" residual.
- **Fix size:** M · **Fix risk:** careful (rule-list compilation is async; must not
  block first paint — VM-validate the render path)

### F4 — git worktree `gitdir:` target is not root-contained (out-of-root HEAD probe)
- **Severity:** P3
- **File:** `rust-core/crates/serve/src/git.rs:84-95` (`git_dir`), used by `git.head`
  `:47-79`.
- **Evidence:** The repo path itself is `fs_ctx.contained(&req.repo)` (`:58`), but when
  `.git` is a **file** (worktree/submodule form) its `gitdir: <path>` target is taken
  verbatim (`:91-92`) and `HEAD` is read from it (`:70`) with no re-containment.
- **Impact:** An attacker who can place a file inside the served root (or a repo whose
  `.git` file they authored) can point `gitdir:` at an arbitrary absolute path; the
  daemon then reads `<that-path>/HEAD`. Disclosure is narrow — the response only
  reveals whether that `HEAD` exists and whether it parses as a ref-name or a 40-hex
  sha (`:72-78`); no arbitrary content leaves. Still, it is an out-of-root read the
  containment model intends to forbid.
- **Suggested fix:** Run the resolved `gitdir` target back through `fs_ctx.contained`
  (or reject non-contained targets) before reading `HEAD`.
- **Fix size:** S · **Fix risk:** safe

### F5 — `mdv-web` treats an empty `Host` header as allowed (anti-DNS-rebinding weakening)
- **Severity:** P3
- **File:** `rust-core/crates/web/src/main.rs:736-742` (`host_allowed`).
- **Evidence:** `if host.is_empty() { return true; }` — a request with no `Host`
  header passes the loopback allowlist that otherwise blocks DNS-rebinding.
- **Impact:** Low. The listener binds `127.0.0.1` only (`:283`), and every real browser
  sends a `Host` header, so the DNS-rebinding vector (a browser resolving
  `attacker.com` → `127.0.0.1`) still carries a non-loopback `Host` and is blocked. The
  empty-host bypass is reachable only by a raw local client, which already has loopback
  access. Noting it because it is an explicit "return true" in a security predicate.
- **Suggested fix:** Return `false` for an empty/absent `Host` (fail-closed) — HTTP/1.1
  requires the header anyway.
- **Fix size:** S · **Fix risk:** safe

---

## Positive observations

- **Custom-URL-scheme jail** (`Security/URLSchemePolicy.swift`) resolves symlinks on
  BOTH the candidate and the jail roots before the prefix check (physical-to-physical),
  uses anchored `hasPrefix(temp + "/")` to defeat the `/T-attacker` sibling, and is
  deliberately existence-agnostic + state-non-disclosing. The threat model (one-click
  "read arbitrary file" primitive) is documented inline. Prior audit findings S2/S3 are
  cited as closed.
- **MCP tool path jail** (`MCPToolCatalog.validatedExistingURL`, `:1153`) uses the same
  symlink-resolved, anchored-prefix containment (home ∪ per-user-temp) and is applied
  to `open_path`, `search_files`, `move_file`, review-store, etc.
- **HTML file rendering** is a genuine layered defense (`HTMLDocumentPolicy.swift`):
  L0 size cap → L1 allowlist sanitizer → L2 JS default-DENY (single source of truth,
  can't be inverted) → L3 `default-src 'none'` CSP + navigation-delegate sub-resource
  fence (`file:` fenced to the document's own directory, remote/`data:`/`javascript:`
  cancelled) → L4 link routing. The trust escalation (`HTMLTrustPolicy`) is fail-closed,
  path-keyed (no directory-wide trust), quarantine-gated, and keeps `connect-src 'none'`
  even when trusted (anti-exfil fence never relaxes; network consent is a *second*
  per-path opt-in).
- **Quarantine handling** (`FileQuarantine.isQuarantined`, `HTMLTrustPolicy.swift:135`)
  correctly probes `com.apple.quarantine` and refuses trust eligibility for
  downloaded/received files.
- **JS injection hygiene:** all outbound host→JS payloads ride as `JSONSerialization`
  JSON post-processed through `JSStringEmbedding.sanitize` to escape U+2028/U+2029
  (`CodeMirrorBridge.swift:719-738`, `MarkdownRenderedView.jsEscape:798`) — the find
  query is not string-concatenated into JS.
- **CodeMirror/Canvas bootstrap** uses `loadFileURL(…, allowingReadAccessTo: baseDir)`
  scoped to the bundle resource dir, not a broad grant; navigation policy treats any
  `data:`/unexpected `.other` nav as an injection attempt.
- **Rust daemons:** 16 MiB frame ceiling guards the decoder (`core/src/wire.rs:71-73`,
  `serve/src/lib.rs:31-32`); `git` is spawned via argv with a 5 s hard timeout, 1 MiB
  output cap, and a draining reader thread (no shell, no pipe deadlock,
  `git.rs:162-197`); `transcript.follow` restricts `{dir,name}` to single components
  ending `.jsonl` (`watch.rs:166-174, 369`); `fs`/`web` containment is
  `canonicalize()` + `starts_with(root)` (component-aware, so no `/site` vs
  `/site-secret` prefix bug); the web server binds loopback with an anti-rebinding
  Host check and an inflight cap.
- **Wire-boundary redaction:** the serve daemon FORCES transcript redaction regardless
  of the request flag (`serve.rs:31-34`, `parse_wire_forced_redaction`) — "nothing
  unredacted leaves the machine," distinct from the local-trust in-process FFI path.
- **Secret handling:** `HistoryContentFilter` actively refuses to persist content that
  looks like a secret (vendor token prefixes + entropy heuristics + assignment shapes),
  erring toward NOT capturing. No secret logging found in Git/LSP/ViewerCore.
- **Production socket** is `0600` via the launchd plist `SockPathMode` (F2 is only the
  self-bind fallback).

---

## Coverage gaps (what I did NOT examine)

- **Parser internals of the untrusted-bytes engines** (markdown/CSV/hex/diff/formula/
  tree-sitter highlight) were sampled at the dispatch boundary only — I confirmed the
  wire layer returns `WireError` (not panic) and that fuzz/proptest lanes exist, but did
  not audit each parser for slice-index/`unwrap` panics on adversarial input. A focused
  fuzz run against `find_engine`, `markdown::render_wire`, and the CSV/hex decoders is
  the right next step.
- **LSP client** (`Sources/ViewerCore/LSP`) — the jsonrpc framing / server-process spawn
  surface was not reviewed; a language server is a subprocess consuming untrusted
  project files and is worth its own pass.
- **Plugins subsystem** (`Sources/ViewerCore/Plugins`, `~/…/Plugins/`,
  `Walkthroughs/`) — the plugin loading/trust model was not examined.
- **Terminal model** and any PTY/exec surface were out of scope for this read.
- **Feeds** (`FeedReaderView`, `FeedRefreshScheduler`) — network fetch + XML/RSS parse
  of remote untrusted content was not audited (potential SSRF / XXE / entity-expansion
  surface).
- **TCC / entitlements / signing** posture (Info.plist capabilities, sandbox status)
  was not evaluated.
- No dynamic verification — all findings are from static reading; F1/F2 impacts are
  reasoned, not exploited.
