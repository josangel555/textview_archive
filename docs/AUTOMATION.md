# AUTOMATION.md — making TextView hackable, controllable, and automatable

**Status:** design draft, no implementation yet. Approve direction before we
slice and ship.

## TL;DR — recommendation

Build a **local MCP server inside the app** as the v1 scripting surface,
wrapped in an **App Intents** facade for Shortcuts/Spotlight/Siri parity.
MCP gives a typed, language-agnostic RPC API native to Claude / Cursor /
any local agent; App Intents covers the Shortcuts case without a second
model.

Ranking:

1. **MCP server** — primary. Typed, agent-native, language-agnostic.
2. **App Intents** — ships alongside. Cheap once vocabulary is locked.
3. **JavaScript via `JSContext`** — defer; revisit for in-process filters.
4. **AppleScript** — defer indefinitely. Cost > benefit in 2026.
5. **Lua via LuaSwift** — reject. No payoff over JS.

> **Questions needing your input** (rest decided below):
> 1. OK to add `swift-mcp` (or equivalent) as a dependency?
> 2. Bundle ID after the TextView rename — keep `com.markdownviewer.*` or
>    move to `com.textview.TextView`? Affects MCP discovery.
> 3. Default transport: Unix socket only, or also offer opt-in loopback TCP?

---

## 1. Problem statement

"Hackable" for a daily-driver viewer is three overlapping problems and we
need to be clear which we're solving:

- **Hackable** — clone the repo, land a feature in under 30 minutes.
  Largely solved; `HACKABILITY.md` is the proof. Out of scope here.
- **Controllable** — an external process (shell, editor, Shortcut, LLM
  agent) drives the app: open files, switch tabs, search, read what's
  visible. Today: handful of verbs via URL scheme + `mdv` shim. We want a
  real API.
- **Automatable** — long-running workflows trigger TextView from outside.
  Requires control *and* observability — the script reads state back, not
  just fire-and-forget.

This doc covers **controllable + automatable**. The plugin axis (in-process
extension) is `PLUGINS.md` — overlap noted where relevant, not redesigned.

Bar: 20 lines of Python/TS/shell (or one prompt to a local agent) should
drive TextView as reliably as `osascript` drives Mail.app, but with JSON
in/out and no AppleScript dictionary archaeology.

## 2. Existing surfaces (what already works)

Not starting from zero. Today's automation surface:

- **URL scheme `markdownviewer://`** — `application(_:open:)` →
  `handleCustomURLScheme` in `main.swift`. Two verbs: `open?path=...`,
  `search?root=...&q=...`. Fire-and-forget, no return channel.
- **`mdv` CLI shim** — `scripts/install-mdv-cli.sh` installs a bash
  wrapper around `/usr/bin/open -a`. Supports `mdv file.md`, `mdv folder/`,
  `mdv -` (stdin → temp file). No state inspection.
- **NSServices provider** — `AppDelegate` registers as
  `NSApp.servicesProvider`; "Open in TextView" appears in the Services
  menu. Same fire-and-forget shape.
- **`--diagnose` / `--script`** — binary flags that drive the app
  headlessly. `--diagnose` dumps the JSON view tree to stdout;
  `--script path.txt` runs a verb sequence (`toggle-view`, `zoom-in`,
  `open`, `select-tab N`, `find-next`, ...) with per-step PNG+JSON.
  `runScriptStep` in `main.swift` is effectively a hand-rolled DSL — the
  richest entry point today and the natural seed for the MCP vocabulary.
- **`SIGUSR1` snapshot trap** — `kill -USR1 $(pgrep MarkdownViewer)` →
  `/tmp/mdv-diagnostic-<pid>.{json,png}`. Live state inspection.

## 3. Capability matrix

Each row is a capability the app can perform. Columns are who can trigger it
**today**. Empty cell = not exposed.

| Capability                          | Menu / hotkey | URL scheme | `mdv` CLI | `--script` DSL | NSServices | v1 target |
|-------------------------------------|:-------------:|:----------:|:---------:|:--------------:|:----------:|:---------:|
| Open file                           | yes           | yes        | yes       | yes            | yes        | MCP       |
| Open folder (set sidebar root)      | yes           | yes        | yes       | yes            | yes        | MCP       |
| New tab / close tab                 | yes           |            |           | yes            |            | MCP       |
| Switch tab (next / prev / by index) | yes           |            |           | yes            |            | MCP       |
| Toggle source/rendered view         | yes           |            |           | yes            |            | MCP       |
| Zoom in / out / reset               | yes           |            |           | yes            |            | MCP       |
| Toggle sidebar visibility           | yes           |            |           | yes            |            | MCP       |
| Show / dismiss command palette      | yes           |            |           | yes            |            | MCP       |
| Run cross-file search               | yes           | yes        |           | yes            |            | MCP       |
| Find in current document           | yes           |            |           | yes            |            | MCP       |
| Toggle bookmark on current line     | yes           |            |           | yes            |            | MCP       |
| Toggle pretty-print / format        | yes           |            |           | yes            |            | MCP       |
| Reload current file                 | yes           |            |           |                |            | MCP       |
| Jump to line number                 | partial       |            |           |                |            | MCP       |
| Get visible text / selection        |               |            |           |                |            | MCP       |
| Get current tab list + URLs         |               |            |           | partial (JSON) |            | MCP       |
| Snapshot window to PNG              |               |            |           | yes            |            | MCP       |
| Dump view-tree diagnostic           | SIGUSR1       |            |           | yes            |            | MCP       |
| Subscribe to file-change events     |               |            |           |                |            | MCP v1.1  |
| Subscribe to tab-switch events      |               |            |           |                |            | MCP v1.1  |
| Set workspace (named session)       | TBD           |            |           |                |            | MCP v1.1  |

The pattern is obvious: the write side is mostly covered, the **read** side
is the missing half. That's the single biggest unlock for v1.

## 4. Five candidate architectures

### A. AppleScript / OSA / Scripting Bridge
**Pros:** macOS native, ships with the OS. Free inclusion in Automator /
Script Editor. Scriptable apps get a small status boost in the Mac
ecosystem.
**Cons:** Dictionary design is its own subskill (terms, classes, suite
XML); `sdef` tooling is dated. Audience shrinking. Synchronous-only. JSON
doesn't fit — everything is records/lists.
**Verdict:** **defer indefinitely.** Cost-to-payoff is wrong for 2026.

### B. JavaScript via `JSContext` (JavaScriptCore)
**Pros:** Bundled with macOS, no new dep. Familiar audience. Easy to load
`.js` from `~/Library/Application Support/TextView/Scripts/`. Sync
in-process calls are cheap.
**Cons:** In-process — any bridge misstep gives the script full process
access. Doesn't help cross-process automation (the agent/editor case).
Encourages "everyone hacks the model directly" → compatibility tar pit.
Better fit for the plugin axis than automation.
**Verdict:** **defer.** Revisit after MCP stabilizes if a concrete need for
in-process render-filter / sync-hook plugins appears.

### C. Lua via `LuaSwift`
**Pros:** Embeddable, small, Neovim-crowd appeal.
**Cons:** JS's downsides plus smaller audience plus extra dep. No win.
**Verdict:** **reject.**

### D. Local MCP server inside the app  ← **recommended**
**Pros:** Model Context Protocol is the de-facto agent-↔-tool standard in
2025-2026 (Claude Desktop, Cursor, Zed, VS Code Copilot, local CLIs all
speak it). Typed tool defs with JSON schemas — declare once, every client
gets autocomplete, validation, discovery for free. Bidirectional (publish
notifications back). Transport-decoupled (stdio / Unix socket / opt-in
TCP). Language-agnostic clients. Shell UX stays nice:
`mdv mcp call open --path foo.md`.
**Cons:** One new dependency (`swift-mcp` or hand-rolled — see Q1).
Protocol is young, expect to bump the version pin once or twice.
Notifications need a long-lived connection — fine over Unix socket.
**Verdict:** **adopt for v1.**

### E. App Intents (Shortcuts + Spotlight + Siri)
**Pros:** First-class macOS integration. Shortcuts wires TextView into
automations without code. Spotlight surfaces intents ("New TextView Tab").
Siri/voice for free. Apple's investment track; AppleScript is the
maintenance track.
**Cons:** Apple-only — useless for cross-platform agents and shell. Action
vocabulary must be small/declarative, no streaming, limited return values.
**Verdict:** **adopt as a thin facade over the MCP vocabulary.** Ship
alongside, not instead of.

## 5. Recommendation

**v1 surface: local MCP server, with App Intents in the same release for the
priority subset.**

| Rank | Surface       | Role in v1                                        |
|:----:|---------------|---------------------------------------------------|
| 1    | MCP server    | Primary programmable API. Read + write. Streaming. |
| 2    | App Intents   | Shortcuts / Spotlight / Siri facade. Write-mostly. |
| 3    | URL scheme    | **Keep**, freeze the verb list, mark legacy.       |
| 4    | `--script` DSL| **Keep**, becomes an MCP client internally.        |
| 5    | JS / Lua / AppleScript | **Don't ship.** |

**Why MCP wins the central slot:**
- Audience we most want to serve is "me and my agents." MCP is the only
  surface that's a native fit.
- Collapses three problems into one design: typed action vocabulary (tool
  defs), read API (resources / `getState`), event stream (notifications).
  AppleScript and URL schemes only solve the first.
- The vocabulary we lock in becomes the source of truth: App Intents wrap
  the same verbs, `--script` becomes an in-process MCP client, and any
  future scripting layer speaks the same nouns. One API to keep stable.
- We avoid AppleScript debt while keeping the option to add a thin
  adapter later if anyone asks.

App Intents in the same release because they're cheap once the vocabulary
exists and they pick up Shortcuts users we wouldn't otherwise reach.

## 6. Capability priority — first 10 actions to expose

Ranked by leverage. Ship in MCP v1; everything else in §3's matrix is
fair game later.

1. `open_path(path, newTab=true) → { tabId }` — files + folders. Returns
   the tab ID for chaining.
2. `get_state() → AppState` — tab list, current URL, view mode, selection,
   zoom, sidebar root, palette state. The missing half of today's API.
3. `select_tab(byIndex? | byId? | byPath?)` — three addressing modes.
4. `set_view_mode("source" | "rendered" | "auto")` — explicit, not toggle.
   Agents want set-state, not toggles.
5. `find(query, scope, caseSensitive, regex) → { matches }` — unifies
   in-doc find and cross-file search.
6. `goto_line(line, column?)` — scroll source view to a position.
7. `get_visible_text(format) → string` — read out what the user sees.
   High leverage for "summarize this doc" workflows.
8. `toggle_bookmark(line?)` + `list_bookmarks() → [...]` — paired CRUD.
9. `snapshot_window(format) → bytes|object` — PNG or JSON view tree, for
   testing and agent feedback loops.
10. `subscribe(events) → stream` — `tabChanged`, `fileChanged`,
    `selectionChanged`. Without this, agents have to poll.

These ten cover ~90% of `--script` today plus the missing read side.

## 7. Concrete API sketch

Swift-side wiring. The MCP server registers tool handlers that delegate to
`DocumentModel` on the main actor. Assumes a small `swift-mcp` package (Q1);
hand-rolled has the same shape.

```swift
// Sources/ViewerCore/Automation/AutomationAPI.swift
//
// Single source of truth for the action vocabulary. MCP, App Intents,
// and the legacy --script DSL all dispatch through this surface.

import Foundation

public protocol AutomationHost: AnyObject {
    @MainActor func openPath(_ url: URL, newTab: Bool) -> UUID
    @MainActor func selectTab(byId: UUID?) -> Bool
    @MainActor func setViewMode(_ mode: ViewMode)
    @MainActor func find(_ q: FindQuery) async -> FindResults
    @MainActor func gotoLine(_ line: Int, column: Int?)
    @MainActor func visibleText(as format: TextFormat) -> String
    @MainActor func snapshot(format: SnapshotFormat) throws -> Data
    @MainActor func currentState() -> AppState
}

public struct AppState: Codable, Sendable {
    public let tabs: [TabSnapshot]
    public let selectedTabIndex: Int?
    public let viewMode: ViewMode
    public let zoom: Double
    public let sidebarRoot: URL?
    public let selection: SourceSelection
    public let isPalettePresented: Bool
}

// Sources/MarkdownViewer/Automation/MCPServer.swift
//
// Owns the Unix-socket listener and translates MCP tool calls to
// AutomationHost calls. One handler per verb; schemas live next to
// the handler for locality.

@MainActor
final class MCPServer {
    let host: AutomationHost
    let socketURL: URL  // ~/Library/Application Support/TextView/mcp.sock

    func start() throws {
        try listener.bind(socketURL)
        register(tool: "open_path", schema: openPathSchema) { args in
            let path = try args.string("path")
            let newTab = (try? args.bool("newTab")) ?? true
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let tabId = self.host.openPath(url, newTab: newTab)
            return .object(["tabId": .string(tabId.uuidString)])
        }
        register(tool: "get_state", schema: emptySchema) { _ in
            try .json(self.host.currentState())
        }
        // ... eight more handlers, same shape ...
    }

    // Notifications: DocumentModel.$tabs.sink → server.publish("tabChanged", ...)
    func publish(_ event: String, _ payload: MCPValue) { /* fan out */ }
}

// Sources/MarkdownViewer/Automation/AppIntents.swift
//
// Thin facade over AutomationHost so Shortcuts can drive the same verbs.

import AppIntents

struct OpenInTextViewIntent: AppIntent {
    static var title: LocalizedStringResource = "Open in TextView"
    @Parameter(title: "Path") var path: String
    @MainActor func perform() async throws -> some IntentResult {
        let host = AppDelegate.shared.automationHost
        _ = host.openPath(URL(fileURLWithPath: path), newTab: true)
        return .result()
    }
}
```

`DocumentModel` conforms to `AutomationHost` — most methods already exist,
we're just gathering them under a protocol. `MCPServer` is the only new
non-trivial code; it's <300 LOC including schema definitions.

## 8. Security model

Default posture: **local-only, file-system-scoped, no exfil.** What
untrusted scripts/agents *cannot* do:

- **Bind scope.** Default transport is a Unix domain socket at
  `~/Library/Application Support/TextView/mcp.sock` (mode 0600, owner-only).
  TCP is **opt-in** via prefs, loopback only (`127.0.0.1`), never
  `0.0.0.0`. No mDNS/Bonjour advertising in v1.
- **No arbitrary FS reads.** `open_path` and `get_visible_text` only
  return paths/contents the user has already opened. No `read_file(path)`.
  Same trust surface as drag-and-drop.
- **No FS writes.** Viewer-only. No write/delete/move verbs. Hard line.
- **No shell execution.** No `run_command`, no `eval`.
- **No network egress on behalf of scripts.** App's own network code
  (none today) stays under app control.
- **Rate / size limits.** `get_visible_text` capped at 10 MB. Snapshot PNG
  capped at screen resolution. No verb may block main thread >100ms;
  long searches return a handle and stream via notifications.
- **Audit log** at `~/Library/Logs/TextView/mcp-audit.jsonl`: timestamp,
  tool name, argument hash, client connection ID. Visible in
  Settings → Automation.
- **First-connect prompt.** Non-modal banner on first connection from a
  new client. Revocable in Settings → Automation. All-or-nothing per
  client in v1, no per-tool grants.

Accepted residual risk: a malicious local process as the same user can
already do everything the MCP server can and more. We don't reduce attack
surface — we make legitimate automation pleasant. Not pretending otherwise.

## 9. Migration path from today's URL scheme

URL scheme stays. Freeze its verb set at today's two (`open`, `search`)
and document as the fire-and-forget tier. Steps:

1. **Land MCP behind a feature flag** (`mcpServerEnabled`, default off).
   Vocabulary + schemas + Unix-socket listener. Ship as opt-in.
2. **Backfill the read side.** `get_state`, `get_visible_text`,
   `list_bookmarks`, `snapshot_window`. This is the win that justifies
   the flag.
3. **Rewire `--script`** as a thin in-process MCP client. One vocabulary,
   two transports. Headless tests get richer assertions for free.
4. **Add App Intents** for the priority-10 actions. Ship Shortcuts
   examples in the README.
5. **Flip the flag on by default** once audit log + first-connect prompt
   land.
6. **URL scheme stays forever** as the trivial tier. New verbs go into MCP.

No breaking changes to URL scheme, `mdv`, `--script`, or NSServices.
Everything additive.

## 10. Non-goals

- **Editing.** Viewer-only. No `insert_text`, `replace_range`, etc. in v1
  or v2. If editing ships, it's its own major version + design doc.
- **Cross-host control.** Local only. No remote MCP, no SSH-tunneled
  agents in v1.
- **Plugin marketplace / discovery.** Same answer as `PLUGINS.md`.
- **AppleScript dictionary.** Not until refusing costs more than
  implementing.
- **In-process scripting (JS / Lua).** Plugin axis, see `PLUGINS.md`.
- **Macro record/playback GUI.** Own product.
- **Render-server mode** (streaming HTML to other apps). Users have the
  source.
- **Multi-app orchestration.** TextView exposes its own state. Cross-app
  coordination is the agent's job.

---

**Decisions I made without asking** (push back if any of these are wrong):
- App Intents ship in the same release as MCP, not later.
- Unix socket is the default transport; TCP is opt-in and loopback-only.
- No write/edit verbs in v1 — viewer-only stays as the hard invariant.
- `--script` mode gets rewired to use MCP internally instead of being
  deprecated, because headless tests already depend on it.
- URL scheme is frozen at today's two verbs; new automation goes into MCP.
