# Changelog

User-facing changes to the app — **features, fixes, and additions you can see or
feel** while using it. Deliberately **excludes** tests, validation, CI, refactors,
and internal/infra work (those live in `docs/AUTONOMOUS_PROGRESS.md` + the git log).
This file is the at-a-glance "what's new" view of the app's progress.

Newest first. Each entry is one plain-language line — what changed, from your seat.

## 2026-06-21

### Added
- **File ▸ Local History** — browse the save-time version snapshots of the current file (timestamp + size) and view any past version read-only.
- **View ▸ Toggle Read-Only** — lock the editor against accidental edits for the session (checkable menu item).
- **File ▸ Export as Word / RTF / RTFD** — export the current Markdown document to a `.docx` Word file, an `.rtf` file, or an `.rtfd` package (headings, lists, bold/italic/strike).
- **Copy as RTF** — copy the current Markdown document to the clipboard as rich text, so it pastes formatted into Mail, Pages, etc.
- **CSV — rectangular select, copy & paste** — shift+arrow extends a cell rectangle in the table view; ⌘C copies it (tab/newline-delimited, paste-ready into a spreadsheet) and ⌘V pastes a TSV grid into cells while editing.
- **More spreadsheet formula functions** — CSV `=formula` cells now support text (LEFT/RIGHT/MID, PROPER, EXACT, REPT, SUBSTITUTE), math (ROUNDUP/ROUNDDOWN, CEILING/FLOOR, TRUNC, SIGN, EXP, LN, LOG10), MEDIAN, conditional aggregates (COUNTIF/SUMIF/AVERAGEIF with `>`/`<`/`>=`/`<=`/`<>` criteria), type checks (ISBLANK/ISNUMBER/ISTEXT/ISNONTEXT/ISLOGICAL/ISERROR), lookup (VLOOKUP/HLOOKUP/INDEX/MATCH), conditionals (IFS/SWITCH), and error handling (IFERROR/ISNA/ISERR).
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
- **Editor scroll position now survives a session switch** — switching to another session and back used to drop a file open in the editor back to the top; the editor's scroll position is now remembered per file and restored, the same way the read-only Source and Rendered views already were.

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
