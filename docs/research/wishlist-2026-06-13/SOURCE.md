# Owner wishlist — intake source (2026-06-13)

Verbatim capture of the owner's wishlist for triage into `tasked` board intake tickets.
Owner priority tiers P0 (highest) → P8. Each section below is a workflow SEGMENT.

---

## SEGMENT: must-need-p0-p1

### P0
- Text view (plain text viewing)
- Text Edit (plain text editing)
- Source view + Syntax highlighting for: JS, TS, JSX, Java, JSON, XML, HTML, CSS, MD, Rust, C, C++, py, YAML, TOML, .ini, SQL, mjs, cjs, CSV, SH

### P1
- Git stuff (diff, log, status, blame)
- Code review

---

## SEGMENT: must-need-p2-p5

### P2
- PDF reader

### P5
- Browser [prohibit local access, block 3rd-party cookies]
- Sheet features: calculation etc.; Excel reading? eval?
- Image: editing; text rendering; selection resize [Raster, Vector, Text]
- Rich Text Markdown editor → [.rtf, .rtfd, .docx, .doc]
- Print, Print as PDF
- View RTF, DOCX, PDF, XLSX
- Unify various search types [Global search, Recents, Command search]
- Help page with all Shortcuts

---

## SEGMENT: must-need-p6-p7

### P6
- VIM support
- Export/Import settings; user-friendly settings location ~/.textview
- Proper name for the app
- AutoSave, Versions, LocalHistory, Timeline
- Spell check, Grammar, LSP checks
- Signing
- Deep agent integrations [ClaudeCode, Codex, Antigravity]
- User themable [Existing theme support?] — VSCode themes? Sublime themes?
- Tmux -CC attach integration similar to iTerm
- Walkthrough as a presentation [Like slides, Docs, Source code, Terminal]
- Repo sourceview [trace repo paths crate → github]; download and explore source of dependencies

### P7
- Own agent harness
- Integrate with PinBoard
- See tasks, solve tasks, see worktrees, review code, walkthrough
- Fully Hackable, Fully Automatable
- Agent Services [Semantic/LSP code search, Global search, Refactor (rename/move), Test runner, Code review]
- TextView command invocable from cmd, like `code`?
- Script command window [run JQ-type stuff], similar to JS Console but operating on tab contents
  - e.g. Filter, transform and create a CSV from a Log and save to file
  - Think log query [Filter, Unzip, regex, topN, sort]; an expression language?
- Pattern identification in a log file? "I find these patterns"
- Built-in credential recognition, obfuscation, secure handling
- Agent Services [what helps an agent work on a project? agent doing grep is not fun]
- Expand on Sessions [SDLC → Requirements, Implementation, Bugs, Fixes, Code Review, Monitoring, CI/CD]
- Inter-person collaboration, Agent collaboration
- Mac's own intelligence for editing/typing/completion?
- Action history [anything you do is reversible] with a history view

---

## SEGMENT: feature-parity-p8

Ref: docs/research/feature-parity-2026-06-11/README.md. "Without risking being another VS Code."

- Markdown side by side
- RichText Editor [Docs style] — hyper-restricted subset of Markdown
- Autocomplete using LSP? Word grammar? Mac native feature?
- Multi-cursor
- Snippets
- Unify Cmd+K, Cmd+G
- Command palette — double-shift shortcut
- Goto / Definition / Usage
- Preview definition [IntelliJ's shortcut]
- Hover symbol info on variables/symbols
- Rename / signature change
- Tab split [left/right]
- Editor git gutter / blame
- 3-way merge
- CSV Table editor
- What other than but similar to Mermaid/Dot can we support?
- Better UX for Worktree management
- Profiling, Memory diffs, Flame charts, composition charts (webpack-analyzer style)
- Remote dev
- Print, PDF Export
- AutoSave, History
- Fully scriptable, fully hackable
- Allow other Git integrations [GitHub, GitLab, proprietary/company-internal] incl. code review
- Cmd+P like VS Code, Cmd+Shift+P
- Hot exit
- VIM support
- Notebooks [not just python — kotlin], with LSP, storage
- Sticky scroll
- Run tests? Run commands? like NPM?
- HTTP Client?
- Local History
- Structural search
- Recent Locations popup
- Inspections / intentions, run configurations, indexing-powered navigation, dataflow analysis

### Parity gap table (with cost signals)
1. Multi-cursor (⌘D select-next) — near-free; CM6 just lacks allowMultipleSelections
2. Autocomplete (none at all) — M; pairs with the TSK-463 LSP-completion thread
3. Print / export-rendered-PDF — near-free (WKWebView.printOperation); most-expected missing baseline
4. Unified Goto Anything (one box, @/: operators) — M; today 4 separate surfaces
5. Project-wide replace (search is read-only) — M
6. LSP rename + code actions — S; LSPTextEditApplier exists, requests just aren't issued
7. Prose spellcheck in markdown editing — S
8. Local history — LocalHistoryStore.swift exists unwired — S
9. Markdown outline panel — parser built+tested, no UI consumes it — S
10. Editor git gutter + inline blame — bridge message already exists — S

---

## SEGMENT: bugs

- Editing a plain text file, pressing Enter changes focus to prev tab (Enter going to file nav?)
- Editing plain text, unsaved changes, switching View Only does not show unsaved contents
- Font mismatch between View/Edit (also mismatch in Shoulder); must be seamless. "View as" should come from other UX like a lock icon beside filenames?
- Editor should support standard key navigation [Arrow, Cmd+Arrow, Opt+Arrow, PageUp/Down, Home/End]
- "-- emoji" causing an extra char when Claude Code prints a table; same issue in terminal
- Crashed when switching sessions [2026-06-11 09:12PM]: asked to save unsaved file, then crashed on switch back. Crash log: ~/Downloads/crash-20260611-211
- Don't we have autosave? Why prompt to save when switching sessions?
- Weird rendering issues in Terminal (e.g. VIM): footer rendered twice; an error pushed it up but never cleared
- Mouse-over line highlight very laggy — Find enabled, Found 1/2956, View Only on a 5000-line log file
- File status footer missing after relaunching / opening a new project
- Last page(s) of a log file not showing line number in shoulder
- Need a way to dismiss Find; Cmd+F again should dismiss it
- Pasted a large JSON in VIM inside Terminal → app Not Responding
- In terminal, typing then moving cursor and deleting chars: deleted chars not removed from view (chars appear deleted from end line); display not matching true state
- If I disable 'View Only' and change files in side nav (temp files - italics) content won't change; only View Only mode changes files
- When previewing files, scroll state of one file carried over to next
- Preserve scroll state per file when previewing files

---

## SEGMENT: minor-features

- Open dialog show recent
- New tab show recent
- New tab show other [Sheet, Image]
- File info pane: Checksum [SHA-256/SHA-128/SHA-512/MD5/CRC]; checksum copy button more responsive/feedback; metadata for all file formats
- Image edit: Undo 1000+ (forgets when tab closed); Crop; Add text/shapes; Tool window; Tools [Draw, Lines, Shapes] Raster?/Vector?
- File nav: keep all tree roots in view; right-click folder → New → [New file]
- Where to store temp files [md render html, git diff]? If on disk, move to in-memory FS?
- Organize the menu items properly
- Dedicated menu item for the type of file being viewed
- Plugin menu item → plugins can add submenus
- How to make this absolutely hackable
- Session menu item should have a section for Tab operations
- Button on top-right for opening the command menu
- Tab: right-click → split right; New Tab shows [Recents, New PlainText/Image/RichText/Source, recent folders (git repo indicator), open own file browser]; drag to reorder tabs; New Tab needs a [New text file] button
- Catalog each keyboard shortcut, compare with Mac apps [TextView, Sublime, VS Code, IntelliJ, Emacs]
- Search tool window: filter buttons in header [Text|FileName]; regex search beside Aa [aa|Aa|.*]
- UI: show Wrap/Special-char toggles on the details pane below tabs beside filename, near Editor|Hex View-Only, separated by dividers; make Wrap/Special Chars toggle buttons not checkboxes (same for View Only); Terminal header pane "Terminal - Name" (pwd, pid)
- Recents tool window → show folder in grey brackets
- Git: merge-style merge on conflict between local changes and disk/remote, non-blocking; use a vim .swp-like approach to persist the diff
- Editor: on disk update, highlight new changes blue and fade; on local/disk conflict allow undo (future merge); git diff text style match Edit/View
- Find/Replace: Cmd+F twice hides find, Cmd+F again opens keeping prev text; need Replace, ReplaceAll
- Terminal: open in pwd; right-click tab → Rename; show terminal name; command history; fav/named commands + history search; support colors; left tab shoulder border; right-click → copy trimmed (avoid leading spaces from Claude Code output)

---

## SEGMENT: plugins-darkmode-music

- Plugins for adding things similar to SQLite browser
  - AWS Plugin [Dynamo, S3, CloudWatch]
  - Plugins expose MCP
  - Plugin Development Kit, Plugin Development Skill for AI
- Dark Mode
- Music (unspecified)

---

## SEGMENT: questions-and-research

Owner wants answers; where ambiguous or a decision is needed, file + park "Need me".

- Need a high-level solid Rust migration plan
- teeth-demonstrated tests — is this in the SOP? If not, add
- Rust fuzzing/property/Miri lanes designed but blocked on dep approvals — explain; do we have tickets needing me?
- How to test MCP/Walkthrough? How are they persisted/serialized? Owner wants to save them
- How to write plugins? Creative plugin ideas?
- Which parts of the app can be decomposed into plugins vs must be in core? [Image editing, …]
- How to expand plugins for full customizability [office integrations: Docs/Wiki/CRUX/CR/CodeBrowser/CodeSearch]
- LSP: own or external? Which approach is robust/fast?
- What to cut from the board?
- How to run WebUI/TUI
- How to lock transitive dependencies of a package and fail build + ask owner approval
- Disable all optional transitive dependencies
- Improve build speed? Iteration speed? UI testing speed?
- Test suite audit
- Do we use Swift Testing or XCTest? Can we migrate? Or XC only for UI tests?
- Are we using modern language/test features? Investigate
- Show supported syntax-highlighting languages in settings [View and Edit]
- Show supported LSP languages and LSP status in settings
- Was CM6 a mistake? Why is it so slow?
- Test coverage check during build/test — what is coverage now, how to enforce in build?
- Look at Swift and Rust recent additions
- Are we using generous multi-threading/multi-processor/async (as needed) patterns? inlining/specializing/generics?
- State of inefficiency — explore where we do throwaway work; can we lazy-load / be more strategic?
- What VS Code toolchains do we get from extensions (Swift/Java/TS)?
- Can we use WASM to reduce WebUI duplication?

### Understand (owner wants explainers)
- How to do code reviews?
- How to monitor Claude Code?
- How does scripting work?
- How does MCP work?
- How do [Claude timeline, Agent view, Transcript search] work?
- Do we have a CLI to interact with the app itself?
- How to interact with LSP — what can I see/do?
- How to separate core yet still use Swift/macOS features for value-added features? [Remote not supported]
