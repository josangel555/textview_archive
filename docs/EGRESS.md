# EGRESS.md — every way TextView can cause network traffic

**Purpose:** when a firewall (Little Snitch / LuLu) flags `TextView.app`
making an outbound connection, this document answers "why" without a code
dig. Maintained as part of TSK-635; verified against source 2026-06-12.

**Origin:** owner observed (2026-06-11) `TextView` (pid 6877) connecting to
`100.64.100.1`. That address is CGNAT space (`100.64.0.0/10`) — with a VPN
active (e.g. the VPN client) it is the tunnel's internal DNS/gateway, i.e. the
**first hop** of an ordinary request, not the destination.

---

## 1. First-party networking: NONE

There is no `URLSession`, `NWConnection`, or socket code anywhere in
`Sources/`. No update checker, no telemetry, no crash reporter. The MCP
automation server is **stdio-only** (`Sources/ViewerCore/Automation/MCPServer.swift`
— its header explicitly forbids URLSession/DispatchIO); it never opens a
network socket.

## 2. WKWebViews (traffic is made by WebKit's networking child process, but
firewalls attribute it to TextView)

| Surface | Remote subresources | Navigations | JS | Verdict |
|---|---|---|---|---|
| **Rendered markdown** (`MarkdownRenderedView`) | **Blocked by CSP** — every page goes through `HTMLRenderer.renderPage` (verified: both call sites + the model render cache), whose CRIT-1 meta is `default-src 'none'; img-src file: data:; connect-src 'none'; frame-src 'none'; object-src 'none'…` — remote `![images]`/badges are denied. (CORRECTION 2026-06-12: an earlier revision of this doc called this surface "the gap" — wrong; the check missed the template CSP.) Residual: no network-layer TEST pins this — a CSP-string regression would re-open egress silently (TSK-635's remaining scope) | link clicks → system browser (http/https/mailto), in-page nav fenced | ON (our own template; WKUserScripts bypass page CSP by design) | Fenced by CSP; needs a regression test. **NOT the source of the owner's observation — see TSK-643** |
| **HTML viewer** (`HTMLRenderedView`) | **Blocked** — injected CSP `default-src 'none'` AND `HTMLDocumentPolicy.decideSubresource` (file:-within-document-dir only) | clicks → system browser or cancelled; `file:`/`data:`/`javascript:` cancelled | default-DENY, per-tab opt-in | Fenced by design (layers L1–L4 in the file header). TSK-635 adds a network-layer verification test |
| **CM6 editor** (`CodeMirrorEditorView`) | local bundle only (`codemirror.html` has zero remote refs) | **default-cancel** — `javascript:`/`vbscript:`/`data:` always blocked; only bootstrap `file:` + same-doc fragments allowed (unit-tested `Coordinator.decide`) | ON (the editor is JS) | Fenced |
| **Mermaid** | runs inside the rendered-markdown WebView; `mermaid.min.js` is vendored (no CDN). Its 52 `http(s)` strings are SVG namespaces/links, not fetches | (same as host view) | (same) | Covered by the rendered-markdown fix once landed |

`markdown.css`, `codemirror.{html,css,js}`, `mermaid-shim.{js,css}`: verified
no remote `@import`/`src` references. Fonts are system fonts only.

## 3. Subprocesses (their traffic is attributed to THEIR binaries, not TextView)

| Spawn site | Binary | Network behavior |
|---|---|---|
| `GitClient` | `git` | **Local-only as invoked** — status/log/diff/stash/worktree/show; no fetch/pull/push/ls-remote/clone anywhere in the call sites. (A hostile repo's `core.fsmonitor` is the rust-core front-end concern, fixed there; the Swift GitClient runs against user-opened repos.) |
| `JQRunner` | `jq` | none |
| `AudioExporter` | host `ffmpeg` (owner-approved external tool) | none for local transcode |
| `LSPClient`/`LSPDiscovery` | `sourcekit-lsp` etc. | language servers may do their own I/O (e.g. index reads); they are separate processes with separate firewall identity |
| `PluginSubprocessHost` | user-installed Tier B plugin binaries | whatever the plugin does — gated by the per-plugin capability grant (`PluginGrantStore`); plugins are the user's trust decision |
| `TerminalModel` | the user's shell | the user's own traffic |
| `SidebarView.openInTerminal`, `main.swift relaunchAndExit` | `/usr/bin/open` | none |

## 4. Practical triage recipe

```bash
lsof -p <pid> -i                      # live sockets for the app process
# WebKit fetches: look for the "com.apple.WebKit.Networking" child of the pid
```
With the CSP verified in place, rendered-markdown badges are NOT the
explanation for app-attributed egress; the observed 2026-06-11 connection
(pid 6877 → 100.64.100.1) is UNEXPLAINED and tracked as TSK-643 — capture
`lsof -p <pid> -i` + the firewall's full flow detail (remote port, process
path) next time it fires.

## 5. Future: every row above emits an audit-log event (TSK-636) — allowed
AND blocked decisions, subprocess spawns with argv — so this table becomes
queryable from inside the app.
