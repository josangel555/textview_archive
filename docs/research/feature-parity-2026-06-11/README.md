# Feature Parity Review — TextView vs TextEdit / Sublime Text / VS Code / IntelliJ IDEA

*2026-06-11. Inventory built from source-of-truth (DESIGN.md, README.md, UI_CATALOG.md,
MANUAL_TESTING.md, `CommandRegistry+BuiltIn.swift`, `Sources/ViewerCore/`,
`Sources/ViewerUI/`, the CM6 build entry `scripts/codemirror-build/entry.js`), with
spot-checks for present-but-unwired code. Reference-editor facts cross-checked against
current releases (Sublime Text 4, VS Code ~1.124, IntelliJ 2026.x, macOS Sequoia TextEdit).*

---

## 1. Executive summary

**What tier the app actually competes in.** TextView is no longer the "viewer, not
editor" of DESIGN.md's original non-goals. As shipped it is a **fast native
viewer-first workbench**: markdown/code/CSV/hex/SQLite/diff/media viewing with a real
CodeMirror 6 editing mode, LSP navigation (hover/outline/goto/references/diagnostics/
format), a tabbed git inspector (status/log+graph/stash/remotes/worktrees), an
integrated PTY terminal, sessions/workspaces, split panes, a command palette, cross-file
search, a subprocess plugin host, an MCP automation server, and a unique Claude Code
activity monitor + walkthrough/code-review layer. That places it **solidly above
TextEdit, at roughly Sublime-class for navigation/viewing, below Sublime for raw text
manipulation, and deliberately below VS Code/IntelliJ on the IDE axis.**

**Where it wins:**

- **vs TextEdit** — wins everywhere except rich text, printing, autosave/Versions, and
  spellcheck. TextView views *vastly* more formats and adds git/search/tabs/sessions.
- **vs Sublime** — wins on *viewing*: rendered markdown + Mermaid, hex/CSV/SQLite/media
  viewers, git panel depth, terminal, LSP out-of-the-box (Sublime needs plugins),
  live file watching/tail, Claude monitor, MCP automation. Loses on text-manipulation
  ergonomics (multi-cursor, snippets, minimap, Goto-Anything unification).
- **vs VS Code** — wins on launch speed, memory, native feel, bundle size (≤48 MB vs
  ~350 MB+), zero-config viewers (hex/CSV/SQLite built in, not extensions), bounded
  large-file handling, and agent-observability (Claude timeline; VS Code has nothing
  comparable). Loses on completion, extensions, debugging, remote, settings sync.
- **vs IntelliJ** — wins on everything IntelliJ is bad at: cold start, footprint,
  viewing arbitrary files instantly. The IntelliJ comparison is a borrow-list, not a
  parity race: local history, rename refactor, structural niceties.

**The 10 highest-value gaps** (full ranking in §5):

1. **Multi-cursor editing** — CM6 ships `rectangularSelection`/`drawSelection` but the
   `allowMultipleSelections` facet + `selectNextOccurrence` (⌘D) are NOT enabled. Table
   stakes for any editor claim; near-free to turn on.
2. **Autocomplete** — no completion of any kind (not even word-based; `@codemirror/autocomplete`
   is absent from the bundle, and there is no LSP `textDocument/completion`).
3. **Print + export-rendered-to-PDF** — zero print path (`NSPrintOperation` unused). The
   single TextEdit-baseline feature a *viewer-first* product is most expected to have.
4. **Unified Goto Anything** — we have the pieces (⌘K palette, ⇧⌘G go-to-path, ⌘L go-to-line,
   LSP workspace symbols) as four separate surfaces; Sublime's `⌘P` + `@`/`:`/`#` operators
   is one. Consolidation, not new machinery.
5. **Project-wide replace** — `CrossFileSearch` is read-only; no replace-across-files.
6. **LSP rename + code actions** — plumbing (LSPClient, LSPTextEditApplier) exists;
   `rename`/`codeAction` requests just aren't issued. Cheapest "IDE feel" win available.
7. **Spellcheck for prose** — a markdown-first product with no `NSSpellChecker`/CM6 spell
   layer in edit mode; TextEdit beats us here.
8. **Local history / versions** — `LocalHistoryStore.swift` exists but is **unwired**
   (no consumers outside its own file). IntelliJ's most-loved safety net; TextEdit has
   Versions. We have the store, not the feature.
9. **Markdown outline panel** — `MarkdownOutline.swift` parses headings (tested) but no
   UI consumes it; the sidebar OUTLINE section is LSP-only, so `.md` files — the
   namesake format — have no outline navigation.
10. **Editor git gutter (changed-line markers) + inline blame** — git panel is strong,
    but the per-line editing surface shows nothing; Sublime/VS Code/IntelliJ all do.

---

## 2. Parity matrix

Legend: **full** = at or above the reference bar · **partial** = exists with real limits ·
**none** = absent. Cell nuance in one word/phrase.

| Dimension | TextView | TextEdit | Sublime | VS Code | IntelliJ |
|---|---|---|---|---|---|
| Plain-text view/edit | **full** (CM6, 50 MB edit cap) | full | full | full | full |
| Rich text (RTF/.docx) | **none** (deliberate) | full | none | none (ext) | partial |
| Markdown rendered preview | **full** (GFM, Mermaid, CSP-locked) | partial (no md) | none (plugin) | full (side-by-side) | full |
| Syntax highlighting | **full** (TreeSitter, lazy grammars) | none | full | full | full |
| Autocomplete / IntelliSense | **none** | none | partial (word+plugin) | full (LSP) | full (semantic) |
| Multi-cursor / column select | **partial** (rect-select only, no multi-caret facet) | none | full (100k cursors) | full | full |
| Snippets | **none** | none | full | full | full (live templates) |
| In-file find/replace (regex) | **full** (mode-routed find; replace editor-only) | partial (no regex) | full | full | full |
| Project-wide search | **full** (gitignore-aware, streaming panel) | none | full | full | full |
| Project-wide replace | **none** | none | full | full (preview) | full (structural) |
| Fuzzy file open | **partial** (⌘K recents/tabs + ⇧⌘G path; not one unified box) | none | full (Goto Anything) | full (⌘P) | full |
| Command palette | **full** (commands + text tools) | none | full | full | partial (dbl-shift) |
| Symbol outline / goto symbol | **partial** (LSP languages only; md outline unwired) | none | full | full | full |
| LSP depth | **partial** (hover/goto×4/refs/symbols/diagnostics/format — no completion/rename/actions) | none | partial (plugin) | full | full (own engine) |
| Refactoring (rename+) | **none** | none | none | partial (LSP) | full |
| Tabs + splits | **full** (tabs, 2-pane split, swap) | partial (windows) | full (grids) | full | full |
| Sessions / workspaces | **full** (named sessions, ⌃Tab, snapshot restore) | none | full (projects) | full (workspaces+profiles) | full |
| Minimap | **partial** (find-match minimap only) | none | full | full | partial |
| Code folding | **full** (fold gutter, fold/unfold-all, syntax ranges) | none | full | full | full |
| Git integration | **full** (status/log-graph/stash/remotes/worktrees/file-history/diff) | none | partial (Sublime Merge upsell) | full (+staging UI) | full |
| Editor git gutter / blame | **none** | none | partial (plugin) | full | full |
| Diff viewer | **full** | none | partial | full (3-way merge) | full |
| Integrated terminal | **full** (own PTY/ANSI engine, dockable, tabs) | none | none (plugin) | full (IntelliSense) | full |
| Hex viewer/editor | **full** (mmap multi-GB, search, edit buffer) | none | none | partial (ext) | partial (plugin) |
| CSV table viewer | **full** (Rust parser, filter/find/cursor) | none | none | partial (ext) | full (table edit) |
| SQLite browser | **full** | none | none | partial (ext) | full (DataGrip-lite) |
| Media (img/audio/video/PDF) | **full** (+image & audio *editing*) | partial (rtfd attach) | none | partial (img only) | partial |
| Diagram render (Mermaid/dot) | **full** (Mermaid + DotGraph) | none | none | partial (ext) | full |
| Large files | **full** (two-tier cap to 512 MiB, bounded RSS) | partial | full (GB-class) | partial (degrades) | partial (refuses) |
| File watching / live tail | **full** (FSEvents, change flash, tail) | none | partial (reload prompt) | partial | partial |
| Plugins / extensions | **partial** (subprocess host, manifests; no marketplace) | none | full (Package Control) | full (marketplace) | full |
| Themes / appearance | **partial** (2 syntax themes + system) | partial | full | full | full |
| Custom keybindings | **full** (`keybinding.json`, registry IDs) | none | full | full | full |
| Settings sync / profiles | **none** | n/a (iCloud docs) | none | full | full |
| Debugging | **none** (deliberate) | none | none (plugin) | full (DAP) | full |
| Remote dev | **none** (deliberate) | none | partial (sftp) | full (SSH/WSL/containers) | full (Gateway) |
| Printing / PDF export | **none** | full | partial (plugin) | partial (ext) | full |
| Autosave / versions / local history | **partial** (save-on-blur, external-edit conflict; LocalHistoryStore unwired) | full (Versions) | full (hot exit) | full (+timeline) | full (Local History) |
| Spellcheck | **none** | full (system) | partial (dict) | partial (ext) | full (+grammar) |
| AI / agent integration | **partial** (observes agents: Claude timeline, transcript search, MCP server) | none | none | full (Copilot agent HQ) | full (AI Assistant) |
| Scriptable automation surface | **full** (MCP tools, script verbs, diagnostic dumps, CLI) | partial (AppleScript) | full (Python API) | full (ext API, CLI) | partial |
| Code review / walkthrough authoring | **full** (comment cards, export, guided walkthroughs) | none | none | partial (PR ext) | partial |
| Claude Code activity monitor | **full** (timeline, live, transcript search) | none | none | none | none |

---

## 3. Per-editor comparison

### 3.1 vs TextEdit — the "can it fully replace it" bar

**Verdict: replaces TextEdit for plain text outright; cannot for rich text.** Four real
gaps, all baseline-Mac expectations rather than editor features.

Notable features we lack (ranked by value to this product):

1. **Printing & PDF export** — TextEdit prints anything; we print nothing. For a
   *viewer*, "⌘P the rendered markdown" is the most-asked baseline ask. WKWebView gives
   `printOperation`/`createPDF` nearly free (already noted in DESIGN.md §13, never built).
2. **System spellcheck** — TextEdit gets `NSSpellChecker` for free; our CM6 edit surface
   has none. Markdown is prose; this hurts more here than in a code editor.
3. **Autosave + Versions** — TextEdit's continuous autosave/Versions browser. We have
   save-on-blur and external-edit conflict prompts, which is weaker; `LocalHistoryStore`
   exists unwired.
4. **Rich text (RTF/.rtfd/.docx) editing** — deliberate non-goal (§4); but note we don't
   even *view* RTF/docx (could render read-only via `NSAttributedString` import cheaply).
5. Dictation/Services text integration, text-to-speech — minor, mostly free with
   NSTextView but our editor is a WebView.

Features we have that TextEdit lacks: essentially the entire product — rendered
markdown, syntax highlighting, tabs/sessions/splits, sidebar tree, git, search-in-folder,
hex/CSV/SQLite/diff/media, terminal, LSP, palette, plugins, MCP, Claude monitor.

### 3.2 vs Sublime Text — the fast-editor bar

**Verdict: we match its *speed ethos* and beat it on viewing surfaces; we lose on
text-manipulation ergonomics, which is Sublime's entire identity.**

Notable features we lack (value-ranked):

1. **Multi-cursor / select-next-occurrence (⌘D)** — Sublime's signature; stays usable at
   100k+ cursors. Our CM6 bundle includes `rectangularSelection` but not
   `allowMultipleSelections` or `selectNextOccurrence` — so effectively single-caret.
   Enabling is a small bundle + keymap change.
2. **Goto Anything unification** — one `⌘P` box: fuzzy file, `@symbol`, `:line`,
   `#in-file-text`. We have each capability in a different surface (⌘K, ⇧⌘G, ⌘L,
   workspace-symbols section). The *operators-in-one-box* model is the borrowable idea.
3. **Minimap** — full-document minimap with viewport + search-hit marks. We already have
   `FindMatchMinimapView`/`FindMinimapLayout` primitives; generalizing is plausible.
4. **Snippets** with tab-stops and per-scope triggers.
5. **Hot exit** — quit with unsaved buffers, restore them verbatim on relaunch (no
   prompt). We prompt on dirty close instead; our sessions restore *files*, not dirty
   buffer contents.
6. **Tab multi-select** (ST4) — niche; low value here.
7. **Per-syntax settings & huge theme ecosystem** — we ship 2 syntax themes, no font
   picker (zoom only).
8. GB-class file *editing* (we cap editing at 50 MB; viewing at 512 MiB is fine for the
   viewer mission).

Features we have that Sublime lacks (differentiators):

- Rendered markdown + Mermaid/dot, hex/CSV/SQLite/media viewers and image/audio editing.
- Real git panel (Sublime upsells Sublime Merge), file/repo history with graph,
  worktrees/stash/remotes tabs.
- Integrated terminal; LSP working out-of-the-box (Sublime requires Package Control + LSP
  plugin); problems panel.
- Live file watching with tail/change-flash (Sublime only reload-prompts).
- Sessions with git-aware snapshots; walkthrough/code-review authoring; Claude Code
  monitor; MCP automation; security-hardened render path (CSP, sanitizer, JS-off).

### 3.3 vs VS Code — the modern-editor bar

**Verdict: we are not, and should not try to be, VS Code. The borrowable items are the
small editor-surface conveniences, not the platform.**

Notable features we lack (value-ranked for *this* product):

1. **Completion** (word-based + LSP `textDocument/completion`) — the single biggest
   "modern editor" delta felt in daily editing.
2. **LSP rename / code actions / signature help** — we already run servers and apply
   text edits (`LSPTextEditApplier`); these are protocol calls away. VS Code's depth
   here is the reference implementation.
3. **Search-and-replace across files with preview/undo.**
4. **Editor git decorations** — gutter change marks, inline blame, "timeline" view.
5. **Sticky scroll** (pinned enclosing scope header) — cheap, high-delight, fits a
   *reading-first* product unusually well.
6. **Breadcrumbs** (path + symbol trail above the editor).
7. **Markdown editing niceties** — paste-URL-as-link, image-paste-to-file, outline,
   linked editing.
8. **Settings sync / profiles** — low value while single-user/local, non-goal for now.
9. **Debugging (DAP), Remote (SSH/containers), notebooks, Live Share, extension
   marketplace, Copilot/agent platform** — all platform-weight; see §4 do-not-chase.

Features we have that VS Code lacks (differentiators):

- **Native speed/footprint**: instant cold launch, ≤48 MB bundle, bounded-RSS large-file
  path; VS Code degrades or disables features on big files.
- **Built-in viewers**: hex (multi-GB mmap + edit), CSV table with filters, SQLite
  browser, real media previews + image/audio *editing* — all extensions (of varying
  quality) in VS Code.
- **Claude Code activity timeline + transcript search** — VS Code has agents that *act*;
  nothing that *audits* an external agent's activity on your repo.
- **MCP automation server** — the app itself is agent-drivable; VS Code's automation
  story is extensions, not a first-class tool surface.
- **Walkthrough player / code-review cards** as a native, file-anchored layer.
- Git worktrees as a first-class panel tab (VS Code still extension-land).
- Quick Action / Services / URL-scheme containment — deep macOS integration.

### 3.4 vs IntelliJ IDEA — the IDE bar (borrow-list only)

**Verdict: full parity is an explicit non-goal; the question is which conveniences
transfer to a viewer-first product.** Worth borrowing, in order:

1. **Local History** — IntelliJ's most-loved safety net: automatic snapshots on save/
   refactor/test, label points, restore deleted files. We have `LocalHistoryStore.swift`
   *unwired* — highest leverage-to-effort ratio on this whole list.
2. **Rename refactor everywhere** (via LSP for us) — IntelliJ's semantic rename is the
   conceptual bar; LSP rename gets 80% for 5% of the cost.
3. **Structural search** flavor — for us, the viewer-angle version is *search with
   TreeSitter node-kind filters* ("only matches inside comments/strings"), not full SSR.
4. **Recent Locations popup** (⌘⇧E — recently *visited positions* with code context,
   not just files) — a navigation gem that fits a reading tool perfectly.
5. **Inspections / intentions, run configurations, indexing-powered navigation,
   dataflow analysis** — do not chase; they require a resident semantic index and a
   build-system model, the antithesis of an instant viewer.

Features we have that IntelliJ lacks: instant launch on arbitrary files/folders (no
project model, no index wait), hex/media/CSV-at-a-click, tail mode, Claude monitor,
MCP automation, tiny footprint. IntelliJ won't open a 200 MB log; we will.

---

## 4. Do-not-chase list

Deliberate non-goals for a fast viewer-first product — each would compromise the core
identity (instant open, low footprint, minimal deps):

- **Debugging (DAP)** — IDE-weight; users debugging have an IDE open already.
- **EDITOR-HOST remoting (the VS Code model: extension host / language servers /
  debuggers running server-side)** — a platform, not a feature; massive server-side
  surface for marginal viewer value. **OWNER CORRECTION (2026-06-11): scope this
  non-goal narrowly.** ENGINE remoting is a stated GOAL of the rust-core split:
  the native UI stays local and `mdvcore` runs on the remote box behind the same
  wire frames (Phase 1 envelope = the RPC boundary; Phase 2 DocId registry makes
  handles network-safe — raw pointers can't cross a socket; `mdvcore-host` +
  ConfinedRoot is the server side; `mdv-web` is the interim answer today). Every
  Phase 1 contract decision must therefore be TRANSPORT-AGNOSTIC: no process-local
  values in frames, coarse calls over chatty ones, self-describing errors,
  capability negotiation (TSK-634) mandatory because client/server skew
  independently.
- **Extension marketplace** — the curated subprocess plugin host is the right risk
  posture (supply-chain, review burden); a marketplace is a product in itself.
- **Rich-text *editing* (RTF/.docx/WYSIWYG)** — different product (word processor);
  read-only RTF/docx *viewing* could be a cheap exception someday.
- **Full semantic indexing / inspections / refactoring catalog (IntelliJ-class)** —
  requires resident indexes and project models; kills instant-open.
- **Run configurations / build-system integration** — same reason.
- **Notebooks (ipynb execution)** — rendering an .ipynb read-only might fit someday;
  execution kernels do not.
- **Real-time collaboration (Live Share)** — heavy infra, off-mission.
- **Cloud settings sync / accounts** — local-first product; revisit only if multi-Mac
  demand materializes.
- **Bundled AI authoring (Copilot-style completions/chat)** — the differentiated
  position is *observing* agents (Claude monitor, MCP), not competing as an AI host;
  also a dependency/network posture change the product has deliberately avoided.
- **GB-class *editing*** — the 50 MB editor cap with the 512 MiB view path is the right
  split; Sublime-class huge-file editing means abandoning CM6-in-WebView, a rewrite.

---

## 5. Ranked candidate backlog — top borrowable features

Effort: **S** ≤ ~1 day · **M** = days · **L** = week+. "Best ref" = which editor's
implementation to study.

| # | Feature | Effort | Best ref | Notes |
|---|---|---|---|---|
| 1 | **Multi-cursor**: `allowMultipleSelections` facet, ⌘D `selectNextOccurrence`, ⌥-click add caret, ⌘⇧L split-selection | **S–M** | Sublime | CM6 supports all of it; bundle rebuild + keymap + bridge/state audit (cursor persistence per tab assumes single caret) |
| 2 | **Print + Export PDF** (rendered markdown first; source via NSPrintOperation later) | **S** | TextEdit | `WKWebView.printOperation` / `createPDF`; already sketched in DESIGN.md §13 |
| 3 | **Markdown outline sidebar section** — wire existing `MarkdownOutline` into the OUTLINE panel for `.md` | **S** | VS Code | Core parsed + tested; UI section exists for LSP, add a markdown provider |
| 4 | **LSP rename + code actions** | **M** | VS Code | `LSPClient` + `LSPTextEditApplier` already apply workspace edits for format; add two requests + UI affordances |
| 5 | **Completion**: CM6 word-based first, then LSP `textDocument/completion` | **M–L** | VS Code | Add `@codemirror/autocomplete` to bundle; LSP source second phase |
| 6 | **Wire LocalHistoryStore** → per-file snapshot on save/external-change, "Local History…" browser with diff view (reuse DiffView) | **M** | IntelliJ | Store exists unwired; diff viewer exists; mostly glue + retention policy |
| 7 | **Unified Goto Anything**: fold go-to-path, `:line`, `@symbol` (LSP + md outline) into the ⌘K box with operator prefixes | **M** | Sublime | Consolidation of 4 existing surfaces; fuzzy matcher exists |
| 8 | **Project-wide replace** with per-match preview + apply (respect read-only files, atomic writes via EditorWriter) | **M** | VS Code | CrossFileSearch supplies matches; needs write path + undo story |
| 9 | **Prose spellcheck** in editor mode (NSSpellChecker bridged into CM6 diagnostics lane) | **M** | TextEdit | Reuse lint-gutter plumbing; markdown/prose scopes only by default |
| 10 | **Editor git gutter**: added/modified/deleted line marks (diff vs HEAD via existing GitClient), click → hunk popover | **M** | VS Code | `setGutterMarkers` bridge message already exists (v2 protocol) |
| 11 | **Sticky scroll** (pinned enclosing heading/scope while scrolling) — for *rendered markdown and source* | **M** | VS Code | Unusually good fit for a reading tool; TreeSitter gives scopes |
| 12 | **Hot exit** — persist dirty editor buffers into session snapshots; restore without prompting | **M** | Sublime | EditorBuffer + SessionSnapshot exist; add buffer persistence + recovery path |
| 13 | **Full minimap** with viewport + find/diagnostic marks | **M–L** | Sublime | Generalize FindMinimapLayout; CM6 has community impls to mirror (no new dep without approval) |
| 14 | **Recent Locations popup** (recently visited file+line with context preview) | **M** | IntelliJ | History plumbing exists (history, per-tab scroll/cursor state) |
| 15 | **Snippets** (tab-stop expansion, per-language) | **M** | Sublime | CM6 `snippet()` support is in `@codemirror/autocomplete` — pairs with #5 |
| 16 | **Theme/appearance depth**: font-family picker, 4–6 more syntax themes, markdown CSS variants | **S–M** | Sublime | Theme machinery (`SyntaxTheme.Name`) exists; content is the work |
| 17 | **Inline blame** (current-line author/date, toggle) | **S–M** | IntelliJ/GitLens | GitClient + status bar exist |

**Sequencing note:** items 1–3 are the highest value-per-effort on the board (two are
S-effort and close embarrassing gaps; one wires existing tested core). Items 4–6 each
convert already-built plumbing into user-visible capability. 7–12 are the "fast editor
credibility" tier. 13–17 are polish.

---

## Appendix A — Verified inventory snapshot (what TextView actually ships, 2026-06-11)

**Viewing**: markdown rendered (CommonMark+GFM, WKWebView, JS-disabled, CSP, HTML
sanitizer, light/dark CSS), Mermaid + DOT graphs, source view (read-only NSTextView,
TreeSitter lazy-grammar highlighting, gutter, invisibles, wrap, folds), hex viewer
(mmap, multi-GB, search, configurable layout), CSV table (Rust parser, filter/find/cell
cursor), SQLite browser, diff viewer, HTML, media previews (image/audio/video/PDF) with
zoom/pan, large-file two-tier path (64 MiB soft / 512 MiB hard), file watcher with
change-flash + tail, pretty-print/format (JSON/XML…), jq filter, JSON syntax check,
folder-stats treemap, metadata panel, status bar (Ln/Col, size, encoding, git).

**Editing**: CM6 editor mode (undo/redo, find/replace panel, fold gutter, indent
guides + detection, bracket matching, rectangular selection, lint gutter fed by LSP
diagnostics, ⌘S + save-on-blur, dirty-dot, external-edit conflict dialog, 50 MB cap),
hex editing (HexEditBuffer), image editor, audio editor (ffmpeg-assisted MP3 export),
new-file creation, line-ending/indent detection, text tools (UUID/SHA-256/Base64/checksum).

**Navigation/search**: tabs (reorder, split 2-pane + swap), named sessions (⌃Tab cycle,
git-aware snapshots, trash/restore), sidebar tree (fuzzy filter, hidden toggle, git
badges, recency, bookmarks file+line, recents, search-anywhere, plugin sections,
resizable accordion panels), ⌘K command palette (files + commands + tools), ⇧⌘G
go-to-path, ⌘L go-to-line, in-file find (mode-routed: native bar / CM6 panel / rendered
find with match minimap), ⇧⌘F cross-file search (gitignore-aware, streaming),
`keybinding.json` user keybindings over a registry of stable command IDs.

**Code intelligence**: LSP pool with PATH discovery (TS/JS, Python, Java jdtls, etc.;
binary-ownership checks), hover, outline, goto definition/declaration/type/implementation,
find references, workspace symbols, problems panel, document format. *No completion,
rename, or code actions.*

**Git**: status badges, status/log(graph)/stash/remotes/worktrees panel tabs, file
history, repo history, diff overlays — all via `/usr/bin/git` shell-out.

**Platform/automation**: integrated terminal (own PTY + ANSI engine, dockable
bottom/left/right, tabs, palette), subprocess plugin host (manifests, grants,
env-scrub + rlimits, sidebar/status extension points, bundled RowCounter), MCP
automation server + script verbs + diagnostic dumps, Claude Code activity timeline +
session index + transcript search, walkthrough player (guided, auto-advance), code
review (comment cards, index, export), Finder Services/UTI/URL-scheme (`markdownviewer://`
with `$HOME ∪ $TMPDIR` containment), drag-and-drop, settings pane (theme, zoom, wrap,
invisibles, indent, terminal placement, ffmpeg path, reset with backup), workspace
restore, security hardening (CSP, sanitizer, regex-complexity guard, symlink-refusing
writes, 0o700 audit dirs). Side products: Rust core with TUI + web front-ends.

**Present in code but NOT shipped (excluded from claims above)**: `LocalHistoryStore`
(no consumers), `MarkdownOutline` (core + tests only, no UI), CM6 multi-caret
(`rectangularSelection` included but `allowMultipleSelections` facet absent).

## Appendix B — Sources

- In-repo: `DESIGN.md`, `README.md`, `UI_CATALOG.md`, `MANUAL_TESTING.md`,
  `Sources/ViewerCore/Commands/CommandRegistry+BuiltIn.swift`,
  `Sources/ViewerCore/` + `Sources/ViewerUI/` listings,
  `scripts/codemirror-build/entry.js`, `Sources/MarkdownViewer/main.swift` (menu wiring),
  `Sources/ViewerUI/SettingsView.swift`.
- Web: [Sublime Text 4 announcement](https://www.sublimetext.com/blog/articles/sublime-text-4),
  [Sublime Tab Multi-Select](https://www.sublimetext.com/docs/tab_multi-select.html),
  [VS Code 1.107 notes](https://code.visualstudio.com/updates/v1_107),
  [VS Code 1.108 notes](https://code.visualstudio.com/updates/v1_108),
  [VS Code 1.124 notes](https://code.visualstudio.com/updates/v1_124),
  [TextEdit — Wikipedia](https://en.wikipedia.org/wiki/TextEdit),
  [TextEdit User Guide](https://support.apple.com/guide/textedit/welcome/mac),
  [IntelliJ Local History docs](https://www.jetbrains.com/help/idea/local-history.html),
  [IntelliJ refactoring docs](https://www.jetbrains.com/help/idea/refactoring-source-code.html),
  [20 Things Developers Love About IntelliJ IDEA](https://blog.jetbrains.com/idea/2021/02/20-things-we-love-about-intellij-idea/).
