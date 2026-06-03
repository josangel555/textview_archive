# UAT Smokes — Plugins & MCP Automation

Durable user-acceptance smoke flows for the **automation / extensibility** surface:
the MCP stdio server (`--mcp-stdio`), the `--script` verb dispatcher, and the
subprocess-plugin host (discovery, capability grants, sidebar sections, audit log).

Each smoke deliberately chains **multiple features into one realistic flow** —
the value is in the seams between them (e.g. open-via-MCP → set-mode → find →
read-back, or grant-prompt → sidebar-render → revoke → re-prompt), not in any
single tool call.

## Source-of-truth references

| Surface | File |
| --- | --- |
| MCP server / lifecycle | `Sources/ViewerCore/Automation/MCPServer.swift` |
| MCP tool catalog (10 v1 tools) | `Sources/ViewerCore/Automation/MCPToolCatalog.swift` |
| MCP framing (Content-Length JSON-RPC) | `Sources/ViewerCore/Automation/MCPFraming.swift` |
| MCP launch / `.prohibited` policy | `Sources/MarkdownViewer/main.swift` (`startMCPServer`, `policy`) |
| Script verbs | `Sources/ViewerUI/Automation/ScriptVerbDispatch.swift` |
| Plugin discovery / load / grant gate | `Sources/ViewerCore/Plugins/PluginRegistry.swift` |
| Plugin subprocess host (Tier B) | `Sources/ViewerCore/Plugins/PluginSubprocessHost.swift` |
| Plugin grant store | `Sources/ViewerCore/Plugins/PluginGrantStore.swift` |
| Plugin manifest schema | `Sources/ViewerCore/Plugins/PluginManifest.swift` |
| Plugins settings pane + grant prompt | `Sources/ViewerUI/PluginsSettingsView.swift` |
| Bundled Row Counter plugin | `Sources/ViewerCore/Plugins/BundledPlugins/RowCounterPlugin.swift` |

## Common preconditions

- App under test: `dist/TextView.app` (bundle id `com.markdownviewer.MarkdownViewer`;
  main executable is `Contents/MacOS/MarkdownViewer`).
- MCP server is launched by spawning the **main executable** directly with
  `--mcp-stdio` (the `.app` wrapper, `open(1)`, won't pipe stdin/stdout):
  `dist/TextView.app/Contents/MacOS/MarkdownViewer --mcp-stdio`.
- The MCP transport is **Content-Length framed JSON-RPC 2.0** over stdin/stdout
  (`Content-Length: N\r\n\r\n<body>`). LF-only headers are accepted on input;
  responses are always CRLF. Body ceiling = 16 MiB; header block ceiling = 8 KiB.
- All scratch files MUST live under `FileManager.default.temporaryDirectory`
  (`/var/folders/...`) or under `$HOME` — `open_path` rejects anything outside
  `$HOME ∪ $TMPDIR`. Never write to `~/Documents`, `~/Desktop`, `~/Downloads`.
- Plugins are discovered under
  `~/Library/Application Support/com.markdownviewer.MarkdownViewer/Plugins/`,
  one folder per plugin, each with a `plugin.json`. Grant decisions persist to
  `…/PluginGrants/grants.json`. Tier B audit log is JSONL at
  `~/Library/Logs/com.markdownviewer.MarkdownViewer/plugins.log` (mode `0o600`).
- For plugin smokes that mutate the real grant store / Plugins dir, **back up and
  restore** the real `Plugins/` folder and `grants.json` so the user's own state
  is untouched. Prefer a clean-room `Plugins/` populated only with the fixture.

---

## SMOKE-PMA-01 — MCP handshake + drive a real document end-to-end

**Combines:** MCP framing · `initialize`/`initialized`/`tools/list` handshake ·
`open_path` (home/temp containment) · `set_view_mode` · `find` · `goto_line` ·
`visible_text` (read-back) · `current_state`.

This is the headline "an agent drives the viewer" flow: a client connects, opens
a file, switches view mode, searches it, jumps to a line, and reads the content
back — asserting the app's state actually changed at each step.

### Preconditions
- Build a fixture markdown file under `$TMPDIR`, e.g.
  `/var/folders/.../mdv-uat/fixture.md`, ~40 lines, containing a unique token
  `NEEDLE_TOKEN` on a known line (say line 12) and at least 3 occurrences total.
- No `dist/TextView.app` window need be open; `--mcp-stdio` launches headless
  (activation policy `.prohibited` — no Dock tile, no menu bar, no window).

### Steps
1. **Spawn** `…/MacOS/MarkdownViewer --mcp-stdio`, capturing stdin/stdout pipes;
   read stderr separately.
   - *Expect:* stderr emits `mcp: server ready on stdio`. stdout is silent (no
     bytes) until the first framed response. The process has **no** Dock icon.
2. **Send** an `initialize` request (framed; `jsonrpc:"2.0"`, an integer `id`).
   - *Expect:* one framed response with `result.protocolVersion == "2024-11-05"`,
     `result.serverInfo == {name:"TextView", version:"1.0.0"}`, and
     `capabilities.tools.listChanged == false`. Response is CRLF-framed.
3. **Send** the `initialized` notification (no `id`).
   - *Expect:* **no** response (notifications are dropped). Server stays alive.
4. **Send** `tools/list`.
   - *Expect:* `result.tools` is an array of exactly **10** tools:
     `open_path, select_tab, set_view_mode, find, goto_line, visible_text,
     current_state, toggle_bookmark, list_bookmarks, snapshot_window`. Each has a
     `name`, `description`, and a JSON-Schema `inputSchema`.
5. **Call** `tools/call` `open_path` with `{path: "<fixture.md>"}`.
   - *Expect:* `tools/call` result `isError:false`; the embedded text block
     parses to `{tabId:"<uuid>"}`. (`newTab` defaults to `true`.)
6. **Call** `set_view_mode` `{mode:"source"}`.
   - *Expect:* result `{mode:"source"}`; the tab is now rendered as source.
7. **Call** `find` `{query:"NEEDLE_TOKEN"}`.
   - *Expect:* `{matches:[…], total:N≥3, truncated:false}`; each match has
     `line`, `column`, `location`, `length`. The match on line 12 is present.
8. **Call** `goto_line` `{line:12}`.
   - *Expect:* `{line:12}`; the source view scrolled to line 12.
9. **Call** `visible_text` (no args).
   - *Expect:* `{text:"…", truncated:false, totalBytes:M}` where the text
     contains `NEEDLE_TOKEN` and `totalBytes == text.utf8.count`.
10. **Call** `current_state`.
    - *Expect:* a snapshot whose tab list includes the fixture, `view mode ==
      source`, and the selected tab points at the fixture.
11. **Send** `shutdown`, then close stdin.
    - *Expect:* `shutdown` returns `result:null`; the read loop stops and the
      process exits cleanly (stderr logs `stdin EOF; server exiting` if it
      reaches EOF first).

### Variations / edge-states
- **EOF before any header:** close stdin immediately after spawn → process exits
  cleanly (no error log line for "framing error").
- **`ping`** at any point → `result:{}` empty success.
- **`set_view_mode` doc/enum drift:** the description lists
  `rendered/source/formatted/table/diff/hex`, but the schema enum is
  `ViewMode.allCases` (also accepts `editor`/`preview`). `{mode:"editor"}` on a
  text file should succeed; `{mode:"banana"}` → tool result `isError:true`
  ("unknown view mode: banana").
- **`find` with a degenerate regex** `{query:".", regex:true}` against a large
  file → result capped at 1000 matches with `truncated:true`, `total` reflecting
  the real count. Catastrophic-backtracking patterns are rejected by the
  ReDoS guard and return empty matches, not a hang.
- **`visible_text` on a binary/non-text tab** → `text:""`.

---

## SMOKE-PMA-02 — MCP path containment, error taxonomy, and malformed framing

**Combines:** `open_path` security containment · JSON-RPC error taxonomy
(`parseError`/`invalidRequest`/`methodNotFound`/`invalidParams`) · tool-level vs
protocol-level error distinction · framing limits · `select_tab` arg validation.

A hostile or buggy client must never crash, hang, or escape the sandbox. This
flow walks every guarded boundary in one session.

### Preconditions
- MCP server spawned as in PMA-01.
- A real file that exists **outside** `$HOME ∪ $TMPDIR`, e.g. `/etc/hosts`.
- A path that does **not** exist, e.g. `/var/folders/.../mdv-uat/nope.md`.

### Steps
1. **Send** raw bytes that are not valid JSON inside a correct Content-Length
   frame.
   - *Expect:* JSON-RPC error response, `error.code == -32700` (parseError),
     `id == null`. Server stays alive.
2. **Send** a framed object missing `"jsonrpc":"2.0"` (e.g. `jsonrpc:"1.0"`).
   - *Expect:* `error.code == -32600` (invalidRequest), echoing the request `id`
     if present.
3. **Send** a valid request with `method:"does_not_exist"`.
   - *Expect:* `error.code == -32601` (methodNotFound), message names the method.
4. **Call** `open_path` `{path:"/etc/hosts"}`.
   - *Expect:* tool result `isError:true`, message contains "outside the user's
     home directory" (permissionDenied). `/etc/hosts` is **not** opened.
5. **Call** `open_path` `{path:"<nonexistent>"}`.
   - *Expect:* tool result `isError:true`, message "path does not exist" (notFound).
6. **Call** `open_path` `{path:"~/"}` (or another existing home path).
   - *Expect:* succeeds — `~` is expanded and `$HOME` itself is allowed.
7. **Call** `select_tab` with **neither** `byIndex` nor `byId`.
   - *Expect:* tool result `isError:true`, "provide byIndex or byId"
     (invalidParams).
8. **Call** `select_tab` `{byId:"not-a-uuid"}`.
   - *Expect:* `isError:true`, "byId is not a valid UUID".
9. **Call** `select_tab` `{byIndex:999}` (out of range).
   - *Expect:* result `{changed:false}` — **not** an error. Out-of-range is a
     no-op, not a failure.
10. **Call** `goto_line` `{line:0}`.
    - *Expect:* `isError:true`, "line must be >= 1".
11. **Send** a frame with `Content-Length` larger than 16 MiB (e.g.
    `Content-Length: 20000000`).
    - *Expect:* the server treats it as `bodyTooLarge` and the framing loop logs
      an error then closes — it never allocates the 20 MB buffer.

### Variations / edge-states
- **LF-only header block** (`Content-Length: N\n\n<body>`) → accepted; response
  still emitted CRLF-framed.
- **Header block > 8 KiB without a blank line** → `malformedHeader`; loop closes.
- **Negative `Content-Length`** → `malformedHeader("negative Content-Length")`.
- **`Content-Length: 0`** → empty body decoded → parse error response (empty body
  is not valid JSON-RPC), id null.
- **macOS-26 `Data` slice-offset hardening:** feed two frames back-to-back in one
  write so the reader's look-ahead buffer carries a partial second frame; the
  second frame must still decode correctly (regression guard for the
  `Data.subdata`/`removeFirst` rebase in `FileHandleReader`).

---

## SMOKE-PMA-03 — MCP bookmarks round-trip + window snapshot, headless

**Combines:** `toggle_bookmark` (file-level + line-level) · `list_bookmarks` ·
bookmark persistence to `bookmarks.json` · `snapshot_window` (headless behaviour)
· `current_state` cross-check.

Exercises the bookmark tools (which mutate the real persistent store) and the
PNG-capture tool, including its documented headless failure mode.

### Preconditions
- MCP server spawned; `initialize` handshake completed.
- A fixture text file under `$TMPDIR`.
- **Back up** `…/Application Support/com.markdownviewer.MarkdownViewer/bookmarks.json`
  before the run; restore it after (these tools write the user's real store).

### Steps
1. **Call** `open_path` on the fixture, then `set_view_mode` `{mode:"source"}`.
   - *Expect:* tab open in source mode.
2. **Call** `list_bookmarks`.
   - *Expect:* `{bookmarks:[…]}` — capture the baseline count B0.
3. **Call** `toggle_bookmark` (no `line`) — file-level bookmark.
   - *Expect:* `{ok:true}`.
4. **Call** `toggle_bookmark` `{line:5}` — line-level bookmark.
   - *Expect:* `{ok:true}`.
5. **Call** `list_bookmarks`.
   - *Expect:* count == B0 + 2. The two new entries: one with no `line` field
     (file-level), one with `line:5`. Both carry `path`, `displayName`, ISO-8601
     `addedAt`.
6. **Call** `toggle_bookmark` (no `line`) again on the same tab.
   - *Expect:* `{ok:true}`; `list_bookmarks` now shows the file-level bookmark
     **removed** (toggle is idempotent off/on). Count == B0 + 1.
7. **Call** `snapshot_window`.
   - *Expect (headless `--mcp-stdio`):* tool result `isError:true`, message
     contains "no window available" (toolFailed). Headless mode has no window to
     capture — this is correct, not a bug.
8. **Call** `current_state`.
   - *Expect:* snapshot reflects the still-present line-5 bookmark on the active
     tab; sidebar/palette fields are present.

### Variations / edge-states
- **`toggle_bookmark` `{line:0}`** → tool error "line must be >= 1".
- **`snapshot_window` against a *live* GUI session** (not headless — e.g. drive
  a launched window app via a side channel): returns `{pngBase64:"…", bytes:N}`
  and the base64 decodes to a valid PNG. (This variation belongs on the VM/GUI
  lane, not the headless gate.)
- **Persistence:** after step 5, kill and re-spawn the server, `list_bookmarks`
  again → the line-5 bookmark survives (read from `bookmarks.json`).

---

## SMOKE-PMA-04 — `--script` verb dispatch drives the model headlessly

**Combines:** `--script` file dispatch · open/lazy-tab/select-tab/close-tab ·
toggle-view · zoom in/out/reset · palette + go-to-path overlays · cross-search ·
sidebar root + nav · bookmark toggle · per-step model dump assertions.

The `--script` path is the headless automation harness the VM UI tests use. This
smoke verifies that a script of verbs mutates `DocumentModel` / sessions and that
each per-step dump (`mdv-step-NN.json`) reflects the change. It overlaps the MCP
surface but reaches model state MCP doesn't expose (palette, go-to, sidebar,
cross-search, sessions).

### Preconditions
- Two fixture files under `$TMPDIR` (`a.md`, `b.txt`) and a fixture **folder**
  with a few files for sidebar/cross-search.
- A script file with one verb per line (see `ScriptVerb.apply` for the full
  vocabulary). Set `MDV_ARTIFACT_DIR` to a unique temp dir so per-step dumps
  don't collide.

### Steps
1. **Launch** `…/MacOS/MarkdownViewer --script <script> ` with
   `MDV_ARTIFACT_DIR=<unique>` and `MDV_BACKGROUND=1` (accessory mode — window
   may appear but won't steal focus; prefer this so a stray window doesn't
   disrupt the host).
2. Script verb `open <abs a.md>` then `snapshot`.
   - *Expect:* dump `currentURL` ends with `a.md`, `tabCount == 1`,
     `currentStateKind == "loaded"`.
3. Verb `open-lazy <abs b.txt>` then `select-tab 2` then `snapshot`.
   - *Expect:* `b.txt` was appended as a **lazy** (`.empty`) tab and materializes
     on `select-tab` (drives `materializeIfNeeded`); dump shows
     `selectedTabIndex == 1`, `currentURL` ends with `b.txt`, state `loaded`.
     (This is the exact shape of the load-bug repro — the file must actually
     load, not show "cannot be loaded".)
4. Verb `toggle-view` then `snapshot`.
   - *Expect:* `currentViewMode` flips (for a markdown/source-capable tab).
5. Verbs `zoom-in`, `zoom-in`, `zoom-reset` then `snapshot`.
   - *Expect:* `zoom` rises by ~0.1 per `zoom-in` (cap 3.0) then returns to 1.0
     on `zoom-reset`.
6. Verbs `show-palette` / `dismiss-palette`, `show-goto` / `dismiss-goto` then
   `snapshot` after each toggle.
   - *Expect:* `isPalettePresented` / `isGoToPathPresented` track true→false.
7. Verb `sidebar-set-root <abs folder>`, then `sidebar-select-next`,
   `sidebar-select-prev` then `snapshot`.
   - *Expect:* `sidebar.rootURL` (`absoluteString`, trailing slash preserved)
     points at the folder.
8. Verb `set-cross-query NEEDLE` (implies show+run) then `snapshot`.
   - *Expect:* `isCrossSearchPresented == true` and cross-search ran against the
     sidebar folder scope.
9. Verb `toggle-bookmark` then `snapshot`.
   - *Expect:* `isCurrentTabBookmarked` flips true.

### Variations / edge-states
- **Window/NSApp-coupled verbs are out of scope here:** `resize`, `find`,
  `diagnostic-window`, `instrumentation-window` return `false` from
  `ScriptVerb.apply` and are handled by the AppDelegate; an unknown verb also
  falls through — neither should crash the run.
- **`goto-commit <abs path>`** opens a file via the go-to-path commit path;
  `goto-commit-new-session <abs folder>` spawns a forced new session.
- **`open` a missing file** → existing tabs are kept and an error tab is
  appended (never clears all tabs); dump `currentStateKind == "error"`.
- **`editor-set-mode editor` + `editor-set-text "…" ` + `editor-save`** on a
  text tab round-trips through the CM6 editor-buffer state machine and writes to
  disk. Re-open the file and assert the new contents.

---

## SMOKE-PMA-05 — Plugin first-install grant prompt → sidebar render → revoke → re-prompt

**Combines:** on-disk plugin discovery · manifest parse + capability declaration ·
grant store fail-closed semantics · grant prompt (Install/Cancel) · Tier B
subprocess sidebar section · Settings → Plugins management (toggle / Revoke) ·
re-prompt on revoke.

This is the full third-party plugin lifecycle: a freshly-dropped plugin must be
**gated** behind a grant decision, render its sidebar rows only once granted, and
re-prompt after the user revokes.

### Preconditions
- Clean-room `Plugins/` dir (back up + replace the real one). Drop a Tier B
  fixture plugin folder `tv-greeter/` containing:
  - `plugin.json`: `manifestVersion:1`, `id:"com.example.tv.greeter"`,
    `name:"Greeter"`, `version:"0.1.0"`, an `author.name`,
    `capabilities:["ui.sidebar","shell.exec"]`, and a `contributes` entry of
    `type:"sidebar_section"`, `provider.tier:"B"`, `bin:"./greet"`,
    `id:"greeter-rows"`, `title:"GREETINGS"`.
  - `greet`: an executable (chmod +x) that reads the stdin JSON envelope and
    prints `{"rows":[{"id":"r1","label":"Hello","detail":"from plugin"}]}` to
    stdout, exit 0.
- Back up + clear `…/PluginGrants/grants.json` so this is a first install.

### Steps
1. **Launch** the app normally (GUI) so `PluginsBootstrap.loadAtLaunch` runs.
   - *Expect:* at launch the `tv-greeter` plugin is discovered, parsed, and —
     because its declared `["shell.exec","ui.sidebar"]` set has no grant — it is
     recorded as **awaiting grant** (loaded entry `enabled:false`, no
     contributions registered yet). A grant `NSAlert` is presented:
     "Install "Greeter" (v0.1.0)?" listing the human-readable capability bullets
     ("Run bundled command-line tools (shell.exec)", "Add a sidebar section
     (ui.sidebar)") and the source folder path.
2. In the prompt, click **Cancel**.
   - *Expect:* decision persisted as `.denied`; the plugin loads
     `loadedWithWarnings(["user denied capabilities: …"])`; **no** sidebar
     section appears; Settings → Plugins shows the row with status
     "User denied — click Revoke to re-prompt".
3. Open **Settings → Plugins**, click **Revoke** on the Greeter row.
   - *Expect:* grant forgotten, plugin disabled; status returns to awaiting.
4. **Relaunch** the app (no hot-reload in v1).
   - *Expect:* grant prompt fires again (revoke → re-prompt). This time click
     **Install**.
   - *Expect:* decision persisted `.granted`; plugin loads `.loaded`; the
     `GREETINGS` sidebar section registers.
5. Open the sidebar; toggle the **Plugins** shoulder-rail panel / expand the
   `GREETINGS` section.
   - *Expect:* the section renders one row `Hello — from plugin` (the Tier B
     subprocess was spawned with a HOME-only scrubbed env, fed the `listRows`
     envelope, and its stdout decoded). An entry is appended to `plugins.log`
     with `result:"ok"`, the plugin id, `cap:"shell.exec"`, the bin, and a
     duration.
6. In Settings → Plugins, toggle the Greeter **off**.
   - *Expect:* contributions dropped (`GREETINGS` section disappears after the
     sidebar re-bodies); the grant is **kept** (toggling off ≠ revoke). Toggle
     back on → section returns.

### Variations / edge-states
- **Grant subset rule:** if a later manifest edit *adds* a capability (e.g.
  `network.egress`), the stored grant no longer covers the declared set →
  re-prompt on next load. Removing a capability does **not** re-prompt (declared
  is still a subset of granted).
- **`grants.json` > 256 KiB** → refused as tampered (treated as no grants);
  plugins re-prompt rather than silently grant.
- **Newer `schemaVersion` on disk** → writes suppressed (don't truncate a newer
  build's fields); in-memory decisions still apply for the session.
- **Unknown `decision` string** in `grants.json` → decodes fail-closed to
  `.denied`, never `.granted`.
- **Stale-render caveat:** `PluginSidebarSections` has no live observation —
  after enable/disable the rows may stay stale until *another* sidebar re-body
  (FS event, hover, root change). Triggering an unrelated re-render should reveal
  the change. (Known limitation, not a fail.)

---

## SMOKE-PMA-06 — Tier B plugin failure taxonomy + subprocess sandbox containment

**Combines:** Tier B subprocess host caps (timeout / stdout overflow / non-zero
exit / spawn fail / decode fail) · per-row error strings in the sidebar · env
scrub (HOME-only) · symlink-escape containment (SEC-007) · audit-log leak-free
descriptors (OBS-6) · audit-log file mode.

Once a plugin is granted, its subprocess is still sandboxed. This flow forces
each failure mode and asserts the inline error row plus a leak-free audit entry.

### Preconditions
- A **granted** Tier B fixture plugin (reuse PMA-05's grant, or pre-seed a
  `.granted` entry in `grants.json` so no prompt fires).
- The plugin folder can swap its `bin` between several test executables, each
  re-discovered on relaunch (no hot-reload). Use a separate plugin id per
  scenario, or relaunch between bin swaps.
- Point the audit log at a temp file where possible (the `PluginSubprocessHost`
  exposes an `auditURLOverride` for tests); otherwise back up `plugins.log`.

### Steps
1. **Timeout:** `bin` is a script that `sleep`s past the 5 s default cap.
   - *Expect:* the `GREETINGS` row renders `(plugin timed out)`. The child is
     SIGTERM'd then SIGKILL'd. Audit line `result:"timeout"`.
2. **stdout overflow:** `bin` prints > 1 MiB to stdout.
   - *Expect:* row `(plugin output too large)`; the read pipe is closed at the
     1 MiB cap. Audit `result:"stdout_overflow"`.
3. **Non-zero exit:** `bin` writes a short stderr and `exit 3`.
   - *Expect:* row `(plugin exited 3)`. Audit `result:"nonzero_exit", exit:3`
     with a bounded stderr tail.
4. **Invalid JSON:** `bin` prints `not json` and exit 0.
   - *Expect:* row `(plugin returned invalid JSON)`. Audit `result:"decode_failed"`
     with a **stable, byte-free** descriptor (e.g. `dataCorrupted@<root>`) — the
     offending plugin bytes must **not** appear in the log (OBS-6).
5. **Spawn fail — missing bin:** `plugin.json` points `bin` at a path that
   doesn't exist.
   - *Expect:* row `(plugin failed to launch)`. Audit `result:"spawn_failed"`
     with `bin_basename` and a stable errno-style descriptor — **no absolute
     filesystem path** in the log.
6. **Symlink escape (SEC-007):** inside the plugin folder, `bin` is a symlink
   pointing **out** of the folder (e.g. → `/usr/bin/osascript`).
   - *Expect:* refused — `(plugin failed to launch)` with reason "bin escapes
     plugin folder after symlink resolution". The host resolves symlinks on both
     the exe and folder and requires containment. `osascript` is **never** run.
7. **Env scrub:** `bin` prints its environment.
   - *Expect:* only `HOME` is present. No `PATH`, `USER`, `TMPDIR`,
     `*_TOKEN`/`*_SECRET`/`AWS_*`/`OPENAI_API_KEY`, etc.
8. **Inspect the audit log file.**
   - *Expect:* the directory `…/Logs/com.markdownviewer.MarkdownViewer/` is
     `0o700` and `plugins.log` is `0o600`. Lines are one JSON object each
     (JSONL), sorted keys, newline-terminated.

### Variations / edge-states
- **`bin` contains `..`** → cheap string-level reject before any spawn
  ("bin path contains '..'").
- **`bin` not executable** (exists but no +x) → spawn fail "bin not executable".
- **Requested `timeoutMs` above 30 s** → clamped to the 30 s max.
- **Tier C provider** (`tier:"C"`) → load warning "uses tier C (WebView) — not
  supported in v1"; no section registered.
- **Unknown contribution `type`** or **unknown `tier`** → recorded as a warning;
  the rest of the manifest still registers (fail isolation).
- **Tier B without `shell.exec` capability** → contribution rejected with
  "missing capability: shell.exec" (no silent escalation).

---

## SMOKE-PMA-07 — Bundled Row Counter plugin + plugin load isolation

**Combines:** bundled (Tier 0) plugin registration (bypasses grant store) ·
`ROW COUNTS` sidebar section reflecting open files · multi-plugin load isolation
(one bad manifest doesn't poison siblings) · Settings → Plugins listing
(BUNDLED pill, no toggle/Revoke) · audit-log "Show Log" button gating.

The first-party bundled plugin must always be present and grant-free, and a
broken third-party plugin in the same dir must not take it (or other good
plugins) down.

### Preconditions
- Clean-room `Plugins/` containing three folders:
  - `good/` — a valid Tier B (or Tier A) plugin (pre-granted).
  - `bad-manifest/` — `plugin.json` is malformed JSON.
  - `bad-version/` — `plugin.json` with `manifestVersion: 2`.
- App launched normally (GUI).

### Steps
1. **Launch** the app and open two text files (so the snapshot has open-file
   contents).
   - *Expect:* the bundled **Row Counter** is registered at launch with **no**
     grant prompt (bundled plugins bypass the grant store).
2. Open the sidebar, expand **ROW COUNTS** (`number.square` icon).
   - *Expect:* one row per open file, label = filename, detail = "N lines"
     (wc-style: trailing partial line counts; empty file = 0 lines), sorted by
     path.
3. Open / close a file.
   - *Expect:* the ROW COUNTS rows track the open-file set (after the sidebar
     re-bodies).
4. Open **Settings → Plugins**.
   - *Expect:* the list shows **Row Counter** with a `BUNDLED` pill, its
     monospaced id `com.markdownviewer.builtin.rowcounter`, capability
     `ui.sidebar`, and **no** enable/disable toggle or Revoke button. The `good`
     plugin shows a toggle + Revoke. The `bad-manifest` and `bad-version` plugins
     appear with their failure status (not silently dropped).
5. Verify load isolation.
   - *Expect:* `good` loaded successfully and renders its section **despite**
     `bad-manifest` / `bad-version` failing to parse/load (per-folder isolation).
6. Check the **Show Log** button.
   - *Expect:* disabled when `plugins.log` doesn't exist yet; after any Tier B
     row pull creates the log, it's enabled and opens the JSONL file in a new
     TextView tab.

### Variations / edge-states
- **Bundled disable is in-memory only** (v1 quirk): bundled plugins have no
  toggle, and `setEnabled(false)` on a bundled id is a no-op flag flip — the
  section stays. Don't expect a bundled section to vanish.
- **Empty Plugins dir / missing dir** → Settings shows only the bundled Row
  Counter and the "No plugins installed." empty-state caption pointing at the
  Plugins dir path.
- **Repeated `loadAll`** (e.g. relaunch) is idempotent — no double-registered
  sections (each load drops the prior registration first).
- **`good` declares `ui.sidebar` only (Tier A)** → registers a placeholder row
  "(Tier A static-bind not yet implemented)" — Tier A static-bind is unbuilt in
  v1; the section is still visibly registered.

---

## Cross-cutting notes for the executor

- **Headless vs GUI lanes.** PMA-01/02 (and PMA-03 minus the live snapshot
  variation) run fully headless via `--mcp-stdio` and the `--script` path —
  host-safe, no window opens. PMA-05/06/07 need a **GUI session** to see the
  grant `NSAlert`, the sidebar sections, and Settings → Plugins; run those on the
  VM / GUI lane, or drive the registry/grant-store/subprocess-host layers
  directly in-process (model + `PluginRegistry` are constructable headless) and
  assert state, deferring the pixel-level sidebar check to the VM.
- **State hygiene.** Bookmark and grant smokes mutate real persistent stores
  (`bookmarks.json`, `grants.json`, the `Plugins/` dir, `plugins.log`). Always
  snapshot-and-restore, or redirect to temp (`PluginSubprocessHost`'s
  `auditURLOverride`, a temp `PluginGrantStore(url:)`, a clean-room Plugins dir).
- **No hot-reload.** Plugin install/grant changes that require re-discovery need
  an app relaunch in v1 — bake relaunches into the plugin flows.
- **Never via MCP:** the MCP catalog deliberately omits the diagnostic/debug
  windows and the observability ring buffer; don't expect tools for them.
