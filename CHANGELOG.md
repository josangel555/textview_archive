# Changelog

User-facing changes to the app — **features, fixes, and additions you can see or
feel** while using it. Deliberately **excludes** tests, validation, CI, refactors,
and internal/infra work (those live in `docs/AUTONOMOUS_PROGRESS.md` + the git log).
This file is the at-a-glance "what's new" view of the app's progress.

Newest first. Each entry is one plain-language line — what changed, from your seat.

## 2026-06-14

### Changed
- **The sidebar can be dragged much wider** — the old fixed ~480 px resize cap is gone; the file/tool sidebar now resizes freely up to the window width (always leaving room for the content area). Useful for deep folder trees and long file names.

### Added
- **Footer path is a clickable breadcrumb** — the file path in the status bar is now a row of clickable segments (`~ › proj › src › file.swift`); click any folder segment to reveal/expand it in the sidebar.
- **Commit diff shows a summary header** — viewing a commit's diff now puts the commit message (author, date, description) and a totals line (files changed, +insertions/−deletions) at the top, above the per-file changes.
- **Keyboard shortcuts for view modes** — **⌘1 / ⌘2 / ⌘3** switch to the 1st / 2nd / 3rd mode button for the current file (e.g. Rendered / Source / HEX for Markdown, Table / Source / HEX for CSV). The View menu shows the current file's mode names next to the shortcuts.
- **New Tab from Clipboard** — **File ▸ New Tab from Clipboard** drops the clipboard text into a fresh scratch tab (handy for pasting a snippet, log chunk, or JSON blob to inspect). If the clipboard is JSON, the scratch opens as a `.json` file so the JSON tools apply; otherwise it's plain text.
- **Rename a session from the menu** — **Session ▸ Rename Session…** renames the active session (prompts with the current name). This joins the existing right-click-on-the-session-tab rename.
- **Sort the CSV table by a column** — click a column header in the CSV/TSV table to sort by it (click again to reverse). Numeric columns sort by value (2 < 10, not "10" < "2"), text sorts case-insensitively, and blank cells sink to the bottom.
- **Drag a file onto the Terminal to paste its path** — dropping a file (or several) on the built-in terminal types the shell-quoted path(s) at the prompt instead of opening the file in a tab. Dropping anywhere else still opens the file as before.
- **`textview://` links** — the app's URL scheme is now `textview://open?path=…` (and `textview://search?…`); the old `markdownviewer://` links keep working as an alias.

### Fixed
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
