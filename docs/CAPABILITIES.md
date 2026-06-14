# TextView — Capabilities & How-To

A user-facing answer to "how do I actually *use* feature X" — automation (MCP),
the TUI/Web front-ends, LSP, code review, and Claude-Code monitoring. (Design
docs live alongside this: `AUTOMATION.md`, `LSP_DESIGN.md`, `CODE_REVIEW_DESIGN.md`,
etc. — those are for builders; this is for the user.)

Legend: ✅ works today · ⚠️ backend built but not surfaced in the UI · 📐 design-only.

---

## 1. Driving the app from a terminal / a script (CLI surfaces)

| Surface | Invoke | Use it for |
|---|---|---|
| **`textview` command** ✅ | Install via **Help ▸ Install '`textview`' Command**, then `textview file.md` | Open files from a shell, like VS Code's `code`. |
| **`--script PATH`** ✅ | `MarkdownViewer --script steps.txt` | Headless UI automation — a verb per line (see below). |
| **`--mcp-stdio`** ✅ | `MarkdownViewer --mcp-stdio` | Programmatic control over JSON-RPC (§2). |
| **`--claude-monitor`** ✅ | `MarkdownViewer --claude-monitor` | Standalone Claude-session monitor window (§5). |
| **URL scheme** ✅ | `open "markdownviewer://open?path=/abs/file.md"` · `…//search?root=/p&q=hi` · `…//walkthrough?path=demo.json` | Deep links. |

`--script` verbs (one per line, `#` comments): `open PATH`, `toggle-view`,
`toggle-sidebar`, `zoom-in/out/reset`, `new-tab`, `close-tab`, `next-tab`,
`prev-tab`, `select-tab N`, `show-palette`, `find`, `goto-line N`,
`ui-click ID`, `delay SECS`, `resize WxH`, `snapshot`. Each step writes a
`mdv-step-NN.{json,png}` diagnostic.

---

## 2. MCP — programmatic automation (answers TSK-802)

The app speaks **MCP (Model Context Protocol) over JSON-RPC 2.0** on **stdin/stdout**
(not a socket). Launch it headless (no Dock/window):

```bash
MarkdownViewer --mcp-stdio
```

Then write newline-framed JSON-RPC to its **stdin** and read replies from **stdout**.
Methods: `initialize`, `tools/list`, `tools/call`, `ping`, `shutdown`
(protocol `2024-11-05`; server `{name:"TextView", version:"1.0.0"}`).

**The 10 tools:**

| Tool | Args | Does |
|---|---|---|
| `open_path` | `path`, `newTab?` | Open a file/folder → returns `tabId`. |
| `select_tab` | `byIndex` (1-based) \| `byId` | Switch tab. |
| `set_view_mode` | `mode` (rendered/source/formatted/table/diff/hex) | Change view mode. |
| `find` | `query`, `regex?`, `caseSensitive?`, `wholeWord?` | Search → up to 1000 matches (line/col/byte). |
| `goto_line` | `line` (1-based), `column?` | Scroll source to a position. |
| `visible_text` | — | Current tab's text (10 MB cap). |
| `current_state` | — | Snapshot: tabs, selection, zoom, sidebar root, palette. |
| `toggle_bookmark` | `line?` | Toggle a line/file bookmark. |
| `list_bookmarks` | — | All persisted bookmarks. |
| `snapshot_window` | — | Window PNG, base64. |

**Example** (pipe three requests into the running server):

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"open_path","arguments":{"path":"/Users/me/README.md"}}}' \
  | MarkdownViewer --mcp-stdio
```

Zero new dependencies (roll-our-own stdio JSON-RPC). Cut from v1: event
streaming, Unix-socket/TCP transports, App-Intents.

---

## 3. The TUI and Web front-ends (answers TSK-784)

Both are pure-Rust front-ends over `mdvcore-core` (no FFI, no JS framework). They
are **not** part of the macOS app build — run them from the rust workspace:

```bash
# Terminal UI (ratatui)
cargo run -p mdvcore-tui -- ~/Documents          # browse a folder
cargo run -p mdvcore-tui -- --snapshot file.md   # headless render, no TTY
#   keys: ↑/↓ nav · ↵ open · ⌫ back · x text/hex · n line-nums · f find · o outline · q quit

# Web UI (std-only HTTP/1.1, localhost only)
cargo run -p mdvcore-web -- ~/Documents          # → http://127.0.0.1:8765/
cargo run -p mdvcore-web -- --port 9999 ~/Notes  # custom port
```

Both ✅ work today; session state persists under `~/.textview/{tui,wui}/config`.
The web server binds **127.0.0.1 only** (never network-exposed), caps at 128
connections, 15 s socket timeout, HTML-escapes everything, no auth (localhost).

---

## 4. LSP — what you can see & do (answers TSK-803)

Phase 1 ships **sourcekit-lsp** (Swift): navigation + info, **plus Format
Document / Rename Symbol / Code Actions** (now surfaced in the **Edit ▸
Language** section). Code **completion** remains out of scope for now.
sourcekit-lsp is found via the Swift toolchain automatically; if the **Outline**
populates for an open code file, the server is working.

| Capability | Trigger | Status |
|---|---|---|
| **Hover** (type + docs) | Pause the mouse over an identifier ~300 ms | ✅ |
| **Go to Definition** | **⌘-click**, **Navigate** menu, or `lsp.gotoDefinition` in the palette | ✅ |
| **Go to Declaration / Type / Implementation** | **Navigate** menu (or `⌘K` → `lsp.goto…`) — wired 2026-06-13 | ✅ |
| **Document Outline** | Auto-fills the sidebar Outline panel for code files | ✅ |
| **Diagnostics / Problems** | Auto: gutter underlines + a sidebar Problems list | ✅ |
| **Format Document / Rename Symbol / Code Actions** | **Edit ▸ Language** section (or the palette) — wired 2026-06-13 | ✅ |
| **Find References** | backend exists, no results-panel UI yet (use ⌘⇧F cross-search meanwhile) | ⚠️ |
| **Workspace Symbols** | backend exists, no results-panel UI yet | ⚠️ |

All LSP commands are rebindable in `~/.textview/keybinding.json`
(`{"lsp.gotoDefinition":"cmd+alt+d", …}`). See the full shortcut list under
**Help ▸ Keyboard Shortcuts**.

---

## 5. Code review (answers TSK-796)

Review git diffs with inline comments, stored project-locally.

- **Start:** open a diff (Git panel ⌥⌘⇧B → Status → click a file), then *New
  Review from Diff…* (palette `⌘K` → "review").
- **Comment:** hover a diff line's gutter → click **+** → pick a severity
  (info/suggestion/issue/blocker/question/praise), write Markdown, **⌘↩** to save.
- **Manage:** Edit / Resolve / Delete / Reply on each comment card.
- **Export:** *Review ▸ Export Current Review* → clipboard (`⌘⇧E`) or a JSON file
  (self-contained, schema `textview.code-review` v1).
- **Stored:** `<repo>/.textview/reviews/<ulid>.json` (git-ignored by default; set
  `"tracked": true` in `.textview/config.json` to commit them).
- ⚠️ Stage-3 bits still landing: multi-line comment ranges, the right-rail
  comments index, the draft→sent state pills.

---

## 6. Monitoring Claude Code (answers TSK-801 / TSK-804)

Read-only views over `~/.claude` transcripts. **Everything is redacted**
(credentials / headers / image blobs stripped) before it reaches the screen.

- **Sidebar "Claude" panel** ✅ — auto-appears when the open project has Claude
  sessions; reverse-chronological events with timestamps + snippets; ↻ to reload.
  Hidden when the project has no transcripts.
- **Standalone monitor window** ✅ — `MarkdownViewer --claude-monitor`: a
  session list (left) + the selected session's transcript (right), with a
  **session-name filter** and a **full-text Content search** across all sessions
  (`ClaudeTranscriptSearch` — case-insensitive substring; no regex/booleans).
  Manual refresh (no live polling); caps at 20k events defensively.

---

*Maintained as the answer to the 2026-06-13 "how does X work" wishlist questions.
Update 2026-06-13: the LSP goto-variants now have a **Navigate** menu and
Format/Rename/Code-Actions an **Edit ▸ Language** section (TSK-823/824). The
remaining "⚠️ backend not surfaced" items are real follow-up candidates (a
results panel for LSP **Find References** / **Workspace Symbols**; finish
code-review stage 3).*
