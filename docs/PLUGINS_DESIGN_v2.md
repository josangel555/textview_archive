# PLUGINS_DESIGN_v2.md — extensibility for TextView

**Status:** design draft, no implementation yet. Supersedes the v1
brainstorm in `/Users/me/Documents/workspaces/claude/markdown_viewer/PLUGINS.md`
where the two disagree; carries forward the parts that still hold.

**Companion docs:**
- `/Users/me/Documents/workspaces/claude/markdown_viewer/PLUGINS.md` —
  v1 brainstorm. Read first for context; this doc replaces its
  packaging / runtime / security sections.
- `/Users/me/Documents/workspaces/claude/markdown_viewer/HACKABILITY.md`
  — module boundaries + "where do I edit X" map. The plugin host has
  to respect those boundaries from the outside, the same way internal
  features do from the inside.
- `/Users/me/Documents/workspaces/claude/markdown_viewer/docs/AUTOMATION.md`
  — the MCP / App Intents automation surface. Plugins can publish into
  MCP; the two systems share the action vocabulary.

---

## 0. TL;DR

- Three tiers of plugin, picked by what the plugin actually needs:
  - **Tier A — JSON config plugins.** No code execution. Themes, file
    icons, language extensions, classifier rules, palette entries.
    Ship in phase 1.
  - **Tier B — Shell-out plugins.** Per-action subprocess, stdin/stdout
    JSON-or-bytes. Pretty-printers, jq-style queries, converters.
    Ship in phase 2.
  - **Tier C — WebView plugins.** Sandboxed `WKWebView` with the host
    talking to JS via `window.webkit.messageHandlers`. Custom
    renderers, interactive views. Ship in phase 3.
- **No native Swift loadable bundles.** TCC, signing, crash blast
  radius, and the "trust prompt is the only mitigation" footgun rule
  them out. v1 design says **never**, not "later." See §3.4.
- **Manifest:** one `plugin.json` per plugin, schema'd, host-version
  pinned, capability-list pinned, signed-by-author optional.
- **Permissions:** capabilities declared in the manifest, user grants
  per-plugin on first install + on capability bump. Stored in the
  existing `JSONFileStore`. No silent escalation.
- **Distribution:** drag-drop a `.tvplugin` folder onto the app window
  (or onto a Plugins settings pane) in v1. No marketplace, no
  auto-update, no curl-pipe-sh.
- **MCP intersection:** a plugin can declare MCP tools in its
  manifest. The host registers them with the MCP server under the
  plugin's namespace. When Claude/Cursor calls
  `tv__protoplugin__pretty_print`, the host routes the call into the
  plugin's Tier B or C runtime.
- **Crash isolation:** Tier B is a subprocess (crash = nonzero exit).
  Tier C is `WKWebView` which is already a separate process. Tier A
  has no runtime — it's data.
- **Phased rollout:** Tier A → Tier B → Tier C. Each phase ships a
  small, useful slice; we are not building a runtime in advance of a
  plugin that wants it.

---

## 1. What v1 (the old PLUGINS.md) got right, and what changes

`PLUGINS.md` was a brainstorm — it surveyed five packaging options and
left them on the table. v2's job is to **cut**.

### Carried forward unchanged

- The list of extension points (file-type handlers, viewer modes,
  sidebar widgets, menu commands, command palette entries, themes,
  highlighters). v2 expands the list, doesn't shrink it.
- The "v0 themes-as-JSON" idea. That's literally Tier A and it ships
  first.
- The manifest-driven contribution model (a JSON file declares what
  the plugin contributes, the host registers each contribution with
  the right subsystem). v2 tightens the schema and versioning.
- Per-plugin enable/disable in Settings.
- "No marketplace in v1." Still no marketplace.
- "Plugin conflicts (two plugins claim `public.json`)" is still a
  real problem and v2 answers it — see §10.4.

### Changed in v2

| Topic                       | v1 stance                                         | v2 stance                                                |
|-----------------------------|---------------------------------------------------|----------------------------------------------------------|
| Native Swift bundles        | Allowed with "trust prompt + signed dev ID"       | **Removed.** Not in v1, not in v2, not ever — see §3.4.   |
| Plugin runtime options      | Hybrid: native + WKWebView + external process     | Tiered: JSON / shell-out / WebView. No native.            |
| WASM                        | Listed as an option                               | Deferred indefinitely. No mature stdlib path on macOS.    |
| AppleScript / OSAKit        | Listed                                            | Out. Same reasoning as `docs/AUTOMATION.md` §4.A.         |
| Lifecycle hooks             | `onLoad / onUnload / onFileOpen / onTabSelect`    | Tier-specific. Tier A has no lifecycle. Tier B is per-call. Tier C has hooks only where the contribution surface needs them. |
| Permissions                 | "Trust prompt with explicit permission list"      | Capability list in manifest + per-plugin grants in `JSONFileStore`, re-prompted on bump. |
| Distribution                | `.mdvplugin` bundle, file picker                  | `.tvplugin` folder, drag-drop onto window or Plugins pane. Same idea, renamed. |
| MCP integration             | Not addressed                                     | First-class: plugins can publish MCP tools. See §8.       |
| Sessions / workspaces       | Not addressed (didn't exist yet)                  | Plugins can persist per-session state via a scoped store. See §2.13. |
| Top sidebar 5-section layout| Not addressed (didn't exist yet)                  | New sections are an explicit contribution point. See §2.1.|
| Git panel                   | Not addressed                                     | Tabbed panel is an extension point (tabs are contributable). See §2.3. |

### Open questions from v1, answered

| v1 open question                                                  | v2 answer                                                    |
|-------------------------------------------------------------------|--------------------------------------------------------------|
| "User-acknowledged trust prompt enough for native bundles?"       | Moot — no native bundles.                                    |
| "Manifest JSON / TOML / Swift macros?"                            | JSON. `JSONDecoder` already in the codebase, no new dep.     |
| "`mdv plugins install <url>` CLI?"                                | No in v1. Drag-drop only. Curl-pipe-install is a footgun.    |
| "How do we handle plugin conflicts (two plugins claim `public.json`)?" | Last-installed wins, but only after explicit user "use this one" pick in Settings. See §10.4. |
| "Is there a market for a marketplace?"                            | Still no. GitHub is fine.                                    |

---

## 2. What can be customized

This is the catalogue of contribution points. Every plugin contribution
in a manifest names one of these points. The host owns the registry
for each point; plugins add entries, they do not replace the host
implementation.

Each entry below lists: **what it is**, **which tier(s) can provide
it**, **which subsystem owns it**, **which capabilities it implies**.
Capability names are normative — see §5 for the full list.

### 2.1 New sidebar sections (custom data sources)

TextView's sidebar today is a fixed 5-section column: **Bookmarks /
File tree / Search / Git status / Outline**. A plugin can add a
sixth, seventh, Nth section.

- **Tiers:** A (static list), B (refresh-on-demand from shell), C
  (interactive WebView body).
- **Owner:** `Sources/ViewerUI/SidebarView.swift` +
  `Sources/ViewerUI/SidebarModel.swift`. The plugin host appends to
  `SidebarModel.pluginSections`, which is a `[PluginSidebarSection]`.
- **Capabilities implied:** `ui.sidebar`. Tier B/C also need
  `shell.exec` or `webview.run` respectively.
- **Manifest fragment:**
  ```json
  {
    "type": "sidebar_section",
    "id": "notes",
    "title": "Notes",
    "icon": "note.text",
    "order": 100,
    "collapsedByDefault": true,
    "provider": { "tier": "B", "command": "list-notes" }
  }
  ```
- **Constraints:** sections render in a fixed-width column. Plugin
  cannot resize the sidebar, cannot inject above Bookmarks (reserved
  for first-party Bookmarks/Tree/Search/Git/Outline), cannot draw
  outside its row range. The `order` field is a hint; ties broken by
  install order; user can drag to reorder in Settings (state stored
  per-user).

### 2.2 New view modes (e.g. `.protobuf` renderer, `.parquet` table)

A view mode is what the mode bar at the top of the content pane
selects between (`Source / Rendered / Hex / Table / ...`). Today
the mode-routing is a `switch` in `ContentView.loadedView(for:)`
(see `HACKABILITY.md` §"Add a new view mode"). v2 turns that switch
into a registry the plugin host writes to.

- **Tiers:** B (renders to text/HTML), C (renders in a WebView).
  Tier A cannot provide a view mode — view modes are runtime
  behaviour, not config.
- **Owner:** `Sources/ViewerCore/ViewModeRegistry.swift` (new) plus
  `Sources/ViewerUI/ContentView.swift` consuming it.
- **Capabilities implied:** `ui.viewmode`. Tier B also `shell.exec`;
  Tier C also `webview.run`.
- **Manifest fragment:**
  ```json
  {
    "type": "view_mode",
    "id": "proto-decoded",
    "label": "Decoded",
    "fileTypes": ["public.protobuf", ".proto", ".pb"],
    "provider": { "tier": "C", "entry": "view.html" },
    "fallback": "hex"
  }
  ```
- **Constraints:** the host gives the plugin **bytes** (or a path,
  with `file.read` capability) and expects either a rendered HTML
  string (Tier C) or a UTF-8 / typed result (Tier B). The host owns
  the surrounding chrome (mode bar, status bar, scroll position
  persistence). The plugin owns the body.
- **Fallback:** if the plugin fails to load or errors at render time,
  the host falls back to `fallback` (a built-in mode id). No silent
  blank panes.

### 2.3 Git panel tabs

The Git panel (currently a tabbed UI inside the right sidebar pane:
**Log / Diff / Blame / Branches**) is a contribution surface. A
plugin can add a tab (e.g. "PR Reviews", "Stash Browser").

- **Tiers:** B, C.
- **Owner:** `Sources/ViewerUI/GitPanelView.swift` (assumed —
  `HACKABILITY.md` lists `ViewerCore/Git/*` but not the panel
  itself; this section may need to register against whichever view
  owns the `TabView`).
- **Capabilities implied:** `ui.gitpanel`. Likely also `shell.exec`
  for any plugin that wants to run `git`.

### 2.4 New file-type icons + classifiers

- **Tiers:** A only. This is pure mapping.
- **Owner:** `Sources/ViewerCore/FileTypeDetector.swift` + icon
  resolution wherever the file row icons render.
- **Capabilities implied:** none. (Plugin doesn't run; it's data.)
- **Manifest fragment:**
  ```json
  {
    "type": "file_icon",
    "match": { "extensions": [".proto", ".pb"], "mime": ["application/x-protobuf"] },
    "icon": "proto.svg",
    "displayName": "Protocol Buffer"
  }
  ```
- **Constraints:** SVG or PNG (≤32×32). Host caches resolved icons
  by hash. Conflicts: first-party always wins (file rows have a
  fallback chain); among plugins, last installed wins but Settings
  shows "X plugins claim this extension" with a picker. See §10.4.

### 2.5 New menu items (top-level + context-menu)

- **Tiers:** A (declare label + action keyword), B, C.
- **Owner:** `Sources/MarkdownViewer/main.swift` (`AppDelegate` menu
  builder).
- **Capabilities implied:** `ui.menu`. Action-side capability
  depends on what the menu item does (e.g. `shell.exec`).
- **Where the items go:**
  - **Top-level:** under a single `Plugins` menu in the menu bar.
    Submenus per plugin. The host never lets a plugin insert a
    top-level menu (no `Plugins → MyPlugin → Edit → Preferences`
    crossing into "Edit"); the menu bar's structure is reserved.
  - **Context menu:** file-tree right-click, tab right-click,
    selection right-click in the source view. Each context menu has
    a stable contribution point id (`ctx.file`, `ctx.tab`,
    `ctx.selection`).
- **Manifest fragment:**
  ```json
  {
    "type": "menu_item",
    "id": "send-to-cursor",
    "title": "Open in Cursor",
    "where": ["menu.plugins", "ctx.file", "ctx.tab"],
    "enabledWhen": "currentURL.scheme == 'file'",
    "keyboard": "$cmd+shift+c",
    "action": { "tier": "B", "command": "open-in-cursor" }
  }
  ```
- **`enabledWhen`:** a tiny expression mini-language (no
  Turing-completeness). Supported operators: `==`, `!=`, `&&`, `||`,
  `!`, paren grouping. Supported variables come from a fixed set
  (`currentURL`, `currentURL.scheme`, `currentURL.pathExtension`,
  `viewMode`, `selectionLength`, `hasSelection`). Reject any
  expression that doesn't parse against the fixed grammar — no
  `eval`.

### 2.6 New keyboard shortcuts

- **Tiers:** A (bind to a built-in command), B, C.
- **Owner:** the same menu builder + `validateMenuItem` in
  `Sources/MarkdownViewer/main.swift`. Shortcuts that aren't bound to
  a menu item go through a separate `KeyboardShortcutRegistry`.
- **Capabilities implied:** `ui.keyboard`. The action's capability is
  whatever the action actually does.
- **Conflict resolution:** first-party shortcuts always win. Plugin
  vs plugin: last installed wins, surfaced in Settings.
- **Format:** `$cmd+shift+c`, `$opt+/`, etc. — the same micro-syntax
  the v1 manifest already used. Host parses, normalises (`$cmd` →
  `.command`).

### 2.7 New TreeSitter languages (without rebuilding the app)

This is the prize. Today, adding a language requires touching five
files and pinning a Swift package (see `HACKABILITY.md` §"Add a new
file type to highlight"). v2 lets a plugin drop in a precompiled
grammar + queries.

- **Tier:** A (data only — but it's binary data, not JSON).
  Technically the grammar is a compiled `.dylib` or `.a`. v1
  ships **`.scm` queries only**, against languages the app already
  links. Phase 2/3 may add full grammar loading.
- **Owner:** `Sources/ViewerCore/Highlight/TreeSitterEngine.swift` +
  `Sources/ViewerCore/Highlight/Queries/`.
- **Capabilities implied:** none for queries-only (data). Future
  full grammar support would require `binary.load` — see §5.6 —
  which v1 **does not allow**.
- **Manifest fragment (queries-only, phase 1):**
  ```json
  {
    "type": "treesitter_queries",
    "language": "swift",
    "queriesPath": "queries/swift-extra-highlights.scm",
    "appendTo": "existing"
  }
  ```
- **Manifest fragment (full language, phase 4+ — NOT v1):**
  ```json
  {
    "type": "treesitter_language",
    "language": "nix",
    "grammar": "grammar.so",
    "queriesPath": "queries/nix-highlights.scm"
  }
  ```
  This second form is documented for forward-compatibility only.
  v1 rejects it with a manifest-validation error. See §3.5.

### 2.8 New themes

The v1 doc already had this as "v0." It is still the cheapest,
safest, highest-leverage extension point.

- **Tier:** A only.
- **Owner:** `Sources/ViewerCore/Highlight/SyntaxTheme.swift` +
  `Resources/markdown.css` (rendered markdown theme).
- **Capabilities implied:** none.
- **Manifest fragment:** see §6.1 — full worked example.

### 2.9 Custom pretty-printers (shell-out OR in-process)

A pretty-printer takes bytes/text in, returns formatted text out.
Today TextView ships `Formatter.swift` with a built-in switch on
`SupportedFormat`. v2 makes that pluggable.

- **Tiers:** B (preferred — shell-out is the natural shape), C
  (allowed but unusual — only worth it if the printer needs DOM).
- **Owner:** `Sources/ViewerCore/Formatter.swift` +
  `Sources/ViewerCore/FormatterRegistry.swift` (new).
- **Capabilities implied:** `format.provide` + `shell.exec` (Tier B).
- **Manifest fragment:**
  ```json
  {
    "type": "formatter",
    "id": "proto-decoded",
    "label": "protoc decode",
    "fileTypes": [".proto", ".pb"],
    "trigger": "manual",
    "action": { "tier": "B", "command": "decode-proto" }
  }
  ```
- **`trigger`:** `manual` (user picks from a menu / palette),
  `auto` (replaces default pretty-print for the file type — requires
  conflict resolution), or `on-format` (runs only when the user hits
  Pretty-print). Default `manual`.

### 2.10 LSP discovery rules

TextView doesn't run LSP servers itself (and may not, ever — that's
an IDE feature). But it can **discover** an LSP server in the
project root (`.luarc.json` → there's a Lua LSP available; show a
status-bar badge or a "diagnose" option). Plugins can teach the host
what to look for.

- **Tiers:** A.
- **Owner:** `Sources/ViewerCore/Project/LSPDiscovery.swift` (new).
- **Capabilities implied:** none (file-tree read only — the host
  already has that ambient).
- **Manifest fragment:**
  ```json
  {
    "type": "lsp_discovery",
    "language": "lua",
    "markers": ["stylua.toml", ".luarc.json"],
    "serverHint": "lua-language-server"
  }
  ```
- **What it actually does:** populates the status bar with a "Lua
  LSP available" badge and a tooltip. v1 does **not** run the LSP.
  Phase later: route diagnostics back into the source view.

### 2.11 Walkthrough step verbs (extension)

The Walkthrough system (`docs/WALKTHROUGH.md` — referenced from
HACKABILITY) drives the app via a script of named steps:
`toggle-view`, `zoom-in`, `find-next`, etc. Plugins can add new
verbs.

- **Tiers:** B, C.
- **Owner:** the walkthrough step dispatcher in
  `Sources/MarkdownViewer/main.swift` (alongside `runScriptStep`).
- **Capabilities implied:** `walkthrough.verb`. The verb itself
  declares any further capability (e.g. `shell.exec`).
- **Manifest fragment:**
  ```json
  {
    "type": "walkthrough_verb",
    "verb": "decode-proto",
    "args": [{ "name": "path", "required": true }],
    "action": { "tier": "B", "command": "decode-proto" }
  }
  ```
- **Why this matters:** the walkthrough is how headless tests drive
  the app (see `docs/AUTOMATION.md` §5 — `--script` is rewired to be
  an MCP client). A plugin that adds a view mode also wants its
  view mode visible to walkthrough scripts. Single registry, two
  consumers.

### 2.12 CR comment templates

Code review (CR) comments — TextView's lightweight review feature —
have a "template" surface for canned comments ("nit: ", "blocker: ").
Plugins can ship template packs.

- **Tier:** A.
- **Owner:** wherever CR templates currently live; assumed
  `Sources/ViewerCore/CR/CRTemplates.swift`.
- **Capabilities implied:** none.
- **Manifest fragment:**
  ```json
  {
    "type": "cr_template",
    "id": "google-style-nits",
    "templates": [
      { "prefix": "nit", "body": "nit: " },
      { "prefix": "tq", "body": "Thought-question: " }
    ]
  }
  ```

### 2.13 Command palette commands

The command palette (`CommandPalette.swift` / `UnifiedFinder.swift`)
already has an internal list. Plugins can add to it.

- **Tiers:** A, B, C.
- **Owner:** `Sources/ViewerUI/CommandPalette.swift` (consumed
  list) + `Sources/ViewerCore/CommandRegistry.swift` (new producer).
- **Capabilities implied:** `ui.palette`. Action capabilities depend
  on what the command does.
- **Manifest fragment:**
  ```json
  {
    "type": "palette_command",
    "id": "decode-proto-here",
    "title": "Decode this .proto",
    "subtitle": "Run protoc --decode_raw",
    "enabledWhen": "currentURL.pathExtension == 'proto'",
    "action": { "tier": "B", "command": "decode-proto" }
  }
  ```

### 2.14 Session-scoped storage

(TextView is adding a "sessions" concept — named multi-tab workspaces
that persist independently. See `STATE.md` for the audit.) Plugins
that hold state (a sidebar widget showing pinned items, a render
filter that remembers preferences) need a place to put per-session
data without polluting the global plugin pref store.

- **Mechanism:** the host hands each plugin a
  `PluginStorage` with two scopes: `global` and `session`. Both
  are JSON, both go through `JSONFileStore`.
- **Path on disk:**
  - global: `~/Library/Application Support/TextView/Plugins/<id>/data.json`
  - session: `~/Library/Application Support/TextView/Sessions/<session-id>/Plugins/<id>/data.json`
- **Capabilities implied:** `storage.global` and/or
  `storage.session`. Each capped at 10 MB; writes that overflow are
  rejected.

### 2.15 Custom URL schemes (sub-paths only)

A plugin can register handlers under `textview://plugins/<id>/<verb>`.
Plugins **cannot** claim arbitrary URL schemes — the host owns
`textview://`. (And `markdownviewer://` stays frozen per
`docs/AUTOMATION.md` §9.)

- **Tiers:** A (declare verb → action mapping).
- **Owner:** `Sources/MarkdownViewer/main.swift`
  `handleCustomURLScheme`.
- **Capabilities implied:** `url.handle`.

### 2.16 Status-bar items

Read-only widgets on the right of the status bar (where line/col +
encoding live today).

- **Tiers:** A (static text bound to a host variable), B (refreshed
  on a host event), C (live WebView fragment — rare; expensive).
- **Owner:** `Sources/ViewerUI/StatusBarView.swift`.
- **Capabilities implied:** `ui.statusbar`.

### 2.17 Render filters (markdown AST hook)

Pre-render hook on the markdown AST. Useful for "make all GitHub
issue refs into links," "expand mermaid code blocks via a different
renderer," etc.

- **Tiers:** C only (must be cheap + sync-ish; subprocess overhead
  on every render is unacceptable).
- **Owner:** `Sources/ViewerUI/MarkdownRenderedView.swift` +
  `Resources/markdown.js`.
- **Capabilities implied:** `render.ast`.
- **Constraints:** filter receives a serialised AST fragment over
  the postMessage bridge, returns a transformed fragment. Total
  budget per render: 100ms wall clock. Over budget → host falls back
  to unfiltered render and logs a warning.

### 2.18 Find providers (cross-file search)

The current cross-file search is filesystem grep. A plugin can add a
custom provider ("search in my notes index", "search Jira").

- **Tiers:** B, C.
- **Owner:** `Sources/ViewerCore/Search/FindProviderRegistry.swift`
  (new).
- **Capabilities implied:** `search.provide`. Likely also
  `network.egress` for non-local providers — which **requires
  explicit per-plugin user grant** (see §5).

### 2.19 Putting it together

Every contribution point is a registry on the host. The plugin host
populates registries at load time from manifests. The host's view
code reads registries to render UI. No global mutable singletons —
the registries are owned by `PluginRegistry` and queried by name.

```
Manifest (plugin.json)
    │
    ▼
PluginRegistry  ──┬──→ SidebarRegistry          (read by SidebarView)
                  ├──→ ViewModeRegistry         (read by ContentView)
                  ├──→ MenuContributionRegistry (read by AppDelegate)
                  ├──→ ThemeRegistry            (read by SyntaxTheme.named())
                  ├──→ IconRegistry             (read by file-row icon resolver)
                  ├──→ FormatterRegistry        (read by Formatter)
                  ├──→ KeyboardRegistry         (read by main.swift key handler)
                  ├──→ TreeSitterQueryRegistry  (read by TreeSitterEngine)
                  ├──→ CommandRegistry          (read by CommandPalette)
                  ├──→ WalkthroughVerbRegistry  (read by main.swift dispatcher)
                  ├──→ CRTemplateRegistry       (read by CR UI)
                  ├──→ LSPDiscoveryRegistry     (read by status bar)
                  ├──→ URLHandlerRegistry       (read by handleCustomURLScheme)
                  └──→ MCPToolRegistry          (read by MCPServer — see §8)
```

---

## 3. Plugin runtime — three tiers

Choosing a runtime is choosing a security model, not just a
language. The tiers below are ordered by risk: A is safest, C is
the most permissive, and there is no D ("native") on purpose.

### 3.1 Tier A — JSON config plugins (no code)

- **What it is:** a `plugin.json` manifest plus static assets (PNG
  icons, SVG icons, `.scm` query files, CSS files, JSON theme
  files). Zero code execution.
- **What it can do:** themes, file icons, language extensions
  (queries-only), CR template packs, LSP discovery rules, palette
  entries that bind to built-in commands, menu items that bind to
  built-in commands, URL handlers that bind to built-in commands.
- **What it cannot do:** anything that requires running code. No
  formatters, no view modes, no sidebar bodies (a Tier A sidebar
  section can show a static list bound to a host variable, nothing
  else), no MCP tools.
- **Permission model:** zero capabilities required for the
  inert-data points. Display-only manifest entries still get a
  "this plugin contributes: X, Y, Z" review on install.
- **Failure mode:** schema validation. A malformed manifest is
  rejected at load with a precise error; nothing partially loads.

### 3.2 Tier B — Shell-out plugins (per-action subprocess)

- **What it is:** the manifest declares one or more **commands**.
  Each command is a relative path inside the plugin folder pointing
  to an executable (script, binary, anything `posix_spawn` can
  run). The host invokes the command with arguments + stdin and
  reads stdout/stderr/exit code.
- **What it can do:** formatters, view modes (that produce
  text/HTML output), find providers, sidebar refreshers, walkthrough
  verbs, MCP tools — anything whose semantic is "input bytes, output
  bytes."
- **Calling convention:**
  - **stdin:** JSON envelope with `{ "input": <base64-or-string>, "context": { "url": "...", "selection": [s,e], "viewMode": "...", "args": {...} } }`. Bytes that are not valid UTF-8 are base64'd; the envelope's `inputEncoding` field says which.
  - **argv:** `[<command>, "--invocation-id", "<uuid>"]`. The plugin doesn't get the user's full env; see env block below.
  - **env:** scrubbed. The host passes only `PATH` (host-chosen,
    points to `/usr/bin:/bin:/usr/local/bin`),
    `TV_PLUGIN_DIR=<plugin folder>`,
    `TV_PLUGIN_DATA_DIR=<storage dir>`,
    `TV_INVOCATION_ID=<uuid>`,
    `TV_HOST_VERSION=<semver>`,
    `LANG=en_US.UTF-8`. No `HOME`, no `USER`, no `SSH_AUTH_SOCK`,
    no AWS env vars, nothing inherited. (The plugin can still call
    `getpwuid(getuid())` if it really wants — we're not trying to
    hide identity, just trying not to leak credentials.)
  - **cwd:** `<plugin folder>`.
  - **stdout:** the plugin's response, format declared in manifest
    (`json` | `text` | `html` | `bytes`).
  - **stderr:** captured into a per-plugin log at
    `~/Library/Logs/TextView/Plugins/<id>.log`. Visible from
    Settings → Plugins → "Show log."
  - **exit code:** 0 = success, non-zero = failure. Failures fall
    back to a built-in (where one exists) and surface a
    non-modal banner.
- **Process lifecycle:** spawned per invocation; not a daemon. If
  the same plugin command is called rapidly, the host coalesces
  (only the latest invocation matters) and serialises per-command
  (no two in-flight invocations of the same command for the same
  document). A "warm pool" — keeping one process alive for repeat
  calls — is a v2.1 thing if profiling demands it.
- **Resource limits:**
  - Wall-clock timeout: 5s default, manifest can request up to 30s.
  - Memory: best-effort `setrlimit(RLIMIT_AS, 512 MB)`. macOS's
    enforcement is loose, but enough to catch runaways.
  - stdout: capped at 16 MB. Beyond that the host closes the pipe.
  - Concurrency: at most 4 in-flight Tier B invocations across all
    plugins, queue beyond that.
- **Crash isolation:** subprocess. Crash = nonzero exit, no host
  impact. SIGKILL on timeout.

### 3.3 Tier C — WebView plugins (sandboxed JS in `WKWebView`)

- **What it is:** an HTML/JS bundle inside the plugin folder.
  The host instantiates a `WKWebView` with the plugin's
  `entry.html` (relative path declared in manifest), no network
  access, custom URL scheme handler scoped to the plugin folder,
  and a message handler bridge.
- **What it can do:** view modes, sidebar widgets (interactive
  bodies), Git panel tabs, render filters, MCP tools (where the
  tool wants to share the same JS code as the view), find
  providers (where the provider wants a rich UI), status-bar
  widgets, walkthrough verbs (rare — usually B is better).
- **Bridge:** `window.webkit.messageHandlers.tv.postMessage(msg)`
  sends a message to the host. The host replies via
  `webView.evaluateJavaScript("window.__tv.onReply(...)", ...)`. A
  small JS shim (`tv.js`, shipped with the host and injected as a
  user script) wraps both directions in promises.
- **The bridge API surface (the *only* things plugin JS can ask the
  host to do):**
  - `tv.host.getInput()` — returns the input bytes / text for the
    contribution that spawned this WebView. For a view mode, the
    file contents. For a render filter, the AST fragment. For a
    sidebar section, nothing (sidebar plugins call
    `tv.host.refresh()` to pull).
  - `tv.host.getContext()` — current URL, selection, view mode,
    session id. Equivalent to the Tier B envelope's `context`.
  - `tv.host.read(path)` — only if the plugin has `file.read`
    capability AND the path is within the currently-open project
    root.
  - `tv.host.shell(command, args)` — only if the plugin has
    `shell.exec`. Goes through the same Tier B subprocess machinery
    (capabilities and limits), even when invoked from C.
  - `tv.host.notify(event, payload)` — push a host-side event
    (`refresh`, `error`, `result`).
  - `tv.host.invokeCommand(id, args)` — invoke a built-in command
    (e.g. `open_path`). Subject to the host's permission model.
  - `tv.host.storage.get(key) / set(key, value) / delete(key)` —
    scoped to the plugin's storage capability.
  - `tv.host.mcp.respond(id, result)` — used when this WebView is
    backing an MCP tool. See §8.
- **What the JS *cannot* do (because the bridge doesn't expose it):**
  - `fetch()` to arbitrary URLs (WKWebView's `WKWebpagePreferences`
    blocks navigation; the custom URL scheme handler only resolves
    paths inside the plugin folder; `network.egress` is gated by
    capability).
  - Access to `localStorage` for exfil — `localStorage` is per-
    `WKWebView` instance and not persisted across sessions; use
    `tv.host.storage` for persistence.
  - Touching other plugins or other WebViews — each plugin runs in
    its own `WKWebView` with a distinct `WKWebViewConfiguration`.
- **Crash isolation:** `WKWebView` already runs in a separate
  process (`com.apple.WebKit.WebContent`). A plugin that
  segfaults its renderer kills its own web content process, not
  the host. The host re-spawns on the next render.
- **Resource limits:**
  - The host kills the WebView if `postMessage` traffic exceeds 50
    MB in a single contribution.
  - WebView is destroyed when the contribution surface is closed
    (tab closed, sidebar section collapsed). Hot-keep one WebView
    per plugin if profiling demands it.

### 3.4 Why no Tier D — native Swift loadable bundles

The v1 doc kept this as an option with "trust prompt + signed dev
ID" as the mitigation. v2 removes it. Reasoning:

1. **TCC is a nightmare.** `Bundle.load()`-ing third-party code
   inside a sandboxed (or hardened-runtime) app means every
   TCC-protected API the plugin touches inherits the host's
   entitlement set, which is too broad. The plugin can ask for
   `Documents`, `Desktop`, `Downloads`, Full Disk Access — and the
   prompt names *TextView*, not the plugin. Users blame the app.
2. **Signing pain.** Either the user disables Gatekeeper (don't),
   or we ship an unsigned-binary-loading binary (TestFlight will
   reject this for the App Store path; notarisation gets messy),
   or we require every plugin author to notarize their dylib
   ($99/yr Apple Developer Program just to ship a TextView plugin).
   Nope.
3. **Blast radius.** A native plugin can scribble `DocumentModel`
   internals, retain-cycle the main actor, call private SwiftUI
   APIs, swizzle NSApplication. There is no sandbox short of a
   separate process. If we want a separate process, we already
   have Tier B.
4. **ABI churn.** Swift's module ABI is stable enough for Apple's
   own frameworks but not for our internal types. We would either
   freeze our internal API (limiting our ability to refactor —
   see `ViewerCore/DocumentController` which we're already
   reshaping) or break plugins every release.
5. **The features people actually want don't need it.** Across
   the §2 contribution list, **every** point that needs code can
   be served by Tier B (subprocess) or Tier C (WebView). The cost
   of native is unjustified.

If a future plugin *really* needs native — say, a hardware-
accelerated 3D viewer — that's a built-in. We ship it in
`ViewerCore` and accept the maintenance burden. We don't open a
loadable-code surface for it.

### 3.5 Forward-compat: things we mention but don't ship in v1

| Idea                              | Status                                                    |
|-----------------------------------|-----------------------------------------------------------|
| WASM via `wasmtime` Swift bindings| Listed in v1. v2 keeps it on the shelf. Mature stdlib path on macOS still missing in 2026. Revisit when Apple ships a WebAssembly System Interface in Foundation. |
| Full TreeSitter grammar loading   | Manifest defines a future `treesitter_language` shape but v1 rejects it. Phase 4+. |
| Persistent Tier B daemons         | Phase 2.1 if profiling needs it. v1 is per-call.          |
| Plugin-to-plugin messaging        | No. Plugins talk to the host, the host coordinates.        |

---

## 4. Plugin manifest

One file: `plugin.json`. Lives at the root of the plugin folder.
The host won't load anything else from the folder until the
manifest validates.

### 4.1 Schema (TypeScript-ish for readability)

```ts
interface PluginManifest {
  // Identity
  id: string;                     // "com.example.tv.proto" — reverse-DNS, [A-Za-z0-9.-]+
  name: string;                   // "Protocol Buffer Viewer"
  version: string;                // "1.2.3" — semver, exact
  author: { name: string; url?: string; email?: string };
  homepage?: string;
  license?: string;               // SPDX id

  // Compatibility
  hostVersion: string;            // ">=0.7 <0.9" — semver range
  manifestVersion: 1;             // bump on incompatible manifest changes

  // Permissions
  capabilities: Capability[];     // see §5; user must grant each

  // Contributions — at least one required, else the plugin is inert
  contributes: Contribution[];

  // MCP tools (see §8) — may be empty
  mcpTools?: MCPToolDecl[];

  // Optional signature block
  signature?: {
    algorithm: "ed25519";
    publicKey: string;            // base64
    signature: string;            // base64 of sign(sha256(manifest minus signature block) ‖ "\0" ‖ tree-hash)
  };
}

type Contribution =
  | ThemeContribution
  | FileIconContribution
  | TreeSitterQueriesContribution
  | LSPDiscoveryContribution
  | CRTemplateContribution
  | SidebarSectionContribution
  | ViewModeContribution
  | FormatterContribution
  | MenuItemContribution
  | KeyboardShortcutContribution
  | PaletteCommandContribution
  | WalkthroughVerbContribution
  | StatusBarItemContribution
  | RenderFilterContribution
  | FindProviderContribution
  | URLHandlerContribution
  | GitPanelTabContribution;

// Each Contribution carries:
//   type: <one of the strings above>
//   id:   string, unique within the plugin
//   ...point-specific fields per §2

type Capability =
  | "file.read"            // read from project root only
  | "shell.exec"           // spawn subprocesses (Tier B)
  | "webview.run"          // host a WKWebView (Tier C)
  | "network.egress"       // outbound network from a Tier B child or a Tier C webview
  | "storage.global"
  | "storage.session"
  | "ui.sidebar"
  | "ui.viewmode"
  | "ui.menu"
  | "ui.palette"
  | "ui.keyboard"
  | "ui.statusbar"
  | "ui.gitpanel"
  | "format.provide"
  | "search.provide"
  | "render.ast"
  | "url.handle"
  | "walkthrough.verb"
  | "mcp.tool";            // exposes one or more MCP tools (see §8)

interface MCPToolDecl {
  id: string;              // local id, namespaced under plugin: "decode_proto"
  description: string;
  schema: JSONSchema;      // input schema, JSON Schema draft 2020-12 subset
  resultSchema?: JSONSchema;
  action: { tier: "B"; command: string } | { tier: "C"; entry: string };
}
```

### 4.2 What "version pinning" means

- `hostVersion` is a semver range against the host (TextView) version.
  The host evaluates the range at load time using a tiny vendored
  semver matcher (no new dep — node-semver subset is ~200 LOC of
  Swift).
- Out-of-range plugins **load but stay disabled** with a UI hint in
  Settings: "This plugin requires TextView 0.9+." We don't silently
  hide; users need to know why their plugin isn't running.
- Manifest version is its own dial — `manifestVersion: 1` is the only
  legal value in v1. We bump it on incompatible schema changes
  (renaming a contribution type, removing a capability), not on
  additive ones.

### 4.3 Where plugins live on disk

```
~/Library/Application Support/TextView/Plugins/
├── com.example.tv.proto/
│   ├── plugin.json
│   ├── decode-proto                 (executable, Tier B)
│   ├── icons/proto.svg
│   └── README.md
├── com.example.tv.dot/
│   ├── plugin.json
│   ├── view.html
│   ├── view.js
│   ├── viz.standalone.js            (bundled lib)
│   └── icons/dot.svg
└── com.example.tv.solarized/
    ├── plugin.json
    ├── theme.json
    └── markdown.css
```

Each plugin gets a folder. The folder name should match the plugin
`id`. The host doesn't enforce that (filesystems differ), but
mismatched names produce a warning at load.

### 4.4 Discovery

At launch:

1. Enumerate `~/Library/Application Support/TextView/Plugins/*/plugin.json`.
2. For each one:
   - Validate against the schema. Reject on any error; log the path
     and the line/column of the offending field.
   - Check `hostVersion` against the running host version. If out of
     range, mark `disabled-incompatible`, skip the rest.
   - Look up the per-plugin grant record in
     `~/Library/Application Support/TextView/plugin-grants.json`
     (a `JSONFileStore`). If the manifest's `capabilities` set
     differs from the granted set, mark `needs-regrant`, skip
     contribution registration, surface in Settings.
   - Otherwise, register every `contributes` entry with the right
     registry. Tier B/C runtimes are *not* started here — they
     spin up on first invocation.
3. Persist a load-result manifest to
   `~/Library/Application Support/TextView/Plugins/.load-log.json`
   so Settings → Plugins can show "what happened on last launch."

Hot-reload (drop-in / drag-drop) re-runs steps 1-3 for the affected
folder only.

---

## 5. Permission model

Plugins do nothing the manifest doesn't declare, and the user grants
each declared capability on install. Re-prompt when the manifest's
capability set changes on update.

### 5.1 The capability list (normative)

| Capability         | What it unlocks                                                                                          | Default scope                                    |
|--------------------|----------------------------------------------------------------------------------------------------------|--------------------------------------------------|
| `file.read`        | Read files inside the **currently-open project root** via `tv.host.read(path)` or the Tier B envelope.   | Project root only. No `~/Documents`.             |
| `shell.exec`       | Run the `commands` declared in the manifest as Tier B subprocesses.                                      | Only the named commands, no arbitrary `system()`.|
| `webview.run`      | Instantiate a `WKWebView` with the plugin's HTML. Required for any Tier C contribution.                  | One WebView per contribution surface.            |
| `network.egress`   | Outbound network. Without this, Tier B children have no `PATH` to `curl`-like tools (the env is scrubbed) and Tier C webviews have all `<script src=>` outside the plugin folder blocked. | All hosts unless `network.allowlist` is also set. |
| `storage.global`   | Write `~/Library/Application Support/TextView/Plugins/<id>/data.json`.                                   | 10 MB cap.                                       |
| `storage.session`  | Per-session storage.                                                                                     | 10 MB cap per session.                           |
| `ui.sidebar`       | Contribute a sidebar section.                                                                            | One per `id`.                                    |
| `ui.viewmode`      | Contribute a view mode.                                                                                  |                                                  |
| `ui.menu`          | Add menu items.                                                                                          |                                                  |
| `ui.palette`       | Add command-palette entries.                                                                             |                                                  |
| `ui.keyboard`      | Bind keyboard shortcuts.                                                                                 | First-party shortcuts always win.                |
| `ui.statusbar`     | Add status-bar item.                                                                                     |                                                  |
| `ui.gitpanel`      | Add Git panel tab.                                                                                       |                                                  |
| `format.provide`   | Register a formatter.                                                                                    |                                                  |
| `search.provide`   | Register a find provider.                                                                                |                                                  |
| `render.ast`       | Hook the markdown AST pre-render.                                                                        | Tier C only, 100ms budget.                       |
| `url.handle`       | Register `textview://plugins/<id>/<verb>`.                                                              |                                                  |
| `walkthrough.verb` | Add walkthrough/script verbs.                                                                            |                                                  |
| `mcp.tool`         | Expose MCP tools to external agents.                                                                     | See §8.                                          |

**There is no `file.write` capability and no plan to add one.**
TextView is a viewer; plugins are viewer extensions. If a plugin
wants to write a file, it does it via shell-out (`shell.exec`) and
the user sees the command in the audit log.

**There is no `binary.load` capability**; native Swift bundles are
not loadable.

### 5.2 Granting and revoking

- **Grant store:** `~/Library/Application Support/TextView/plugin-grants.json`
  via `JSONFileStore`. Per plugin id:

  ```json
  {
    "com.example.tv.proto": {
      "grantedAt": "2026-05-17T12:00:00Z",
      "grantedFor": ["shell.exec", "mcp.tool"],
      "grantedHostVersion": "0.8.1",
      "manifestHash": "sha256:..."
    }
  }
  ```

- **Re-prompt triggers:**
  - The manifest's `capabilities` set grows or changes — even if the
    user previously said "always" for the old set.
  - The plugin's `manifestHash` differs from the stored hash AND
    capabilities differ. (Adding a static file doesn't re-prompt;
    adding a new contribution with a new capability does.)
  - The user clicks "Revoke" in Settings → Plugins.
- **Granularity:** per-plugin, whole capability set. Not per-tool,
  not per-call. Matches what the user can usefully reason about.

### 5.3 First-install prompt UX

Non-modal panel:

```
┌─────────────────────────────────────────────────────────────────┐
│  Install "Protocol Buffer Viewer" (1.2.3)?                      │
│  by Example Co. — example.com/proto-plugin                      │
│                                                                 │
│  This plugin would be able to:                                  │
│    • Run a bundled command-line tool (shell.exec)               │
│    • Expose 2 MCP tools to local agents (mcp.tool)              │
│    • Add 1 view mode for .proto files (ui.viewmode)             │
│    • Add 1 menu item (ui.menu)                                  │
│                                                                 │
│  This plugin would NOT be able to:                              │
│    • Make network requests                                      │
│    • Read files outside the open project                        │
│    • Modify, delete, or rename any file                         │
│                                                                 │
│  Source: ~/.../Plugins/com.example.tv.proto/                    │
│                                                                 │
│  [ Install ]  [ Inspect ]  [ Cancel ]                           │
└─────────────────────────────────────────────────────────────────┘
```

"Inspect" opens the plugin folder in the file tree pane (read-only).

### 5.4 What the prompt deliberately does *not* say

- No promise that the plugin "is safe." We don't know.
- No "verified by TextView" badge. We don't run a review process.
- No "millions of installs." There is no marketplace.

The prompt tells the user **what the plugin can do**, not whether
they should trust it. That choice stays with the user.

### 5.5 Network-egress allowlist (optional refinement)

`network.egress` is binary in v1 (allow / deny). v2.1 should add a
manifest-declared host allowlist:

```json
"capabilities": ["network.egress"],
"networkAllowlist": ["api.example.com", "*.cdn.example.com"]
```

Enforcement for Tier C: a custom `WKURLSchemeHandler` on the
WebView's `WKWebViewConfiguration` rejects requests outside the
allowlist. For Tier B: harder (the subprocess can do whatever its
binary lets it). Document the limitation. The point is to make
egress *visible* in the manifest review, not to be a watertight
firewall.

### 5.6 Audit log

`~/Library/Logs/TextView/plugins-audit.jsonl`. One line per
capability-using event:

```json
{ "ts": "2026-05-17T12:34:56Z", "plugin": "com.example.tv.proto", "cap": "shell.exec", "command": "decode-proto", "args_hash": "sha256:abc...", "invocation": "uuid", "exit": 0, "duration_ms": 42 }
```

Surfaced in Settings → Plugins → "Activity." Same shape as the MCP
audit log (`docs/AUTOMATION.md` §8), and the two can share a viewer
UI.

---

## 6. Sample plugins (worked examples)

Three complete, ready-to-implement examples covering all three
tiers. Each lists every file the plugin would ship.

### 6.1 Sample plugin 1 — `com.example.tv.solarized` (Tier A, theme)

**Goal:** a Solarized Light/Dark theme pair.

**Files:**
```
com.example.tv.solarized/
├── plugin.json
├── solarized-light.theme.json
├── solarized-dark.theme.json
└── markdown.css           (optional — rendered markdown styles)
```

**plugin.json:**
```json
{
  "id": "com.example.tv.solarized",
  "name": "Solarized Themes",
  "version": "1.0.0",
  "author": { "name": "Example Co." },
  "license": "MIT",
  "hostVersion": ">=0.7 <0.9",
  "manifestVersion": 1,
  "capabilities": [],
  "contributes": [
    {
      "type": "theme",
      "id": "solarized-light",
      "label": "Solarized Light",
      "appearance": "light",
      "sourcePath": "solarized-light.theme.json",
      "markdownCSSPath": "markdown.css"
    },
    {
      "type": "theme",
      "id": "solarized-dark",
      "label": "Solarized Dark",
      "appearance": "dark",
      "sourcePath": "solarized-dark.theme.json",
      "markdownCSSPath": "markdown.css"
    }
  ]
}
```

**solarized-light.theme.json (excerpt):**
```json
{
  "background": "#fdf6e3",
  "foreground": "#586e75",
  "selection": "#eee8d5",
  "captures": {
    "comment":          { "fg": "#93a1a1", "italic": true },
    "keyword":          { "fg": "#859900" },
    "string":           { "fg": "#2aa198" },
    "number":           { "fg": "#d33682" },
    "function":         { "fg": "#268bd2" },
    "type":             { "fg": "#b58900" },
    "variable":         { "fg": "#586e75" },
    "operator":         { "fg": "#586e75" },
    "punctuation":      { "fg": "#93a1a1" }
  }
}
```

**Capabilities:** none. Pure data. Install prompt says:
"This plugin adds 2 themes."

**Host wiring:** `ThemeRegistry` reads `sourcePath` and
`markdownCSSPath` lazily on theme selection. The existing
`SyntaxTheme.named(_:)` (per `HACKABILITY.md` §"Add a new theme")
extends from a closed enum to a registry lookup; for now, host
treats plugin themes as `.custom(id:)` and synthesises a
`SyntaxTheme` from the JSON at activation time.

### 6.2 Sample plugin 2 — `com.example.tv.proto` (Tier B, shell-out)

**Goal:** for `.proto` and `.pb` files, offer a "Decoded" view that
shells out to `protoc --decode_raw` to render a structured view.

**Files:**
```
com.example.tv.proto/
├── plugin.json
├── bin/decode-proto                 (POSIX shell script, executable)
├── icons/proto.svg
└── README.md
```

**plugin.json:**
```json
{
  "id": "com.example.tv.proto",
  "name": "Protocol Buffer Viewer",
  "version": "1.0.0",
  "author": { "name": "Example Co.", "url": "https://example.com" },
  "license": "Apache-2.0",
  "homepage": "https://github.com/example/tv-proto",
  "hostVersion": ">=0.7 <0.9",
  "manifestVersion": 1,
  "capabilities": ["shell.exec", "ui.viewmode", "ui.menu", "mcp.tool", "format.provide"],
  "contributes": [
    {
      "type": "file_icon",
      "match": { "extensions": [".proto", ".pb"] },
      "icon": "icons/proto.svg",
      "displayName": "Protocol Buffer"
    },
    {
      "type": "view_mode",
      "id": "proto-decoded",
      "label": "Decoded",
      "fileTypes": [".proto", ".pb"],
      "provider": { "tier": "B", "command": "decode-proto", "outputFormat": "text" },
      "fallback": "hex"
    },
    {
      "type": "formatter",
      "id": "proto-decoded",
      "label": "protoc decode",
      "fileTypes": [".proto", ".pb"],
      "trigger": "manual",
      "action": { "tier": "B", "command": "decode-proto" }
    },
    {
      "type": "menu_item",
      "id": "decode-here",
      "title": "Decode This .proto",
      "where": ["menu.plugins", "ctx.file"],
      "enabledWhen": "currentURL.pathExtension == 'proto' || currentURL.pathExtension == 'pb'",
      "action": { "tier": "B", "command": "decode-proto" }
    }
  ],
  "mcpTools": [
    {
      "id": "decode_proto",
      "description": "Decode a .proto or .pb file with protoc --decode_raw.",
      "schema": {
        "type": "object",
        "properties": {
          "path": { "type": "string" },
          "format": { "type": "string", "enum": ["text", "json"], "default": "text" }
        },
        "required": ["path"]
      },
      "action": { "tier": "B", "command": "decode-proto" }
    }
  ]
}
```

**bin/decode-proto (POSIX shell):**
```sh
#!/usr/bin/env sh
# stdin: JSON envelope; stdout: decoded text.
set -eu

ENVELOPE="$(cat)"
INPUT_PATH="$(printf '%s' "$ENVELOPE" | /usr/bin/python3 -c 'import json,sys; e=json.load(sys.stdin); print(e["context"]["url"])')"

# Strip file://
INPUT_PATH="${INPUT_PATH#file://}"

# Locate protoc on PATH (only /usr/bin:/bin:/usr/local/bin available).
if ! command -v protoc >/dev/null 2>&1; then
    echo "protoc not found. Install with: brew install protobuf" >&2
    exit 64
fi

# --decode_raw doesn't need a .proto schema; works for binary .pb files.
exec protoc --decode_raw < "$INPUT_PATH"
```

**Capabilities:** `shell.exec` (mandatory for Tier B),
`ui.viewmode`, `ui.menu`, `mcp.tool`, `format.provide`. The install
prompt enumerates all four.

**Host wiring:** `ViewModeRegistry` knows that opening `.proto`
files with mode `proto-decoded` selected means: spawn
`bin/decode-proto`, pipe in the envelope, render the stdout as a
plain-text view (host-owned text container). `MCPToolRegistry`
exposes `tv__com_example_tv_proto__decode_proto` (see §8).

### 6.3 Sample plugin 3 — `com.example.tv.dot` (Tier C, WebView)

**Goal:** render `.dot` (Graphviz) files using a bundled
`viz.standalone.js` (the Emscripten-compiled Graphviz library).

**Files:**
```
com.example.tv.dot/
├── plugin.json
├── view.html
├── view.js
├── viz.standalone.js        (vendored Graphviz, ~1 MB)
├── style.css
└── icons/dot.svg
```

**plugin.json:**
```json
{
  "id": "com.example.tv.dot",
  "name": "Graphviz Viewer",
  "version": "1.0.0",
  "author": { "name": "Example Co." },
  "license": "MIT",
  "hostVersion": ">=0.8 <0.9",
  "manifestVersion": 1,
  "capabilities": ["webview.run", "ui.viewmode", "ui.menu"],
  "contributes": [
    {
      "type": "file_icon",
      "match": { "extensions": [".dot", ".gv"] },
      "icon": "icons/dot.svg",
      "displayName": "Graphviz"
    },
    {
      "type": "view_mode",
      "id": "dot-rendered",
      "label": "Rendered",
      "fileTypes": [".dot", ".gv"],
      "provider": { "tier": "C", "entry": "view.html" },
      "fallback": "source"
    },
    {
      "type": "menu_item",
      "id": "export-svg",
      "title": "Export as SVG…",
      "where": ["ctx.tab"],
      "enabledWhen": "viewMode == 'dot-rendered'",
      "action": { "tier": "C", "entry": "view.html", "function": "exportSVG" }
    }
  ]
}
```

**view.html:**
```html
<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <link rel="stylesheet" href="style.css">
    <script src="viz.standalone.js"></script>
    <script src="view.js" defer></script>
  </head>
  <body>
    <div id="graph"></div>
  </body>
</html>
```

**view.js:**
```js
(async () => {
  // tv.js is auto-injected by the host as a user script.
  const input = await tv.host.getInput();   // { encoding: "utf8", text: "digraph { a -> b }" }
  const viz = new Viz();
  try {
    const svg = await viz.renderString(input.text);
    document.getElementById("graph").innerHTML = svg;
  } catch (err) {
    document.body.innerHTML = `<pre class="err">${escapeHtml(String(err))}</pre>`;
    tv.host.notify("error", { message: String(err) });
  }
})();

function escapeHtml(s) {
  return s.replace(/[<>&"]/g, c => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;" }[c]));
}

// Optional: an action the host can call back into.
window.exportSVG = async () => {
  const svg = document.getElementById("graph").innerHTML;
  await tv.host.invokeCommand("save_dialog", { suggested: "graph.svg", contents: svg });
};
```

**Capabilities:** `webview.run`, `ui.viewmode`, `ui.menu`. No
`network.egress` — Graphviz is vendored. No `file.read` — the host
hands `view.js` the input via `tv.host.getInput()`.

**Host wiring:** `ViewModeRegistry` knows that
`com.example.tv.dot/view.html` is the entry. When the user opens a
`.dot` file and `Rendered` is selected, the host instantiates a
`WKWebView` pointing at the plugin folder, injects `tv.js`, sets
the WebView's `WKWebViewConfiguration` to deny all navigation
outside the plugin folder, and loads `view.html`.

---

## 7. Plugin host — code sketches

This section is a sketch, not implementation. The shapes are
intended to be small and Swift-idiomatic; treat them as a starting
point.

### 7.1 Module placement (per `HACKABILITY.md` boundaries)

```
ViewerKit/
  PluginManifest.swift             — pure types, no logic
  Capability.swift                 — capability enum
  PluginID.swift                   — newtype
  PluginContribution.swift         — contribution enum cases

ViewerCore/
  Plugin/PluginRegistry.swift      — load, validate, register
  Plugin/PluginHost.swift          — Tier B / Tier C dispatch
  Plugin/PluginPermissionStore.swift — wraps JSONFileStore
  Plugin/PluginAudit.swift         — jsonl writer
  Plugin/SubprocessRunner.swift    — Tier B
  Plugin/SemverRange.swift         — vendored ~200 LOC
  Plugin/ContributionRegistries.swift — Theme/Icon/ViewMode/.../MCPTool

ViewerUI/
  PluginIntegration/SidebarPlugins.swift
  PluginIntegration/ViewModePlugins.swift
  PluginIntegration/WebViewPluginViewController.swift  (NSViewControllerRepresentable per HACKABILITY)

MarkdownViewer/
  PluginMenuIntegration.swift      — top-level Plugins menu
  PluginInstallDelegate.swift      — drag-drop handler
```

`ViewerKit` holds types. `ViewerCore` holds the pure logic
(manifest parsing, semver matching, subprocess spawning, audit
writing). `ViewerUI` holds the SwiftUI / AppKit integration. The
executable target only wires menus and drag-drop.

### 7.2 `PluginManifest` (ViewerKit)

```swift
public struct PluginManifest: Codable, Sendable {
    public let id: PluginID
    public let name: String
    public let version: SemVer
    public let author: Author
    public let homepage: URL?
    public let license: String?
    public let hostVersion: SemVerRange
    public let manifestVersion: Int        // must == 1 in v1
    public let capabilities: Set<Capability>
    public let contributes: [Contribution]
    public let mcpTools: [MCPToolDecl]?
    public let signature: Signature?

    public struct Author: Codable, Sendable {
        public let name: String
        public let url: URL?
        public let email: String?
    }

    public struct Signature: Codable, Sendable {
        public let algorithm: String       // "ed25519"
        public let publicKey: String       // base64
        public let signature: String       // base64
    }
}

public struct PluginID: Codable, Sendable, Hashable, RawRepresentable {
    public let rawValue: String
    public init?(rawValue: String) {
        // [a-zA-Z0-9.-]+ and contains at least one dot
        guard rawValue.range(of: #"^[A-Za-z0-9][A-Za-z0-9.\-]*\.[A-Za-z0-9.\-]+$"#,
                             options: .regularExpression) != nil
        else { return nil }
        self.rawValue = rawValue
    }
}

public enum Capability: String, Codable, Sendable, CaseIterable {
    case fileRead          = "file.read"
    case shellExec         = "shell.exec"
    case webviewRun        = "webview.run"
    case networkEgress     = "network.egress"
    case storageGlobal     = "storage.global"
    case storageSession    = "storage.session"
    case uiSidebar         = "ui.sidebar"
    case uiViewmode        = "ui.viewmode"
    case uiMenu            = "ui.menu"
    case uiPalette         = "ui.palette"
    case uiKeyboard        = "ui.keyboard"
    case uiStatusbar       = "ui.statusbar"
    case uiGitpanel        = "ui.gitpanel"
    case formatProvide     = "format.provide"
    case searchProvide     = "search.provide"
    case renderAST         = "render.ast"
    case urlHandle         = "url.handle"
    case walkthroughVerb   = "walkthrough.verb"
    case mcpTool           = "mcp.tool"
}

public enum Contribution: Codable, Sendable {
    case theme(ThemeContribution)
    case fileIcon(FileIconContribution)
    case treesitterQueries(TreeSitterQueriesContribution)
    case lspDiscovery(LSPDiscoveryContribution)
    case crTemplate(CRTemplateContribution)
    case sidebarSection(SidebarSectionContribution)
    case viewMode(ViewModeContribution)
    case formatter(FormatterContribution)
    case menuItem(MenuItemContribution)
    case keyboardShortcut(KeyboardShortcutContribution)
    case paletteCommand(PaletteCommandContribution)
    case walkthroughVerb(WalkthroughVerbContribution)
    case statusBarItem(StatusBarItemContribution)
    case renderFilter(RenderFilterContribution)
    case findProvider(FindProviderContribution)
    case urlHandler(URLHandlerContribution)
    case gitPanelTab(GitPanelTabContribution)

    // Custom Codable: dispatch on `type` discriminator.
}
```

Each `XxxContribution` is a small struct with the fields named in §2.
Decoding uses a discriminator key (`type`) at the outer level; the
custom `Codable` walks the discriminator and delegates.

### 7.3 `PluginRegistry` (ViewerCore)

```swift
public final class PluginRegistry {
    private let pluginsDir: URL
    private let grants: PluginPermissionStore
    private let hostVersion: SemVer
    private(set) public var loaded: [PluginID: LoadedPlugin] = [:]

    // Registries — one per contribution point. Each is a thin wrapper
    // around a [PluginID: [Contribution]] map that emits a Combine
    // publisher on change.
    public let themes      = ThemeRegistry()
    public let icons       = IconRegistry()
    public let viewModes   = ViewModeRegistry()
    public let formatters  = FormatterRegistry()
    public let sidebars    = SidebarSectionRegistry()
    public let menus       = MenuContributionRegistry()
    public let keys        = KeyboardRegistry()
    public let palette     = CommandRegistry()
    public let walkthrough = WalkthroughVerbRegistry()
    public let crTemplates = CRTemplateRegistry()
    public let lsp         = LSPDiscoveryRegistry()
    public let urls        = URLHandlerRegistry()
    public let queries     = TreeSitterQueryRegistry()
    public let renderFilt  = RenderFilterRegistry()
    public let finders     = FindProviderRegistry()
    public let statusBar   = StatusBarItemRegistry()
    public let gitPanel    = GitPanelTabRegistry()
    public let mcpTools    = MCPToolRegistry()

    public init(pluginsDir: URL, grants: PluginPermissionStore, hostVersion: SemVer) {
        self.pluginsDir = pluginsDir
        self.grants = grants
        self.hostVersion = hostVersion
    }

    public func loadAll() throws -> LoadReport {
        var report = LoadReport()
        let folders = try FileManager.default.contentsOfDirectory(at: pluginsDir,
                                                                  includingPropertiesForKeys: nil)
        for folder in folders where folder.hasDirectoryPath {
            do {
                let plugin = try loadOne(folder: folder)
                loaded[plugin.manifest.id] = plugin
                report.loaded.append(plugin.manifest.id)
            } catch let e as LoadError {
                report.failed.append((folder, e))
            }
        }
        return report
    }

    public func loadOne(folder: URL) throws -> LoadedPlugin {
        let manifestURL = folder.appendingPathComponent("plugin.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        guard manifest.manifestVersion == 1 else {
            throw LoadError.unsupportedManifestVersion(manifest.manifestVersion)
        }
        guard manifest.hostVersion.contains(hostVersion) else {
            throw LoadError.hostVersionMismatch(required: manifest.hostVersion, actual: hostVersion)
        }

        let manifestHash = SHA256.hash(data: data).hexString
        let grantState = grants.state(for: manifest.id,
                                      expecting: manifest.capabilities,
                                      manifestHash: manifestHash)
        switch grantState {
        case .granted:
            break
        case .needsGrant, .needsRegrant:
            throw LoadError.needsUserGrant(manifest.id, requested: manifest.capabilities)
        }

        // Validate each contribution against the granted capability set.
        for contribution in manifest.contributes {
            let required = contribution.requiredCapabilities
            guard required.isSubset(of: manifest.capabilities) else {
                throw LoadError.contributionExceedsCapabilities(contribution, required)
            }
        }

        // Register.
        for contribution in manifest.contributes {
            registerContribution(contribution, plugin: manifest.id, folder: folder)
        }
        for tool in manifest.mcpTools ?? [] {
            mcpTools.register(tool, plugin: manifest.id, folder: folder)
        }

        return LoadedPlugin(manifest: manifest, folder: folder, manifestHash: manifestHash)
    }

    public func unload(_ id: PluginID) {
        for registry in allRegistries { registry.dropAll(forPlugin: id) }
        loaded[id] = nil
    }
}
```

### 7.4 `PluginHost` (Tier B + Tier C dispatch — ViewerCore)

```swift
public final class PluginHost {
    private let registry: PluginRegistry
    private let audit: PluginAudit

    /// Run a Tier-B command, returning stdout.
    public func runShell(plugin: PluginID,
                         command: String,
                         envelope: PluginEnvelope) async throws -> PluginResult {
        guard let p = registry.loaded[plugin] else { throw PluginError.unknownPlugin(plugin) }
        guard p.manifest.capabilities.contains(.shellExec) else { throw PluginError.missingCapability(.shellExec) }
        guard let cmd = p.manifest.commandPaths[command] else { throw PluginError.unknownCommand(command) }

        let exe = p.folder.appendingPathComponent(cmd)
        try ensureExecutable(exe)

        let invocation = UUID().uuidString
        let start = Date()

        let result = try await SubprocessRunner.run(
            executable: exe,
            argv: ["--invocation-id", invocation],
            stdin: try JSONEncoder().encode(envelope),
            env: scrubbedEnv(plugin: p, invocation: invocation),
            cwd: p.folder,
            timeout: p.manifest.timeoutForCommand(command) ?? .seconds(5),
            stdoutCap: 16 * 1024 * 1024,
            memoryCap: 512 * 1024 * 1024
        )

        audit.log(plugin: plugin, capability: .shellExec, command: command,
                  argsHash: envelope.argsHash, invocation: invocation,
                  exit: result.exitCode, duration: Date().timeIntervalSince(start))

        if result.exitCode != 0 {
            throw PluginError.commandFailed(plugin: plugin, command: command,
                                            exit: result.exitCode, stderr: result.stderr)
        }
        return PluginResult(stdout: result.stdout, stderr: result.stderr)
    }

    /// Create a WKWebView for a Tier-C contribution.
    /// (UI module owns the actual instantiation; this returns a config.)
    public func webViewConfig(plugin: PluginID, entry: String) throws -> PluginWebViewConfig {
        guard let p = registry.loaded[plugin] else { throw PluginError.unknownPlugin(plugin) }
        guard p.manifest.capabilities.contains(.webviewRun) else { throw PluginError.missingCapability(.webviewRun) }
        let entryURL = p.folder.appendingPathComponent(entry)
        guard FileManager.default.fileExists(atPath: entryURL.path) else {
            throw PluginError.missingEntry(entry)
        }
        return PluginWebViewConfig(
            pluginFolder: p.folder,
            entry: entryURL,
            grantedCapabilities: p.manifest.capabilities,
            bridgeShim: bundledBridgeShimJS,
            allowedNetworkHosts: p.manifest.networkAllowlist ?? []
        )
    }
}
```

### 7.5 `WebViewPluginViewController` (ViewerUI)

The UI module instantiates a `WKWebView` from the config. Following
`HACKABILITY.md` LESSONS, it uses `NSViewControllerRepresentable`
(not `NSViewRepresentable`) and never wraps the WebView in an
intermediate `NSView` container.

```swift
final class PluginWebViewController: NSViewController, WKScriptMessageHandlerWithReply {
    let config: PluginWebViewConfig
    let host: PluginHost
    var webView: WKWebView!

    override func loadView() {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(PluginURLSchemeHandler(folder: config.pluginFolder),
                                forURLScheme: "tv-plugin")
        cfg.userContentController.add(self, contentWorld: .page, name: "tv")
        cfg.userContentController.addUserScript(
            WKUserScript(source: config.bridgeShim,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true)
        )
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        cfg.defaultWebpagePreferences = prefs

        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.setValue(false, forKey: "drawsBackground")
        self.view = webView

        let entryURL = URL(string: "tv-plugin:///\(config.entry.lastPathComponent)")!
        webView.load(URLRequest(url: entryURL))
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        Task {
            do {
                let reply = try await dispatchBridgeCall(message.body)
                replyHandler(reply, nil)
            } catch {
                replyHandler(nil, String(describing: error))
            }
        }
    }
}
```

### 7.6 The bridge shim (`tv.js`, injected as a user script)

```js
(function() {
  if (window.tv) return;
  const pending = new Map();
  let nextId = 1;

  function call(method, params) {
    return new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, { resolve, reject });
      window.webkit.messageHandlers.tv.postMessage({ id, method, params })
        .then(result => { resolve(result); pending.delete(id); })
        .catch(err => { reject(err); pending.delete(id); });
    });
  }

  window.tv = {
    host: {
      getInput:   ()              => call("getInput",   {}),
      getContext: ()              => call("getContext", {}),
      read:       (path)          => call("read",       { path }),
      shell:      (cmd, args)     => call("shell",      { command: cmd, args }),
      notify:     (event, data)   => call("notify",     { event, data }),
      invokeCommand:(id, args)    => call("invokeCommand", { id, args }),
      storage: {
        get:    (k)      => call("storage.get",    { key: k }),
        set:    (k, v)   => call("storage.set",    { key: k, value: v }),
        delete: (k)      => call("storage.delete", { key: k }),
      },
      mcp: {
        respond: (id, result) => call("mcp.respond", { id, result }),
      },
    },
  };
})();
```

### 7.7 ViewerCore pure-logic vs ViewerUI integration

The boundary stays exactly where `HACKABILITY.md` puts it.
**ViewerCore** holds:

- `PluginRegistry` (loading, validation, registry maps).
- `PluginHost` (Tier B dispatch — subprocess + audit).
- `SubprocessRunner` (pure logic — spawns Process, no AppKit).
- All registries (`ThemeRegistry`, `ViewModeRegistry`, ...).
- `SemverRange`, `PluginAudit`, `PluginPermissionStore`.

**ViewerUI** holds:

- `PluginWebViewController` (uses `WKWebView`, so it must live where
  AppKit imports are allowed).
- `SidebarPlugins` (consumes `SidebarSectionRegistry` and renders).
- `ViewModePlugins` (consumes `ViewModeRegistry` and renders).
- The drag-drop install gesture.

**MarkdownViewer (exe)** holds:

- `PluginMenuIntegration` (top-level `Plugins` menu builder, consumes
  `MenuContributionRegistry`).
- The URL-scheme dispatch into `URLHandlerRegistry`.
- The first-launch + change-of-capabilities prompt.

Tests against ViewerCore can run headlessly (per
`HACKABILITY.md` §Module boundaries). Tests that exercise
WKWebView need a windowed test target. Both exist today; this just
respects the line.

---

## 8. MCP intersection

Recap of `docs/AUTOMATION.md`: TextView's v1 automation surface is a
local MCP server inside the app, bound to a Unix domain socket at
`~/Library/Application Support/TextView/mcp.sock`. Tools are registered
against an `AutomationHost` protocol that `DocumentModel` implements.
Tool namespace is flat: `open_path`, `get_state`, etc.

Plugins extend the MCP surface. The model:

### 8.1 Plugin declares tools in the manifest

```json
"capabilities": ["shell.exec", "mcp.tool"],
"mcpTools": [
  {
    "id": "decode_proto",
    "description": "Decode a .proto or .pb file with protoc --decode_raw.",
    "schema": {
      "type": "object",
      "properties": { "path": { "type": "string" } },
      "required": ["path"]
    },
    "action": { "tier": "B", "command": "decode-proto" }
  }
]
```

### 8.2 Host registers the tool under a namespaced name

To avoid collision with built-in MCP tools and across plugins, the
host registers each plugin tool as
`plugin__<sanitized-plugin-id>__<tool-id>`. So
`com.example.tv.proto` + `decode_proto` becomes
`plugin__com_example_tv_proto__decode_proto`.

Built-in tools keep flat names (`open_path`, `get_state`). The
`plugin__` prefix is reserved for plugins. Two plugins can declare
the same tool `id` — the namespacing keeps them distinct.

### 8.3 The MCP server routes the call

```
MCP client (Claude Code, Cursor, ...)
        │
        ▼ JSON-RPC over Unix socket
  MCPServer.handleToolCall(name, args)
        │
        ├─ if name starts with "plugin__":
        │    plugin = parsePluginID(name)
        │    toolID = parseToolID(name)
        │    decl   = registry.mcpTools[plugin, toolID]
        │    result = await PluginHost.runTool(plugin, toolID, args)
        │    return result
        │
        └─ else (built-in tool):
             dispatch to AutomationHost as in docs/AUTOMATION.md §7
```

`PluginHost.runTool` is a tiny dispatcher: Tier B → wrap args in the
envelope, run the command, parse stdout against `resultSchema`. Tier
C → instantiate a (possibly cached, headless) WebView, call the
declared entry function via `evaluateJavaScript`, await the response
via the bridge.

### 8.4 Why route MCP calls through the plugin runtime instead of the host

Two reasons:

1. **Single capability model.** If a plugin can do X via the
   `Plugins` menu, an MCP client can do X. No second permission
   axis. Audit log captures both paths uniformly.
2. **One implementation of "decode proto."** The Tier B script is
   reused whether the caller is a user click, a walkthrough step, or
   an MCP call. The manifest binds id → action once.

### 8.5 Capability `mcp.tool` is required separately

A plugin that lists no `mcp.tool` capability cannot expose MCP tools
even if it ships `mcpTools` in the manifest — the host validates and
rejects the manifest. The point: a user installing a sidebar widget
should not silently grant external-agent access. Two capabilities,
two grant lines, two audit trails.

### 8.6 What about resources / prompts?

MCP also supports *resources* (read-only URIs) and *prompts* (
templated agent instructions). Plugins **may not** add resources or
prompts in v1. Reason: resources expose URIs that an agent can read
unbounded, and prompts are tiny influence vectors that a malicious
plugin could use to redirect agent behaviour. We keep plugins to the
*tool* surface, where the host can audit each call.

### 8.7 Notifications

A plugin tool **cannot** publish MCP notifications in v1.
Notifications go from host → client only, and the host owns the
notification vocabulary (`tabChanged`, `fileChanged`, etc.). A
plugin that wants to push state to MCP clients does it by exposing
a `subscribe_<thing>` tool that holds a long-running connection — or
just by exposing a `get_<thing>` tool and letting the client poll.
Phase 2.1 if a real use case appears.

---

## 9. Sandboxing + safety

### 9.1 What plugins CAN do

- Read files within the open project root (`file.read` cap).
- Run their bundled commands as a subprocess with a scrubbed env
  (`shell.exec` cap).
- Render in a WebView with a custom URL scheme that only resolves
  inside the plugin folder (`webview.run` cap).
- Make outbound network requests, but only with `network.egress`
  cap, only after the user grants it, and only to allowlisted hosts
  if the manifest declares one.
- Read/write their own per-plugin / per-session JSON storage.
- Contribute UI to declared surfaces (sidebar, view mode, menu,
  palette, status bar, Git panel tab).
- Expose MCP tools to local agents.

### 9.2 What plugins CANNOT do

- Write, modify, delete, rename, or move any file. (There's no
  `file.write` capability; the host doesn't expose `tv.host.write`.)
- Read files outside the open project root via host APIs. (A
  subprocess can technically read anything its uid can — see
  §9.4 — but `tv.host.read` enforces the project-root scope.)
- Bind a network listener.
- Spawn arbitrary subprocesses outside the declared `commands`.
- Load native dylibs into the host process.
- Touch other plugins' storage, WebViews, or contributions.
- Influence first-party shortcuts.
- Add MCP resources or prompts.
- Modify the menu bar outside the `Plugins` menu and declared
  context menus.
- Change the URL scheme outside `textview://plugins/<id>/`.
- Run on background launch (no `onLoad` daemon hook).

### 9.3 Resource limits (recap)

| Resource              | Tier B                                 | Tier C                                          |
|-----------------------|----------------------------------------|-------------------------------------------------|
| Wall-clock per call   | 5s default, up to 30s by manifest      | None per call; 100ms budget on render filters   |
| Memory                | `RLIMIT_AS = 512 MB` best-effort       | WKWebView default + 50 MB postMessage cap       |
| Stdout / message      | 16 MB cap                              | 50 MB message bus cap                           |
| Concurrency           | 4 in-flight across all plugins         | One WebView per contribution surface            |
| Network               | Egress only with cap                   | Egress only with cap                            |
| Filesystem            | scrubbed env, cwd = plugin folder      | URL scheme handler limits to plugin folder      |

### 9.4 The honest residual risk

A Tier B subprocess is `posix_spawn`ed as the user. It inherits the
user's uid. macOS App Sandbox (if we ever ship sandboxed — currently
we don't) would constrain it; outside the sandbox, the subprocess can
`open(2)` anything the user can. The mitigations:

- We scrub the env so the subprocess doesn't inherit credentials.
- We restrict `PATH` to system binaries — but the subprocess's own
  binary can ignore `PATH`.
- The `shell.exec` capability requires user grant.
- The audit log captures every invocation.

Realistically, this is the same trust the user gives any command-line
tool they `brew install`. The plugin system makes the surface
visible (manifest review + audit log) and makes the invocation
attributable. It does not make plugins safe to run untrusted.

We say this out loud in the install prompt's small-print line:
"Plugins run as you. We restrict what TextView's APIs let them do,
but we cannot prevent them from doing anything macOS lets your user
account do." That's the honest version.

### 9.5 Crash isolation

- **Tier A:** no runtime. Nothing to crash.
- **Tier B:** subprocess. Crash, infinite loop, panic — exit code
  != 0, SIGKILL on timeout. Host falls back to a built-in mode or
  shows an error banner. No host crash.
- **Tier C:** `WKWebView` runs in `com.apple.WebKit.WebContent`,
  which is process-isolated. A renderer crash kills the WebContent
  process; the host catches `webView(_:webContentProcessDidTerminate:)`
  and shows "Plugin crashed — Reload?" Plugin can't take down the
  host this way. (It can crash the host by exhausting bridge
  bandwidth, which is why we cap at 50 MB.)

---

## 10. Distribution + installation

### 10.1 The chosen path for v1: drag-drop a `.tvplugin` folder

- A plugin is a folder named like `com.example.tv.proto.tvplugin/`
  (or just `proto.tvplugin/`).
- The folder contains `plugin.json` at its root.
- The user drags the folder onto:
  - the TextView dock icon, OR
  - the main window, OR
  - the Plugins settings pane.
- The host triggers the install flow: read manifest, validate,
  show the §5.3 prompt, on accept copy the folder into
  `~/Library/Application Support/TextView/Plugins/<id>/`.

`.tvplugin` is just a folder. It can also be a zip with that
extension that the host unpacks. We pick **folder, not bundle and
not zip** for v1: bundles want `Info.plist`-style metadata that
duplicates our manifest; zip adds an unzip step. Folder is the
minimum-friction shape, and `Finder` shows it as a folder, which is
*good* — users can inspect the contents before installing.

### 10.2 Uninstall

Settings → Plugins → "Uninstall" deletes the folder from
`~/Library/Application Support/TextView/Plugins/<id>/`. Per-plugin
storage is **kept** by default ("uninstalled" stays
"un-installed-but-data-remembered"); a checkbox "also delete saved
data" wipes the storage directory. Grants are removed.

### 10.3 What we are NOT doing in v1

- **No marketplace.** Same answer as v1.
- **No `tv plugin install <url>` CLI.** Curl-pipe-install is a
  footgun; the prompt-then-install ritual is the boundary that
  makes the security model legible.
- **No automatic update.** Plugin author ships a new version, user
  drags the new folder in; the existing install is replaced after
  a re-prompt if capabilities changed.
- **No code-signing requirement.** The manifest has an optional
  `signature` block (§4.1) that pins the manifest to an ed25519
  key. The host doesn't gate install on it in v1 — it just shows
  "signed by <key-fingerprint>" in the prompt if present.
  Phase 4+: optional "only install signed plugins" pref.
- **No Brew tap.** A user is welcome to publish a Brew formula that
  drops a plugin folder into the right place; we don't endorse a
  particular index.

### 10.4 Plugin conflicts

Two plugins claim the same `view_mode` for `.json`, or the same
file icon for `.proto`. v1 resolution:

- **Built-in always wins** for view modes that have a built-in.
- **Among plugins, last installed wins** by default — but the loser
  is *not* unloaded; it stays registered, just not the default.
- Settings → Plugins shows the conflict ("2 plugins claim .json
  view modes: built-in, com.x.json-tree") with a picker that lets
  the user choose.
- The picker writes a `defaultViewModeOverrides` map into
  `PreferencesStore` (extending the existing per-extension override
  shape that `DocumentModel` already carries).

For non-default contributions (palette entries, menu items), there
is no conflict — they all show up, distinguished by plugin name in
the UI.

---

## 11. Phased rollout

The plan is to ship the smallest useful thing, learn, then expand.
Each phase ships before the next is designed in detail.

### Phase 1 — Tier A only

**Scope:**
- Manifest loader (full schema, but only Tier A contribution types
  recognised — Tier B/C declarations rejected at parse time).
- Themes from JSON.
- File icons from JSON + PNG/SVG.
- LSP discovery rules.
- CR template packs.
- TreeSitter `.scm` query packs (additive to built-in queries).
- Per-plugin storage (`storage.global` only; sessions not wired
  yet).
- Drag-drop install.
- Settings → Plugins pane (list, enable/disable, uninstall, view
  log).
- Permission grant store (every Tier A plugin in v1 needs zero
  capabilities, so the grant flow is exercised but trivially).

**Out of scope this phase:** any code execution. No `shell.exec`,
no `webview.run`, no MCP tool registration.

**Exit criteria:** the three sample plugins' Tier A subsets (theme,
proto icon, dot icon) work end-to-end. Settings pane lists them.
Uninstall returns the registries to clean state.

### Phase 2 — Tier B

**Scope:**
- `SubprocessRunner` with scrubbed env, timeouts, stdout cap, audit
  log.
- Capabilities: `shell.exec`, `format.provide`, `search.provide`,
  `walkthrough.verb`, `ui.viewmode` (Tier B view modes that emit
  text/HTML).
- View mode registry consumed by `ContentView`.
- Formatter registry consumed by `Formatter`.
- Walkthrough verb registry consumed by `runScriptStep`.
- MCP tool registration for Tier B tools (requires AUTOMATION.md
  Phase 2-3 to have landed — see §8).
- First-install prompt (real, not trivial — Tier B always has
  `shell.exec`).
- Audit log viewer in Settings → Plugins → Activity.

**Exit criteria:** the `com.example.tv.proto` sample plugin runs
end-to-end. `protoc` is found on PATH, `.proto` files render in
"Decoded" mode, the MCP tool `plugin__com_example_tv_proto__decode_proto`
shows up in `tools/list` and runs.

### Phase 3 — Tier C

**Scope:**
- `PluginWebViewController` (NSViewControllerRepresentable).
- `WKWebView` config with custom URL scheme handler scoped to the
  plugin folder.
- `tv.js` bridge shim shipped as a host resource.
- Bridge methods: `getInput`, `getContext`, `read`, `shell`,
  `notify`, `invokeCommand`, `storage.*`, `mcp.respond`.
- Capabilities: `webview.run`, `render.ast`, `ui.gitpanel` (Tier C
  Git panel tabs), `ui.sidebar` (Tier C sidebar bodies).
- WebView-backed view modes consumed by `ContentView`.
- Render filter registry consumed by `MarkdownRenderedView`.

**Exit criteria:** the `com.example.tv.dot` sample plugin renders
Graphviz files in a tab. Cmd+K → "Export as SVG…" works. Crash of
the WebContent process re-spawns cleanly.

### Phase 4+ — Speculative

Anything past Phase 3 we'll re-evaluate from real usage. Likely
candidates (none committed):

- Network allowlist enforcement for Tier B (hard to do; may stay
  documentation-only).
- Persistent Tier B daemons (warm-pool) if subprocess spawn cost
  shows up in profiling.
- Full TreeSitter grammar loading (the `treesitter_language`
  contribution shape that's currently rejected).
- MCP resources / prompts from plugins (rejected in v1, may revisit).
- Optional code-signing enforcement.
- App Sandbox shipping mode + how plugins survive the transition.

---

## 12. Test strategy

### 12.1 Layers

| Layer                      | Lives in                                            | Tests                                                              |
|----------------------------|-----------------------------------------------------|--------------------------------------------------------------------|
| Manifest parsing           | `Tests/ViewerKitTests/PluginManifestTests.swift`    | Schema validation, version-range parsing, contribution discriminator dispatch, error messages with line/col. |
| Capability checks          | `Tests/ViewerCoreTests/PluginPermissionTests.swift` | Grant store reads/writes, re-prompt triggers, manifest-hash mismatch detection, contribution-capability subset check. |
| Subprocess runner          | `Tests/ViewerCoreTests/SubprocessRunnerTests.swift` | Timeout, memory cap, env scrubbing, stdout truncation, exit-code handling, signal handling, concurrency cap. |
| Registry behaviour         | `Tests/ViewerCoreTests/RegistryTests.swift`         | Register/unregister, conflict detection, ordering, Combine publisher fires on change. |
| Plugin loading             | `Tests/ViewerCoreTests/PluginRegistryTests.swift`   | Load happy path, malformed manifest, version mismatch, missing grant, multiple plugins, hot-reload. |
| WebView bridge             | `Tests/ViewerUITests/PluginWebViewBridgeTests.swift`| Async message round-trip, error paths, capability-enforced rejects, scheme handler scoping. |
| MCP plugin tool routing    | `Tests/MarkdownViewerTests/MCPPluginRoutingTests.swift` | `tools/list` returns plugin tools, namespacing, missing-capability rejects, dispatch to Tier B + Tier C. |
| Integration (fixture tree) | `Tests/IntegrationTests/PluginFixtureTests.swift`   | Boot the app pointed at `Tests/Fixtures/Plugins/`, assert three sample plugins load. |
| Audit log                  | `Tests/ViewerCoreTests/PluginAuditTests.swift`      | jsonl format, rotation, redaction of args >1KB. |

### 12.2 Fixture plugin tree

```
Tests/Fixtures/Plugins/
├── com.fixture.theme-pass/         (Tier A, valid)
├── com.fixture.icon-pass/          (Tier A, valid)
├── com.fixture.shell-pass/         (Tier B, valid, exits 0 with predictable JSON)
├── com.fixture.shell-timeout/      (Tier B, sleeps forever — tests timeout)
├── com.fixture.shell-overrun/      (Tier B, writes 100 MB to stdout — tests cap)
├── com.fixture.webview-pass/       (Tier C, hello-world)
├── com.fixture.webview-crash/      (Tier C, throws on load — tests recovery)
├── com.fixture.manifest-malformed/ (plugin.json with a syntax error)
├── com.fixture.manifest-bad-version/ (manifestVersion: 999)
├── com.fixture.cap-mismatch/       (contribution needs shell.exec but doesn't declare it)
└── com.fixture.host-mismatch/      (hostVersion: ">=99")
```

Each fixture plugin is a minimum viable repro — never more than
~30 lines of shipped code. They're checked in.

### 12.3 What integration tests assert (per fixture)

- **theme-pass:** loads. `ThemeRegistry.themes` contains its two
  themes. UI smoke shows the names in the theme picker.
- **shell-pass:** loads. Calling its formatter via
  `PluginHost.runShell` returns the expected stdout. Audit log has
  one entry.
- **shell-timeout:** loads. Calling its formatter raises
  `PluginError.commandFailed` with exit indicating SIGKILL. Wall-
  clock under 6s.
- **shell-overrun:** loads. Output is truncated at the cap; error
  surfaced.
- **webview-pass:** loads. `PluginWebViewController` instantiates,
  the WebView signals `loaded`, `tv.host.getContext()` returns the
  fixture URL.
- **webview-crash:** loads. WebContent terminates after entering
  view; host catches `webContentProcessDidTerminate`, marks the
  contribution as failed, shows banner.
- **manifest-malformed / bad-version / cap-mismatch / host-mismatch:**
  fail at load with precise error categories. Settings pane shows
  them in the "Failed to load" list.

### 12.4 Headless test invocation

The plugin host's pure-logic tests (ViewerCore) run under `swift
test` headlessly, no WindowServer. The WebView tests live in
`ViewerUITests` and need the same windowed test harness that
`SourceViewVisualRegressionTests` uses (see HACKABILITY.md). MCP
plugin-routing tests live in the executable target and use an
in-process MCP client, same shape as `docs/AUTOMATION.md` §9 plans
for `--script`.

### 12.5 Manual smoke before each phase ships

A short checklist in `MANUAL_TESTING.md` extension:

```
[ ] Drag a malformed-manifest fixture onto the app — see precise error.
[ ] Drag a valid theme plugin — see install prompt, accept, theme appears.
[ ] Drag a Tier B plugin — install prompt names "shell.exec", accept,
    open a fixture .proto file, "Decoded" mode renders.
[ ] Uninstall a Tier B plugin — view mode disappears, fallback resumes.
[ ] Re-install with bumped capabilities — re-prompt appears.
[ ] Open Settings → Plugins → Activity — last 50 invocations visible.
[ ] Kill protoc mid-call — error banner, no host hang.
[ ] Drag a Tier C plugin — webview renders, Cmd+K shows its commands.
[ ] Force-quit the WebContent process via Activity Monitor — host
    survives, "Reload?" appears.
```

---

## 13. Decisions made without asking (push back if any are wrong)

- **No native Swift bundle tier.** Removed even as a "phase 4
  maybe." Not in v1, not in v2, not later. (§3.4 has the full
  argument.)
- **Manifest format is JSON.** TOML / YAML / Swift-macro DSLs
  rejected. Already have `JSONDecoder` and `JSONFileStore`.
- **One folder per plugin, not a bundle.** Folder is inspectable in
  Finder; bundle metadata duplicates the manifest.
- **`.tvplugin` extension** (matches the TextView rename in
  `docs/AUTOMATION.md`). Old `.mdvplugin` (from v1 PLUGINS.md) is
  not back-compat — there are no shipped plugins to be back-compat
  with.
- **Drag-drop only for install.** No CLI install, no URL install.
- **No `file.write` capability.** Viewer-only. Matches the
  AUTOMATION.md hard invariant.
- **Plugin tools are namespaced under `plugin__` in MCP.** Built-in
  tools keep flat names.
- **Plugin tools can NOT publish MCP notifications, resources, or
  prompts.** Tools only.
- **`hostVersion` mismatch → loaded but disabled.** Not silently
  ignored.
- **Last-installed-wins** for plugin-vs-plugin conflicts, with a
  picker in Settings. Built-in always wins over plugins.
- **No code signing required to install.** Optional signature block
  is informational only in v1.
- **Phase 1 is Tier A only.** Three months of feedback on inert
  data plugins before we ship Tier B. Right ordering: shake out the
  manifest, registry, and UX with the safe tier before we open the
  shell-out surface.

---

## 14. Open questions for the next review pass

1. Should `network.egress` for Tier B be enforced via a packet
   filter (`pf` rules, per-process), or accepted as documentation-
   only? Packet filter requires root; documentation-only weakens
   the manifest review's promises. Lean: documentation-only +
   audit-log the launch.
2. `ui.gitpanel` — does the Git panel's `TabView` already
   support arbitrary tabs, or do we need to refactor it to consume a
   registry? (Read of `Sources/ViewerUI/GitPanelView.swift`
   needed to confirm.)
3. Should plugin storage be **encrypted at rest** (using Keychain
   for the key)? Default answer no — same trust posture as
   `PreferencesStore` — but mention if a plugin asks to encrypt.
4. App Intents for plugin actions: should the priority-10
   AppIntents from `docs/AUTOMATION.md` §7 *also* expose plugin
   commands? Lean: no in v1, defer to v2. App Intents has a small
   vocabulary and we want it stable.
5. Theme JSON schema — match what `SyntaxTheme` exposes today, or
   extend? Need a separate small design doc once Phase 1 starts
   (themed CSS for the rendered-markdown side is the messy part —
   see HACKABILITY.md §"Add a new theme" TODO about a CSS
   generator).
6. Should we ship a `tv plugin lint <folder>` CLI for plugin
   authors? Cheap (it's just the manifest validator), and it lets
   authors test offline. Lean: yes, in Phase 1 — same binary as
   the host with an extra subcommand.

---

## 15. Appendix — full contribution-type cross-reference

A single table tying §2 to the §7 registry and the existing
file-map from `HACKABILITY.md`:

| Contribution         | Tier(s) | Registry                  | Today's owner (per HACKABILITY)                              | Notes                              |
|----------------------|---------|---------------------------|--------------------------------------------------------------|------------------------------------|
| `theme`              | A       | `ThemeRegistry`           | `ViewerCore/Highlight/SyntaxTheme.swift`                     | Phase 1                            |
| `file_icon`          | A       | `IconRegistry`            | (file row icon resolver — new entry point)                   | Phase 1                            |
| `treesitter_queries` | A       | `TreeSitterQueryRegistry` | `ViewerCore/Highlight/Queries/`                              | Phase 1, additive only             |
| `lsp_discovery`      | A       | `LSPDiscoveryRegistry`    | (new — `ViewerCore/Project/LSPDiscovery.swift`)              | Phase 1, status-bar surface only   |
| `cr_template`        | A       | `CRTemplateRegistry`      | (assumed `ViewerCore/CR/CRTemplates.swift`)                  | Phase 1                            |
| `palette_command`    | A/B/C   | `CommandRegistry`         | `ViewerUI/CommandPalette.swift`                              | Phase 1 (A binds to built-in only) |
| `url_handler`        | A       | `URLHandlerRegistry`      | `MarkdownViewer/main.swift handleCustomURLScheme`            | Phase 1                            |
| `menu_item`          | A/B/C   | `MenuContributionRegistry`| `MarkdownViewer/main.swift` AppDelegate                      | Phase 1 (A only)                   |
| `keyboard_shortcut`  | A/B/C   | `KeyboardRegistry`        | `MarkdownViewer/main.swift`                                  | Phase 1 (A only)                   |
| `formatter`          | B       | `FormatterRegistry`       | `ViewerCore/Formatter.swift`                                 | Phase 2                            |
| `view_mode`          | B/C     | `ViewModeRegistry`        | `ViewerUI/ContentView.swift loadedView(for:)`                | Phase 2 (B), Phase 3 (C)           |
| `walkthrough_verb`   | B/C     | `WalkthroughVerbRegistry` | `MarkdownViewer/main.swift runScriptStep`                    | Phase 2                            |
| `search_provider`    | B/C     | `FindProviderRegistry`    | (new — `ViewerCore/Search/FindProviderRegistry.swift`)       | Phase 2 (B), Phase 3 (C)           |
| `sidebar_section`    | A/B/C   | `SidebarSectionRegistry`  | `ViewerUI/SidebarView.swift` + `SidebarModel.swift`          | Phase 1 (A static), Phase 2/3      |
| `status_bar_item`    | A/B/C   | `StatusBarItemRegistry`   | `ViewerUI/StatusBarView.swift`                               | Phase 1 (A), Phase 2/3             |
| `git_panel_tab`      | B/C     | `GitPanelTabRegistry`     | `ViewerUI/GitPanelView.swift` (assumed)                      | Phase 2/3                          |
| `render_filter`      | C       | `RenderFilterRegistry`    | `ViewerUI/MarkdownRenderedView.swift` + `Resources/markdown.js` | Phase 3                         |
| (mcp tools)          | B/C     | `MCPToolRegistry`         | `MarkdownViewer/Automation/MCPServer.swift` (per AUTOMATION) | Phase 2 (B), Phase 3 (C)           |

End of design.
