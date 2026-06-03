# UAT smokes — master index

Durable, maintainable catalog of every UAT smoke across the app. Each area has
its own Markdown file (linked below); every smoke is listed by `id` + title so
this index stays grep-able as the catalog grows.

**App under test:** `dist/TextView.app` (Finder name TextView.app; bundle id
`com.markdownviewer.MarkdownViewer`).

## How to re-run

Re-execute the existing smoke catalog (skip discovery/authoring) by launching
the **giga-uat** workflow in run-only mode:

```js
Workflow({ name: "giga-uat", args: { mode: "run-only", date: "<today>" } })
```

`mode: "run-only"` reuses the authored `docs/uat/smokes/*.md` catalog and goes
straight to live execution against `dist/TextView.app`; it does **not**
re-mine git/docs/code or re-author smokes. A full pass (discovery + authoring +
execute) is the default `mode: "full"`. Per-run logs land in
`docs/uat/UAT_RUN_<date>.md`; remaining/staged bugs in `UAT_BUGS.md`; run state
in `docs/uat/UAT_RUN_STATE.md`.

## Maintenance

- One row per smoke; keep `id` and title verbatim in sync with the area file's
  `## <id> — <title>` heading.
- When you add/rename/remove a smoke, update both the area `.md` and this index
  in the same change.
- IDs are load-bearing (the executor maps them to T4 companion suites under
  `Tests/ViewerUITests/uat/`); never recycle a retired id for a different smoke.

## Consolidation notes (2026-06-03 dedup pass)

A redundancy sweep across all 13 areas merged/removed the duplicated smokes
below. **Total coverage is unchanged** — every surface, interaction, variation
and edge-state of a removed/trimmed smoke is still exercised by at least one
surviving smoke (named below). Retired ids are **not recycled** (the executor
keys T4 companions off ids); the area files keep a removal stub at the old id.

**Removed (pure duplicates):**

| Retired id | Was | Coverage now lives in |
|---|---|---|
| `SC-CHROME-03` | "Nested sessions: create/switch/rename/restore per-session tab set & sidebar" — a near-complete clone of the dedicated Sessions area | `SESS-01` (create/switch/tab-survival), `SESS-02` (GoTo new-session), `SESS-03` (rename), `SESS-05`/`SESS-07` (per-session sidebar/expansion/Open-As restore + bloat heal), `SESS-06` (GLOBAL zoom/wrap/theme #184), `SESS-10` (autosave), `SESS-11`/`SESS-12` (menu shortcuts + strip presence). The `SessionTabBar` chrome-composition angle moved to `SC-CHROME-05` step 5. |
| `SMK-SEARCH-07` | "CSV / SQLite in-viewer filtering alongside global find" — CSV/SQLite filter mechanics duplicated the Previews viewers | `PV-05` (CSV global/per-column/scope filters, persistence, ragged rows, large-file bound, split slot), `PV-04` (SQLite seeded SELECT, run/cancel, read-only authorizer, 1000-row cap, busy_timeout, split-unsupported). The one search-specific assertion — `Cmd+F` text-find is a **distinct surface** from the table filter, and SQLite **SELECT-is-the-search** — folded into `SMK-SEARCH-08` (new step 6). |

**Trimmed to a focused scope + cross-reference (no longer re-walk another area's owned surface):**

| Smoke | Trimmed duplication | Pointed at |
|---|---|---|
| `SC-CHROME-02` | Open-As exhaustive list / carry-mode / latest-switch-wins **Bug C** race (kept only the ModeBar *chrome rendering* of picker/chip/badge/toggles + high-zoom) | `VM-06` |
| `SC-CHROME-05` | rail per-kind toggles / `SidebarDataPresence` fill / divider gating / forced-placeholder *content* (kept only the chrome-pin invariant under over-subscription + resize, Bug A, + `SessionTabBar` stack order) | `SFB-05`, `SFB-06` |
| `VM-02` | the editor *lifecycle* (save entry points, save-on-blur, undo, **conflict prompt**, cap, fold/go-to-line, cursor restore) — kept Source↔Editor↔HEX routing + text-vs-binary classification | `cm6-1`..`cm6-5` (conflict → `cm6-4`) |
| `VM-03` | full jq pipeline (run/cache/alerts/caps/css-xpath-absence) — kept only "jq enabled for JSON" | `SMK-SEARCH-06` |
| `VM-04` | HEX viewer internals (search modes/validation/stepping/caps/click-highlight/width) — kept Preview↔HEX *routing*, fresh-image→HEX (Bug B), SQLite-not-HEX, binary picker-hidden, #218 | `PV-07`, `SMK-SEARCH-05` |
| `PV-06` | exhaustive Open-As + mode-switch **Bug C** race — kept the preview-category default-mode matrix + HEX fallback + picker-hidden | `VM-06`, `SC-CHROME-02` |
| `PV-08` | single-folder sibling-nav mechanics — kept cross-folder enumeration discard + sidebar/status interplay | `PV-01` |
| `SC-MENU-03` | find-bar *internals* (per-mode controls/bags/regex) — kept `⌘F`/`⌘Z`/`⇧⌘G`/`⌘W` accelerator *routing* + app-quit guard gap | `SMK-SEARCH-01` |
| `SC-MENU-04` | session activation/LRU/collision *behavior* — kept Session-menu *presence + accelerator wiring* + Debug-gating + `--mcp-stdio` menu-absence | `SESS-11`, `SESS-12` |
| `SFB-09` | File-History *view* (master-detail/range compare) — kept the context-menu entry point + tracked-ness gating | `GP-09` |
| `SFB-10` | New-Session/Set-as-Git-Root/Search-in-Folder *destinations* — kept the folder context-menu entry points | `SESS-01/05`, `GP-07/10`, `SMK-SEARCH-03/04` |
| `SFB-12` | session-machinery edges (capture/leak/clamp/downgrade) — kept sidebar-prefs (show-hidden/sort/recency/bookmarks) persistence | `SESS-05/06/07` |

These trims preserve each smoke's distinct end-to-end story while pushing
shared mechanics to their single owning area, so a surface is asserted once
(deeply) rather than re-walked thinly in 2-3 places.

## Catalog

13 areas covered (87 active smokes; `SC-CHROME-03` and `SMK-SEARCH-07` retired
from the original 89). Click an area to open its smoke file.

### [Tabs & Window Chrome](./tabs-and-window-chrome.md)

`tabs-and-window-chrome` — TabBar / ModeBar / StatusBar / shoulder rails / split / chrome-pin.

| ID | Title |
|----|-------|
| `SC-CHROME-01` | Multi-tab lifecycle: open, switch, dirty-dot, close-with-prompt, neighbor-selection |
| `SC-CHROME-02` | ModeBar view-mode routing + Open As override + language badge in one flow |
| ~~`SC-CHROME-03`~~ | *Removed (duplicate of the Sessions area) — id retired, see Consolidation notes* |
| `SC-CHROME-04` | StatusBar fidelity: live Ln/Col, metrics, stale-on-disk Modified chip, type-aware fields |
| `SC-CHROME-05` | Chrome-pin invariant: rails + accordion over-subscription and resize never blank/compress the bars |
| `SC-CHROME-06` | Split view + zoom + window-drop, all chrome bars cooperating |

### [Sidebar: File Tree & Bookmarks](./sidebar-filetree-and-bookmarks.md)

`sidebar-filetree-and-bookmarks` — FILES tree, BOOKMARKS, accordion rails, git-aware sidebar, context menus.

| ID | Title |
|----|-------|
| `SFB-01` | Open a folder, navigate the tree, open files into tabs, follow-active-tab re-roots |
| `SFB-02` | Keyboard-only tree navigation with auto-scroll and collapse/expand |
| `SFB-03` | Bookmark a file from the tree and from the tab; verify mirror across FILES, BOOKMARKS, palette, status |
| `SFB-04` | Line-level bookmarks: set, mirror to gutter, jump back, filter by kind |
| `SFB-05` | Shoulder rail panel toggles drive the accordion; data-presence dims/fills icons |
| `SFB-06` | Resize the sidebar and individual accordion panels; persistence across relaunch |
| `SFB-07` | Sort & recency-color modes; recency heatmap stripe reflects file age |
| `SFB-08` | Git-aware sidebar: status badges, repo-root glyphs, folder-stats panel |
| `SFB-09` | File context menu: Open in New Tab / Split / Open As / Copy Path / Reveal / File History |
| `SFB-10` | Folder context menu: Open in New Session, Set as Git Root, Search in Folder, Open in Terminal |
| `SFB-11` | Reveal-in-Sidebar from a tab, with Files-lock interplay |
| `SFB-12` | Show-hidden, sort, recency, bookmarks all persist per-session across relaunch |

### [View Modes](./view-modes.md)

`view-modes` — source / editor / hex / rendered / preview / formatted routing & persistence.

| ID | Title |
|----|-------|
| `VM-01` | Markdown: default Rendered, ⇧⌘R round-trip to Source, find in both, zoom carries |
| `VM-02` | Same text file across Source ↔ Editor ↔ HEX (dirty state, save, mode carry, large-file caps) |
| `VM-03` | Structured data: CSV Table ↔ Source, JSON Format (Pretty-Print) ↔ Source, and Open-As cross-routing |
| `VM-04` | Native preview vs HEX routing (fresh-image→HEX + carry-flip regressions; HEX internals → PV-07/SMK-SEARCH-05) |
| `VM-05` | Diff & HTML specialized rendered views, plus the universal Empty/Loading/Error envelope |
| `VM-06` | Mode persistence, split view, and Open-As exhaustive coverage in one session |

### [CM6 Editor](./cm6-editor.md)

`cm6-editor` — edit / save / dirty / close, undo-redo bridge, conflict prompts, capacity caps.

| ID | Title |
|----|-------|
| `cm6-1` | First edit makes a tab dirty, ⌘S clears it, status/tab reflect the round-trip |
| `cm6-2` | Undo/redo across the AppKit menu ↔ CM6 JS bridge, with find/replace |
| `cm6-3` | Close a dirty tab: Save / Don't Save / Cancel prompt, and the app-quit gap |
| `cm6-4` | External edit while dirty: the conflict prompt (Keep My Edits / Discard & Reload) |
| `cm6-5` | Editor capacity, mode-routing, indentation/fold/go-to-line, and per-tab cursor restore |

### [Search](./search.md)

`search` — find-bar / cross-file / unified panel / jq / css / xpath.

| ID | Title |
|----|-------|
| `SMK-SEARCH-01` | Find-bar isolation across view modes (rendered → source → editor) |
| `SMK-SEARCH-02` | Cross-file search modal: scope, jump-to-line, and skip rules |
| `SMK-SEARCH-03` | Cross-file file-scope folder-fallback + reserved jq/css/xpath modes |
| `SMK-SEARCH-04` | Search Anywhere sidebar panel: live debounce, scope, jump |
| `SMK-SEARCH-05` | HEX viewer search: hex/ASCII modes, validation, stepping, caps |
| `SMK-SEARCH-06` | jq filter pipeline (Format/JSON → result tab) with absence + error handling |
| ~~`SMK-SEARCH-07`~~ | *Removed (CSV/SQLite filters → PV-04/PV-05; find-vs-filter boundary folded into SMK-SEARCH-08) — id retired* |
| `SMK-SEARCH-08` | Cross-surface search continuity & open-at-line consistency (+ `Cmd+F`-vs-CSV/SQLite-filter surface boundary) |

### [Git Panel](./git-panel.md)

`git-panel` — status / log / stash / trees / remotes / review tabs, multi-repo, refresh policy, history.

| ID | Title |
|----|-------|
| `GP-01` | Open a repo, walk every tab, verify counts/badges/empty-states and the on-switch refresh |
| `GP-02` | Status tab: grouping, click-to-open, Show Diff → structured DiffView, badge colors |
| `GP-03` | Log tab: commit graph, HEAD/branch/tag chips, lazy pagination, commit → diff tab, hard cap |
| `GP-04` | Stash tab: Apply / Pop / Show / Drop (destructive confirm) with live working-tree mutation |
| `GP-05` | Trees tab: worktree rows, CURRENT/LOCKED/PRUNABLE chips, click-to-navigate (prunable disabled) |
| `GP-06` | Remotes tab: name / URL / last-fetch, ssh→https translation, web-open, file:// no-op |
| `GP-07` | Multi-repo: header repo picker, focus-follow, explicit pin, and pin release on focus-move |
| `GP-08` | Refresh policy: on-window-focus, 60s timer, manual ⌥⌘R, equality-guarded no-op |
| `GP-09` | File History: master-detail commits, single-commit modes, Cmd-click range compare |
| `GP-10` | Folder & Repository History; File History gating on tracked-ness |
| `GP-11` | Menu / rail entry points and section collapse interplay |

### [Sessions](./sessions.md)

`sessions` — tabs-within-tabs / nested workspaces, LRU, per-session capture, restore, autosave.

| ID | Title |
|----|-------|
| `SESS-01` | Create two sessions, each keeps its own tabs across a switch |
| `SESS-02` | + button → Go-to-path prompt → new session (empty-entry flow) |
| `SESS-03` | Rename a session inline; persists and survives relaunch |
| `SESS-04` | LRU re-activation: closing active selects most-recently-used, not adjacent |
| `SESS-05` | Per-session split pane, sidebar expansion & include-hidden captured per session (no leak) |
| `SESS-06` | GLOBAL zoom / word-wrap / theme are app-wide, NOT per-session |
| `SESS-07` | Restore on relaunch: skip unreadable/missing-root, never re-root at HOME, heal bloat |
| `SESS-08` | Inactive-session watcher paused; active session auto-reloads; no cross-session stale events |
| `SESS-09` | Per-session shoulder-rail panel layout: seed-once per kind, user edits win, persisted |
| `SESS-10` | Crash-recovery autosave: last ~500ms of live state survives a SIGKILL between switches |
| `SESS-11` | Jump-to-Session menu, ⌃1–9 shortcuts, and Session/Window menus reflect live state |
| `SESS-12` | Single-session layout: strip presence & context-menu affordances scale with session count |

### [LSP](./lsp.md)

`lsp` — hover / go-to-def / outline / refs / diagnostics.

| ID | Title |
|----|-------|
| `LSP-01` | First-touch TS file: server cold-start drives Outline + hover + Problems together |
| `LSP-02` | Navigate by symbol: Cmd-click definition + right-click nav submenu + Outline jump in one flow |
| `LSP-03` | Workspace symbols + Problems severity filtering + cross-file diagnostic navigation |
| `LSP-04` | Resilience: server crash/restart, position-encoding correctness, language-gating, and diagnostics-window honesty |

### [Plugins & MCP Automation](./plugins-and-mcp-automation.md)

`plugins-and-mcp-automation` — MCP handshake/tools, --script verbs, plugin grant/tier sandbox.

| ID | Title |
|----|-------|
| `SMOKE-PMA-01` | MCP handshake + drive a real document end-to-end |
| `SMOKE-PMA-02` | MCP path containment, error taxonomy, and malformed framing |
| `SMOKE-PMA-03` | MCP bookmarks round-trip + window snapshot, headless |
| `SMOKE-PMA-04` | --script verb dispatch drives the model headlessly |
| `SMOKE-PMA-05` | Plugin first-install grant prompt → sidebar render → revoke → re-prompt |
| `SMOKE-PMA-06` | Tier B plugin failure taxonomy + subprocess sandbox containment |
| `SMOKE-PMA-07` | Bundled Row Counter plugin + plugin load isolation |

### [Previews](./previews.md)

`previews` — image / audio / video / pdf / sqlite / csv / hex fallback.

| ID | Title |
|----|-------|
| `PV-01` | Image preview: open, fit/zoom/pan, sibling navigation, metadata, never-HEX-on-open |
| `PV-02` | Audio & video preview: playback transport, metadata, full-screen affordance differences |
| `PV-03` | PDF preview: page navigation, zoom, metadata, large-file & HEX routing |
| `PV-04` | SQLite browser: schema sidebar → seeded query → results, read-only enforcement, cancel |
| `PV-05` | CSV/TSV table: filter (global + per-column + scope), column resize, virtualization, persistence |
| `PV-06` | Default-mode routing per preview category + HEX fallback (Open-As exhaustive/race → VM-06) |
| `PV-07` | HEX viewer as universal fallback: dump, search (hex & ASCII), width, click-highlight |
| `PV-08` | Media tab × sidebar × status-bar interplay (cross-folder enumeration discard; sibling-nav mechanics → PV-01) |

### [Settings, Menus & Shortcuts](./settings-and-menus-and-shortcuts.md)

`settings-and-menus-and-shortcuts` — dynamic menu validation, Settings window, shortcut collisions.

| ID | Title |
|----|-------|
| `SC-MENU-01` | Dynamic menu validation: labels & enable-state track the active tab's type and view mode |
| `SC-MENU-02` | Open Recent + Window menu + per-tab number shortcuts + documented shortcut collisions |
| `SC-MENU-03` | Find accelerator routing, Edit clipboard, and the unsaved-edits guard gap |
| `SC-MENU-04` | Session menu + Debug-menu gating + menu-bar absence in headless modes |
| `SC-SET-01` | Settings window: dedup, live two-way binding to the document window, and menu reflection |
| `SC-SET-02` | Advanced: Clear All bookmarks (destructive confirm) + Reset window state (now real) |
| `SC-SET-03` | Privacy, Plugins, and LSP Diagnostics: the deep-link and tool-window launchers |

### [Walkthrough & Code Review](./walkthrough-and-code-review.md)

`walkthrough-and-code-review` — walkthrough engine/transport, code-review threads, honest-gaps coverage.

| ID | Title |
|----|-------|
| `WCR-01` | CLI-launched v1 walkthrough: auto-advance through openFile + revealLine + highlightRange + setView, driven by the transport bar |
| `WCR-02` | Multi-target walkthrough: showPopover anchoring + splitFile + revealInSidebar + openGitPanel + addBookmark |
| `WCR-03` | awaitUser silent-halt + Note-button + runDiff + schema-rejection: the honest-gaps walkthrough |
| `WCR-04` | Code review end-to-end: seeded threads → diff overlay with severities/staleness → resolve → Mark Complete → Export |
| `WCR-05` | Empty/zero-review states + project-local store + flush-race durability + drop-transport gating |
| `WCR-06` | Walkthrough + Code Review intended-integration boundary: Note-during-review-of-a-diff (currently decoupled) |
