# Changelog

## 2026-07-09

### Security
- **Credential warn-badge.** When a document you open contains a likely secret
  (AWS/GitHub/Slack/GCP keys, PEM private-key blocks, JWTs, high-entropy
  `secret=`/`token=` assignments), a non-modal badge now appears above the editor —
  "N potential secrets detected" with a Details popover listing each one **redacted**
  (line + type, never the raw value). TextView never modifies the file. On by default;
  switch it off under Settings ▸ Privacy & Permissions ▸ Secret detection.

### Changed
- **Convert menus show the current value.** Format ▸ Convert Encoding / Convert Line
  Endings now check-mark what the open file currently is, and Convert Indentation shows a
  "Current: …" header — so you're no longer converting blind. (The status bar already
  shows encoding · EOL · indent.)

### Added
- **Curve, polygon & text tools in the image editor.** Three new paint tools: **Curve** (drag to
  lay a smooth arc), **Polygon** (click each corner, then Close Polygon — filled or outlined), and
  **Text** (click to drop an editable, movable text label). Anti-aliased.
- **Fill a selection.** With a marquee/lasso selection active, the new **Fill** button paints the
  whole selected region with the current color (undoable). Deleting a selection is now undoable too.
- **Three more shapes.** The image editor's shape gallery gained **heart**, **lightning**, and
  **speech callout** — drag a box to place one, filled or outlined.
- **Move & resize shapes on the image canvas.** The image editor's paint tools gained a
  **select** tool (the ⌖ icon): click a placed shape to select it — it shows a dashed outline with
  eight resize handles — then drag its body to move it or a handle to resize. Previously a placed
  shape was fixed once drawn. (Undo works on each move/resize.)
- **Git panel now stages, commits, and discards.** The sidebar Git ▸ Status tab gained the
  standard loop: a **＋/－** on each row to stage/unstage, a commit-message field with a **Commit**
  button (disabled until something's staged and a message is typed), and **Discard Changes…** on a
  file's menu — which always asks first, so you can't lose uncommitted work by accident. It was
  view-only before.
- **Language-server status in the footer.** When you open a code file, a small chip in the
  status bar now shows whether its language server is running, starting, failed, or not
  installed — so features like hover, go-to-definition and completions stop failing silently.
  Click it for the per-language list (with install hints for missing servers) and a Restart
  button to revive a crashed server without waiting out the cooldown.
- **Move the terminal to any edge.** The terminal pane's tab strip now has a Dock control —
  send the terminal to the left, right, or bottom of the window (the current edge is
  check-marked). Previously the terminal could only be moved by editing preferences.
- **First-run sample tour.** A fresh install now opens a "Welcome to TextView.md" that shows
  off the lenses (rendered headings, a table, a highlighted code fence, a Mermaid diagram, a
  task list) — shown once. Reopen it any time via Help ▸ Open Sample Document (it never
  overwrites a file of your own by that name).
- **Extended shape gallery in the image editor.** The paint tools gained a Shapes menu with
  12 parametric shapes — triangle, right-triangle, diamond, pentagon, hexagon, 4/5/6-point
  stars, and arrows (up/down/left/right). Pick one and drag a box to place it, filled or
  outlined. (Heart/lightning/callouts are coming.)
- **Recover a deleted file.** File ▸ "Recover Deleted File…" lists recently-opened files you
  deleted that still have Local History, and recreates one from its latest saved version
  (atomic — it never overwrites a file that's since reappeared). Restores now work even
  when the file is gone from disk.
- **Terminal pane header.** The terminal now shows a header row — "Terminal — <name>
  [<working dir>, pid <n>]" — that tracks the shell's live working directory (updates as
  you `cd`) and its process id.
- **Structural Search now has examples.** The tree-sitter structural-search panel gained an
  "Examples" button — a language-tailored list (Swift / Python / JS-TS / Rust) of insertable
  queries, so you can run one in a click without knowing the DSL. Syntax errors in your query
  now show live under the field as you type.
- **New-tab omnibox.** The "no file open" screen now has a single field: type a file or
  folder path to open it, a URL or git-repo link to open it in your browser, or any other
  text to run a cross-file search. Recent files still list below.
- **Markdown "Contents" outline panel in the sidebar.** Opening a markdown file now shows
  a live heading outline in the sidebar — a filterable list you can click to jump to a
  section. It sits below the code Outline panel and appears only for markdown documents.
- **Manage Terminal Favorites editor.** Terminal ▸ Terminal Favorites ▸ "Manage Favorites…"
  now opens a real editor — rename in place, reorder up/down, delete, and filter — instead
  of dropping you into the raw JSON file.

### System work
- **Code-review journey verified end-to-end + documented (TSK-1445).** Added `ReviewJourneyTests`
  driving the whole loop on a REAL commit diff — open review → comment on a diff line → reply →
  resolve → persist → reopen-from-disk (survives) → export (carries the hunk) → `get_review_context`
  MCP parity — closing the "never driven as a whole" gap (the backends/UI/per-unit tests already
  existed; no product friction surfaced). Rewrote `docs/CAPABILITIES.md` §5 as the step-by-step
  workflow incl. the `get_review_context`/`list_review_comments` agent tools.
- **Render-tail on-screen UAT lane (VM pyramid).** Built deterministic `MDV_UI_SCENE`
  scenes that drive each built-but-unreachable render tail to its exact on-screen state,
  rebuilt `dist` on the UTM VM (offline toolchain), captured by window-id and read the
  pixels as proof. Verified this session: video fallback card (TSK-1474), archive
  browser (TSK-1469), notebook cell outputs (TSK-1440), dependency-graph canvas
  (TSK-1470 — nodes + edge arrows paint; scene resets the restored terminal/sidebar so
  the hosted graph tab is visible), markdown outline panel (TSK-1438), terminal favorites
  editor (TSK-1475). Each scene is a committed guard + host applier test.
- **Launch-mode UAT lane** (aqua-runner `monitor-*` scenes): the Claude Session Monitor
  (`--claude-monitor` window, not a `MDV_UI_SCENE`) is now UAT-drivable — the runner builds
  a fixture root + launches in monitor mode via `MDV_MONITOR_ROOT`. Verified TSK-1477's
  empty-state message + session-list rendering on the VM.

## 2026-07-07

### Added
- **`mdv` command line**: `mdv <file/folder>` opens things in TextView from the shell
  (no second instance); `mdv session <name>` switches saved sessions. Opt-in install:
  `bash scripts/install-app.sh --with-cli`.
- **Spreadsheet formulas are now on by default** — computed values show in the grid
  (with a subtle ƒ marker), the raw `=formula` edits in its own box, and grid edits
  can actually be saved to disk (Save/Discard bar). Powered by the rust engine;
  `PROPER()` joined the function set.
- Agent tooling: a `who_calls` MCP tool answers "who calls this symbol?" via the live
  language server (definition + up to 200 callers as `file:line`).

### Security
- **Hostile-repo protection**: opening a folder that ships its own language-server binary
  (e.g. in `node_modules/.bin`) no longer runs it silently — TextView blocks it and asks
  once ("Trust and Run" / "Block"); trust persists per binary. Headless contexts always
  block. System-installed language servers are unaffected.
- **Credential recognition (foundation)**: a detector for AWS keys, private-key blocks,
  GitHub/Slack/Google tokens, JWTs and high-entropy `password=`/`token=` assignments —
  the visible badge/mask arrives with the next render slice.

### Fixed
- Quitting or relaunching TextView no longer kills a connected Claude Code MCP session —
  the bridge now reconnects automatically and requests queue while the app restarts.
- Vim mode no longer beeps when you press Esc while already in normal mode.
- DOT/Graphviz and PlantUML code fences render as labeled diagram blocks again on the
  (default) rust markdown path — previously that treatment only existed on the legacy
  fallback renderer.
- Very large CSVs (>4 MB) no longer open as a blank grid (a wire-size cap was silently
  emptying the table; they now assemble in windows).

### System work
- **Stage-B twin deletions (batch B3)**: six Swift engine twins deleted (~3,300 lines) —
  fuzzy ranking, transcript projection, CSV parser, CM edit-applier, markdown visitor,
  code folds — rust-core is now the ONLY engine for each, with observable degradation
  instead of silent fallback. Behavior and security pins retargeted through the engines;
  A/B parity suites retired with the twins they compared. Find-engine deletion parked on
  an owner call (regex lookaround trade-off); a chronically-flaky fold bench fixed itself
  by now measuring the rust engine.
- **Stateful core S2–S4 (batch B1)**: rust-core now holds editor documents statefully — text
  crosses the FFI once at open, keystrokes ship only deltas; owner-ratified eviction (1.5 GB /
  200 docs, unsaved docs never evicted — law-tested); a shadow-mode differential net
  (`MDV_RUST_DOCSTORE=shadow`) mirrors every CM6 edit into the core and counts divergences
  (zero-divergence is the gate for the future authority flip). Adversarial no-panic property
  tests; both gates green (9,659 tests).
- **Formula finish (B6)**: MDV_RUST_FORMULA flipped on (every rust-core capability now
  ships enabled — Stage A closed); the Swift formula evaluator + parser deleted
  (1,089→148 lines, the 7th twin); 77 contract tests retargeted to the rust engine.
- **Remote-core groundwork (B8)**: mdv-web serves the shared surface bundles
  (allowlist-only) + a `/surface/editor` scaffold + a hand-rolled RFC 6455 WebSocket
  bridge (`/ws/editor`, real-socket E2E); the CM bridge's 42-message catalog extracted
  into `schemas/cm-bridge.json` with two-sided drift pins (day-one catch: a raw-string
  `scrollToLine` dispatch bypassing version negotiation); the daemon-vs-instances
  lifecycle designed (`docs/DAEMON_LIFECYCLE_DESIGN.md`, slices TSK-1553–1558); the
  first async MCP tool lane (LSP-backed tools never park the main actor).
- **Guards + hygiene (B4/B5)**: per-surface real-render matrix guard, webview allowlist,
  no-resurrection tooth, color ratchet, 188 missing rustdoc comments → `#![deny]`;
  the CSV paging ask measured and denied on evidence (owner rule: measure first).
- **Security batch (B9)**: the LSP spawn gate enforced at the real spawn site (fail-closed,
  spawn-site tests with a node_modules/.bin threat fixture); `scripts/test-bounded.sh`
  (memory+deadline watchdog for test runs, self-test-proven); secret-detector corpus with
  pinned false-positive contract. External-edit auto-merge + trust-mode failure surfacing
  deferred on the VM lane (buffer-mutating/render halves must not ship unwatched).
- Tracking: BACKLOG rewritten as the pre-sorted 25-batch queue; repo moved back to
  `~/Documents` (iCloud sync verified off); 5-min batch-loop cron armed; B7's three
  from-scratch web surfaces deferred on the VM lane (TSK-1550).

## 2026-07-05

### Added
- **TextView now works as an MCP server for Claude Code (and any MCP client).** Register once
  (`claude mcp add --scope user textview -- /Applications/TextView.app/Contents/MacOS/MarkdownViewer --mcp-connect`)
  and agents get all 31 tools — open files, drive verbs, author Canvas docs. While the app is
  running, agents drive the LIVE app over its new local socket (edits appear in your open
  windows); when it's closed, the same config transparently falls back to a headless instance.

### Fixed
- **MCP clients timed out connecting (30 s).** The server only spoke LSP-style Content-Length
  framing while the MCP spec (and Claude Code) use newline-delimited JSON. The server now
  accepts both and replies in kind.

## 2026-07-04

### System work
- rust-core migration unblocked end-to-end: owner resolved the TSK-649 flip gate (no calendar
  soak — single-user; validation = the new Stage-B UAT plan, docs/STAGE_B_DELETION_UAT_2026-07-04.md),
  the formula display design (TSK-1215: computed value in-grid + separate formula edit box), and
  the eviction policy (TSK-589: dirty never evicts; clean LRU under min(1–2 GB, 200 files)).
- fold gate flipped default-ON (TSK-1202 ladder complete; off-switch MDV_RUST_FOLD=0) — first
  step of the Stage-B deletion sequence.
- tracking: WebUI surface-sharing epic TSK-1507 + whole-core plan-gap tickets TSK-1508–1514 +
  computed-cell marker TSK-1515 filed; BACKLOG carries both analyses.

## 2026-07-02

### Fixed
- **Snippets (and Insert Date & Time / Go to Line) no longer land in the wrong
  document.** Inserting a snippet used to also insert into other recently-viewed
  editor tabs kept warm in the background, and could replay an old insert or
  line-jump into a tab you opened later. Every such action is now addressed to
  the tab you fired it in, applied exactly once, only there. (Keyboard-focus
  routing audit: docs/FOCUS_ROUTING.md.)

### Added
- **Footer toggles for spell check and autocomplete.** Two new chips in the status bar turn the editor's spell-check squiggles and autocomplete on/off instantly (persisted) — the quick relief valve when typing feels slow in large text files. Also in the command palette (Toggle Spell Check / Toggle Autocomplete).
- **Search in Files grew live progress, Stop, collapsible results, and a safe
  two-step replace.** While a big folder is scanned you now see "N scanned ·
  M found" with a Stop button that keeps whatever was already found; each
  file's matches can be folded away with a chevron; the search box remembers
  your last query when reopened. Replace-across-files is no longer one blind
  click: "Preview Replace" first shows exactly what would change — total and
  per-file counts, plus any files that couldn't be processed — and only an
  explicit Replace confirm writes to disk.
- **Bookmarks and Recents clean up after themselves.** Both sidebar panels
  grew a "remove missing" action that sweeps entries whose files were deleted
  or moved outside the app (bookmark pruning is undoable with ⌘Z), recents
  rows gained "Remove from Recents", and the empty states now teach the
  feature — "No bookmarks yet — ⌘D bookmarks the current file."
- **File tree grew safe file operations — Move to Trash, New Folder, Move to
  Folder, and renames that open tabs follow.** Right-click a file or folder:
  Move to Trash asks first and is always recoverable (never a hard delete;
  tabs open on it stay open and re-saving recreates the file), New Folder
  creates a non-colliding "untitled folder", and Move to Folder relocates
  without ever overwriting. Renaming or moving a file — or a whole folder —
  now retargets any open tabs (including unsaved edits) instead of stranding
  them on the old path with a "deleted on disk" dot.
- **Local History grew Restore — and File → Local History now opens the full
  timeline.** The File-menu entry used to open a bare view-only list; it now
  opens the same viewer as the context menus: timeline with per-save size
  deltas ("2.1 KB (+340 B)"), diff-vs-current, range diffs, and a confirmed
  Restore that works even when the file isn't open (it opens it for you).
  Restore is safe by construction: your current file and any unsaved edits are
  snapshotted into history first, the restored text arrives as a normal
  undoable edit (⌘Z), and nothing touches the disk until you save.
- **Snippet manager grew search, preview, and one-keystroke insert.** Edit →
  Manage Snippets now filters by name, id, or body as you type; shows a live
  preview of exactly what a snippet inserts (tab-stop markup stripped) with a
  tab-stop summary; and inserts into the active editor via double-click, the
  Insert button, or plain Return (Save moved to ⌘S). Empty search results and
  an empty library explain themselves with a next step.
- **Keyboard shortcuts for the daily markdown loop.** Check Links is now ⇧⌘K,
  Align Markdown Tables ⌥⌘A, and Insert Table of Contents ⌥⌘O — shown in both
  the menu bar and the command palette (which already displays every command's
  key). The full reference stays at Help → Keyboard Shortcuts.
- **Paste announces what it did — "Pasted as table — Undo".** Universal Paste
  (clipboard → new tab) used to be invisible magic; now a small notice says
  what the clipboard became (text, table, image, Markdown, rich text, or an
  opened file) with an Undo button that closes the tab it created.
- **Failures and long operations now surface on screen (toasts + progress).**
  A shared, non-blocking notice area (bottom-right) shows errors with their
  reason, success confirmations, and in-flight operation progress with Cancel
  where supported. First wired: feed refreshes that fail now say which feeds
  couldn't be reached (previously silent), and clipboard text tools confirm
  what they did (previously visible only in the Logs view).
- **Tool views now explain themselves when empty.** Feeds, HTTP Request, the
  SQLite browser, the folder size map, the script console, and the task runner
  used to open as a blank pane (or a terse "No feeds"); each now says what the
  view does and what to do first, in one consistent style.
- **Feed Reader (RSS) is now reachable — File → Feed Reader.** The built-in feed reader (subscriptions, OPML import, refresh, unread counts) was complete but had no way to open it; it now opens in a tab.
- **Canvas Presentation mode:** build a themed slide deck entirely through the
  agent tools — stepped reveals, identity-morph transitions (a shared element
  glides between slides), a keyboard-driven player, one-file offline HTML
  export that plays with no network, and a print layout (one slide per page →
  File▸Print▸Save-as-PDF for a PDF deck). The step timeline is verifiable
  before any screenshot.
- **Canvas grid layout:** a container can lay its children in N equal columns
  (`columns=3`) — closes the design gauntlet's hand-assembled-grid gap.
- **Canvas design system:** reusable components (edit a definition once, every
  copy updates), a starter kit of six building blocks, instant whole-document
  retheming, charts/tables/code/diagrams as first-class content, data-driven
  repetition, and a design-quality audit that now also measures the real page
  (overflow, contrast). Verified by a ten-brief design gauntlet: every brief
  built through the agent tools without falling back to raw HTML.
- **Canvas visual editing (WYSIWYG):** .canvas files now open into a rendered
  canvas with a layers tree and a properties inspector — click to select,
  double-click to edit text in place, drag to reorder, ⌘Z to undo; agents and
  humans edit the same live document without overwriting each other.
- **Canvas agent tools:** agents connected to the app can now create, author
  (in a compact teaching language), read back, lint, undo, save, reopen, and
  export canvas documents — 9 new MCP tools plus two one-line script verbs
  (`canvas-export`, `canvas-apply-file`); exports are self-contained HTML.
- **Canvas engine (foundation, not yet user-visible):** the core of the upcoming
  Canvas feature — agents (and soon the UI) can build and edit visual documents
  through typed, undoable operations or a compact authoring language, with design
  tokens for live retheming, validation that teaches instead of failing silently,
  and documents that save/reload byte-identically.

### System work
- rust-core: canvas module complete for M1 (store/props/fence/ops/tokens/lowering/
  patch-plans/wire/lint/persistence/DSL/doc facade) + 5 new FFI entry points; ~60
  new tests incl. proptests, golden fixture, teeth-verified guards.
- Swift: CanvasDocSession/Adapter + 7-verb bridge codec + webview E2E suite rebuilt
  on the real engine (local 4/4, e2e p95 30ms vs 50ms budget).
- Tracking: M1 slices S1-S9 driven on the board (7 validated, 2 fixed pending fuzz +
  VM-parity); LESSONS grew 4 entries (apply-time anchors, gate/commit separation,
  equivalent mutants, SwiftPM xctest-link staleness).


The **owner's** at-a-glance view of progress — both **user-facing** change and
**total effort**. User-facing features/fixes/perf go under **Added / Changed / Fixed /
Performance** (descriptive, from the user's seat). Non-user-facing effort (tests,
CI/infra, refactors, gated rust-core ports, tracking) is summarized terse under
**System work** per date — so a "147 commits, 3 user-facing" day shows where the rest
went. Detailed per-item narrative lives in `docs/AUTONOMOUS_PROGRESS.md`.

Newest first. Each entry is one plain-language line — what changed, from your seat.

## 2026-06-30

### Added
- **Find in PDF (⌘F).** Opening a PDF and pressing ⌘F now shows a "Find in PDF…" bar that highlights **all** matches in the document at once (yellow) with the current one selected, and steps through them (⌘G / the bar arrows, with an "n/total" counter). Previously ⌘F on a PDF opened the text-source find bar, which couldn't search a PDF. (Case-insensitive by default.)
- **Multi-sheet OpenDocument (.ods) spreadsheets show a sheet-tab strip.** A `.ods` workbook with more than one sheet now shows a tab strip above the grid — click a tab to view that sheet — matching the Excel (.xlsx) behaviour. (Read-only; each sheet's cells are its displayed values.)
- **Word (.docx) documents open RENDERED with structure.** Opening a `.docx` now shows it as rendered Markdown — **headings, bullet/numbered lists, and bold/italic preserved** — instead of one flat wall of text. (Read-only; toggle to Source to see the extracted Markdown. Dependency-free — reuses the in-app OOXML reader.)
- **RTF (.rtf) documents render their formatting.** Opening a `.rtf` (e.g. a TextEdit document) now shows **bold and italic** rendered, instead of flat text. (Read-only; toggle to Source for the extracted Markdown.)
- **Terminal tab strip has a shoulder divider.** The terminal's tab strip now draws a thin separator on its outer edge (matching the app's side-rail dividers), so the terminal pane reads as a distinct surface. Follows the strip's position (top / left / right).
- **Paste rich text as Markdown.** "Paste as New Document" (⇧⌘V) of copied rich text that carries HTML (a web page, a doc) now opens it as structured **Markdown** — headings become `#`, bullet/numbered lists become `-`/`1.`, bold/italic/links preserved — instead of a raw RTF dump. (Also fixes HTML-only clipboards that previously just beeped.)
- **New Walkthrough button.** The Walkthroughs browser (File ▸ Walkthroughs) now has a **New Walkthrough** button that creates a ready-to-edit starter tour (a small 3-step example) in your library and opens it — so building your own walkthrough is discoverable instead of guesswork. Repeated clicks never overwrite an existing one (names auto-increment). Pairs with the new authoring guide (`docs/WALKTHROUGH_AUTHORING.md`).
- **Drag the Terminal icon to dock the terminal.** The Terminal shoulder icon is now draggable like the other tool icons — drag it onto the left, right, or bottom edge to dock the terminal pane there (it opens if it was closed). The Settings ▸ Terminal pane-placement picker still works too. (Clicking the icon still toggles the terminal as before.)
- **Multi-sheet Excel (.xlsx).** Opening a workbook with more than one sheet now shows a sheet-tab strip above the table — click a tab to view that sheet. Previously only the first sheet was shown. (Read-only viewer; each sheet's cells are its displayed/computed values.)
- **Convert Image (View ▸ Convert Image…)** — over an open image, pick a target format (PNG / JPEG / HEIC / BMP / GIF / TIFF) and, for lossy formats, a quality level; Convert opens the re-encoded image in a new tab. Runs off the main thread so a large image never freezes the window.
- **Extract Audio from Video (View ▸ Extract Audio from Video…)** — over a video, pick an audio format (WAV / AIFF / CAF / AAC / MP3) and bit rate; it strips the video and opens just the audio track in a new tab (uses your installed ffmpeg).
- **Convert Audio (View ▸ Convert Audio…)** — over an audio file, change its format/quality (lossless PCM or lossy AAC/MP3 with a bit-rate choice) → the converted file opens in a new tab. Same panel as Extract Audio.
- **Editor autocomplete** — the code editor now invokes completion (Ctrl-Space): an LSP server's suggestions when one is configured for the language, otherwise an in-file word fallback — shown in the standard CodeMirror popup. (The completion backend existed but was never wired to the editor.)
- **Image annotations are fully editable after placement.** Select a shape drawn on an image and adjust its stroke colour, **fill**, line width, **rotation**, and position/size from the inspector panel; for a text annotation, edit its text, size, and **bold/italic**. Previously a placed annotation couldn't be changed.
- **⌘K command palette: Convert Encoding + Align Markdown Tables.** Re-save the active file as UTF-8 / UTF-16 / Windows-1252 / ISO-Latin-1, and re-align GFM pipe tables — both now reachable from the command palette (previously menu-only).
- **Lock a file's view mode from the file list.** Right-click a file in the sidebar ▸ **Lock View As →** and pick a mode (Source / Rendered / Editor / Table / HEX / …) to pin how that file opens (e.g. always open a `.log` as Source); ▸ **Unlock View As** clears it. The choice persists across reopens, and a small lock badge marks view-locked files in the list. (Previously the per-file view-as lock was only reachable from the mode bar of an already-open file.)
- **Copy Reference covers a selection — now with a menu item + shortcut.** Select several lines in the editor and run **Edit ▸ Copy Reference** (⌘⌥⇧C, also in the ⌘K command palette) to copy a line-RANGE `mdv://` reference (`…?line=10&endLine=20`) to paste to an agent — "these are the lines I mean". With no selection it copies the current line as before. (Source-view selections carry the range today.)

### Fixed
- **YAML/TOML frontmatter is now hidden.** A `.md` file starting with a `---` (or `+++`) metadata block (Jekyll/Hugo/Obsidian) used to render that block as a horizontal rule + a giant heading of the raw key/values; it's now correctly suppressed, so the document starts at its real content.
- **Align Tables leaves indented code alone.** Pipe content inside a 4-space indented code block was being reformatted as a table (stripping its indentation); it's now correctly left untouched (fenced code was already skipped).
- **Promote/Demote Headings no longer corrupts code.** A `#` line inside an indented code block (or an HTML comment) was being shifted along with real headings — mangling the user's code; those lines are now left untouched (fenced code was already safe).
- **Table-of-Contents links now actually jump to their heading.** Inserted-TOC anchors used a different slug rule than the renderer's heading ids, so links for headings with punctuation or extra spaces (e.g. "Setup & Config") went nowhere; both now use one shared rule.
- **Outline / TOC ignores commented-out headings.** A `#` heading inside an HTML comment block (`<!-- … -->`, e.g. a commented-out section) no longer appears in the outline sidebar, TOC, or lint results.
- **Check Links no longer false-flags code examples.** A `[text](url)` written inside an inline code span (common in docs *about* Markdown) was treated as a real link and reported broken; code-span links are now correctly ignored.
- **Document outline / Table of Contents no longer shows false headings from code.** A `#`-comment inside an indented (4-space) code block was mistaken for a heading, polluting the outline sidebar and inserted TOC; it's now correctly ignored (CommonMark 0–3 space rule).
- **Opening a Word (.docx) document keeps its tables.** Tables in a .docx used to flatten into loose lines; they now render as proper Markdown tables (matching the headings/lists the viewer already preserved).
- **Pasting a nested list keeps its indentation.** A rich-text paste of a nested bullet/numbered list used to merge the sub-items into their parent; nested items now indent correctly.
- **Pasting a table from a browser/spreadsheet keeps its structure.** A rich-text paste of an HTML table used to collapse every cell into one run of text; it now becomes a proper Markdown table (header + rows, cells escaped).
- **Pasting code from a browser/doc keeps its formatting.** A rich-text paste of a code block used to collapse into one broken run (newlines mangled); it now becomes a proper fenced code block with lines intact.
- **Image editor: annotations (shapes, arrows, text) are now undoable, and ⌘Z works correctly when you mix annotations, painting, and crop/resize.** Adding, moving, restyling, or deleting an annotation can now be undone/redone — and undo steps back through annotations, paint, and geometry edits in the exact order you made them.
- **Image editor: annotations (shapes, arrows, text) are now included when you Save a Copy.** Vector annotations drawn over an image were silently dropped from the exported file; the saved image now matches what you see.
- **Image editor: undo works correctly when you mix painting and crop/resize/rotate.** Undo now steps back through your paint strokes and transforms one at a time in order, instead of reverting a transform and the previous stroke together.
- **Image editor: Tone sliders no longer silently do nothing after you start painting.** Painting bakes the current tone into the image, so the Tone controls now disable with a note ("discard paint to adjust") instead of appearing to work but having no effect.
- **Image editor: crop/resize/rotate now work after painting.** Applying a geometry edit once you'd started painting silently did nothing (and was lost on export); the painted layer now transforms with the image.
- **Image editor: brush/eraser/bucket strokes are now undoable.** Painting lived
  outside the undo history, so ⌘Z couldn't take back a stroke; each stroke (and
  Clear) is now a proper undo/redo step (memory-bounded).
- **Excel (.xlsx) and OpenDocument (.ods) spreadsheets open as a GRID.** They were opening as raw tab-separated *text* in the source view — the table grid (and the multi-sheet tab strip) was never actually shown. They now default to the Table view, so a workbook reads as a spreadsheet, and a multi-sheet `.xlsx` shows its sheet-tab strip as intended.
- **Music keeps playing when you switch sessions/tabs.** Audio playback was tied to the media view, so switching away deallocated the player and stopped the music; it now lives at the app level and survives the switch.
- **The side-nav file tree respects its shoulder toggle.** With the File-nav toggle off (only Bookmarks on) the file tree used to stay visible; it now hides as expected.
- **Empty shoulder bars no longer clutter the edges.** A shoulder with no docked panels is hidden (it'll reveal as a drop target during a drag once panel-dragging ships) instead of showing a permanent bare strip.
- **Terminal colours look right for CLI tools.** Settings ▸ Terminal ▸ Colour scheme adds a "Classic (xterm)" palette — the vivid standard ANSI colours tools like claude code expect (the old default was muted).
- **The terminal pane resizes freely** — the artificial 900×800 size cap is gone (the window + split layout still bound it).
- **New ▸ Image from the New-Tab landing** — the welcome screen now has a "New Image" button (next to New File) that opens a blank canvas in the image editor.
- **Terminal copy no longer carries trailing whitespace.** Copying a selection from the terminal now trims the cell-grid's trailing-space padding and the bottom blank rows (matching Terminal.app / iTerm), so pasted command output isn't ragged. Interior blank lines are kept.
- **Commit diffs: select multiple lines.** Click a line's gutter and shift-click another to select a range (highlighted), then right-click → "Copy N Selected Lines". Previously only a single line was selectable (the per-line rendering blocked cross-line text selection).

### Performance
- **Image editor stays responsive during adjustments.** The tonal sliders (brightness / contrast / exposure / shadows / highlights / sharpness) now render off the main thread, so dragging them on a large image no longer freezes the window — the preview updates when ready instead of stalling the UI.

### System work
- **Tests/quality:** DocumentModel SRP slice (zoom controls → `+Zoom` + a clamp test that was a gap); tooltip appear-delay test backfill; UAT TextKit-2 "blank" false-negative fixed (DiagnosticDump reports a TK2-safe `textLength`).
- **Validate-drain:** drove a batch of fixed/review items to `validated` with real teeth — UAT-TK2 (1332), PaneRetention LRU mount-probe (1240, VM-confirmed), ChromeBodyEvalCount parallel flake (1328), VM Swift-6.1.2 RustCore forward-compat (1210, VM-confirmed), tooltip delay (1209), hide-file-property-pane gate (1304).
- **Palette/reuse:** the encoding-convert + align-tables ⌘K commands above reuse existing host methods (no new engines).
- **Spikes/owner-decisions:** CSV viewport-paging (1139 — windowing conflicts with the table's filter/sort/find feature set) and the ⌘K render-panel commands (1335 pt2 — NSAlert→panel refactor) surfaced as tradeoffs rather than churned.
- **Lessons:** verify-before-build (caught + reverted a duplicate encoding converter — grep the feature noun broadly, incl. main.swift menus); a bare Swift-6.1.2 VM build poisons `.build` for the 6.3 test lane.
- **Perf/rust-core:** git porcelain-parser proptest hardening (no-panic + count-bounds); MEASURED the "MD open laggy" regression (TSK-598) on the VM → a ~334ms CoreAnimation commit stall (same class as Page-Up jank), host render-gen + mermaid ruled out; image-editor off-main render landed (above).
- **Spreadsheet (TSK-1141):** multi-sheet `.xlsx` shipped end-to-end (design-first) — `TextFile` retains all sheets + re-derives the active sheet on switch (String-contract-safe, additive, host-tested), and `SpreadsheetView` renders the sheet-tab strip (VM-render-validated via an in-process hosting test). User-facing entry above.
- **Image edit-state session persistence (TSK-1303, both slices — code-complete):** image-editor edits (tone/geometry ops + vector overlay) now persist across a session switch. Slice 1 = the model CORE (`Tab.imageEditState` + `TabSnapshot` Codable round-trip + an `imageEditStateByURL` channel + capture/restore/fallback), mirroring the rendered-scroll (TSK-1041) pattern that solved the same session-switch-drain class. Slice 2 = the view↔model binding — `ImageEditorViewModel(_:initialEditState:)` seeds the recreated editor declaratively at construction, `ImageEditorView` writes edits back via `.onChange`, threaded `ContentView → MediaPreviewView → ImagePreview`; and the pre-`makeSnapshot` capture wired at all three `SessionsAppCoordinator` boundaries (detach/autosave/quit) — the slice caught + fixed a placement bug (slice-1's capture was in the post-snapshot drain, so nothing serialized). Host-tested with teeth (18 tests: serialization round-trip + downgrade guard + capture/restore/fallback model layer + the declarative-seed init + the capture→serialize coordinator sequence). On-screen validation (the live mount seeds + a real edit → switch → edits present) is the T5-pixel / AX-gesture tier — T5 blocked on the VM Screen-Recording grant (TSK-1334) — so no user-facing "Fixed" entry until that confirms; the persistence LOGIC is fully host-proven.
- **Non-modal disk-conflict banner (TSK-1166):** when a file changes on disk while you have unsaved edits, the PASSIVE watcher case now raises an inline `DiskConflictBanner` above the editor (Keep Mine / Take Disk / Merge) instead of a blocking NSAlert — a modal is jarring for a change you didn't initiate. The deliberate `refreshTab` (right-click ▸ Refresh) keeps its modal confirm, where a blocking prompt is right. Extracted `EditorCoordinator.applyExternalEditOutcome` as the shared resolution so the banner + modal can't drift on the data-safety-critical buffer handling; `DocumentModel.resolveDiskConflict` maps the 3 intents through it + clears the banner; the save-time `SaveConflictDecision` remains the backstop. Host-tested with teeth (resolveDiskConflict keepMine/takeDisk/merge apply the right outcome + clear; capture-fold verified RED). On-screen banner visibility (above the CM6 WebView — the compositor-occlusion class, mitigated by its own compositingGroup+zIndex) is the T5-pixel tier, blocked on the VM Screen-Recording grant (TSK-1334) — so left at review; the model + resolution logic is fully host-proven.
- **PDF find engine (TSK-1140 slice 1):** `PDFSearcher` — a host-tested text-search cursor over `PDFDocument.findString` (ordered matches + next/prev/wraparound + "n/total" summary + case-insensitive default), the search/cursor core for PDF reader find. Host-tested with teeth (7 tests: real generated-PDF search, wraparound verified RED, case-sensitivity, empty/no-match). Not yet user-facing — the render slices (a FindCoordinator `pdf` bag + `PDFView.setCurrentSelection` + a PDF find bar, mirroring the existing per-mode find bags) follow; the current PDF viewer's ⌘F is a no-op until they land.
- **PDF find WIRED end-to-end (TSK-1140 slices 2-4):** ⌘F in a PDF tab now opens a "Find in PDF…" bar that highlights matches in the PDFView and steps them with ⌘G / the bar arrows — replacing the old no-op (⌘F on a PDF previously opened the useless *source* find bar). Built as a 4th FindCoordinator `pdf` bag (mirroring rendered/source/editor) driving a `PDFPreviewFindable` wrapper whose Coordinator runs `PDFSearcher` + applies `PDFView.setCurrentSelection`/`scrollSelectionToVisible`; ⌘F/⌘G route to the pdf bag for `.pdf` tabs (via `currentCategory`), and the shared `next()/prev()` dispatch gained a pdf branch. Host-tested with teeth (FindCoordinator pdf bag show/dismiss/toggle/nonces + next/prev **dispatch-to-pdf** RED-verified; PDFSearcher engine). The on-screen PDFView highlight is the render tail — T4-validatable via `PDFView.currentSelection` STATE (not the T5 Screen-Recording grant), so it can reach validated; left at review pending that run.
- **PDF find VALIDATED host-side (TSK-1140 slice 5):** extracted the consumer's search→selection logic from `PDFPreview.updateNSView` into a testable `@MainActor PDFFindDriver` and host-tested it against a **real `PDFView`** — a query selects the match (`PDFView.currentSelection == the match`), a next-nonce steps it, a no-match clears it, identical inputs don't re-search. `PDFView.currentSelection` IS the on-screen highlight (PDFView renders it natively) and is testable without a window (no T5 grant), so the PDF-find behaviour is validated on the host — the rare render feature that reaches validated without the pixel tier. Teeth: the driver not applying the match → `currentSelection` nil, RED.
- **⌘F bag-routing hardened (TSK-1140 follow-up):** extracted the "which find bar does ⌘F open" decision (rendered/editor/pdf/source) from `main.swift.findInPage`'s inline if-chain into a pure, host-tested `FindBarRouting.target(viewMode:category:supportsViewModeToggle:)` — behavior-preserving, but the routing (incl. the new PDF branch) is now regression-guarded (`FindBarRoutingTests`, 7, pdf-branch RED-verified) instead of untestable `@objc` code.
## 2026-06-29

### Added
- **Universal Paste — Edit ▸ Paste as New Document (⇧⌘V)** — paste anything from the clipboard and it opens in the right viewer: an image → the image viewer, a table (HTML/TSV) → the CSV viewer, rich/plain text → the editor, a file path → that file. The clipboard is always treated as data (never executed).
- **Walkthrough illustrations now appear on screen** — a walkthrough step's `diagram` verb renders as an overlay: ASCII/Unicode art in a monospace callout, or an image, with an optional caption (Mermaid diagrams show their source for now; rendered Mermaid is coming). Previously the illustration was dispatched but never displayed.
- **Terminal Command Palette (View ▸ Terminal Command Palette…)** — a searchable picker over your terminal command history + saved favorites: type to filter (favorites first, pinned), pick one, and it's inserted at the terminal prompt ready to run (no surprise auto-execute — you review and press Return). A cross-session searchable recall the shell's up-arrow can't give you.
- **Task Runner (View ▸ Task Runner…)** — discover and run your project's tasks without leaving the app: it finds package.json scripts, Cargo commands, and Makefile targets, lists them, and runs the one you pick with its output captured inline (bounded — a runaway task can't hang the app). Quick way to fire a build/test/lint and read the result.
- **Structural Search (View ▸ Structural Search…)** — search the active file by SYNTAX, not text: type a structural query (e.g. `function_declaration name=$X`, `call_expression name="print"`) and get a list of matching AST nodes (each with its kind + source snippet). Far more precise than regex against formatting/comments/strings. (Results list now; click-to-jump is a follow-on.)
- **Script Console (View ▸ Script Console…)** — a JQ-style query/transform console over the active buffer: run a JavaScript expression over your JSON, log **lines**, or **CSV** (`input` / `$` is the parsed buffer), see the pretty-printed result, and **Apply →** to open it in a new tab. Runs off the main thread with a soft timeout, so a runaway script never hangs the app.

### Fixed
- **No more crash on an invalid `jq` filter, a misbehaving plugin, or any fast-failing subprocess.** A subprocess that exited before reading its input (jq rejecting an invalid filter; a plugin crashing) could, under load, take the whole app down with SIGPIPE — it closed its input before the app finished writing to it. Both the shared subprocess runner **and** the plugin host now suppress SIGPIPE on the stdin write (`F_SETNOSIGPIPE`), so an early-exiting tool surfaces its error cleanly instead. (Fixes a real invalid-filter-under-load crash + a recurring CI flake; the whole subprocess-write class is now covered.)

### System work
- **Structural-search UI controller (TSK-1161)** — added `StructuralSearchViewModel` (query → `StructuralQueryParser` → `TreeSitterEngine.structuralSearch` over the active buffer → ranged matches / error), host-tested over the Swift grammar. The results panel + DocumentModel wiring + View-menu trigger + VM-validation follow (the Script Console template).
- **Script console — engine, safe execution, JSON/log/CSV input + controller (TSK-698 slices 2/4/4b/3a)** — `JSTransform.runAsync` runs the sandboxed JSC transform off the main thread with a soft timeout (approach B): a runaway script returns `.timedOut` so the UI never hangs. Input formats cover JSON, log **lines** (`input.filter(l => /ERROR/.test(l))`), and **CSV** (header-keyed row objects: `input.filter(r => r.status === "ERROR")`, via the quote-aware CSVParser). Plus `ScriptConsoleViewModel` (the console controller: input/expression → run → output/error state). All host-tested. The SwiftUI **console panel** (`ScriptConsoleView` — format picker / expression field / Run / Apply / output+error) is now built too; remaining is its presentation wiring (DocumentModel flag + menu trigger + apply-to-new-tab) and VM-validation.
- **Structural-search query DSL parser (TSK-723)** — added `StructuralQueryParser` (a tree-sitter-inspired query string → `StructuralQuery`: node kinds + `|` OR + `@capture` + field predicates `=`/`~`/`:`/`=$cap` + `(child)` containment), feeding the already-built `StructuralSearchEngine` matcher. Host-tested (each construct + errors + 3000-input no-panic fuzz). The search UI surface is the TSK-1161 render tail.
- **Image overlay shape-selection model (TSK-1321, first slice)** — placed vector annotations (rect/ellipse/line/arrow) can now be selected + moved/resized/restyled after placement, at the model layer: `selectedShapeID` + `selectLatestShape`/`moveSelectedShape`/`resizeSelectedShape`/`restyleSelectedShape` over the existing overlay primitives (the owner's "start with just the latest"). Host-tested. The on-canvas selection handles + drag gestures are the render tail; rotate needs a `VectorShape` rotation field (follow-up).
- **Music survives session/tab switch — persistent audio player (TSK-1308)** — the audio `AVPlayer` was owned by the media-tab view, so a session switch (view teardown) deallocated it and stopped playback. Added an app-level `AudioPlaybackController` that holds the player (survives teardown); `AudioPlayerHost` binds to it (reuse same-URL, replace on change). Host-tested (reuse/replace contract); on-screen survival is the VM/owner tail.
- **Terminal pane expands freely — lifted the 800/900 size caps (TSK-1313)** — `TerminalPaneLayout.maxHeight`/`maxWidth` were UX caps blocking horizontal/vertical expansion; raised to corruption-guard ceilings (100 000, mirroring `PanelDockLayout.maxSize`), so the window + split layout bound the usable size. Min floors + the absurd-value guard preserved. Host-tested.
- **Removed the redundant image-editor "Box" draw button (TSK-1309)** — the one-shot Box button committed a hardcoded centred red box, redundant with the interactive `.drawRect` tool in the tool picker (the discoverable, positionable equivalent). Removed the button + its helper.
- **Side-nav file-tree respects its shoulder toggle (TSK-1314)** — the FILES tree was mounted on folder-presence (`rootURL`), bypassing its per-panel `.files` override, so it stayed visible when the File-nav shoulder toggle was off (only Bookmark on). Gated `filesPanel` (+ its FILES↔accordion divider) on `isVisible(.files)`, mirroring the bug5 pluginSections fix; `.auto` preserves the default, only an explicit `.hidden` toggle hides it. Host-tested (the override contract); on-screen tree-hide is the VM tail.
- **Test-flake fix — ChromeBodyEvalCountTests parallel stability (TSK-1328)** — the body-eval-count suite's fixed pre-measure pump was too short under machine load, letting a stray async body leak into the measured window (an off-by-one gate flake, isolation-green). Replaced it with a settle-to-quiescence pump; the regression teeth are preserved.
- **Terminal colour scheme — selectable ANSI palette (TSK-1312)** — the `.classic` (xterm-standard) ANSI theme existed but `TerminalPalette` hardcoded the muted `.default` (the likely cause of claude-code colours looking off — muted vs the vivid colours CLI tools expect). Added a `terminalColorThemeName` preference + `AnsiTheme.named()` lookup + made `TerminalPalette` theme-aware (`@MainActor`, perf-preserving), then **COMPLETED** it: a Settings → Terminal → Colour scheme picker (Default / Classic xterm) bound to a new `@Published DocumentModel.terminalColorThemeName` (applied at launch + on change → rebuilds the palette; open terminals recolour on next redraw). Host-tested. On-screen verification (picker render + recoloured terminal) is the VM/owner tail.
- **New Image on the New-Tab landing (TSK-1306)** — added a "New Image" button to the empty-state landing (next to New File) wired to `newBlankImageForLanding` (the action + `BlankImageCreator` model already existed + host-tested; the landing button was the missing entry point the owner reported). AX id `mdv.emptyState.newImage` for the VM click-test. On-screen + AX-click verification is the VM tail.
- **Image format/quality convert primitive (TSK-1325)** — added `Exporter.convert(contentsOf:to:)`: ImageIO-decode any image file → re-encode through the existing `Exporter.encode` (5 formats png/jpeg/heic/gif/tiff + quality + metadata-strip). Host-tested (format-change + dimensions-survive + not-readable/decode-failed errors). The convert UI (pick target format+quality) is the ViewerUI tail.
- **Audio transcode foundation — extract-audio-from-video + audio format/quality convert (TSK-1323/1324)** — added `AudioExporter.transcodeArgs`, one file→file ffmpeg builder serving both (the `dropVideo` flag = extract vs convert), reusing the existing `runFFmpeg`/`FFmpegLocator`/`AudioExportSpec` infra + the `--` arg-injection sentinel; codec/container map for wav/aiff/caf/aac/mp3. Host-tested (argv per format + sentinel + bit-rate floor). The extract/convert UI action is the ViewerUI tail.
- **Smart-paste foundation — HTML→Markdown formatter (TSK-1327, first of the owner intake)** — added `RichTextHTMLParser`: pasteboard `public.html` → the restricted `RichTextDocument` IR → canonical Markdown via the existing serializer (bullet lists → `- `, headings → `#`, bold/italic/strike/links/code, entity-decoded). Common rich-paste tags; TOTAL (never panics on untrusted pasteboard HTML — 3000-input fuzz). Host-tested. The paste-WIRING (intercept paste into a textable field → parse → insert) is the ViewerUI render tail.
- **VM render lane re-established + validated (after the owner reopened VM work)** — synced + ran the in-process WebView render lane on the VM: **78 render tests green, 0 failures** (CM6 editor, rendered-MD, theme parity, blame gutter, diff/block-patch, scroll-restore). Confirmed the render PATH is healthy on the VM; scoped **TSK-1247** (the spawned-app UAT's preview WebView is blank — a test-harness issue, NOT a user bug, and the likely root of TSK-1200 + the scroll-UAT failures, which are therefore harness-false, not real scroll bugs).
- **TSK-1247 spawned-app-UAT render blocker root-caused** — the VM GUI session doesn't framebuffer-composite app-window *content* (the window is logically healthy + the T5 window-ID capture works; only the framebuffer/script-bus path fails), so live-WebView spawned-app UATs read scrollY −1. Added an env-gated `MDV_WINDOW_DIAG` window-state probe; the fix is a focused effort (UAT window-ID render-forcing, or a VM display-config change). Test-infra only — no user-facing impact, and the in-process lane already covers agent render-validation.
- **rust-core hardening — parser crash-prevention fuzz (formula + CSV)** — added no-panic proptests feeding arbitrary input to the formula evaluator (`evaluate`) and the CSV parser (`parse`/`parse_arena`), asserting neither panics on malformed input (both were previously property-tested only on WELL-FORMED input). Confirms a bad cell expression OR a malformed `.csv` file can't crash the app — de-risks the gated `MDV_RUST_FORMULA` (TSK-1215) flip + the crash-on-open path. (Swept the other parsers — hex/markdown/find already covered.) Rust gate green.
- **Editor click-anchor fix (TSK-1188, at review/VM-pending)** — a plain click after scrolling could extend a selection from the previous caret + jump the viewport back; the CM6 active-line plugin + selection-match drag-gate were dispatching transactions *synchronously* inside their mouse handlers (re-entrant → corrupted CM6's `MouseSelection` anchor), now deferred to a microtask so the click places a collapsed caret. Host grep-guard pins the deferral; on-screen behavior is the VM follow-up.
- **DocumentModel SRP split — hot-path tab core + completion engine continue (TSK-1110)** — tab close-variants, async tab-loaders, view-mode switching, lazy tab-materialization (`materializeIfNeeded`), lazy/multi-file open (`appendLazyTab`/`openMultiple`), the LSP completion engine (`editorCompletions`/`handleCompletionRequest`/`requestCompletions` folded into `+CM6Completion`), sidebar reveal / follow-active-tab (`revealInSidebar`/`followActiveTabIfNeeded`), the active-file Markdown export/lint commands (`lintActiveMarkdown`/`checkLinksInActiveMarkdown`/`htmlExportForActiveMarkdown`/`writeActiveMarkdownPreviewHTML`), the active-file CSV/JSON data-format conversions (`activeCSVAsMarkdownTable`/`activeCSVAsJSON`/`minifyActiveJSON`/`activeJSONAsCSV` + content-sniffing), the active-file text-transform commands (Edit ▸ Lines/Transformations — sort/reverse/dedupe lines, case, whitespace cleanup), the active-file Markdown structural transforms (heading-shift, insert-TOC), the active-file format conversions (encoding / line-ending / indent convert), LSP go-to navigation (definition/declaration/type/impl verbs), the LSP editor commands (find-references, whole-document format, rename-symbol, code-actions), and in-editor markdown-table-align each carved out (behavior-preserving exact moves; the tab/close/open/completion host test suites guard them). **DocumentModel.swift now ~3230 lines (from 5835, ~45%); 57 extensions** — the cohesive-logic extraction is complete; what remains is the irreducible open/close/select coordination core + observable state.
- **Gate reliability** — tamed the recurring `TabOpPerf` wall-clock false-red: the worst-case model-side selectTab/closeTab timing can't measure reliably under the parallel headless gate (CPU contention spikes a single op to ~330ms — not a real freeze), so the timing assert now runs isolated/nightly only (the test body still runs under the gate), same policy as the CrossFileSearchBench flake fix.
- **Subprocess robustness** — the audio-export `ffmpeg` spawn now routes through the shared `ProcessRunner` (wall-clock timeout + SIGTERM→SIGKILL escalation), like the rest of the app's subprocesses; the prior raw `waitUntilExit()` had no bail, so a wedged ffmpeg could in principle block the export forever (low practical risk — the input is app-generated — but a real consistency/defense-in-depth gap; found by the post-SIGPIPE subprocess audit). + 3 deterministic tests.
- **LSP config write-back (TSK-1128 model slice)** — `LSPWorkspaceOverrides.setServerCommand` writes/updates a language's server binary in the workspace `lsp.json` (preserving all other entries + their env/args + unknown keys, updating an existing alias in place, atomic, refusing to clobber a malformed file) — the host-tested model behind the upcoming Settings ▸ LSP binary picker (the picker UI is the render follow-on). 5 host tests.
- **rust-core hardening** — added a property-test suite to the transcript parser pinning its contract invariants (the event cap is strictly honored, every parsed event carries an id, parse is deterministic), complementing the existing no-panic fuzz.
- **Terminal command history now captures commands (TSK-1176 populate-model)** — the history store existed but was orphaned (nothing fed it). A new input-side line accumulator reconstructs completed command lines from the raw keystroke stream (Enter-delimited, backspace-aware, conservatively dropping arrow-recalled / tab-completed lines so nothing garbled is ever recorded) and feeds a process-wide shared store as you type. The in-app history-search UI over it is the render follow-on. 18 host tests (13 accumulator + 5 TerminalModel wiring).
- **CSV convert commands now use the fast Rust parser (TSK-1300)** — CSV→Markdown-table / CSV→JSON / CSV-summary were parsing via the slow Swift twin directly while the CSV *view* already used Rust; routed them through the same `RustCSVAdapter` (Rust-default, fail-safe Swift fallback), so large-CSV converts are ~2.5× faster and consistent with the view. Output-preserving (the 6 convert tests pass unchanged).
- **Terminal command-search model (TSK-1176 search-half)** — `TerminalCommandSearch.unified` merges the pinned favorites + auto-recorded history into one ranked, de-duplicated list (favorites first with their titles, then history-only commands MRU; a command in both shows once as the favorite) — the host-tested model behind the upcoming in-app terminal command palette. 6 host tests; the palette UI is the render follow-on.
- **DocumentModel SRP split continues (TSK-1110)** — view-mode-lock (`currentViewModeIsLocked` / `toggleCurrentViewModeLock`) carved into `DocumentModel+ViewModeLock.swift`; plus an audit of the 19 prior SRP pointer comments caught + removed one orphaned doc comment (the `displayedText` slice left its `///` dangling). Behavior-preserving; headless gate green.
- **DocumentModel SRP slice — Editable HEX (#234) carved out (TSK-1110)** — the per-tab dirty-bytes stash + armed-edit state + disk write-back (`saveHexEdits`, with the symlink/IO NSAlert prompts) moved to `DocumentModel+EditableHex.swift` (the 3 stored props stay; `hexDirtyBytes`/`hexEditArmedTabs`/`watchedURL` widened private→internal). Behavior-preserving; headless gate green.
- **DocumentModel SRP slice — editor-coordinator state forwarders + CM6 mount-seed carved out (TSK-1110)** — the indentation/cursor/scroll/diagnostics/gutter/fold forwarders + `editorMountSelectionSeed` (the caret-wins-else-restored-scroll-line CM6 seed) moved to `DocumentModel+EditorState.swift` (zero widening). Behavior-preserving; headless gate green.
- **DocumentModel SRP slice — tab navigation carved out (TSK-1110)** — the tab move/cycle forwarders (`moveTab` / `moveCurrentTabLeft` / `moveCurrentTabRight` / `selectNextTab` / `selectPreviousTab`) moved to `DocumentModel+TabNavigation.swift` (thin forwarders; zero widening). Behavior-preserving; headless gate green.
- **DocumentModel SRP slice — per-tab dict forwarders carved out (TSK-1110)** — the CSV-filter-state + HEX-byte-width forwarders to TabCoordinator (+ the `CSVFilterState` alias) moved to `DocumentModel+PerTabDicts.swift` (zero widening). Behavior-preserving; headless gate green.
- **DocumentModel SRP slice — git-panel focus carved out (TSK-1110)** — `showGitPanel` / `canFocusGitPanel` moved to `DocumentModel+GitPanelFocus.swift` (the GitPanelTab enum + nonces stay; zero widening). Behavior-preserving; headless gate green.
- **DocumentModel SRP slice — source-view scroll-to-line forwarders carved out (TSK-1110)** — `sourceScrollLineTarget` / `sourceScrollLineNonce` / `scrollSource` moved to `DocumentModel+SourceScroll.swift` (thin SourceViewChannel forwarders; zero widening). Behavior-preserving; headless gate green.
- **DocumentModel SRP slice — file-history/extensions availability helpers carved out (TSK-1110)** — `extensionsInventory` / `canShowLocalHistory` / `repoRelativePath` moved to `DocumentModel+FileHistoryAvailability.swift` (zero widening). Behavior-preserving; headless gate green.
- **DocumentModel SRP slice — tab close-variants carved out (TSK-1110)** — `closeCurrentTab` / `closeOtherTabs` / `closeTabsToRight` moved to `DocumentModel+TabCloseVariants.swift` (the core `closeTab` + shared helpers stay; `settleSelectionAfterClose` widened private→internal). The first hot-path-core slice — a behavior-preserving exact move, host-validated by the tab-close test suite. Behavior-preserving; headless gate green.
- **DocumentModel SRP slice — async tab loaders carved out (TSK-1110)** — `loadBinaryAsync` / `loadTextAsync` (the off-main BinaryFile/TextFile reads with the latest-switch-wins guard) moved to `DocumentModel+TabLoading.swift` (made internal so `materializeIfNeeded` calls them; zero other widening). Behavior-preserving; headless gate green.
- **DocumentModel SRP slice — view-mode switching carved out (TSK-1110)** — `toggleViewMode` / `selectViewMode` / `setCurrentViewMode` (the per-mode state machine: async HEX/text re-load, formatted flag, media-preview restore, editor-cap gate) moved to `DocumentModel+ViewModeSwitch.swift` (zero widening; + cleaned an orphaned doc the prior loaders slice left). Behavior-preserving; headless gate green.

## 2026-06-28

### Added
- **Editor autocomplete — a completion popup in the CM6 editor.** Typing an identifier (or ⌃Space) now offers completions: LSP completions when a language server is configured for the file, and an in-file buffer-word fallback otherwise (the vim-Ctrl-N class every editor ships). (TSK-1136 — closes TSK-463; the render wiring landed, the live popup validates on the VM lane.)
- **Paste as New Document (⇧⌘V) — Universal Paste.** Edit ▸ Paste as New Document opens the clipboard's best representation in a new tab: a copied image → the image viewer, a spreadsheet range → the table viewer, rich/plain text → the editor, a copied file → the file itself. When the clipboard carries several representations it picks the richest (file > image > table > rich > plain). Treats the clipboard as data — never executes it. (TSK-1163 / TSK-958 — menu/live action landed, validates on the VM lane.)
- **Spell-check in the editor — misspelled words underlined.** The CM6 editor now spell-checks prose files (markdown + plain text) as you type and underlines misspellings; the squiggles coexist with LSP error diagnostics. Markdown-aware — it skips code spans and fenced blocks so code isn't squiggled, and large files are skipped to stay snappy. (TSK-1146 — completes the spell-underline half of TSK-685; the live squiggles validate on the VM lane.)

### Fixed
- **⌘F no longer hijacks the sidebar file-filter.** Pressing ⌘F while typing in the sidebar's file-nav filter (or a rename / go-to-path prompt) opened the document find bar and yanked focus away mid-type; it now stays in the field. A find bar that's already open still toggles closed with ⌘F. (TSK-1248)
- **Creating a new file/image from the landing screen (no folder open) no longer hangs.** The "New File"/"New Image" buttons fall back to a temp scratch location when nothing is open — but the app then treated that temp directory as a workspace and enumerated its entire contents (potentially thousands of churny system files), causing a multi-second freeze (and briefly dumping the temp dir into the sidebar). It now skips rooting the temp scratch dir. (TSK-1294)
- **Rendered-Markdown find: you can scroll the document with the keyboard while the find bar is open.** Pressing PageDown / PageUp / up- / down-arrow while the find field had focus did nothing — the keys died in the text field, so you were effectively pinned at the current match. They now scroll the rendered page (the find field has no use for them anyway). (TSK-1271)

### System work
- **Landing New-File temp-dir hang (TSK-1294)** — found via the TSK-836/1181 test-speed work (the DocumentModelTests "slow class" was essentially ONE 12.9s test). Root: `recordOpenedFile` auto-rooted the sidebar to an opened file's parent when no folder was open → enumerated the huge temp dir for the landing scratch fallback; `createNewFile`/`createNewBlankImage` also reloaded the temp dir's children. Fix: skip the auto-root for the temp dir + gate the sidebar reload on a new `SidebarModel.contains(_:)` in-tree check. Test 12.9s→0.012s; host-tested (contains unit test + landing no-enumeration teeth: expanded empty + rootURL nil).
- **Test-speed capture (TSK-836) validated** — `test-timings.sh`/`.py` (per-class slowest-first table) verified end-to-end (952 classes / 254s serial) + host-tested (TestTimingsTests); data-enabled the split/de-sleep follow-ups. The TSK-1181 split was reverted — the slow class was the TSK-1294 bug, not class size.
- **AX drift-guard test sped up 36× (TSK-836)** — `everyCriticalIdExistsInViewerUISource` (the Swift-Testing suite's slowest test / parallel long-pole) ran `source.contains("\"id\"")` once PER catalogued id over a multi-MB concatenated-source blob — O(ids × source). Replaced with a single regex pass collecting every quoted `"mdv.…"` literal into a Set + O(1) membership per id (O(ids + source)); semantically identical with the same teeth (a renamed/removed id is absent → the guard fires), plus a new `quotedMdvLiterals` teeth test (quoted-exact: bare/prefix/absent don't count). 1.992s→0.055s; host gate green.
- **rust-core: serve envelope codec gains a fuzz lane (TSK-585)** — `serve/src/envelope.rs` is a hand-rolled MessagePack wire codec (encode/decode the protocol-v1 Frame) that decodes UNTRUSTED bytes off the remote-protocol wire, but carried only example tests. Added a DIY xorshift fuzz pair (no new dep, mirrors the core crate's fuzz lane): decode-never-panics over 20k arbitrary/truncated byte strings (the untrusted-boundary contract) + encode/decode round-trip over 5k arbitrary frames (all 3 frame types, full-range u64 ids, the aux side-channel). A fresh empirical sweep (grep BOTH `proptest!` AND `*_fuzz_*`) found this genuine gap; rust gate green.
- **rust-core: `whitespace::reveal` (show-invisibles) proptest hardening** — the pure per-line space→·/tab→→ transform shared by every front-end's whitespace-markers toggle carried only example tests. Added a property suite over arbitrary input: char-count invariant (the documented guarantee), idempotence (markers aren't space/tab), no raw space/tab survives, and identity on already-clean lines. A fresh per-module proptest-coverage sweep flagged it (zero `proptest!`/`*_fuzz_*` refs); rust gate green.
- **DocumentModel SRP slice — view-hosting carved out (TSK-1110)** — the view-hosting tab logic (`hostedView(forID:)` / `openHTTPClient()` / `openHostedView(_:)`) moved to a new `DocumentModel+ViewHosting.swift` extension (the `hostedViews` registry stays as internal storage; `updateDerived` widened private→internal for SRP slices). Behavior-preserving; compile + headless gate green.
- **DocumentModel SRP slice — command registry carved out (TSK-1110)** — keybinding load/reload + palette dispatch (`loadKeybindings` / `logKeybindingResult` / `invokeCommand`) moved to `DocumentModel+CommandRegistry.swift` (the `commandRegistry`/`macros`/`sessionsCoordinator` storage stays; `commandRegistry`'s setter widened private(set)→internal(set)). Behavior-preserving; compile + headless gate green.
- **DocumentModel SRP slice — active-theme derivation carved out (TSK-1110)** — the computed theme views (`activeThemeDefinition` / `activeTheme` / `activeThemeCMPalette` / `themedExtraStylesheet`) moved to `DocumentModel+Theming.swift` (the `themeOverride`/`selectedThemeID` storage stays; zero visibility-widening — all read public deps). Behavior-preserving; compile + headless gate green.
- **DocumentModel SRP slice — syntax-highlight cache access carved out (TSK-1110)** — `highlightCacheActor` + `highlightRuns` moved to `DocumentModel+Highlighting.swift` (the `highlightCaches` registry + `HighlightCacheKey` typealias stay; registry widened private→internal). Behavior-preserving; compile + headless gate green.
- **DocumentModel SRP slice — print/export-PDF signals carved out (TSK-1110)** — the model-side print/export signals (`canPrintRenderedPage` / `printRenderedPage` / `exportRenderedPDF` / `recordPDFExportResult`) moved to `DocumentModel+PrintExport.swift` (the `@Published` nonces + the PDFExportRequest/Result structs stay; zero widening). Behavior-preserving; compile + headless gate green.
- **DocumentModel SRP slice — rendered-markdown HTML cache carved out (TSK-1110)** — the memoized `renderPage` cache (`renderedHTML` / `renderedHTMLIfCached` / `requestRenderedHTML` / `storeRenderedHTML`, ~140 lines) moved to `DocumentModel+RenderedCache.swift` (the cache storage + `RenderedHTMLKey` stay; 4 storage props widened private→internal). Behavior-preserving; compile + headless gate green. The biggest slice yet.
- **DocumentModel SRP slice — displayed-text derivation carved out (TSK-1110)** — the View-Only/.source lens text resolver (`displayedText(for:)` / `displayText(for:)` — large-read-only passthrough, live dirty-buffer text, formatted-view memo) moved to `DocumentModel+DisplayText.swift` (pure host logic; zero widening). Behavior-preserving; compile + headless gate green.
- **DocumentModel SRP slice — in-app terminal launching carved out (TSK-1110)** — `openTerminalHere` / `openTerminalInApp` / `insertTerminalFavorite` moved to `DocumentModel+TerminalLaunch.swift` (the terminalPane coordinator + favorites store stay; zero widening). Behavior-preserving; compile + headless gate green.
- **DocumentModel SRP slice — active-file LSP queries carved out (TSK-1110)** — `activeFileUnanalyzedByLSP` / `activeFileHasLSPSymbols` / `fetchActiveCodeSymbols` (the `@`-palette code-symbol fetch + analyzed/has-symbols gates) moved to `DocumentModel+ActiveFileLSP.swift` (reads the LSP coordinators; zero widening). Behavior-preserving; compile + headless gate green.
- **DocumentModel SRP slice — editor-buffer lifecycle + save carved out (TSK-1110)** — the per-tab EditorBuffer forwarders + the save-with-diff/repo/LSP-refresh path (`editorBuffers` / `editorBuffer` / `ensureEditorBuffer` / `updateEditorText` / `saveActiveEditor` / `saveEditor` / `discardEditorBuffer` + the `DirtyClosePrompt` alias) moved to `DocumentModel+EditorBuffer.swift` (no stored state moved; zero widening). Behavior-preserving; compile + headless gate green.
- **DocumentModel SRP slice — shared LSP gate + position conversion carved out (TSK-1110)** — `lspLanguageConfigured` / `lspPosition` (the single-source-of-truth LSP gate + CM6→LSP position conversion) moved to `DocumentModel+LSPShared.swift` (pure helpers; zero widening). Behavior-preserving; compile + headless gate green.
- **DocumentModel SRP slice — CM6 LSP hover bridge carved out (TSK-1110)** — `respondToEditorHover` + `sendEditorHoverResponse` moved to `DocumentModel+CM6Hover.swift` (zero widening; behavior-preserving even though CM6-render-adjacent — the dispatch call is unchanged). Compile + headless gate green.
- **DocumentModel SRP slice — CM6 LSP completion bridge carved out (TSK-1110)** — `respondToEditorCompletion` + `sendEditorCompletionResponse` moved to `DocumentModel+CM6Completion.swift` (the `handleCompletionRequest` resolution seam stays; zero widening). Behavior-preserving; compile + headless gate green.
- **DocumentModel SRP slice — "Open As…" universal viewer menu carved out (TSK-1110)** — `openAsCategories` / `openAs` / `setCurrentCategoryOverride` / `defaultViewMode` / `setDefaultViewMode` / `sniffCategory` moved to `DocumentModel+OpenAs.swift` (5 core file-lifecycle members widened private→internal; the open path is more coupled). Behavior-preserving; compile + headless gate green.
- **gate: killed a recurring CrossFileSearchBench false-red (TSK-952 follow-up)** — the per-line new-vs-old wall-clock RATIO assert is noise-dominated inside the parallel gate (best-of-5 still flaked it 3× in one session); it now skips under `MDV_HEADLESS_GATE` (prints the speedup instead) while staying live for dedicated/serial perf runs, and the correctness asserts are unchanged. Stops a flaky red that masked real failures + cost an investigation each time.
- **rust-core: pm lifecycle state-machine drift guards (TSK-345)** — the pm work-item lifecycle keeps TWO separately-maintained §2.2 tables: `can_transition` (shape) and `can_actor_transition`'s `allowed`-actor set (ownership). Added two exhaustive invariant tests over all states × actors: `actor_gating_subset_of_shape_legality_exhaustive` (no actor may perform a shape-illegal transition — the safety boundary) + `every_legal_transition_has_a_permitted_actor` (no shape-legal edge is actor-orphaned/dead — guards the `_ => &[]` drift). Both pass on the current tables; rust gate green.
- **tests: RichTextSerializer coverage (TSK-706)** — the restricted-IR → canonical-Markdown serializer (the Docs-style RichText editor) was exercised only indirectly (the RichText tests cover the parser + the RTF output, not the Markdown serializer). Added a Swift Testing suite (RichTextSerializerTests, 10 tests): canonical block/inline output, CommonMark backtick-run fencing, metacharacter escaping (inline everywhere; block markers only at line-start), ordered-list renumbering, blockquote paragraph-joining, + the documented round-trip idempotence `parse(serialize(parse(x)))==parse(x)` over 6 inputs. Found by a content-based ViewerCore coverage sweep (a prior suffix-based sweep had missed it). Host gate green.
- **tests: FileQuarantine security-boundary coverage** — `FileQuarantine.isQuarantined` (the `com.apple.quarantine` getxattr check that gates raw-HTML JavaScript trust — a quarantined/downloaded file must not be trust-eligible) was uncovered: the HTMLTrustPolicy tests inject `isQuarantined` as a bool, so the real detection had no test. Added FileQuarantineTests (5 IO tests): plain temp file → not quarantined, the xattr set → detected, removed → cleared, nonexistent path → false, an unrelated xattr → not mistaken for quarantine. Host gate green.
- **tests: CSP-meta delivery coverage** — `HTMLDocumentPolicy.cspMeta(trusted:)`, the LIVE Content-Security-Policy `<meta>` emitter for rendered HTML (the untrusted `cspMetaTag` var was tested, but the parameterized fn the trusted-document envelope actually uses had no direct test). Added 3 tests: untrusted matches the strict tag + anti-drift (the two emitters must agree), trusted relaxes script-src but KEEPS the anti-exfiltration fence (connect/object/base/form 'none'), and well-formedness (exactly 4 attr quotes — a stray quote would void the policy). Host gate green.
- **ci: headless gate ~7% faster** — the merge gate's `swift test` now runs `--num-workers 18` (the run phase is I/O/wait-bound — process-spawn LSP/MCP smoke, timeout + fd-leak tests — so oversubscribing the 12 cores fills idle waits). Measured: 12w=101s → 18w=94s; 32w flaked (rc=1) under 2.7× oversubscription, so 18 is the reliable knee. (TSK-847)
- **refactor: DocumentModel SRP — Focus-shortcuts carved out** to `DocumentModel+FocusShortcuts.swift` (TSK-1110 continues). The "clean vein drained" call was premature: `DocumentModel.swift` is still 5788 lines with cohesive un-extracted clusters (Editable-HEX, View-hosting-tabs, CM6-LSP-bridge, …).
- **tracking: BACKLOG next-50 re-pulled from a fresh board scan** (small + large, user-facing first) — added the new render-tail slices (CSV-viewport, PDF/DOCX/xlsx/browser viewers, spell-grammar, feeds-UI, audio-AU, vector-editing), the new find bug (TSK-1271), and board/CI infra (441–445, 831/835/852); dropped the items completed this session.
- **editor: LSP/in-file completion bridge — protocol foundation (TSK-1136)** — added the CM6↔Swift completion message protocol (`requestCompletion` inbound / `completionResponse` outbound + a ViewerCore `CMCompletionItem`) with codec encode/decode + a dispatch reply-empty fallback, host-tested via the codec round-trip. The backend seam (`handleCompletionRequest` → LSP / in-file fallback) was already done; the remaining render slice (entry.js `@codemirror/autocomplete` + the codemirror.html async completion source + ContentView wiring + rebundle) is the focused session — `npm ci` verified feasible this tick.
- **csv: viewport-paging window decision (TSK-1139)** — host-tested `CSVViewportPager`: given the filtered row count + the visible range + the cached window, it returns which window `[offset,limit)` to fetch (visible range padded by a buffer) and whether a refetch is needed (cache-diff — a small scroll within the cached span doesn't re-pull). Factors the testable window-math out of the VM-only SwiftUI scroll handler (11 host tests). The CSVTableView scroll→fetch→render integration (consuming `CSVRowWindowSource`) is the VM-tail render session.
- **editor: spell-check → CM6 squiggle mapping (TSK-1146)** — `SpellDiagnosticMapping` (`SpellingIssue` → `CMDiagnostic`, host-tested ×8) — the spell analog of `CMDiagnosticMapping`, feeding the existing `setDiagnostics` → `lintGutter` squiggle path that already renders LSP diagnostics. Verify-before-build found the LSP-diagnostic squiggles + `SpellCheckEngine` already done+tested; the debounced spell-pass + merge-with-LSP wiring is the remaining render slice.
- **editor: spell + LSP diagnostics now coexist (TSK-1146)** — `EditorCoordinator` source-tracks LSP and spell editor diagnostics separately and merges them (offset-sorted) into the CM6 squiggle channel, so re-publishing one source no longer clobbers the other (LSP errors + spell underlines show together) + a `setEditorSpellDiagnostics` seam. Host-tested ×4 (merge sort · the seam maps+publishes · empty-clears · the LSP↔spell no-clobber contract). The debounced spell-pass trigger feeding the seam is the remaining render slice.
- **editor: markdown-aware spell scope (TSK-1146)** — `MarkdownSpellMask` excludes code from spell-check (fenced blocks + inline `code` spans) via `excludedRanges` + a `filterProse` helper, so prose squiggles never land on code/identifiers (the "highest standards" requirement for markdown spell-check). Host-tested ×6. The correct core the debounced spell trigger (remaining render slice) runs before publishing.
- **rust-core proptest lane grown** — differential proptests added for cm_edit (batch apply == naive splice, TSK-1291), outline (fence suppression, TSK-1292), json (round-trip, TSK-1293), find (substring scan agrees with an independent byte-window scanner + match-validity / grep-distinctness invariants), and nav (filter_entries: subsequence soundness/completeness vs an independent oracle + best-first ordering; sort_entries: permutation + comparator-ordering + dirs-first grouping; NavHistory: op-sequence bounds + back/forward round-trip + push-truncate/coalesce), format (pretty_json idempotence over a recursive valid-JSON generator), indent (detect oracle: consistent tabs→Tabs / 4-space→Spaces(4) / tab+space→Mixed, additive to the existing no-panic fuzz), theme (parse_hex/css_hex color round-trip + #abc shorthand expansion), view (table_col_widths differential-vs-recompute + gutter_width digit-count + clamp_line range/idempotence), meta (text_metrics: lines == stdlib str::lines + count invariants), table_arena (rectangular Table round-trip exact + from_table arity-normalization + accessor consistency), markdown security (safe_url never yields an executable javascript:/vbscript: scheme — incl. the control-char bypass — + escape strips raw <>\"'), image (identify magic-byte parser never panics on arbitrary/truncated bytes — a no-fuzz-target crash surface), mermaid (parse never panics + render_host is XSS-safe: source HTML-escaped, no tag injection), history (MRU push: dedup + front-insert + cap, vs an independent recompute), runtime (eviction_plan: pinned never evicted, within byte+count budget unless only-pinned-remain, TTL reaper drops expired unpinned — the memory-eviction correctness contract), find_engine (host find: UTF-16 positions valid + no-panic on arbitrary text/regex incl. astral chars + literal count == naive), and dispatch (the FFI method router never panics on any method + arbitrary req/aux frame bytes — the untrusted-frame boundary); TSK-585 lane, all gate-green. Concurrency/inlining audit answered (TSK-794: generous Swift concurrency; deliberate rust size-opt).
- **VM Swift 6.1.2 forward-compat build fix (TSK-1210)** — the RustCore remote-core `MsgPackValue` enum's `case map([(MsgPackValue, MsgPackValue)])` (a recursive TUPLE type) tripped Swift 6.1.2's type-checker ("circular reference"; 6.3 compiled it fine), breaking the VM bare-`swift build` forward-compat lane. Replaced the tuple with a named `MsgPackPair` struct (nominal types resolve like the working `array([MsgPackValue])` case) across MessagePack/CoreClient/RemoteTransport + the test construction sites. VM-verified: RustCore now compiles on 6.1.2. Restores the forward-compat signal (the 6.1.2 build catches strictness skew the host's 6.3 misses — it caught TSK-401).
- **DocumentModel SRP split — Format slice (TSK-1110)** — carved the Pretty-print/Format responsibility (effective-language detection + the format-toggle, 8 members, ~76 lines) out of the 7692-line DocumentModel.swift into `DocumentModel+Format.swift` (the established forwarder-extension pattern); widened the shared `loadedText` content helper from `private` to internal. Behavior-identical move; host gate green. Core 7692→7616 lines.
- **DocumentModel SRP split — Save-a-Copy slice (TSK-1110)** — carved the Save-a-Copy + close-dirty file-lifecycle group (6 members) into `DocumentModel+SaveCopy.swift`, reading the HEX dirty-bytes through a new vended `dirtyHexBytes(forTabID:)` accessor so the private `hexDirtyBytes` stash stays encapsulated (no mutable-state leak across the boundary). Behavior-identical move; host gate green. Core 7616→7523 lines.
- **DocumentModel SRP split — Bookmarks slice (TSK-1110)** — carved the 13-member bookmark command surface (file/line toggle, remove×2, clear, undo, refresh, open-with-TOCTOU-guard, dismiss/warning-message, targets, is-bookmarked) into `DocumentModel+Bookmarks.swift`. The @Published `bookmarks`/`lastBookmarkOpenWarning`, the `publishBookmarksChange()` publisher, and the gutter line-cache stay on the main class; the moved mutators route through `publishBookmarksChange()` + a vended `setBookmarkOpenWarning(_:)` so neither `private(set)` setter leaks. Behavior-identical (state stays on the same object → zero observation change → zero render risk); 91 bookmark tests green. Core 7542→7424 lines.
- **DocumentModel SRP split — Cross-search slice (TSK-1110)** — carved the 7-member cross-file search/replace command surface (showCrossSearch×2, openGlobalSearch, dismissCrossSearch, runCrossSearch, runCrossFileReplace, the pure `replaceStatusText`) into `DocumentModel+CrossSearch.swift`. The @Published cross-search state stays on the main class; the private `crossSearchGeneration` cancellation counter (a stored property) widened private→internal so the extension can drive it (a pure impl detail with no public-API contract — unlike bookmarks' `private(set)` public setters, which were vended). Behavior-identical (no @Published move → zero render risk); 67 cross-search tests green. Core 7424→7284 lines.
- **DocumentModel SRP split — Active-document-actions slice (TSK-1110)** — carved the 10-member active-document tool-window + export surface (showAnnotations / showLogPatterns / showPackageExplorer / showLocalHistory / showDependencyGraph / showFolderTreemap + docx/RTF/RTFD/copy-RTF exporters) plus the shared `activeTextFile` helper into `DocumentModel+ActiveDocActions.swift`. `activeTextFile` (the only private symbol) moves WITH the group — every caller is in it, the tail stayers don't use it — so no relaxation/vending; all other deps (openHostedView/localHistoryStore/sidebar/openPath) were already public. Behavior-identical (no @Published involved → zero render risk); LocalHistory teeth green. Core 7284→7137 lines.
- **DocumentModel SRP split — File-history launchers slice (TSK-1110)** — carved the 5 Git File-History + Local-History launcher methods (canShowFileHistory / openFileHistory / openLocalHistory(forTabID:) / canShowLocalHistory(forTabID:) / openLocalHistory(for:)) into `DocumentModel+FileHistory.swift` (the other half of the "Git File History" grab-bag MARK). The `fileHistoryAvailability` cache (a stored property, internal) stays on the main class; all deps were already public/internal (GitClient/FileHistoryView/UnifiedHistoryView/localHistoryStore/editorBuffer/updateEditorText) — clean verbatim move (incl. the intricate `@Sendable` closures), no relax/vend, doc comments included. Behavior-identical (no @Published → zero render risk); FileHistory teeth (19) green. Core 7137→6991 lines (cumulative SRP 7692→6991, ~701 lines out across 6 slices).
- **DocumentModel SRP split — Git-log legacy slice (TSK-1110)** — carved the legacy git-log → synthetic-markdown surface (`GitLogScope` enum + `showGitLog` + the pure static `gitLogMarkdown`/`writeGitLog` + the private `presentGitLogFailure`) into `DocumentModel+GitLog.swift`. `presentGitLogFailure` (private, only showGitLog calls it) moves with the group; the static formatters stay `DocumentModel.*` (SaveCopyTests references them); the nested `GitLogScope` enum lives in the extension. Behavior-identical; git-log teeth (29) green. Core 6991→6889 lines (cumulative SRP 7692→6889, ~803 lines out across 7 slices).
- **DocumentModel SRP split — Code-folding slice (TSK-1110)** — carved the Fold/Unfold menu-action surface (`FoldDispatchTarget`/`FoldCommand`/`FoldDispatch` nested types + `canFoldActiveDocument` + `foldAll`/`unfoldAllActiveDocument` + the private `dispatchFold`) into `DocumentModel+Folding.swift`. The `@Published private(set) lastFoldDispatch` one-shot + the private nonce STAY on the main class (an extension can't declare stored properties); the moved `dispatchFold` writes through a newly-vended `recordFoldDispatch(_:target:)` (the bookmarks vend pattern). Behavior-identical (no @Published moved → zero render risk); FoldMenuActionTests cover the dispatch behavior. **Re-enters the SRP track** — the prior "natural pause" was premature (a fresh MARK scan found several cohesive clusters still extractable: git-diff-gutter, scroll-persistence, completion-bridge, view-mode-control). Core 6889→6825 lines (cumulative 7692→6825, ~867 lines out across 8 slices).
- **DocumentModel SRP split — Breadcrumb slice (TSK-1110)** — carved the file-path breadcrumb surface (the `BreadcrumbSegment` nested type + the computed `pathBreadcrumb` + `navigateToBreadcrumb`) into `DocumentModel+Breadcrumb.swift`. The cleanest kind of slice — a verbatim MOVE with no stored state / @Published, and both deps (`currentURL`, `revealInSidebar`) already public, so no widen/vend. Behavior-identical (zero render risk); ContentToolbarMappingTests cover the breadcrumb. Core 6825→6753 lines (cumulative 7692→6753, ~939 lines out across 9 slices).
- **DocumentModel SRP split — Scroll-persistence slice (TSK-1110)** — carved the per-file scroll/zoom + hot-exit unsaved-text persistence machinery (~13 methods: captureScroll/restoreScroll/applyRestoredScroll/pushLiveEditorScroll/persistScrollMemory/captureScrollForActiveTab + captureUnsavedTextForAllTabs/restoreUnsavedTextIfNeeded + the preview/rendered-scroll memory) into `DocumentModel+ScrollPersistence.swift` — the biggest slice yet. The 3 backing dicts stay on the class widened private→internal; the DEBUG `_test_` scroll-probe counters widened `public private(set)`→`public internal(set)` so the moved code can write them; the 2 eviction-cap statics moved with their methods; all core deps (editor/sourceView/zoom/scrollMemory/scrollSource/seedEditorScroll) were already public. Behavior-identical (no @Published moved → zero render risk); host gate PASSED. Core 6753→6387 lines (cumulative 7692→6387, ~1305 lines out across 10 slices).
- **DocumentModel SRP split — View-mode-control slice (TSK-1110)** — carved the content-toolbar view-mode presentation layer (availableViewModes / viewModePresentation / selectViewPrimary / setViewOnly / toggleViewOnly / applyFocusMode / showsFormatButton / toggleFormatLens / showsRender·EditorPrimary / visibleViewPrimaries + the 2 static hint/upgrade helpers) into `DocumentModel+ViewModeControl.swift`. A clean verbatim MOVE — no stored state/@Published, all deps (currentViewMode/setCurrentViewMode/isHexEditArmed/setHexEditArmed/panelLayout/tabs) already public, no widen/vend. Behavior-identical (zero render risk); host gate PASSED. Core 6387→6221 lines (cumulative 7692→6221, ~1471 lines out across 11 slices).
- **DocumentModel SRP split — Footer-git-chip slice (TSK-1110)** — carved the footer git chip's repo-root memo + branch-switch actions (gitChipRepoRoot computed + the private static gitChipRootCache + openWorktreeInNewWindow + switchBranch + the private presentGitSwitchAlert) into `DocumentModel+GitChip.swift`. A clean verbatim MOVE — no @Published (the root memo is a private static cache that moves with the group; presentGitSwitchAlert private moves with switchBranch), all deps (currentURL/sidebar/openFolderInNewSession/reloadCurrentFile) already public, no widen/vend. Behavior-identical (zero render risk); host gate PASSED. Core 6221→6090 lines (cumulative 7692→6090, ~1602 lines out across 12 slices).
- **DocumentModel SRP split — Raw-HTML-JavaScript opt-in + trust slice (TSK-1110)** — carved the per-tab raw-HTML JS opt-in + per-document trust decisions (htmlJavaScriptEnabled/currentHTMLJavaScriptEnabled/setHTMLJavaScriptEnabled/toggleCurrentHTMLJavaScript + htmlTrusted/htmlTrustEligible/setHTMLTrusted/shouldOfferHTMLTrust + showsHTMLJavaScriptToggle) into `DocumentModel+HTMLJavaScript.swift` (a grab-bag-MARK split — the rendered-HTML cache half stays). The @Published `htmlJavaScriptOptIn` set stays on the class widened private→internal; `htmlTrustStore` stays public; `purgeCaches` still prunes the opt-in set. Behavior-identical (security-critical default-deny preserved; zero render risk); host gate PASSED. Core 6090→6007 lines (cumulative 7692→6007, ~1685 lines out across 13 slices).
- **DocumentModel SRP split — Go-to-path slice (TSK-1110)** — carved the Go-to-path prompt's show/dismiss/record/commit + open-panel-recents merge (6 funcs) into `DocumentModel+GoToPath.swift` (the GoToPath half of the old Command-registry grab-bag MARK; the keybindings half stays). The 2 prompt-intent stored vars (goToPathNewSessionIntent/goToPathPrefill) stay on the class widened private(set)→internal(set); isGoToPathPresented/lastGoToError are @Published public; openPath/openFolderInNewSession/goToPathHistory already accessible (not entangled — uses public openPath). Behavior-identical (zero render risk); host gate PASSED. Core 6007→5938 lines (cumulative 7692→5938, ~1754 lines out across 14 slices).
- **DocumentModel SRP split — Git-diff-gutter slice (TSK-1110)** — carved the off-main git-diff/git-blame gutter compute (refreshDiffMarks/refreshBlameMarks/toggleEditorBlame/refreshSplitDiffMarks + resolveGutterRoot/relativePath + 2 statics) into `DocumentModel+GitDiffGutter.swift` (the diff/blame/split sub-cluster of the 5-concern gutter MARK; editor-folds + sticky-scroll + loadedText stay). `sourceDiffMarks` (@Published private(set)) stays on the class with a vended `setSourceDiffMarks`; `diffMarksTask`/`splitDiffMarksTask` widened private→internal; `editorBlameActive` public. Behavior-identical (zero render risk); host gate PASSED. Core 5938→5788 lines (cumulative 7692→5788, ~1904 lines out across 15 slices).
- **External-edit 3-way auto-merge — decision wired (TSK-1269 slice 1)** — `DocumentModel.reconcileExternalEdit(forTabID:url:)` now computes the merge outcome (base = last-saved, ours = live editor buffer, theirs = on-disk) via the previously-orphaned `ExternalEditReconciler`, so non-overlapping external edits can auto-merge instead of forcing a blunt keep-mine/reload-theirs choice. Host-tested (6 cases: noExternalChange / cleanReload / autoMerged / conflict + the no-buffer & unreadable-disk nil guards). The apply (buffer-replace) + flow-routing are the render tail (slices 2/3); the current flow is already data-safe (it prompts), so this is the convenience win.

## 2026-06-27

### Added
- **Copy Reference** — tabs, sidebar files/folders, bookmarks, and Recents have a right-click "Copy Reference" menu item, and the editor has a **Copy Reference (current line)** command (palette / shortcut). Each copies a shareable `mdv://…` reference to the clipboard, so you (or an agent) can point precisely at a file — or an exact line (from a bookmark, or the editor's current line). (The native-chrome-element form follows.)

### Fixed
- **CSV: a single-column file ending in an empty value no longer drops that row.** A quoted-empty final cell (`""`) was mistaken for the blank line a trailing newline leaves, and silently dropped; it's now kept as a real empty cell (a genuine trailing blank line is still dropped). Found *and* fixed via the new property-test lane (TSK-1286).
- **Emoji & other astral characters in opened `.rtf` files no longer vanish.** A `.rtf` stores any codepoint above U+FFFF (emoji, rare CJK, math symbols) as a UTF-16 surrogate pair; the text extractor was discarding each half as an invalid character, so the whole character disappeared. It now reconstructs the full character. Found + fixed via an audit-harden pass on the hand-rolled RTF parser.

### System work
- **Copy-Reference UI (TSK-1256)** — wired the `mdv://` element-ref pipeline (already host-complete) to four context menus (TabBar / SidebarView / BookmarksSection / RecentlyOpenedSection) plus an editor command + `copy-reference` script-verb (DocumentModel.lineReference pure builder, host-tested 3×; CommandRegistry vocabulary teeth caught the allowlist gap), each using the host-tested `ElementRef.file(…).serialized`; non-data-affecting (clipboard), on-screen capped at review.
- **VM-harness + board (TSK-1283/1253/1154/1254/941/463/1279)** — fixed the GUI-session `test-in-vm.sh all` EMFILE false-failure flood (asuser ulimit 8192→16384, validated: 182→0); corrected 4 #NNN-corrupted ticket understandings; spiked/verify-stated the remaining wave-12 (each blocked on engine/owner/render, recorded); host-verified dark-mode's major surfaces already adapt (chrome semantic + markdown.css fully adaptive).
- **Agent action surface (TSK-1284/1254)** — `goto-line` script-verb (agent line-navigation via run_verb; host-tested, validated); AX-id catalog 40→42 (LocalHistory + PackageExplorer promoted to the agent-facing contract, drift-guard verified).
- **Wave-12 host layers (TSK-1149/941)** — RSS reader: `FeedRefreshScheduler` (due-feeds model) + `FeedReaderViewModel.refresh()` orchestration (`FeedFetching` seam, scheduler→fetch→ingest) complete the RSS host layer; approve/reject: `HunkReviewState` (per-hunk selection→resolvedText) + `AgentDiffApply.applyToFile` (divergence-guarded write — closes a historical-revert corruption risk: apply only if the agent's edit is still present + unique) complete its host layer with data-safety. Both render tails (tool-window view / per-hunk review UI) deferred to VM sessions (occlusion / data-affecting) with recorded recipes.
- **Board hygiene (TSK-1253)** — stale-progress reclaim validated (fleet: 0 progress lane / `liveLeases:[]`; INT-126 auto-expire guards recurrence).
- **rust-core deps (owner-approved 2026-06-27)** — memchr SIMD `memmem` wired into `hex_search_find` (TSK-399; zero new surface — already in-tree via pulldown-cmark; rust-core gate green, hex tests 54/0); proptest property-test lane COMPLETE (TSK-585 — dev-dep default-features=false+["std"]; property suites across filter / diff / CSV / formula / hex (memmem find-all == a naive non-overlapping scan — verifies the TSK-399 SIMD refactor) / wire (frame round-trip + arbitrary-byte robustness of the length-prefix parser) / session (op-replay determinism + set_filter idempotence) / fuzzy (match iff CI-subsequence existence) — completing the ticket's named scope of wire-laws · CSV round-trip · session-op-replay; the CSV-quoting suite FOUND and then FIXED a real parser bug, TSK-1286); cargo-fuzz/wasm32 queued, rusqlite built (the PM store). cargo-mutants rejected on dep hygiene (its full tree compiles on the dev machine) → DIY mutation-testing options recorded. Each dep has a use-follow-up + a CLAUDE.md "Rust-core dev tooling" convention so they're used as intended.
- **Project-management store — slices 1–4f (TSK-345)** — new isolated `mdvcore-pm` crate: rusqlite 0.39 against the SYSTEM libsqlite3 (`default-features=false`, NO bundled — zero new native lib per the v2 design; macOS ships libsqlite3). Kept OUT of `mdvcore-core` so it stays sans-IO/wasm-buildable. Slice 2a is the event-sourcing CORE — an append-only `event_log` + a `work_item` projection, with `append` committing the event AND its projection atomically (one transaction) and `replay` rebuilding the projection as a pure fold over the log (the v2 invariant: the log is the truth, current state is a deterministic rebuild). Gate-green (replay-identity + atomic-project + logged-noop tested). Slice 3 adds on-disk persistence (`open(path)` — durable across reopen). Slice 4a adds the lifecycle state-machine — the v2 §2.2 `State` enum (10 classes) + `can_transition` (the full transition table, incl. `*→Abandoned` + terminal-state guards), host-tested. Slice 4b adds the per-edge actor-gating — the §2.2 ownership table as the SAFETY boundary (the doer's ceiling: an agent proposes done but never self-certifies; human admission/kill gates; system requeue/verify), host-tested. Slice 4c adds the `work_next` (Ready dispatch queue, FIFO) + `state_rollup` (count-by-state) queries. Slice 4d wires the lifecycle ENFORCEMENT into `append` — a `PmError` model rejects illegal-shape / unauthorized-actor / unknown-item / non-canonical transitions BEFORE writing (the §2.2 safety boundary, now enforced not just checkable). Slice 4e adds the doer≠verifier identity guard — `claimed_by` is recorded on entry to Active, and an actor cannot certify its own work (the §1.4 capstone: an agent structurally cannot self-certify; a distinct verifier succeeds). Slice 4f adds dependency edges — `wi_edge` (depends_on / consumes / touches) + `add_edge` with **transactional cycle rejection** (a depends_on cycle is rejected before it's written — the v2 §1.7 invariant; a recursive-CTE reachability check) — and a **dependency-aware `work_next`** (a Ready item is dispatchable only when its depends_on prerequisites are all finished — the §1.7 finish-to-start gate), plus inverse-edge queries (`dependents_of` / `consumers_of`) for impact analysis and the **consumes-ripple auto-cascade** (invalidating an item ripples to its transitive VerifiedDone consumers via logged system-actor events in the same transaction — replay-deterministic; the §1.7 reverse-ripple). Slice 4h makes the edges THEMSELVES event-sourced (an `EdgeAdded` event → projection; `add_edge` logs it and `replay` rebuilds `wi_edge` from the log) — so the store is now fully event-sourced: both `work_item` and the dependency graph rebuild deterministically from the event log alone. Slice 5a adds the wire protocol — `PmRequest`/`PmResponse` + `dispatch` (domain errors → an `Error` response, never a panic) + a msgpack frame codec `dispatch_bytes` (the host-testable FFI/remote contract). The extern-C exposure + the Swift `libsqlite3` staticlib-link (slice 5b — cross-cutting) and the hash-chain (slice 2b — parked on the crypto-hash dep) are the remaining tail.
- **DOM-patch perf-lever host+FFI (TSK-838)** — the rendered-Markdown WebView's 2-9s full-reload storm gets its host+FFI core: a depth-aware HTML block splitter (`split_top_level_blocks`, split↔concat-exact), a prefix/suffix block differ (`block_patch` → `[Keep/Delete/Insert]` + `apply_block_patch`, the JS-applier host model), and an FFI-callable wire entry (`block_patch_wire` / `dispatch::Method::HtmlBlockPatch` / `MDV_METHOD_HTML_BLOCK_PATCH=17`), so a re-render can diff two renders into a minimal block patch instead of reloading the whole page. Proptested on REAL pulldown-cmark output (split-rejoin exact · apply(old,patch)==new · end-to-end reconstruct) + a wire round-trip; rust-core gate green incl. header-drift. The JS DOM applier + WarmHTMLWebViewCache integration + the perf-validation are the owner/VM render tail.
- **Agent-drivable surface — read/action symmetry (TSK-1254)** — extended the agent self-driving surface to all 4 axes. Addressing: AX-id catalog 42→59 (added the previously UN-addressable core tab strips — document tabbar / session-tab bar / split — plus walkthrough / search-anywhere / markdown-overview / action-history / problems / claude-timeline / find-match-list / recently-opened / media-preview / observability). Action: `close-split` verb (deterministic, vs the state-dependent toggle). Discovery: `list_verbs` + `list_surfaces` MCP tools (agent self-enumeration of the ~134-verb action vocabulary + the addressable surfaces). Reading: `current_state` gained the journey-state an agent asserts on (split-open / vim-mode / per-tab dirty) + the live session list (enumerate sessions to drive the session-* verbs by id/name). All host-tested with teeth, MCP-reachable (not AX-TCC-gated); read/action symmetry across tabs · verbs · surfaces · sessions.

- **DOM-patch perf-lever COMPLETE + VM-validated (TSK-1183/838, gated MDV_DOM_PATCH OFF)** — the host+FFI core (TSK-838, above) got its full apply path this run: a `jsPayload` Swift→JS wire format + `BlockPatchJS.applyFunction` (the JS DOM-mutator that replays `RenderedBlockDiff.apply`'s exact index semantics on `document.body`) + the gated `updateNSView` rewiring (a SAME-FILE re-render now block-patches in place instead of a full `loadHTMLString` reload, falling back to a reload when the diff is large / ineligible). Validated end-to-end on the VM-webview lane: `applyBlockPatch` on a clean body (BlockPatchApplyWebViewTests), the live-rendered body aligns 1:1 with `splitBlocks` so the patch targets `document.body` directly (BlockPatchAlignmentProbeTests), and the production `tryApplyDOMPatch` helper patches a live WebView (small→patch / large→fallback). Gated default-OFF so production is unchanged; the owner flips `MDV_DOM_PATCH` + confirms the on-screen perf win (kills the 2–9s per-keystroke rendered-MD reload storm). This also clears the same-file-re-render component of the MD-open-lag (TSK-598).
- **rust-core front-end parity — back/forward + multi-file tabs (TSK-250, VALIDATED)** — `core::nav::NavHistory` (a pure, front-end-agnostic back/forward visited-path stack with browser truncate-forward semantics) wired into the Web front-end (`/back` + `/forward` routes that push on `/view` and replay the resolved target + in-page ◀ Back / Forward ▶ chrome buttons), plus host tests proving the pre-existing TUI multi-file tabs (open / `cycle_tab` wrap-switch / close / persist). Both halves fully host-tested (NavHistory 5 + web route/chrome + tui cycle_tab), rust-core-gate-green, poison-tolerant locks — agent-validated with the complete test artifact.

- **Render-tier test coverage + boundary (TSK-1270/1290/1279/400)** — rendered-MD find now has WebView render-tests, both VM-validated on a live WKWebView: clear removes ALL highlights incl. the active match (lossless), and run-behavior (count accuracy / case sensitivity / next-prev cycling+wrap / regex-metachar escaping). Dark-mode pixel guard (TSK-1279) asserts the `theme-dark` window paints mostly-dark with light-mode teeth (the scene applies on the VM; pixel capture is the all-mode/nightly tier). Reconciled the `mdvcore-rpcd` spike (TSK-400) as superseded by the implemented `mdv-serve` daemon. Documented the agent-validatable boundary (WebView/DOM tests validate clean in `webview` mode; T5-pixel needs all-mode — `test`-mode screencapture is TCC-denied).

## 2026-06-26

### Changed
- **Tool results now open in a panel, not a pop-up.** Check Links, Lint, Document Statistics, and CSV Summary show their results in a floating panel — click a row to jump to that line, copy everything, keep editing while it's open — instead of a blocking alert. All four are now also in the command palette.
- **Menus reorganized for clarity.** The overloaded View menu is decluttered: a new **Tools** menu (Document Statistics, Check Links, Lint Markdown, CSV Summary), a **File ▸ Export / Share** submenu (Copy as HTML/Markdown/JSON/CSV, Export HTML, Open in Browser), and a new **Format** menu (encoding/line-endings/indentation, trim whitespace, tabs↔spaces, table of contents, promote/demote headings, align tables). View now holds only see-the-doc actions.
- **Editor caret no longer blinks** — the text cursor is now steady in both vim modes (the NORMAL-mode block cursor and the INSERT-mode line caret).
- **Paste a copied table → opens as a table** — "New Tab from Clipboard" now detects a copied spreadsheet/web-table range (tab-separated) and opens it in the CSV/table viewer instead of as plain text. Comma-bearing prose is unaffected (only real tab-delimited grids are treated as tables).

### Fixed
- **Enter / arrow keys no longer "leak" from the editor to the file sidebar** — when typing in a split (or recently tab-switched) editor, pressing Enter could jump focus to the file tree and open the selected file. The editor's keys now stay in whichever editor pane is focused. (Root: the app keeps several editor panes mounted for instant tab-switching, and the key router was only checking the topmost one.)
- **The app now launches on other Macs** — a copy of the app sent to another Mac used to crash instantly on launch; it was secretly loading its editor/highlighting resources from the folder it was *built* in, which doesn't exist anywhere else. The app is now fully self-contained and runs anywhere (Apple Silicon, macOS 15+; clear the download quarantine or right-click → Open the first time, since it isn't notarized yet).

### System work
- **Build/packaging (TSK-1257)** — root-caused the clean-machine launch crash to the SwiftPM `Bundle.module` accessor resolving resource bundles from a hardcoded dev `.build` path. Added a `Bundle.resolveResourceBundle` resolver (prefers the app's own `Contents/Resources`); stamped a real `Info.plist` into each shipped resource bundle; new host-safe `--verify-resources` packaging self-check wired into `build-app.sh` (post-sign) + `verify-app.sh` (fails the build if any resource resolves from `.build`); `verify-app.sh` strict-codesign now runs on a de-xattr'd copy to dodge the iCloud `FinderInfo` false-failure. Fixed build vended to the private `mvd_dist` repo.
- **Test-infra (TSK-1258)** — restored the headless gate to green: the `ScriptVerbCatalog` drift test now recognizes `ScriptRunner.swift` as the second dispatch surface (the runner-only `wait-editor-line`/`wait-rendered-scroll` verbs were false-flagging since the TSK-1047 scroll work).
- **Test-infra (TSK-1174)** — extracted `GitTestRepo` into a shared `TestSupport` library target (test-only, never shipped) so both ViewerCoreTests and ViewerUITests can share one git-repo fixture builder; re-pointed the 6 existing ViewerCoreTests users (the 13 ViewerUITests git classes' migration off their duplicated setup follows).
- **Agent-automation tooling (TSK-1254/1193/1154/1052)** — out-of-process AX driver host foundation + the curated agent-drivable AX-id catalog expanded to 33 surfaces (drift-guarded — added the rendered-Markdown/HTML view, the diff content surface, the LSP outline, and the code-review composer); two new agent-callable MCP tools — `list_runnable_tasks` (discover npm/Cargo/Make/test tasks) and `process_memory` (reports phys_footprint incl. compressed, not VSZ/RSS); image-editor dirty-rect paint-compositing model; 11 menu-only edit transforms made palette- + script-verb-invokable (TSK-1186 — heading promote/demote, line sort/reverse/dedup, line-ending LF/CRLF/CR + indentation tabs/spaces converters), growing the agent-drivable action surface.
- **Agent-drivable interface — comprehensive (TSK-1254/1256/1162/941/649)** — the agent self-driving surface filled out end-to-end. AX-id catalog grew to 39 (added the status-bar STATE surface: git / vim-mode / modified / macro-recording / memory). Four more agent MCP tools: `outline` (heading TOC), `git_status` (repo/branch via `.git/HEAD`, no subprocess), `run_verb` (the **entire ~60-verb script bus** as one action tool — the public action surface), `lint` (Markdown image-alt / heading-skip / dup-anchor). Element-ref `mdv://` addressing host pipeline complete (model → resolution → dispatch → live target; the right-click "Copy Reference" UI is the render tail). Macro record/replay feature (core+vm — the orphaned MacroRecorder wired through the verb dispatch + a status-bar recording indicator). Approve/reject agent-diff patch-apply engine (Model A revert-on-reject, hunk-level). Rust formula + fold flips confirmed render-safe (the only two pending — fold VM-confirmed via a new frugal `webview` test-lane mode). All host-tested + self-validated where host-completable; the render UIs (Copy-Reference, macro-indicator pixel, approve/reject review) cap at review.
- **Rust-core ports validated (TSK-1213/1202)** — the formula-evaluator and fold-region Rust ports confirmed at full Swift↔Rust parity (differential-fuzz + 6-language A/B); both ship behind flags pending the owner soak+flip.
- **Rust-core cm-delta seam (TSK-543 stage-1)** — wired the built `apply_delta_wire` as a new envelope method (`MDV_METHOD_CM_APPLY_DELTA`, capability `1<<15`) through the FFI dispatch + the mdv-serve dispatch + the Swift capability pin, so a CodeMirror edit-apply can return only the changed region instead of the whole buffer — the foundation for cutting the remote/gated cm-apply wire traffic. Gates green. Stage-2a added the Swift `mdvCoreApplyCMEditsDelta` wrapper (the seam is now callable + round-trip-tested end-to-end Swift→FFI→rust); the live-editor mirror-adoption + session-keyed (base-once) stages follow.
- **Board hygiene / validation drain** — ~45 `fixed`/`review` items battle-tested to `validated` with teeth; ~50 built engines reclaimed `fixed`→`review`; #NNN-corrupted understandings corrected, duplicate tickets deduped, orphaned-ViewerCore-core audit + delete-set surfaced, approve/reject design resolved (revert-on-reject is the only feasible model).
- **Editor key-event leak class + wave-12 model-first slices (TSK-1280/1281/1282/1149/1279)** — root-caused the owner's "Enter leaks to the file nav" to `SidebarKeyMonitor` yielding against only the topmost editor (`current()`) while `MountedPanesLRU` mounts several panes; fixed to honour every live editor pane (`liveWebViews`), with a host multi-pane teeth test. The owner-requested key-leak *audit* then found the same class in `EscFocusMonitor`'s Esc classifier (TSK-1281, fixed the same way) and the deeper root — `current()` returned the first-registered, not the focused, editor, so action sites like snippet-insert targeted the wrong mounted pane (the owner's snippet-"random-places" bug, TSK-1282) — fixed host-side: `current()` now prefers the editor that contains the key-window first responder, via a host-tested generic preference helper; the on-screen snippet-lands-in-the-focused-pane confirm is VM. RSS feed-reader display-composition model (newest-first + read-state annotation, per-feed unread rollups) built host-first ahead of the render tool-window. Dark-mode theme-readiness audit first pass (the top hardcoded colors are legitimate scrims/accents/hairlines; the real "white border / black text" breaks need a VM dark-mode pixel survey — filed). Build-speed ask answered with data: the incremental inner loop is healthy (leaf change → 1 file ~5s, no cross-module cascade; the gate's 95s is cold-compile + the parallel test run). VM `all` re-validated the session body green; caught + fixed one cross-test miss (the PMA01 MCP-tool-list count).
- **VM-harness fd-exhaustion fix + RSS reader view-model (TSK-1283/1149)** — a GUI-session `test-in-vm.sh all` flooded 182 EMFILE ("Too many open files") FALSE failures (host-green pure-logic suites failing to open temp files) — root-caused to `swift_test()`'s asuser-inner `ulimit` (8192) sitting below the outer shell's (16384); the GUI-session live-UI sweep exceeded it as the suite grew. Raised the inner limit to 16384 (graceful fallback) so the VM validation lane stops false-reding (the key-leak class's test classes all passed on that run — not a regression). RSS reader: added the host-tested `FeedReaderViewModel` (selection + fetched-feed cache + mark-read → summaries/items via the pure model) — the stateful layer the render tool-window will bind.

## 2026-06-22

### Added
- **Open Word / RTF / OpenDocument / Excel files as text** — `.docx`, `.rtf`, `.ods`, and `.xlsx` files now open as readable **read-only** text (their extracted content) instead of raw bytes; a save can never overwrite the original document.
- **Command palette ▸ text case** — Uppercase, Lowercase, and Capitalize text transforms are now invokable from the command palette (they were menu-only).

### Changed
- **⌘K freed for the terminal** — ⌘K no longer opens the command palette; use **⇧⌘P** or **double-Shift** to open it.

### System work
_147 commits today; ~3 user-facing (above). The rest, by area:_
- **Tests (~63)** — robustness + Swift-vs-Rust differential-parity fuzz sweep across the shipped engines (find, diff, CSV, hex, format, outline, fuzzy, indent, transcript, formula); host-coverage backfill for the JSON / CSV / edit / security model wiring; WebView-tier + bundle-cap doc guards.
- **Rust-core ports, behind flags — pending owner flip (~17)** — folds engine + FFI + 6-language A/B parity adapter; the formula port made parity-clean (5 fuzz-found bugs fixed); LSP zero-server completion + workspace-binary-trust decision cores.
- **CI / VM / build (~16)** — repaired the VM validation lane (Swift-6.3 build, lazy-grammar dylib shipping, WebView fd-exhaustion false-failures); hardened the coverage scripts (low-disk guard, manual profdata-merge fallback) + reclaimed 23 GB of stale profraw; prod `/Applications` release build; exec-size cap 60→65 MB.
- **Tracking (part of ~34 doc commits)** — root-caused the VM-UAT 0-dumps blocker (TSK-1243, HOME-half fixed); 7-subagent board reconcile (confirmed the board is accurate, not lagging); consolidated all tracking docs into one `BACKLOG.md` + archived the stale ones.

## 2026-06-21

### Added
- **Web viewer — rendered Markdown (default)** — the standalone web front-end now shows `.md` files as formatted HTML by default (headings, bold, lists, links), with Source/Hex toggles to see the raw bytes; unsafe links are stripped.
- **File ▸ Local History** — browse the save-time version snapshots of the current file (timestamp + size) and view any past version read-only.
- **View ▸ Toggle Read-Only** — lock the editor against accidental edits for the session (checkable menu item).
- **File ▸ Export as Word / RTF / RTFD** — export the current Markdown document to a `.docx` Word file, an `.rtf` file, or an `.rtfd` package (headings, lists, bold/italic/strike).
- **Copy as RTF** — copy the current Markdown document to the clipboard as rich text, so it pastes formatted into Mail, Pages, etc.
- **CSV — rectangular select, copy & paste** — shift+arrow extends a cell rectangle in the table view; ⌘C copies it (tab/newline-delimited, paste-ready into a spreadsheet) and ⌘V pastes a TSV grid into cells while editing.
- **File ▸ Annotations** — a jump-list of the current file's TODO / FIXME / HACK / XXX / NOTE / BUG markers; click one to jump straight to that line.
- **File ▸ Log Patterns** — a frequency-ranked summary of the current log's repeated line patterns (masked templates + counts + an example), for fast log triage.
- **Folder stats → treemap** — a "Show Treemap" button on the folder/repo statistics card opens that folder's size treemap.
- **Settings ▸ Extensions lists walkthroughs** — your saved walkthrough library now appears alongside installed plugins in the Extensions inventory.
- **File ▸ Package Dependencies** — for an open package.json / Cargo.toml, a list of its declared dependencies with versions and runtime/dev badges.
- **File ▸ Dependency Graph** — visualize your project's import dependency graph (file→file imports) in a tab; click a node to open that file. Also from the command palette.
- **File ▸ Folder Sizes (Treemap)** — a size-proportional treemap of the open folder, so you can see what's eating disk at a glance. Also from the command palette.
- **Settings ▸ Advanced ▸ Multi-session workspace** — a toggle for the sessions feature (on by default), now adjustable instead of buried as a hidden preference.
- **Settings ▸ Extensions** — an at-a-glance list of your installed plugins.
- **File ▸ New Image** — create a new blank image (choose width, height, and background color) and start editing it right away. Also offered in the New File submenu and the sidebar folder's right-click ▸ New File menu.
- **CSV/TSV view** — navigate cells with the arrow keys (the focused cell is ringed) and copy the focused cell with ⌘C.
- **Interactive walkthroughs** — when a walkthrough pauses to ask you something, the player now shows the prompt with quick-reply buttons and a free-form field; your answer continues the tour.
- **File ▸ Walkthroughs** — browse your saved walkthroughs and, from one place, run, resume (from where you left off), rename, or delete them (right-click). Also from the command palette.
- **Image editor — paint on the image** — with a paint tool selected (brush / pencil / eraser / airbrush / eyedropper / fill), draw directly on the image; drag for a continuous stroke. The pencil is a hard 1px draw; the brush and eraser can be round or square; the airbrush sprays a soft scatter.
- **Image editor — shape tools** — pick the rectangle, rounded-rectangle, ellipse, line, or arrow tool and click-drag to draw it, with a live preview as you size it. Toggle "Fill shape" to draw the closed shapes filled instead of outlined.
- **Image editor — full selection toolkit** — select a region with the rectangular marquee or the free-form lasso (dashed outline); drag inside it to move it, or Copy/Cut it to the clipboard, Paste an image in, Crop to it, Delete it (erase to transparent), Select All, or Invert the selection.
- **Image editor — flip, rotate & skew** — Flip Horizontal/Vertical, Rotate Left / Right / 180°, and Skew by horizontal/vertical degrees (all undoable).
- **Image editor — invert colors** — turn the image into a photo-negative (undoable).
- **Image editor — foreground & background colors** — a second (background) color with a Swap button; Clear fills the whole canvas with the background color.
- **Image editor — color palette** — a strip of preset color swatches; click one to set the paint color.
- **Image editor — recent colors** — a "Recent" swatch strip remembers the colors you've picked (eyedropper or palette) for quick reuse.
- **Image editor — resize** — a Resize dialog to scale the image by percent or to exact pixel dimensions, with an optional aspect-ratio lock.
- **Image editor — Save** — save edits back to the original file (or Save a Copy for an unsaved new image).
- **Image editor — more save formats** — Save a Copy now writes BMP, GIF, and TIFF in addition to PNG, JPEG, and HEIC.
- **Image editor — canvas size** — the Resize dialog has a "Canvas size" mode that pads or crops the canvas to new dimensions without scaling the image.
- **Image editor — copy/paste via file** — Copy the selection (or whole image) out to an image file, and Paste an image file onto the canvas.

### Performance
- **Image editor** — adjusting sliders and edits is snappier on large images: the source is now decoded once and reused, instead of being re-decoded on every change.
- **Image editor** — Save a Copy no longer freezes the window while a large image encodes and writes; it now saves in the background.

### Fixed
- **Find bar** — reopening Find (Cmd+F) now restores your previous search text in the rendered and source views (the editor already did this).
- **Tooltips** — open a touch slower so a pointer just passing over a control no longer flashes a tooltip.

## 2026-06-20

### Added
- **Local History** — right-click a file (in the sidebar or its tab) ▸ **Local History** to see a list of saved versions, click one to view it or diff it against the current file, select a range to see the cumulative change across it, and **Restore** a version back into the editor as an undoable edit. Versions are recorded automatically when you save edits (text files only; `.env` and other secret-like files are never kept; 20 MB cap; on by default and configurable).
- **View ▸ Focus Mode** — one-click workspace presets (Coding, Code Reading, Doc Reading, Git History, Git Diff, Code Review) that pin the sidebar to the panels relevant to that activity and switch to the lens it reads best in.
- **Toggle View Only with ⇧⌘L** — a keyboard shortcut + View-menu item (and command-palette verb) to flip the active tab's read-only lock on/off, instead of only the toolbar checkbox.
- **Edit ▸ Transformations — Make Upper Case / Make Lower Case / Capitalize** — TextEdit-style case transforms for the active text file, in the Edit menu (and invokable from the command palette). With no selection they transform the whole file.
- **Syntax highlighting in the editor for 22 languages** — editing a file now colors code for the full set the viewer already highlights: JSON, Rust, JavaScript, TypeScript, JSX, TSX, Java, C, C++, C#, Swift, Kotlin, Lua, Python, Shell/Bash, YAML, HTML, CSS, Go, Ruby, Markdown, XML, and SQL. Previously the editor only colored Markdown, JS/TS/TSX, Python, and JSON — everything else showed as plain text the moment you switched to Edit.

### Performance
- **Smaller app download** — the app shed ~12.5 MB of duplicated syntax-grammar files. Code highlighting now runs entirely through the shared Rust engine instead of carrying a second, redundant set of parser libraries (Python, Shell, Java, C, C++, C#, Rust, Lua) just for the viewer. No change to what gets highlighted.
- **Image-editor adjustment sliders feel smoother** — dragging Brightness/Contrast/etc. no longer re-runs the full image pipeline on every tiny movement; the render now waits for a brief pause and runs once, so the sliders stay responsive.
- **Typing in the Hex view's search box is smoother** — searching a large binary file no longer scans the whole file on every keystroke; the scan now waits for a brief pause in typing, so the field stays responsive.
- **Switching sessions is faster** — a rendered-Markdown file you return to no longer rebuilds its preview from scratch on every session switch; its already-rendered view is kept warm and re-shown instead of re-paying the slow web-view load each time. Tearing down the outgoing session's tabs on a switch was also doing redundant per-tab work (git-diff / outline / language-server refresh) once per tab — now done once.
- **Switching an HTML file between Render and Editor is faster** — toggling a `.html` tab's lens (or leaving and coming back) no longer rebuilds its rendered preview and re-loads the whole document each time; the rendered web view is kept warm and re-shown, so big self-contained HTML files don't re-pay the slow render on every switch.

### Changed
- **New sessions open clean — just the file tree** — a fresh session now starts with only the Files tool window open; every other panel (git, search, outline, timeline, …) starts closed. Open whatever you need and it's remembered for that session.
- **Editor invisible characters are subtler** — showing whitespace in the editor now uses a lighter, thinner mark, and the line-break symbol is a return arrow (↵) instead of the heavier pilcrow (¶), so spaces/tabs/newlines read as a quiet hint rather than competing with your code.

### Fixed
- **Saving no longer silently overwrites changes another program made to the file** — if a file you have open with unsaved edits gets changed on disk by something else, pressing ⌘S now stops and asks how to resolve it (View Diff / Save as Copy / Reload from Disk / Overwrite) instead of blindly clobbering the on-disk change. A clean file that changed on disk still just reloads, as before.
- **Saves are now recoverable** — every successful save records a Local History version of the file's text, so an accidental overwrite can be recovered.
- **The footer file stats no longer flash blank when switching tabs** — switching between two already-open files could briefly blank the Size/Lines/encoding readout for a frame; the footer now shows the file size with a "loading…" label during that instant instead of going empty.
- **Split view now opens and closes instantly** — "Open in Split" (and closing the split with the ✕) used to appear stuck: the pane wouldn't show up, or wouldn't go away, until you clicked a different tab to force a refresh. The split pane now appears and disappears immediately, no tab switch needed.
- **Rendered Markdown scroll position now survives a session switch** — switching to another session and back used to snap a Markdown file's rendered preview back to the top; your place in the rendered view is now remembered per file and restored across session switches (it already survived tab switches within a session).
- **Editor scroll position now survives session AND tab switches** — switching sessions/tabs (or away and back, including the switch-tab → switch-session → return combo) used to drop a file open in the editor back to the top; the editor now keeps its loaded view warm and restored — with your in-progress unsaved edits intact — the same way the read-only Source and Rendered views already were.

## 2026-06-19

_A large batch landed today (the integrated backlog-drain wave). Highlights below; some bigger features shipped their core + wiring with on-screen polish still being validated._

### Added
- **More commands runnable from the `>` palette** — Fold All, Unfold All, Show Repository History, and Clear Recent Files are no longer menu-only; type `>` in Quick Open and run them like any other command.
- **Review agent-written diffs in-app** — in the Claude session monitor, an agent's `Edit`/`Write`/`MultiEdit` tool call now renders as a colored unified diff (red removals, green additions, per-file +/- stats) instead of a raw `old_string:`/`new_string:` text dump.
- **Plugins can open web/office integrations** — a plugin's menu item can now open an external service URL (Docs, Wiki, Code Review, CodeSearch, a code browser) in your browser, with the current file's path/name filled into the link. Locked down to https/http only.
- **Claude hook activity in the sidebar** — the Claude section now has a collapsible "Hooks" segment listing live tool activity (Edit, Bash, Read…) captured by the optional `monitor-log.sh` hook, scoped to the current project, with failed tool calls flagged in red.
- **Make TextView your default app for a file type** — Settings now has a "File Associations" section showing whether TextView is the default handler for Markdown, Plain Text, and Source Code, with a one-click "Make Default" per type (revertable in Finder's Get Info → Open With).
- **New Session ▸ Kind** — the session-tab `+` button and File → New Session now let you start a session as a Project, Code Review, Agent Session, CI/CD, or Metrics — each pre-arranges the side panels for that kind of work (e.g. Code Review forwards Git + Problems; Agent Session forwards the Claude timeline + Git).
- **Plugins can now add clickable buttons to sidebar rows** — a plugin's sidebar row can carry an action (e.g. a "Copy as Crux URL" button) that runs the plugin's command when clicked, not just show text.
- **Automation: set the zoom level by script** — the built-in MCP automation server gained a `set_zoom` tool, so an agent/script can now set the content zoom (clamped to 50%–300%) the same way it already opens files, switches view mode, and jumps to a line.
- **Agent automation: global file search over MCP** — the headless MCP server gained a `search_files` tool so a connected agent can grep across a folder tree (matches grouped by file, with line text), the first of the Agent Services suite.
- **Code-review comments** — you can now add and view review comments on a diff (the add-comment control + comment list are reachable from the review surface).
- **Code-review export — with or without code snippets** — the review Export menu now offers two clipboard payloads: copy with the verbatim diff snippets inline (for handing the whole context to Claude), or copy a leaner version with just the comments + line anchors (when the receiver already has the source, or the code shouldn't leave the machine).
- **CSV: keyboard cell navigation + copy** — arrow keys move the focused cell (with Home/End/Page-Up/Down), and ⌘C copies the focused cell's value.
- **Image editor: paint + annotation tools** — raster paint (brush, flood fill, color-picker eyedropper) plus non-destructive vector annotations (rectangle, line, arrow, ellipse, text) over the image.
- **LSP: a Problems panel + code completion** — diagnostics are surfaced in a Problems/health view, and editor completion is now wired up.
- **LSP works "for free" from a VS Code / Cursor install** — if you don't have a language server on your `PATH`, the app now also looks inside your installed VS Code / Cursor / VSCodium / Insiders / Windsurf extensions (newest version wins), so e.g. the Java server bundled by the Red Hat Java extension is found automatically — no separate `brew install` needed.
- **Worktree management UI** — add / remove / prune git worktrees from the Git panel (was a read-only list).
- **"View as" lock** — pin a file's view mode by name so reopening it re-applies your choice.
- **Open dialog shows recents**, **window size + sidebar width are remembered across launches**, and **sessions can be turned off** (single-root mode, no session strip).
- **Terminal tabs reopen where you left off** — a terminal tab now remembers the directory you last `cd`'d into (not just where it was first opened), so after a relaunch its shell starts in that directory again.
- **More diagram formats** + **richer web viewer** (themed colors + a server-side command palette at `/cmd`).
- **"Format JSON" is easier to find** — the View → Pretty-Print menu item now names the file's type ("Pretty-Print JSON", "Pretty-Print XML", …), and the command palette surfaces both Pretty-Print and Minify when you search "format", "json", or "compact".

### Fixed
- **Invisible characters are readable in the Source view** — turning on "Show invisible characters" now draws spaces (·) and tabs (→) in a clear secondary tone instead of the washed-out OS faint grey, matching the editor's invisibles.
- **Editor current-line highlight no longer sticks after a drag-select** — while you drag to select text the current-line highlight now stays out of the way, and once you let go it follows your caret again instead of getting stuck on the line where you released the mouse.
- **Fold / Unfold All now works in the Source view** — the menu items were dead in Source mode (only the CM6 editor folded); they now collapse/expand in any foldable lens.
- **Git diff: select multiple lines** — you can now drag-select across several diff lines instead of just one.
- **Closing a split pane works** (and no longer stalls) — the close button now reliably tears the second pane down.
- **Per-file scroll & zoom is remembered** across session switches and even after closing a file (size-capped; only stored if you actually scrolled/zoomed).
- **Session tab name tracks the current folder** — it relabels when you change the root (e.g. Open Folder), unless you've manually renamed the session.
- **Image "Save a Copy" reports write failures** instead of silently losing data; other previously-swallowed save/export/decode errors now surface too.
- **Horizontal scrollbar no longer flickers while typing**, and the **hovered-row highlight is no longer offset** in the editor.
- **Browser-preview & git-diff temp files no longer pile up forever** — the scratch caches behind "Open in Browser" and the git diff/commit tabs are now pruned (old/excess files evicted), so they stop slowly accumulating on disk.
- **Your sessions and unsaved work are safer across crashes and external edits** — saved state (sessions, bookmarks, history) is now flushed to disk durably so it survives a crash or power loss; a legacy/older session index is no longer discarded as "corrupt" (your open-session list and ordering are kept); and when restoring unsaved edits after a relaunch the app now notices if the file changed on disk while it was closed, instead of silently overwriting it. Large in-progress edits (over 1 MB) are now preserved across a relaunch too, instead of being dropped.

### Security
- **Hardened HTML export / Open-in-Browser against XSS** — author HTML is escaped on the export path and a restrictive Content-Security-Policy is shipped; the in-app HTML sanitizer's event-handler and `javascript:`-scheme bypasses are closed; exported image inlining refuses path-traversal.
- **Robustness/DoS hardening** in the rust-core remote path (MessagePack recursion-depth cap, bounded orphan-event buffer), a SQLite use-after-free fix, an `ffmpeg` locator safety check, and several timer/observer memory-leak backstops.
- **Closed a `javascript:` URL-smuggling XSS in rendered markdown** — a link whose scheme hides a stripped tab/newline (`java⇥script:`) that the browser collapses back to `javascript:` is now rewritten to `about:blank` instead of passed through.

### Performance
- **Smoother typing in big files** — the bottom status bar (Lines / Chars / Size / indent / line-endings) no longer re-encodes and rescans the whole editor buffer on every keystroke; the readout now reuses its last result when the text hasn't changed and only recomputes on a real edit, so typing into large source files stays fluid.
- **No UI stall when right-clicking files in a git repo** — the "File History" menu item used to run `git` on the main thread every time the tab/sidebar context menu drew (which could be many times per open), briefly freezing the app on a slow or locked repo; the check now runs in the background and the menu enables/disables itself once it resolves.
- **Smoother drag-selection in the editor** — dragging to select text no longer re-scans the visible page for matching words on every mouse-move (it was doing that on each frame of the drag); the match highlight now runs once when you let go, so the selection sweep stays fluid in large/wide files.
- **Faster editor + highlighting plumbing** — the Rust FFI no longer double-copies every response frame, syntax tokenization stops re-bridging the whole file per highlight, and `cm_apply` is moving to keystroke-sized edits instead of shipping the whole document each tick.
- **Folder stats no longer block** other folder lookups (the git walk runs off the actor + coalesces duplicate work).
- **Smoother window & pane resizing** — the sidebar no longer rebuilds itself on every resize frame; resize ticks that can't change any panel's size are now dropped, so dragging the window edge (and internal panes) feels less janky.
- **Snappier Claude-monitor search** — typing in the monitor's session filter no longer re-lowercases every session and re-sorts the whole list on each keystroke; the sorted list + per-session search text are precomputed once per refresh, so filtering a large session list stays fluid.

## 2026-06-18

### Performance
- **Global search: smoother scrolling with high-match files** — a file with hundreds of matches no longer renders them all at once; the results cap each file's rows and show a "+N more — open" row, so scrolling the results stays responsive.
- **Command palette: faster `@`-symbol typing in large files** — the heading list is no longer re-parsed on every keystroke (computed once per file), so jumping to a heading stays responsive in big documents.

### Added
- **Folder size treemap (bundle analyzer)** — a folder's contents can now be shown as a size-proportional treemap: the bigger the file or subfolder, the bigger its tile, color-coded by file type, so "what's eating this folder" reads at a glance. Subfolders are summed recursively; build/VCS dirs and hidden files are skipped.
- **Git log: more commit actions** — right-clicking a commit now offers **Copy SHA**, **Copy Short SHA**, **Copy Subject**, and **Copy Reference** (`<short-sha> <subject>`, git-oneline style), not just "Review Commit".
- **CSV viewer: copy a whole row or column** — the cell right-click menu now has **Copy Row** (tab-separated) and **Copy Column** (one value per line) alongside Copy Cell, so you can paste a row or column straight into a spreadsheet.
- **Find in source: a "show all matches" list** — next to the match minimap, a new list button opens a popover listing every match (line number + that line's text); click a row to jump straight to it. Complements the existing tick minimap and Next/Previous.
- **Bookmarks can be scoped to the current folder** — a new "R" filter chip in the Bookmarks panel shows only the bookmarks under the folder you currently have open, alongside the existing file / folder / line (F/D/L) filters.
- **Syntax highlighting for extensionless & misnamed scripts** — a file with no extension (or a misleading one) that starts with a shebang like `#!/usr/bin/env python3` or `#!/bin/bash` now gets the right syntax highlighting (Python, shell, Node/JS, Ruby, Lua) instead of showing as plain text.

### Fixed
- **Git diffs match the editor's text size** — diff lines now use the same font size as the Editor/Source view (your content font-size + zoom), so a line in a diff reads at the same size as the same line in the editor. Previously the diff body used a fixed UI-chrome size that ignored your editor font-size preference.
- **⌘F is disabled for files too large for the editor** — when a file exceeds the editor's size limit (shown as the "too large" placeholder, which has no editor), ⌘F and the Find menu are now correctly disabled instead of opening a find bar with nothing to search. (Find still works in that file's Source/Preview views.)
- **Opening a split view no longer stalls the UI** — the second pane now loads its file off the main thread (with a brief loading indicator) instead of re-reading the whole file synchronously on every redraw, which could freeze the window when opening a split on a larger file.
- **⌘F no longer opens an invisible Find bar on rendered HTML** — in HTML files shown in rendered mode (where in-page find isn't supported yet), ⌘F and the Find menu are now correctly disabled instead of silently toggling a find bar you couldn't see. (Find still works as before in the editor, source, and rendered Markdown.)
- **Arrow-key scrolling works in the Markdown preview regardless of tab position** — switching to a rendered preview now gives it keyboard focus, so ↑/↓/Page-Up/Page-Down scroll it immediately. Previously only the last-opened tab's preview responded to arrows; other previews were "dead" to the keyboard until you clicked them.
- **The code editor consistently shows the text cursor (I-beam)** — the cursor no longer flips between an arrow and the I-beam as you move across a line; it stays the I-beam over editable text, matching every other text editor.

## 2026-06-16

### Fixed
- **Dismissing the command palette no longer loses editor focus** — after you close the ⌘K / ⇧⌘P palette (Esc, click-away, or running a command), keyboard focus returns to the active editor instead of going nowhere, so you can keep typing right away.
- **Editor line-number gutter no longer text-selectable** — the gutter no longer lets you accidentally select the line numbers, and it shows the normal arrow cursor instead of the text I-beam.

## 2026-06-15

### Added
- **Vim mode in the editor** — turn on **View ▸ Vim Mode** for modal editing in the code editor: normal/insert/visual modes, `hjkl` navigation, operators like `dw`/`ciw`, `:` ex-commands, registers, and macros. It's **opt-in and off by default**, the choice is remembered across launches, and it's included in exported settings. `:w` / `:wq` / `:x` save the file (same as ⌘S — the unsaved-dot clears); ⌘S and ⌘F still work as usual. The current mode (**NORMAL / INSERT / VISUAL**) shows in the footer status bar, and the normal-mode block cursor is blue.

## 2026-06-14

### Changed
- **The sidebar can be dragged much wider** — the old fixed ~480 px resize cap is gone; the file/tool sidebar now resizes freely up to the window width (always leaving room for the content area). Useful for deep folder trees and long file names.

### Added
- **Terminal Favorites** — keep a curated list of commands you run often and insert them into the built-in terminal with one click via **View ▸ Terminal Favorites**. Manage the list with **Edit Favorites…** (opens a simple JSON file you can hand-edit). Shell up-arrow history still works as usual; this is the cross-session shortlist.
- **Misnamed JSON/CSV files get their tools** — a JSON or CSV file saved with the wrong extension (e.g. `data.txt` holding JSON, or a CSV with no `.csv` suffix) now offers the matching tools (Minify JSON / JSON→CSV; CSV → Markdown table / Summary / JSON) based on a quick look at its content, not just the filename. Detection is conservative — plain prose is never mistaken for data.
- **More commands in the command palette** — **Wrap Long Lines**, **Show Invisibles**, and the Edit text-transforms (**Remove Empty Lines**, **Collapse Blank Lines**, **Trim Trailing Whitespace**, **Ensure Final Newline**, **Minify JSON**, **Insert Table of Contents**, **Insert Date and Time**) are now searchable + runnable from the ⌘K / ⇧⌘P palette, not just the menus.
- **Find References in the menu + command palette** — **Navigate ▸ Find References** (and the `>Find References` palette command) lists every reference to the symbol at the editor cursor in the LSP navigation panel. Previously this was only on the source-view right-click.
- **Refresh / Reload from Disk in the file tree** — right-click a folder → **Refresh** force re-reads it (and its open sub-folders) from disk, for cases the automatic watcher can miss (network/iCloud mounts). Right-click an open file → **Reload from Disk** re-reads it into its tab.
- **Right-click the footer breadcrumb** — right-clicking a segment of the status-bar path now offers the same actions as the file tree (Reveal in Sidebar / Reveal in Finder / Copy Path, plus Open Folder + Open in Terminal for folders, Open in Default App for the file).
- **Right-click a commit → Reviews** — the Git-log commit menu now has a **Reviews** submenu listing the reviews that cover that commit (click one to open it); it's loaded only when you open the submenu.
- **Footer path is a clickable breadcrumb** — the file path in the status bar is now a row of clickable segments (`~ › proj › src › file.swift`); click any folder segment to reveal/expand it in the sidebar.
- **Commit diff shows a summary header** — viewing a commit's diff now puts the commit message (author, date, description) and a totals line (files changed, +insertions/−deletions) at the top, above the per-file changes.
- **Keyboard shortcuts for view modes** — **⌘1 / ⌘2 / ⌘3** switch to the 1st / 2nd / 3rd mode button for the current file (e.g. Rendered / Source / HEX for Markdown, Table / Source / HEX for CSV). The View menu shows the current file's mode names next to the shortcuts.
- **New Tab from Clipboard** — **File ▸ New Tab from Clipboard** drops the clipboard text into a fresh scratch tab (handy for pasting a snippet, log chunk, or JSON blob to inspect). If the clipboard is JSON, the scratch opens as a `.json` file so the JSON tools apply; otherwise it's plain text.
- **Rename a session from the menu** — **Session ▸ Rename Session…** renames the active session (prompts with the current name). This joins the existing right-click-on-the-session-tab rename.
- **Sort the CSV table by a column** — click a column header in the CSV/TSV table to sort by it (click again to reverse). Numeric columns sort by value (2 < 10, not "10" < "2"), text sorts case-insensitively, and blank cells sink to the bottom.
- **Drag a file onto the Terminal to paste its path** — dropping a file (or several) on the built-in terminal types the shell-quoted path(s) at the prompt instead of opening the file in a tab. Dropping anywhere else still opens the file as before.
- **`textview://` links** — the app's URL scheme is now `textview://open?path=…` (and `textview://search?…`); the old `markdownviewer://` links keep working as an alias.

### Fixed
- **Find Next / Find Previous (⌘G / ⌥⌘G) now work** — they step through matches in whichever find bar is open (Rendered, Source, or Editor), instead of doing nothing. They grey out when no find bar is open.
- **Find & Replace (⌥⌘F) is now greyed out unless you're in the editor** — replace only works on the editable Editor view, so it no longer looks available (then silently just opens Find) in the read-only Rendered/Source views.
- **An open tab now follows an external rename** — if a file you have open is renamed (or moved within its folder) by another app, the tab updates to the new name instead of showing "file not found". (A true delete, or a move out of the folder, still reports gone.)
- **Dragging a folder within the file tree no longer "traps" you into it** — accidentally dragging a folder (or sub-folder) and dropping it back in the same window no longer re-roots the sidebar into that folder. External folders still open as the new root; use right-click ▸ Open Folder to intentionally go into a sub-folder.
- **Markdown task lists now render checkboxes** — `- [x] done` / `- [ ] todo` show a real (disabled) checkbox in the rendered view, and completed items are dimmed + struck through, instead of the `[x]`/`[ ]` marker being dropped.
- **"Open in Terminal" now uses the built-in terminal, in the right folder** — right-clicking a file or folder in the file tree → Open in Terminal opens a new tab in the app's own terminal pane, cd'd to that folder (a file opens its containing folder), instead of launching macOS Terminal.app.
- **Larger unknown-type text files no longer open stuck in HEX** — a big file with an unknown/odd extension that's actually plain text now opens in the text (Source) view instead of a hex dump, matching what the view picker offers. (Small files were already fine; this was the off-main path for files over ~4 MB.)
- **Git log: clicking the same commit no longer stacks duplicate tabs** — re-clicking a commit (or re-running a cumulative diff) now focuses the existing diff tab instead of opening another copy.
- **Preview tabs are italic-only, not bold** — an ephemeral preview tab no longer goes bold when selected; the italic already marks it as preview.
- **UTF-16 files no longer garble after editing** — saving a UTF-16-encoded text file (or rewriting one via project-wide replace) now keeps its byte-order mark, so a short UTF-16 file reopens correctly instead of being mis-read as Windows-1252/Latin-1 and showing garbled characters.

### Changed
- **Bottom attributes bar uses toggle buttons** — Wrap, Special chars, Enable JS, and the preview Info toggle are now press-to-toggle buttons (matching the Find bar) instead of small checkboxes, so their on/off state reads at a glance.

### Added
- **Line tools** — **Edit ▸ Lines** ▸ Sort Ascending / Sort Descending / Reverse / Remove Duplicates / Remove Empty Lines / Collapse Blank Lines operate on the whole current file in place (keeping its line-ending style and trailing newline). Remove Empty Lines drops blank and whitespace-only lines; Collapse Blank Lines squeezes runs of 2+ blank lines down to one. Handy for tidying lists, `.gitignore`s, word lists, pasted text, etc.
- **Promote / Demote Headings** — **Edit ▸ Promote Headings** / **Demote Headings** shift every heading in a Markdown file up or down a level at once (clamped to H1–H6) — handy for nesting a document under a new parent, merging files, or flattening. Code blocks and non-headings are left alone.
- **Open in Browser** — **View ▸ Open in Browser** opens the rendered Markdown in your default web browser (as a self-contained file with images embedded) — for a full-window read, browser print-to-PDF with proper page breaks, zoom, or quick sharing.
- **JSON → CSV** — with a `.json` file open whose top level is an array of objects, **View ▸ Copy as CSV** copies it as a CSV table (columns = the combined keys, properly quoted; nested objects/arrays become compact JSON in their cell). The inverse of the existing CSV → JSON, so you can round-trip tabular data between the two formats.
- **CSV Summary** — with a `.csv`/`.tsv` file open, **View ▸ CSV Summary** profiles it: total rows and columns, and for each column its filled/empty cell counts, whether it's numeric, and (for numeric columns) the min, max, and mean. A quick way to sanity-check a data file without loading it into a spreadsheet.
- **CSV → Markdown table / JSON** — with a `.csv`/`.tsv` file open, **View ▸ Copy as Markdown Table** copies it as a padded, aligned Markdown pipe table, and **View ▸ Copy as JSON** copies it as a JSON array of objects (one per row, keyed by the header, column order preserved). Handy for dropping tabular data into a doc or a script.
- **Lint Markdown** — **View ▸ Lint Markdown** reports common doc-quality issues in the current Markdown file: images with no alt text, headings that skip a level (e.g. H1 → H3), and duplicate heading anchors (which make `#`-links ambiguous). Each finding lists its line and rule.
- **Minify JSON** — **Edit ▸ Minify JSON** compacts the current `.json` file onto one line, stripping whitespace while keeping your key order and exact number formatting intact (it only touches valid JSON). Complements the existing Pretty-Print.
- **Check Links** — **View ▸ Check Links** scans the current Markdown file for broken **local** links and images: it resolves relative paths against the file's folder and reports any whose target is missing (external `http(s)` links and in-page `#anchors` are left alone). Handy for keeping docs' cross-references honest.
- **Copy / Export as HTML** — **View ▸ Copy as HTML** puts the rendered Markdown on the clipboard as a complete HTML document, and **View ▸ Export as HTML…** saves it to a `.html` file. The exported file is **self-contained** — local images are embedded inline, so it stays intact when you move or share it — and, unlike the in-app preview, it has no network lockdown, so it renders normally in a browser.
- **Insert Table of Contents** — **Edit ▸ Insert Table of Contents** (Markdown files) generates a linked, nested TOC from the document's own headings and drops it in, wrapped in `<!-- toc -->` markers. Run it again after editing headings and it updates the same block in place (no duplicates); it's inserted below any YAML front-matter.
- **Convert indentation** — **Edit ▸ Convert Indentation ▸ {Tabs → Spaces / Spaces → Tabs}** rewrites the leading indentation of every line to your chosen style (using the editor's indent width), leaving mid-line alignment and line endings untouched.
- **Trim trailing whitespace / ensure final newline** — **Edit ▸ Trim Trailing Whitespace** strips trailing spaces and tabs from every line, and **Edit ▸ Ensure Final Newline** adds a single newline at the end if it's missing. Both keep the file's existing line-ending style and encoding.
- **Document statistics** — **View ▸ Document Statistics** shows the current file's line, word, and character counts (with and without whitespace).
- **Convert line endings** — **Edit ▸ Convert Line Endings ▸ {LF / CRLF / CR}** rewrites the current file's line endings to Unix (LF), Windows (CRLF), or Classic-Mac (CR), keeping its text encoding and any unsaved edits. (The status bar already showed the current convention; now you can change it.)
- **Text size setting** — Settings → Appearance has a new **Text Size** slider that sets the base font size for content: the editor, the source view, **and the rendered-Markdown view** (8–32 pt). The Zoom control still multiplies on top, so Text Size sets your baseline and Zoom scales everything (content + UI) from there.
- **Trim & fade audio, save a copy** — the audio editor can now trim a clip (set the start/end at the playhead) and add fade-in/fade-out (equal-power or linear), then **Save a Copy…** of the trimmed/faded result as WAV, AIFF, CAF, or M4A/AAC (MP3 too if ffmpeg is installed). The original file is never modified.
- **Frequency spectrum in the audio editor** — the audio editor now has a spectrum toggle (the ECG-waveform button next to the time readout); turn it on to see a live frequency-spectrum panel below the waveform that tracks the playhead as the track plays or you scrub.
- **`@` jump-to-heading from the command palette** — in a Markdown file, type `@` then part of a heading (e.g. `@install`) to get a list of matching headings; arrow-pick one and press Return to jump to it. Completes the unified "Goto Anything" palette: files, `>` commands, `:` line, `#` in-file text, `@` headings.
- **`#` search-in-file from the command palette** — type `#` then some text (e.g. `#TODO`) in the palette to get a navigable list of matching lines in the current file; arrow-pick one and press Return to jump to it. (Part of the unified "Goto Anything" palette, alongside `:` line and `>` commands.)
- **`:` go-to-line in the command palette** — type a colon and a line number in the palette (e.g. `:42`) and press Return to jump straight to that line in the current file, alongside `>` for commands. (Part of unifying the palette into one "Goto Anything" box.)
- **Double-tap Shift opens the command palette** — press **⇧ Shift twice quickly** (IntelliJ "Search Everywhere" style) to pop the command palette, alongside ⇧⌘P / ⌘K. Tapping Shift while typing (e.g. for capital letters) doesn't trigger it — only two clean Shift presses with nothing in between.
- **Insert Snippet** — **Edit ▸ Insert Snippet** drops a ready-made fragment at the cursor (when editing): a Markdown table, code fence, link, collapsible `<details>` section, or TODO comment. **Add your own** by editing `~/Library/Application Support/MarkdownViewer/snippets.json` (a list of `{id, name, body}`; they show up in the menu, and an `id` matching a built-in overrides it). (Jump-between-placeholders + an in-app editor are coming.)
- **Git-blame age heatmap** — with the blame gutter on, each line's gutter cell is now tinted on a dark→light blue scale by how recently it was last changed (oldest = dark, newest = light, scaled to the file's own history) — so recent edits stand out at a glance.
- **Convert Encoding** — **Edit ▸ Convert Encoding** re-saves the current file in a chosen text encoding (**UTF-8, UTF-16, Windows-1252, or Western/Latin-1**), including any unsaved edits. If the text can't be represented in the target encoding (e.g. an emoji → Latin-1), the conversion is refused and the file is left untouched.
- **Richer PDF & media file-info** — opening a PDF now shows its **Subject, Keywords, Creator, Created/Modified dates, page size, and encrypted status** (alongside the existing pages/title/author); audio & video files now show their **codec** (H.264, HEVC, AAC, …) next to dimensions/sample-rate.
- **Align Markdown Tables** — a new **Edit ▸ Align Markdown Tables** command tidies the GFM pipe tables in the file you're editing: columns are padded to line up, and `:--` / `:-:` / `--:` alignment markers are respected (code fences and escaped `\|` are left alone). Markdown's own modes (Rendered / Source) are unchanged.
- **⇧⌥F formats the document** — the VS Code "Format Document" shortcut now works (runs the language server's formatter on the current file), alongside the existing Edit-menu item.
- **Project-wide replace** — the search panel (⌘⇧F) is no longer read-only: click the replace toggle, type a replacement, and **Replace All** rewrites every match across all the listed files at once (literal or regex with `$1` groups). Each file is rewritten safely — its text encoding is preserved, the write is atomic, and symlinks aren't clobbered.
- **Hot exit (restore unsaved edits)** — quit with unsaved changes in a tab and they come back on relaunch: the tab reopens with your in-flight edits intact and marked unsaved, instead of reloading the last-saved version from disk (like VS Code).
- **New File offers a type** — the **New File** menu (File menu and right-click a folder in the sidebar) is now a submenu — create a blank **Text**, **Markdown**, **CSV**, or **JSON** file, so it opens with the right syntax highlighting. (Plain Text File keeps ⌘N.)
- **Open in Default App** — right-click a file in the sidebar or a tab → **Open in Default App** to hand it to its system default app (a `.png` to Preview, a `.csv` to Numbers, …), alongside the existing Reveal in Finder.
- **Language Mode menu** — **View → Language Mode** shows the current file's syntax language (checkmarked) and lets you switch it for the active tab — handy when a file's extension doesn't match its contents (e.g. force a `.txt` of JSON to highlight as JSON). Picking the file's natural language clears the override.
- **⇧⌘P opens the command palette** — the VS Code shortcut now works (alongside the existing ⌘K), so it's there in your muscle memory. (Plain ⌘P stays the standard macOS Print shortcut.)
- **Command-palette button in the toolbar** — a ⌘ button at the far top-right of the content toolbar opens the command palette, so you can search-and-run any command with the mouse instead of having to remember the shortcut.
- **Tab operations in the Session menu** — the Session menu now has a **Tab Operations** section (New Tab, Close Tab, Next / Previous Tab, Move Tab Left / Right), so the open-file tab commands are discoverable from the menu bar, not just via keyboard shortcuts.

### Performance
- **Opening larger files stays responsive** — files bigger than ~4 MB are now read off the main thread (previously only files above 64 MB were), so opening a multi-MB file — or one that iCloud hasn't downloaded yet — no longer briefly freezes the window while it loads.
- **Faster project-wide search** — searching across files now reads and matches files **in parallel** across CPU cores instead of one at a time (a 3,000-file benchmark dropped from ~590 ms to ~125 ms), so big multi-file searches return noticeably sooner. Results are identical — same matches, same order.
- **Faster syntax highlighting after launch** — the app now warms its language grammars in parallel across all CPU cores (instead of one at a time on a single thread), and warms Markdown first, so your first opened file gets highlighted noticeably sooner — especially right after starting the app.
- **Snappier highlighting on large files** — the syntax-highlight data now crosses to the UI in a leaner format (~4× smaller, decodes ~5× faster), so opening or scrolling a big source file or a long Markdown doc with many code blocks renders its colors quicker.
- **Faster large-CSV open** — the CSV parser now loads cells straight into its compact in-memory store instead of building a throwaway intermediate copy first, so opening a big spreadsheet does roughly half the memory work (no per-cell allocation churn, one fewer full copy of the data).

## 2026-06-13

### Fixed
- Opening a file with very long lines (a Jupyter notebook with embedded image data, a minified bundle, a one-line JSON dump) no longer freezes the app — such files now soft-wrap automatically so the text view stays responsive instead of hanging.
- Terminal no longer becomes unresponsive when pasting a large blob (e.g. big JSON into vim) — heavy output bursts stay smooth.
- Split view now shows your **unsaved edits** live, instead of the last-saved text from disk.
- Mouse-over line highlighting is no longer laggy on large (5000-line) log files while Find is active.
- Crash fixed when switching sessions after a save prompt on an unsaved file.
- Editor now keeps focus on **Enter** and handles arrow / word / line navigation keys (was jumping focus to the sidebar).

### Added
- **More clipboard tools** — **URL Encode / Decode**, **HTML Encode / Decode**, and **Trim Trailing Whitespace** in the Command Palette (⌘K), rounding out the clipboard transform suite.
- **Clipboard text transforms** — six new Command-Palette (⌘K) tools that rewrite the clipboard: **Sort Lines (A→Z / Z→A)**, **Remove Duplicate Lines**, **Reverse Lines**, **UPPERCASE**, and **lowercase** — alongside the existing UUID / Base64 / SHA-256 clipboard tools.
- **Photo EXIF in file-info** — opening an image now shows its **date taken**, **camera** (make/model), **lens**, **focal length**, **ISO**, **exposure**, **aperture**, **software**, and **GPS coordinates** when present (expanded from the previous small EXIF subset).
- **Deeper file-info metadata** — the file-info panel now shows the file's **permissions** (e.g. `644 rw-r--r--`), **owner** / **group**, **inode**, and **hard-link count** (when a file has more than one), alongside the existing size / dates / type.
- **Open Terminal Here** — a new **Open Terminal Here** command (Command Palette, ⌘K) opens a terminal already `cd`'d to the focused file's folder, instead of starting in your home directory.
- **Rename terminal tabs** — right-click a terminal tab → **Rename…** to give it a name (e.g. `build`, `logs`, `server`); the name shows on the tab. Leave it blank to reset to `Terminal N`. (Per session — names reset when the tab closes.)
- **Live memory in the status bar** — the status bar now shows the app's current memory footprint (`Mem`), with a tooltip that adds the current tab's loaded-content size; the full WebKit-helper breakdown stays in the Memory tool window. (Cheap to sample — it never scans every process on the system.)
- **Pretty-Print minified JavaScript & CSS** — open a minified or one-line `.js` / `.mjs` / `.cjs` / `.css` file and **Pretty-Print** (View menu / format toggle) now re-indents it into readable, block-structured code. Joins the existing JSON and XML formatting; strings, template literals, regexes, comments and `url(…)` values are left exactly as written.
- **Format / Rename / Code Actions in the Edit menu** — the language-server **Format Document**, **Rename Symbol…**, and **Code Actions…** commands now have Edit-menu items (previously palette/keybinding-only), completing the LSP commands in the menu bar.
- **Navigate menu** — Go to Definition / Declaration / Type Definition / Implementation are now in a top-level **Navigate** menu (previously reachable only via the command palette or a custom keybinding).
- **Export / Import Settings** — back up your preferences (theme, font, zoom, wrap, per-type view defaults, …) to a JSON file and restore them on another machine, from the **TextView ▸ Export/Import Settings…** menu.
- **Audio tags in file info** — music files now show their **Title / Artist / Album / Year** in the file-info panel, alongside the existing duration / sample-rate / channels.
- **Archive file info** — opening a `.zip` / `.jar` / `.tar` now shows a summary in the file-info panel: format, file & folder counts, and total uncompressed size.
- **Database file info** — opening a SQLite database now shows a summary in the file-info panel: table / view / index counts, total rows, text encoding, and page size.
- **`textview` command-line launcher** — Help → Install '`textview`' Command installs a `textview` shell command so you can open files from a terminal (`textview file.md`), like VS Code's `code`.
- **Search by file name + regex** — the search panel (⌘⇧F) now has a **Text · File name** toggle and a regex (`.*`) toggle, so you can find files by name, or match file contents/names with a regular expression (bad patterns are flagged inline).
- **Keyboard Shortcuts reference** — Help → Keyboard Shortcuts opens a searchable, grouped list of every shortcut in the app (and reflects any custom keybindings you've set).
- **Set a default view per file type** — pin "always open Markdown as Source" (instead of Rendered), "CSV as Source" (instead of Table), and so on, from the file-type menu (bottom-right). Stops you re-clicking "Editor" on every open.
- **Per-file scroll memory when previewing** — return to a file and it's right where you left off, in both the source view and rendered markdown.
- **Markdown outline** in the sidebar — heading-tree navigation for `.md` files (jump to any section).
- **Print** and **Export as PDF** for rendered markdown / HTML.
- **Multi-cursor editing** — ⌘D select-next, ⌥-click to add a caret, ⌘⇧L split-selection.
- **Rename** and **code actions** via the language server.
- **File-info checksums** (CRC-32 / MD5 / SHA-1/256/512) with a copy button on media files.
- Settings now list the **supported language-server and syntax-highlighting languages**, with install status.
- Recents tool-window shows each file's **containing folder in grey** so same-named files are distinguishable.

### Performance
- Faster first scroll of very large log/source files — the line-number gutter now finds line breaks in one pass instead of a per-character bridged lookup (no more millions of message-sends on a multi-MB file).
- First open of a source file no longer hitches — the one-time syntax-highlight grammar compile (~400 ms) now happens off the main thread / warmed at launch.
- Faster tab switching — open panes are kept mounted, so switching back no longer reloads the page.
