# Feature backlog audit (2026-06-05)

Source: `feature-backlog-audit` workflow (wf_332394c9, 40 agents) — every leaf item in the owner braindump classified against the codebase at `main @ e973e4e`.

**373 items** — implemented 211 · partial 62 · not-implemented 62 · ambiguous 21 · contradicting 6 · duplicate 6 · not-needed 4 · not-possible 1.

The **not-implemented** (62) and **partial** (62) items are/Will be filed on the `tasked` board. This doc is the four buckets you asked for — contradicting / not-needed / not-possible / extremely-ambiguous — plus duplicates, each with a one-line why.
## Contradicting (6)

- **Wishlist > LSP › Runner [Main/Run function etc]** — A code Run/Main runner conflicts with the explicit viewer mandate; LSP_DESIGN.md rejects code lens 'Run | Debug' as edit-adjacent and out of scope.
- **Wishlist > LSP › Test runner** — A test runner is execution functionality outside the read-only viewer mandate that bans run/debug/code-action surfaces; absent in code.
- **Wishlist > LSP › Debugger** — A debugger (DAP/breakpoints/launch) conflicts with the viewer-only mandate and is absent; also a major out-of-scope subsystem for a read viewer.
- **Text Edit > Next 2 > Feature › Why is Souce mode not having syntax higlight for JS, Java etc** — Premise is false against current code: Source mode highlights JS and Java — both have TreeSitter grammars, query files, and ship as lazy dylibs in the built app.
- **MarkdownViewer > Work > Terminal › xterm.js ?** — xterm.js was once floated (and noted 'decided' in an early door doc) but the actually-shipped terminal is the native custom build of #278 — the two approaches conflict and the native path won; no xterm.js in the codebase.
- **MarkdownViewer > Work > Improvements › Session independence. Everything in a sesssion needs its own state, tabs, selections, tool window states, scrool state etc.** — Tabs/selection/tool-window layout/scroll ARE already per-session, but the blanket 'everything needs its own state' conflicts with the owner-LOCKED (#184) design that zoom/theme/word-wrap/ui-scale/sidebar-width are deliberately GLOBAL ('duplicating per-session would be user-hostile').

## Not needed (4)

- **Far Future › Integrate SwiftTerm** — A working terminal already ships, but it is a custom PTY-backed direct-drawing NSView built deliberately to avoid the SwiftUI/NSScrollView compositor pathology — adopting SwiftTerm would be a redundant dependency superseding the in-house impl.
- **Far Future › Plugin PoC** — A Plugin PoC is superseded — Plugins shipped to v1 (Tier B subprocess host, registry, grant store, Settings pane, bundled RowCounterPlugin), bootstrapped at app launch.
- **Far Future › Walkthrough PoC** — A Walkthrough PoC is superseded — Walkthrough is a shipped feature (engine state machine, player UI, --walkthrough flag, drop transport, schema v2).
- **Far Future › MCP PoC** — An MCP PoC is superseded — MCP is fully shipped (MCPServer, --mcp-stdio headless mode, MCPToolCatalog, automation host conformance).

## Not possible (1)

- **Text Edit > Future › iOS Note app to read iCloud files** — Project is deliberately macOS-only (Package.swift platforms = .macOS(.v15)) AppKit/SwiftUI with Catalyst explicitly rejected in DESIGN.md; an iOS Notes/iCloud reader is a separate product, not feasible in this architecture.

## Extremely ambiguous (21)

- **Bugs › Sessions** — Bare 'Sessions' bucket header with no actionable content of its own; the actionable work is in child items #47/#48.
- **Bugs › Find** — Bare section header 'Find' with no actionable content; it is the parent grouping for #59/#60, not a discrete requirement.
- **Wishlist › Filenav** — 'Filenav' as a bare item is underspecified — a file-navigation sidebar tree already exists fully (SidebarView/SidebarModel with arrow/Enter keyboard nav), so it's unclear whether this is a parent label for the sub-items #109/#110 or a request for a new dedicated file-nav surface.
- **Wishlist › Image** — Bare 'Image' parent/umbrella header with no concrete requirement; the actual asks are its P0..P2 children (#114-119).
- **Wishlist › Extra** — Empty 'Extra' catch-all wishlist bucket with no content to action.
- **Wishlist › File** — Bare category header 'File' with no concrete ask — it only groups the File sub-items (#127-129); nothing actionable on its own.
- **Wishlist > Tools › Tokens** — 'Tokens' is underspecified - could mean JWT decode, token counting, or random-token generation; no token tool exists either way, but which one is unclear.
- **Text Edit › Overview window** — No feature named 'Overview window' exists; nearest candidates (find-match minimap, the planned 'Omni window', cross-search) are distinct, so the term needs owner clarification.
- **Text Edit > Next › Configuration management** — Underspecified — per-setting config already exists (PreferencesStore, ~/.textview/keybinding.json, full SettingsView), but whether this means config export/import/sync/profiles (absent) is unclear without owner clarification.
- **Text Edit > Future › Explore more what we can do in Headless mode** — Open-ended 'explore what we can do in headless mode' is a research prompt, not an actionable spec; a substantial headless surface already exists (MCP stdio, --script DSL, --diagnose, three Rust front-ends) so the unmet ask is undefined.
- **Text Edit > Next 2 > File menu › Show attribute beside?** — Phrased as an open question ('Show attribute beside?'); the recency stripe shows a time attribute visually but there's no inline textual size/date column, and the desired attribute is unspecified.
- **Text Edit > Next 2 › Feature** — Bare section header ('Feature') with no actionable content of its own; its children (#229, #230) are the real items.
- **Text Edit > Next 2 > Feature › Once we view CSV table, next render is wired** — CSV table view is fully shipped (.table mode / CSVTableView), but 'next render is wired' is too vague to know which next renderer is meant.
- **MarkdownViewer > Work › Cutomization, Scripting** — Customization/scripting is too broad to action as one item: substantial pieces already ship (CommandRegistry, KeybindingConfig, MCP automation host, Plugins v2 subsystem) while the AUTOMATION.md scripting surface is still a design draft — owner must scope what 'customization/scripting' means here.
- **MarkdownViewer > Work › Improvements** — Bare container/parent node ('Improvements') with no concrete deliverable specified — needs owner detail to action.
- **MarkdownViewer > Work > Improvements › Image** — Bare top-level 'Image' heading with no actionable content; its children (#282-285) are the real items, and the image previewer is already rich (MediaPreviewView.ImagePreview).
- **MarkdownViewer > Work > Improvements › Improvements** — Bare 'Improvements' container heading with no concrete ask; only meaningful child is #290.
- **MarkdownViewer > Work > Improvements > Improvements › Perf** — Bare 'Perf' header with no specific target; perf infrastructure already exists (PerfSignpost, mem-profile) but the item names no concrete improvement to action.
- **MarkdownViewer > Bug › Row count tool window is shown always and can't find a shoulder button to dismiss it** — Unclear which element 'row count tool window' is; if it's the always-on StatusBar/metrics strip (ContentView:237) it genuinely has no dismiss/shoulder toggle (real gap), but docked tool windows DO have a 'Hide this tool window' close button — owner must clarify the element.
- **MarkdownViewer > Bug › 3 Shoulder buttons not doniing anything [4,5,6] - like git log, changes etc.** — Shoulder rail buttons are all wired to panelLayout.toggle and do toggle their panels; buttons 4/5/6 are git/claude/outline (not 'log/changes'), and toggling forces a panel .shown even with no data, so 'doing nothing' likely means an empty panel — the item is imprecise about which buttons and what 'nothing' means.
- **Far Future › Absolutely hackable** — 'Absolutely hackable' is an aspirational goal, not an actionable item; substantial hackability already exists (clone-and-extend, MCP, --script DSL, plugins) but 'absolutely' has no defined bar to verify against.

## Duplicate (6)

- **Text Edit > Next › Mini VS Code type** — Same aspiration as #153/#155 — 'be a code editor like a major competitor'; substantively duplicates the Notepad++/Sublime parity buckets (CM6 editor + LSP already deliver the VS-Code-like core).
- **Text Edit > Next › Sublime type** — Same open-ended 'be like a competing editor' aspiration as #153/#154; no distinguishing Sublime-specific acceptance criteria given.
- **Text Edit > Next > Extensive Git repository visualizer › Think Windows Git visulizaer tool** — Child clarification of #157 ('think Windows Git visualizer tool' i.e. GitExtensions/TortoiseGit) — same feature, already delivered by the topo-graph Git panel.
- **Text Edit > Next 2 > Git panel should have tabs › Trees** — "Trees" is the same GitPanelModel.Tab.trees case as #204 Worktree (title "Trees", body GitWorktreesTab); already implemented and identical to #204.
- **Text Edit > Next 2 > Feature > Preview mode › Usefull when previewing images** — A sub-note of #236 (preview mode is 'useful when previewing images'); same feature, no separate scope.
- **Far Future > Code review assitant › Walk through** — Same feature as #344 ('Walk through' is the bare restatement of 'Agent will walk through code'); both are the implemented Walkthrough engine.

