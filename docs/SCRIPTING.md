# SCRIPTING.md — how scripting / automation actually works (as built)

Answer to TSK-799 *"How does scripting work?"* — a code-grounded survey of
the scripting surface **as it exists in the tree today**, not the design
aspiration. (The older `docs/AUTOMATION.md` is the original *design draft*
and is marked "no implementation yet"; much of it has since landed and
drifted. This doc describes what the code does now; `AUTOMATION.md` remains
the design rationale.)

There is no single "scripting language" in TextView. Instead there are
**six distinct, layered surfaces**, each with a different audience and trust
model. They share one underlying verb vocabulary where it makes sense.

```
                    ┌─────────────────────────────────────────┐
  external agent ──▶│  MCP server (--mcp-stdio)                │  typed RPC, read+write
  Claude / Cursor   │  MCPToolCatalog · MCPServer · AutomationHost
                    └───────────────┬─────────────────────────┘
                                    │ delegates to
  VM / headless ───▶  --script DSL  │   ┌──────────────────────┐
  test harness       ScriptRunner ──┼──▶│  ScriptVerb.apply()  │  ~110 verbs, the
                                    │   │  (the dispatch switch)│  core action vocab
  command palette ─▶ CommandRegistry┘   └──────────────────────┘
  + menus            scriptVerb token ──────────▲
                                                │ replays through
  macros ──────────▶ MacroRecorder ─────────────┘   (record/replay command seq)

  Plugins ─────────▶ PluginRegistry · PluginSubprocessHost   out-of-process extensions
  shell / Finder ──▶ URL scheme · mdv CLI · NSServices       fire-and-forget entry points
```

---

## 1. The core: the `--script` verb vocabulary

The richest and most central surface. A *script* is a newline-delimited
list of `<verb> [arg]` lines. The runtime authority is one big `switch` in:

- `Sources/ViewerUI/Automation/ScriptVerbDispatch.swift` —
  `ScriptVerb.apply(verb:to:sessions:)`

It takes a verb line and a `(DocumentModel, SessionsAppCoordinator)` pair,
mutates model state, and returns `true` if it recognised the verb. It is
deliberately **window-free** — no `NSApp`, no `NSWindow` — so the same
dispatch drives both production and headless tests. A handful of genuinely
window-coupled verbs (`resize`, `find` via responder chain, the debug tool
windows) are NOT handled here; `apply` returns `false` and the caller
(`AppDelegate.runScriptStep`) handles the residue.

Two callers share this one switch:

1. **VM / live path** — `--script <file>` on the command line.
   `Sources/MarkdownViewer/ScriptRunner.swift` reads the file, runs each
   line through `runScriptStep` → `ScriptVerb.apply`, and captures a
   per-step PNG + JSON dump (the `snapshot` verb). This is the L4/L5
   UI-test driver.
2. **Headless harness** — `Tests/ViewerUITests/Harness/HeadlessHarness`
   drives the same verbs in-process against a throwaway `DocumentModel`,
   reading state back via `ScriptVerb.modelStateDump(...)` (the identical
   projection the VM path dumps).

### Verb inventory

The verbs are now also enumerated *as data* in
`Sources/ViewerCore/Automation/ScriptVerbCatalog.swift` — `ScriptVerbCatalog.all`.
A host test (`ScriptVerbCatalogTests.testCatalogMatchesDispatchSwitch`)
parses the `case "…":` labels out of the dispatch switch and asserts the
catalog matches exactly, so this list cannot silently rot. Grouped by
surface (see `ScriptVerbCatalog.grouped()`):

| Surface | Example verbs |
|---|---|
| **View** | `toggle-view`, `toggle-sidebar`, `zoom-in/out/reset`, `toggle-format`, `toggle-word-wrap`, `toggle-invisibles`, `toggle-split`, `swap-split`, `set-theme`, `folder-stats`, `focus-document/terminal/file-nav/git`, `terminal-open-here` |
| **Tabs** | `new-tab`, `close-tab`, `next-tab`, `prev-tab`, `select-tab N`, `move-tab-left/right`, `confirm-dirty-close save\|discard\|cancel` |
| **Files** | `open PATH`, `open-lazy PATH`, `open-as "<category> <path>"`, `set-open-as <category>\|auto`, `reload`, `save-copy PATH` |
| **Editor (CM6)** | `editor-set-mode <mode>`, `editor-focus`, `editor-set-text TEXT`, `editor-save`, `editor-format`, `edit-remove-empty-lines`, `edit-collapse-blank-lines`, `edit-trim-trailing`, `edit-ensure-final-newline`, `edit-minify-json`, `edit-insert-toc`, `edit-insert-date`, `toggle-blame` |
| **Language Server** | `editor-goto-definition/declaration/type-definition/implementation`, `editor-find-references`, `lsp-rename NAME`, `show-lsp-rename`, `show-code-actions`, `lsp-seed-diagnostics "<e> <w> [i] [h]"`, `lsp-clear-diagnostics`, `lsp-seed-references N`, `lsp-clear-navigation` |
| **Find** | `show-find`, `dismiss-find`, `find-next`, `find-prev`, `show-cross-search`, `dismiss-cross-search`, `set-cross-query Q` |
| **Sidebar** | `sidebar-set-root PATH`, `sidebar-select-next/prev`, `sidebar-walk-up` |
| **Sessions** | `session-open-folder PATH`, `session-open-new PATH`, `session-activate N`, `session-close-active`, `session-open-home`, `session-new-via-goto`, `session-next/prev`, `session-rename NAME` |
| **Git** | `show-git-panel`, `git-file-history`, `file-history PATH`, `git-panel-root [PATH]`, `git-panel-tab NAME`, `git-log-click/cmd-click/shift-click SHA`, `git-log-cumulative-diff`, `goto-commit PATH`, `goto-commit-new-session PATH` |
| **Bookmarks** | `toggle-bookmark`, `toggle-line-bookmark` |
| **Metadata** | `metadata-compute-checksum`, `metadata-set-checksum-algorithm ALGO` |
| **Text Tools (clipboard)** | `tools.uuid`, `tools.sha256`, `tools.base64Encode/Decode`, `tools.sortLinesAsc/Desc`, `tools.uniqueLines`, `tools.reverseLines`, `tools.upperCase/lowerCase`, `tools.trimTrailing`, `tools.urlEncode/Decode`, `tools.htmlEncode/Decode`, `tools.fileChecksum` |
| **Command Palette** | `show-palette`, `dismiss-palette`, `show-goto`, `dismiss-goto` |
| **Harness / Profiling** | `delay SECS`, `snapshot`, `nav-sweep CYCLES`, `emit-test-log` |

> Verbs whose `case` is shared (the `git-log-*click` family) are listed
> once per token in the catalog. `confirm-dirty-close`'s `save/discard/cancel`
> and `folder-stats`' `on/off` are *argument literals*, not verbs.

---

## 2. MCP server — the agent-facing API

For external agents (Claude Desktop, Cursor, local CLIs). The app, launched
with `--mcp-stdio`, runs as a headless JSON-RPC MCP server over stdio (no
Dock icon, no window). Wiring:

- `Sources/MarkdownViewer/main.swift` — `--mcp-stdio` branch creates an
  `MCPServer`.
- `Sources/ViewerCore/Automation/MCPServer.swift` — the JSON-RPC request
  loop (`MCPProtocol.swift` + `MCPFraming.swift` are the wire format).
- `Sources/ViewerCore/Automation/MCPToolCatalog.swift` — the **ten v1
  tools**: `open_path`, `select_tab`, `set_view_mode`, `find`, `goto_line`,
  `visible_text`, `current_state`, `toggle_bookmark`, `list_bookmarks`,
  `snapshot_window`. Each has a JSON Schema (`tools/list`) + dispatcher.
- `Sources/ViewerCore/Automation/AutomationHost.swift` — the `@MainActor`
  protocol the catalog dispatches through. `DocumentModel` conforms (see
  `Sources/ViewerUI/Automation/DocumentModel+AutomationHost.swift`); tests
  use `FakeAutomationHost`.

This surface is **read + write** (the `--script` DSL is the bigger write
vocabulary; MCP adds the missing structured read side: `current_state`,
`visible_text`, `list_bookmarks`, `snapshot_window`).

### MCP security model (enforced in code)

`MCPToolCatalog.validatedExistingURL` is the path fence:

- Resolves `~` and symlinks (physical-to-physical), then requires the path
  to be **inside the user's home** or the per-user temp dir — `/etc`,
  `/System`, other users' homes are rejected (`permissionDenied`).
- Containment is checked **before** existence so an out-of-jail path can't
  be probed via the differential `notFound` vs `permissionDenied` error
  (an existence oracle). This is the MCP prong of AUDIT finding S3.
- `visible_text` is capped at 10 MB (`AutomationLimits.visibleTextMaxBytes`),
  with code-point-boundary-correct truncation.
- `find` pre-validates regex through `RegexComplexityGuard` (ReDoS guard)
  before compiling, so a bad pattern returns an error rather than an
  ambiguous empty result.

---

## 3. Command palette + keybindings + menus

The user-facing front-end onto the same verb vocabulary.

- `Sources/ViewerCore/Commands/CommandRegistry.swift` — `CommandDescriptor`
  (id, title, category, `defaultShortcut`, **`scriptVerb`**, `replayability`).
  A command's canonical invoker is the `scriptVerb` token it maps to — the
  palette/menu feeds it straight through `ScriptVerb.apply`. Commands with
  no pure verb (open panels, the find router, debug windows) carry
  `scriptVerb == nil` and are menu-only.
- `Sources/ViewerCore/Commands/CommandRegistry+BuiltIn.swift` — the catalog.
- `Sources/ViewerCore/Commands/KeybindingConfig.swift` — user overrides via
  `keybinding.json`. `CommandRegistry.applying(overrides:)` folds them over
  the defaults (user > default); `shortcutMap` resolves keystroke → command
  with last-wins conflict reporting. The command `id` is a config contract:
  never renamed once shipped.

---

## 4. Macros — record + replay a command sequence

`Sources/ViewerCore/Commands/MacroRecorder.swift` (TSK-957). Pure model —
no AppKit, no `@MainActor`, fully host-tested.

- `Macro` = an ordered, named, `Codable` list of `CommandInvocation`
  (command id + string→string args) — persistable to disk.
- A **replayability gate** (`CommandReplayability` on the registry entry) is
  enforced at *both* ends: `record` refuses pointer/selection-dependent or
  interactive-prompt commands (`.excluded`), and `replay` re-checks every
  step (defence in depth for macros loaded from disk authored against an
  older catalog).
- `MacroDispatcher` is the sink protocol: production forwards each step to
  `ScriptVerb.apply` via the descriptor's `scriptVerb`; tests pass a spy.

This is what unifies the palette and the script vocabulary: a macro is just
a recorded list of command ids that replay through the same dispatch switch.

---

## 5. Plugins — out-of-process extensions

A separate axis (not "scripting the running app" but "extending it"):

- `Sources/ViewerCore/Plugins/PluginManifest.swift` — `plugin.json` schema.
  v1 ships two contribution types: `sidebar_section` and `menu_item`, each
  with Tier A (static / declarative) and Tier B (subprocess-backed) actions
  (Tier C / WebView is parsed-and-rejected). Capabilities (`ui.sidebar`,
  `ui.menu`, `shell.exec`) gate contributions; unknown caps/contributions
  decode to `.unknown` for forward-compat rather than failing the load.
- `Sources/ViewerCore/Plugins/PluginRegistry.swift` — discovery + load
  report. `PluginGrantStore.swift` — per-plugin capability grants.
- `Sources/ViewerCore/Plugins/PluginSubprocessHost.swift` — spawns Tier B
  binaries with a request envelope (the `shell.exec` capability authorises
  this). Plugins live under
  `~/Library/Application Support/com.markdownviewer.MarkdownViewer/Plugins/`.

Design rationale: `docs/PLUGINS_DESIGN_v2.md`.

---

## 6. Legacy / fire-and-forget entry points

The thin, no-return-channel surfaces (kept, frozen):

- **URL scheme `markdownviewer://`** — `handleCustomURLScheme` in
  `main.swift`: `open?path=…`, `search?root=…&q=…`.
- **`mdv` CLI shim** — `scripts/install-mdv-cli.sh` wraps `open -a`:
  `mdv file.md`, `mdv folder/`, `mdv -` (stdin → temp file).
- **NSServices** — "Open in TextView" in the Services menu.
- **`SIGUSR1` snapshot trap** — `kill -USR1 <pid>` dumps
  `/tmp/mdv-diagnostic-<pid>.{json,png}`.
- **`--diagnose`** — dumps the JSON view tree to stdout and exits.

---

## How the surfaces relate (one vocabulary, many doors)

The `--script` verb switch is the spine. The palette, menus, and macros all
funnel through it via `CommandDescriptor.scriptVerb`. The MCP tool catalog
is a parallel, more-strongly-typed door that delegates through the
`AutomationHost` protocol to the same `DocumentModel`. Plugins are the one
genuinely separate axis (process extension, not app control). The legacy
URL/CLI/Services/signal surfaces are fire-and-forget shims that predate all
of it and are intentionally frozen.

### Source map

| Concern | Files |
|---|---|
| Verb dispatch (the spine) | `Sources/ViewerUI/Automation/ScriptVerbDispatch.swift` |
| Verb inventory (data + drift test) | `Sources/ViewerCore/Automation/ScriptVerbCatalog.swift` |
| `--script` runner | `Sources/MarkdownViewer/ScriptRunner.swift` |
| MCP server + tools | `Sources/ViewerCore/Automation/{MCPServer,MCPToolCatalog,MCPProtocol,MCPFraming,AutomationHost}.swift` |
| AutomationHost impl | `Sources/ViewerUI/Automation/DocumentModel+AutomationHost.swift` |
| Palette / keybindings | `Sources/ViewerCore/Commands/{CommandRegistry,CommandRegistry+BuiltIn,KeybindingConfig}.swift` |
| Macros | `Sources/ViewerCore/Commands/MacroRecorder.swift` |
| Plugins | `Sources/ViewerCore/Plugins/*.swift` |
| Legacy entry points | `Sources/MarkdownViewer/main.swift` (URL scheme, NSServices, signal traps) |
