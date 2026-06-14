# Changelog

User-facing changes to the app — **features, fixes, and additions you can see or
feel** while using it. Deliberately **excludes** tests, validation, CI, refactors,
and internal/infra work (those live in `docs/AUTONOMOUS_PROGRESS.md` + the git log).
This file is the at-a-glance "what's new" view of the app's progress.

Newest first. Each entry is one plain-language line — what changed, from your seat.

## 2026-06-14

### Changed
- **Bottom attributes bar uses toggle buttons** — Wrap, Special chars, Enable JS, and the preview Info toggle are now press-to-toggle buttons (matching the Find bar) instead of small checkboxes, so their on/off state reads at a glance.

### Added
- **Open in Default App** — right-click a file in the sidebar or a tab → **Open in Default App** to hand it to its system default app (a `.png` to Preview, a `.csv` to Numbers, …), alongside the existing Reveal in Finder.
- **Language Mode menu** — **View → Language Mode** shows the current file's syntax language (checkmarked) and lets you switch it for the active tab — handy when a file's extension doesn't match its contents (e.g. force a `.txt` of JSON to highlight as JSON). Picking the file's natural language clears the override.
- **⇧⌘P opens the command palette** — the VS Code shortcut now works (alongside the existing ⌘K), so it's there in your muscle memory. (Plain ⌘P stays the standard macOS Print shortcut.)
- **Command-palette button in the toolbar** — a ⌘ button at the far top-right of the content toolbar opens the command palette, so you can search-and-run any command with the mouse instead of having to remember the shortcut.
- **Tab operations in the Session menu** — the Session menu now has a **Tab Operations** section (New Tab, Close Tab, Next / Previous Tab, Move Tab Left / Right), so the open-file tab commands are discoverable from the menu bar, not just via keyboard shortcuts.

### Performance
- **Faster syntax highlighting after launch** — the app now warms its language grammars in parallel across all CPU cores (instead of one at a time on a single thread), and warms Markdown first, so your first opened file gets highlighted noticeably sooner — especially right after starting the app.
- **Snappier highlighting on large files** — the syntax-highlight data now crosses to the UI in a leaner format (~4× smaller, decodes ~5× faster), so opening or scrolling a big source file or a long Markdown doc with many code blocks renders its colors quicker.

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
