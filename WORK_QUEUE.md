# Work Queue — active first, completed at the end (reorganized 2026-06-16)

Owner ask: scan the `tasked` board, pick the next ~50 to work on — **features + bug fixes**,
ignore the validation tail. Tracked HERE (check the box when done); the board lifecycle is separate.

**Ordering = execution order.** Top = do-first (small, host-buildable, user-facing → host-test the model,
ship to `review`). Lower = bigger / heavier. `[VM]` = render/interaction validation is the VM tail (build +
host-test the model anyway). `[slice]` = umbrella with concrete gaps. `[~]` = partial/parked (remaining work).

Mark `[x]` when shipped (commit + board → at least `review`). **Active items are up top; the Completed
record is at the bottom of this file** (2026-06-16 reorg).

---

# ===== ACTIVE (remaining work) =====

## ★ Intake 2026-06-14 — remaining

**P0 — user-felt latency (fix first; most need a VM/Instruments trace):**
- [ ] **TSK-892** — File-nav hover is slow (constant friction; find per-hover compute) `[trace]`
- [ ] **TSK-887** — Command palette typing laggy `[trace]`
- [ ] **TSK-888** — Global search typing + result-scroll laggy `[trace]`
- [ ] **TSK-890 / 891 / 895** — CM6 editor feel: drag-select slow / Page-Up janky / h-scrollbar flicker on type (MD≫Swift; ties TSK-791) `[trace]`
- [ ] **TSK-889** — ~699KB JSON open laggy (warm path; distinct from TSK-842 cold/iCloud) `[trace]`
- [ ] **TSK-908** — Right-click commit very slow (menu build) `[trace]`

**P1 — broken user-facing behavior (host-fixable bugs; ship model + leave render at review):**
- [ ] **TSK-910** — Git diff: only one line selectable → multi-line selection `(537)` `[DESIGN-ON-BOARD: SwiftUI per-Text .textSelection can't span; needs per-hunk AttributedString vs per-line review affordances → render slice, not a quick fix]`
- [ ] **TSK-905** — Preview ↑/↓ broken unless tab is last (first-responder by tab position) `[DESIGN-ON-BOARD: WKWebView first-responder-by-tab-position; VM-deep AppKit focus chain, thin host teeth — pair with TSK-818 key-synth lane]`
- [x] **TSK-906** — Palette dismiss loses editor focus `[bc93d6f → review; editorFocusRequest nonce → makeFirstResponder + dispatch(.focus), 1 teeth; live focus = VM]`
- [ ] **TSK-893 / 894 / 896** — Editor: cursor pointer↔I-beam flip / current-line highlight stuck after drag / hovered-row offset
- [x] **TSK-917** — Gutter selectable + cursor-icon confusion `[b675551 → review; .cm-gutters user-select:none + cursor:default, 1 teeth; appearance = VM]`
- [ ] **TSK-921 / 922** — Split: can't close pane / open-split slow+doesn't appear `(714)`
- [ ] **TSK-912** — Code-review comments: how to add + where listed (discoverability/missing UI) `(537)`

**P2 — quick-win features / UX (host-buildable, [VM] render at review):**
- [~] **TSK-901** — Auto-detect content type — "language" half (misnamed code → highlighting) remaining `[ContentTypeSniffer shipped; language deferred]`
- [ ] **TSK-898** — Render|Editor|HEX as a segmented button GROUP (pure visual restyle — VM)
- [⊘] **TSK-936 / 937 / 938** — Toggle-View-only · Focus Terminal/Nav/Git/File · Esc→current tab `[PARKED→owner (TSK-936 waiting:human): shortcut keys + "view-only" semantics overlap ⇧⌘R/⌘1-3 — a UX/muscle-memory call; editor⇄view-only impl ready on key-choice]`
- [ ] **TSK-924** — CSV: multi-cell select + copy/paste `(711)` (view-coupled selection — VM)

**P3 — bigger / design-first / epics:**
- [ ] **TSK-947** — ⌘F dead in HTML-rendered + over editor size-cap (B5)
- [ ] **TSK-948** — Source code folding dead-wired (B10)
- [~] **TSK-951** — palette-parity umbrella (B1+B2) — tail: foldAll/unfoldAll model method, undo/redo first-responder, param converters `[slice shipped c36f1b9]`
- [ ] **TSK-897** — Editor missing many languages' highlighting (reopen TSK-362) `[triage]`
- [ ] **TSK-940..945** — Agent integration: review/approve agent diffs · line-ref-to-agent · LSP/diag sharing · browser MCP · security audits `(687, epic→slices)`

## 0. Perf — user-felt latency (HIGH priority; measured 2026-06-14) — remaining

- [~] **TSK-845** — Micro-bundle: `ContentFingerprint` utf8.count ×3, MsgPackReader always-builds-tree, lazy-tab materialize `[PROFILE-GATED — needs `text` provenance profile before a behaviorally-invisible commit]`
- [ ] **TSK-839** — Attribute + fix the 30–366 ms per-nav main-thread CoreAnimation commit stall (the REAL felt 'nav slow' root) `[Time-Profiler attribution first]`
- [ ] **TSK-838** — Rendered-MD WebView: persistent page + DOM-patch instead of full `loadHTMLString` reload (2–9 s reload storm; quantifies TSK-624) `[architectural — spike + slices]`

- [ ] **TSK-564** — Swift FFI boundary does a DOUBLE copy of every response frame (rust-core perf)
- [ ] **TSK-543** — cm_apply ships the FULL doc across FFI both directions per edit batch (~10× traffic/tick)
- [ ] **TSK-826** — FFI receive-side whole-frame copy: decode directly from MdvBuf (extends 564)
- [ ] **TSK-827** — TreeSitterEngine.tokenize bridges whole file to NSString + per-predicate substring (perf)

## A. Quick wins — small features, host-buildable — remaining

- [ ] **TSK-708** — Preview definition (IntelliJ Quick Definition / Cmd+Y) `[VM]`
- [ ] **TSK-704** — Markdown side-by-side editor + live preview `[VM]`
- [ ] **TSK-766** — Editor: git-diff text style match Edit/View `[VM]`
- [~] **TSK-751** — Organize the menu items properly `[PARKED→owner: "properly" undefined; asked which menus feel wrong]`
- [~] **TSK-746** — Open dialog: show recents `[LOW-VALUE: NSOpenPanel can't cleanly host custom recents; Open Recent exists]`
- [~] **TSK-709** — Unify Cmd+K and Cmd+G (palette/goto) `[PARKED→owner: "unify" ambiguous; ⌘G is standard Find-Next]`

- [ ] **TSK-574** — rust-core: pub API surface with zero consumers; WireError rich-error channel never sent
- [ ] **TSK-820** — rust-core: deprecate/remove the dead per-method C symbols (post-envelope cleanup)
- [ ] **TSK-307** — Button: show bookmarks from just the root folder in a new view
- [ ] **TSK-374** — Find match list view
- [ ] **TSK-811** — "View as" affordance redesign — per-filename lock icon (split from TSK-732)
- [ ] **TSK-836** — build/test: capture per-class swift-test timings, split the slowest classes
- [ ] **TSK-849** — build/test: trim fixed sleeps + shard the subprocess-tail classes (~22s run floor)
- [ ] **TSK-850** — build/test: share immutable git/temp fixtures across a class (vs per-method)

## B. [PARTIAL] slice continuations — remaining

- [~] **TSK-769** — Terminal UX bundle: remaining (command history-search, colors, tab shoulder border). Done: open-in-pwd, tab-rename, copy-trimmed, favorites `[278a0fa]`
- [⊘] **TSK-343** — History, Revert `[OWNER-GATED — board state waiting:human; needs your repro/decision → loop skips]`
- [~] **TSK-358** — "window sizing" half remaining (font-size slice shipped 6a045e0/2ad2518)
- [~] **TSK-382** — Squeeze DocumentModel memory `[triaged — needs VM memory-profile; no host-visible structural leak]`

- [ ] **TSK-302** — CSV/table: cell navigation (arrow keys) + Cmd+C copies the whole cell `[VM]`
- [ ] **TSK-303** — Find support in the table view `[VM]`
- [ ] **TSK-305** — Markdown minimap / overview window (top-right)
- [ ] **TSK-368** — Terminal tool window with tabs
- [ ] **TSK-373** — New → Code review / Agent session / Project view

## C. Medium features — remaining

- [ ] **TSK-463** — Wire LSP completion to the editor (request implemented, never invoked) `[VM]`
- [⊘] **TSK-470** — Zoom split: UI-chrome zoom vs document zoom `[OWNER-GATED — board state waiting:human → loop skips]`
- [ ] **TSK-495** — Unified tool-window placement: any tool window → any shoulder, drag-and-drop `[VM]`
- [ ] **TSK-506** — Folder-stats treemap (bundle-analyzer) Canvas render (TreemapLayout exists) `[VM]`
- [ ] **TSK-668** — Wire CSV table view to windowed-snapshot paging (backend exists) `[VM]`
- [ ] **TSK-280** — Dependency graph view
- [ ] **TSK-319** — Dependency Package explorer
- [ ] **TSK-318** — Ask the agent questions about a Code Review (CR Q&A)
- [ ] **TSK-677** — Unify search types (Global search / Recents / Command search)
- [~] **TSK-705** — Snippets — remaining: CM6 Tab-key wiring (apply SnippetSession) + management UI `[MODEL COMPLETE @ 667f8ba/8de8b2c/08d4e28/9393706]`
- [~] **TSK-727** — Unified "Goto Anything" — remaining: code-file `@` via LSP documentSymbols `[CORE COMPLETE @ a4022b9/…/651eaca]`

- [ ] **TSK-685** — Spell check / Grammar (NSSpellChecker) + LSP checks
- [ ] **TSK-712** — 3-way merge
- [ ] **TSK-713** — Diagram formats beyond Mermaid/Dot
- [ ] **TSK-721** — HTTP client
- [ ] **TSK-722** — Task / command runner (run tests & npm/package scripts)
- [ ] **TSK-723** — Structural search
- [ ] **TSK-586** — rust-core: shared golden corpus for cross-language parity + differential fuzzing
- [ ] **TSK-588** — rust-core: perf-floor ratchet bench + periodic cargo-mutants teeth audit
- [ ] **TSK-818** — test-infra: VM key-synthesis interaction lane (T4) — unblocks key-routing tail (730/728)

## D. Bigger features / epics — remaining

- [~] **TSK-675** — Text Edit: plain-text editing [P0 epic] — remaining: line ops (duplicate/move/delete), column/block select, macro record-replay, insert/overwrite `[slices 1-5 shipped f472ad6,…,d07a815]`
- [ ] **TSK-670** — PDF reader: view/open PDFs in-app [P2 epic]
- [ ] **TSK-264** — Sessions optional (run without the session system)
- [ ] **TSK-265** — Multi-window session support
- [ ] **TSK-711** — CSV table editor (editable cells)
- [ ] **TSK-679** — VIM modal editing in the editor [P6 epic] — core shipped (review); VM keystroke smoke remaining

- [ ] **TSK-715** — Profiling / Memory diffs / Flame charts (webpack-analyzer style)
- [ ] **TSK-716** — Better worktree-management UX
- [ ] **TSK-749** — Image edit: add text & shapes (draw tools, crop, 1000+ undo)
- [ ] **TSK-754** — Plugin API: let plugins contribute menu items / submenus

## E. Owner-input-needed (surface, don't autonomously guess)

- [ ] **TSK-733** — Save-prompt on session switch despite autosave [bug; waiting:human — needs repro]
- [ ] **TSK-791** — Editor feels slow / "was CM6 a mistake?" [bug/perf; informed by TSK-837 perf lane]

---

# ===== COMPLETED (shipped to review/validated — kept for record) =====

**★ Intake P1/P2/P3:**
- [x] **TSK-900** — Plain-text file locked in HEX, Editor can't show it `[a64c52a → review; hex→source upgrade on text verdict, 4 teeth]`
- [x] **TSK-907** — Git log: same entry opens a duplicate tab `[a1de1b7 → review; open-or-focus by URL + 2 teeth]`
- [x] **TSK-914** — "Open in Terminal" opens macOS Terminal.app, not in-app `[06c04d1 → review; in-app terminal at node folder + 3 teeth; covers TSK-769 PWD]`
- [x] **TSK-920** — drag-to-Terminal pastes the file path (not capture) `[review; TerminalDropFormatter + drag-dest, 7 teeth]`
- [x] **TSK-919** — File-nav: sub-folder self-drag trap `[review; DropReRootPolicy, 6 teeth; drag gesture=VM]`
- [x] **TSK-902** — Preview tab title italic not bold `[30f672c → review; TabTitleStyle host-tested, pixel=VM]`
- [x] **TSK-903** — Rendered MD doesn't check/strike GFM task items `[review; rust+swift disabled-checkbox + CSS strike; gates green]`
- [x] **TSK-929** — External rename → tab follows the rename `[review; inode capture + RenameFollower, 5 teeth; live watcher=VM]`
- [x] **TSK-899** — view-mode shortcuts ⌘1/⌘2/⌘3 (positional) `[review; selectViewMode(at:) + displayName, 3 teeth; key routing=VM]`
- [x] **TSK-913** — File-nav right-click → Rename `[review — ALREADY BUILT: SidebarView Rename… + F2 → FileRenamer]`
- [x] **TSK-915 / 916** — File tree auto-refresh + "Reload from disk" `[915 ALREADY BUILT (FolderWatcher); 916 0921186 — refreshFromDisk + reloadFileFromDisk, 7 teeth]`
- [x] **TSK-932** — Unsaved blue dot on modified tab `[review — ALREADY BUILT: TabBar dirty-dot]`
- [x] **TSK-918** — Remove max-width cap on horizontal panel resize `[review; PanelResize.clampWidth window-relative, 6 teeth]`
- [x] **TSK-925** — CSV: sort by column header `[review; CsvSort comparator + 11 teeth; header click=VM]`
- [x] **TSK-911** — Commit-diff summary header `[review; CommitDiffSummary.preamble + DiffView banner, 5 teeth]`
- [x] **TSK-909** — Right-click commit → Reviews submenu `[review; ReviewStore.reviews(forCommit:) + lazy Menu, 3 teeth]`
- [x] **TSK-933** — Footer filename as breadcrumb `[review; BreadcrumbPath.segments + StatusBar, 5 teeth]`
- [x] **TSK-934** — breadcrumb right-click = file-nav context menu `[583b4c5 — BreadcrumbPath.menuActions, 2 teeth]`
- [x] **TSK-928** — Rename URL scheme markdownviewer:// → textview:// `[review; textview primary + alias, teeth]`
- [x] **TSK-935** — New Tab → Paste / virtual-paste clipboard to a scratch buffer `[review; New Tab from Clipboard + NewFileType.detect, 9 teeth]`
- [x] **TSK-931** — Rename a session `[review; Session ▸ Rename Session… + SessionRename.sanitize]`
- [x] **TSK-904** — "Format JSON" discoverability `[answered: Pretty-Print + Minify JSON exist]`
- [x] **TSK-926 / 927** — CLI: open file/folder · pipe stdin → tab `[5749369 — ALREADY BUILT mdv shim; LaunchArgs.parse 9 teeth]`
- [x] **TSK-930** — Named saved sessions `[review — ALREADY BUILT: sessions persist tabs+panelLayout]`
- [x] **TSK-939** — Parity audit `[review; docs/PARITY_AUDIT_2026-06-14.md — matrix + 10 gaps; surfaced TSK-946..951]`
- [x] **TSK-946** — Find Next/Prev (⌘G/⌥⌘G) inert `[ee78398 — FindCoordinator.next()/prev(), 8 teeth]`
- [x] **TSK-949** — Find&Replace (⌥⌘F) not greyed outside editor `[ee78398 — canFindAndReplace gate, 3 teeth]`
- [x] **TSK-950** — LSP Find-References no menu/palette `[842d5fe — Navigate ▸ Find References + palette cmd, 6 teeth]`

**§0 Perf:**
- [x] **TSK-840** — Parallelize launch grammar-warm + markdown-first `[validated 64d4c3d]`
- [x] **TSK-843** — Cache per-call gate decision (getenv fast-path) `[validated 9c4eb01]`
- [x] **TSK-841** — Highlight wire → positional arrays `[validated e99ca14]`
- [x] **TSK-844** — CSV open: parse straight into the arena (CsvSink) `[validated 3d75f39]`
- [x] **TSK-842** — Files ≤64 MiB read+decode off-main (cold/iCloud cliff) `[validated a9103b3 — deferReadOffMainBytes=4 MiB]`

**A. Quick wins:**
- [x] **TSK-755** — Session menu "Tab operations" section `[25b732a]`
- [x] **TSK-756** — Top-right toolbar palette button `[e31bc99]`
- [x] **TSK-753** — View → Language Mode menu item `[192211b]`
- [x] **TSK-747** — New-tab offer other types (txt/md/csv/json) `[5ed9d51; blank-image deferred]`
- [x] **TSK-762** — Wrap/special-char toggle buttons `[a1dadb5]`
- [x] **TSK-707** — Command palette double-Shift `[da10ae9 — DoubleTapModifierDetector + DoubleShiftMonitor, 18 host tests]`
- [x] **TSK-720** — ⇧⌘P palette binding `[validated b4c4c20]`
- [x] **TSK-710** — Hover symbol info (LSP hover) `[review — ALREADY BUILT in CM6: hoverTooltip → respondToEditorHover]`
- [x] **TSK-719** — Sticky scroll `[cf9ac7c — StickyScrollHeaders; overlay=VM]`
- [x] **TSK-718** — Hot exit (restore unsaved buffers) `[8ba2a2f — TabSnapshot.unsavedText 1 MiB cap]`
- [x] **TSK-726** — Project-wide replace `[3b5724b — CrossFileReplace engine + ⌘⇧F Replace row]`
- [x] **TSK-759** — Drag to reorder tabs `[review — already shipped: TabBar onDrag/onDrop → moveTab]`
- [x] **TSK-757** — Keyboard shortcut catalog + gap-fill `[664a8d1 — docs/KEYBOARD_SHORTCUTS_AUDIT.md + ⇧⌥F Format]`
- [x] **TSK-355** — "Open in" — Reveal in Finder / Open in external app `[c84e8bf — Open-in-Default-App added]`

**B. [PARTIAL] slices (the shipped slice):**
- [x] **TSK-348** — Deep metadata: PDF + AV codec fields `[validated 575c1c5; XMP remaining → folded into ticket]`
- [x] **TSK-352** — NotePad++ tools: encoding-convert slice `[0686526; column/block + macro = separate slices]`
- [x] **TSK-350** — Formatting: Align Markdown Tables `[8449333; other detect() absences deliberate]`
- [x] **TSK-360** — Source-view line-age blame heatmap `[933737b — BlameHeatmap; tint=VM]`

**C. Medium:**
- [x] **TSK-524** — Image-editor UI + Save-As dialog `[review — ALREADY BUILT; 42 host tests]`
- [x] **TSK-533** — Audio spectrum panel `[fb2ada6 — AudioWaveform.spectrum + Canvas; render=VM]`
- [x] **TSK-534** — Audio draggable trim + fade `[dc17ac8 — AudioTrimFade + Save-a-Copy, 13 teeth; handles=VM]`

---

## Excluded (and why) — not in this queue

- **Validation tail** (per owner): the `fixed`/`review`-lane VM-render validations (TSK-806/743/468/734/730/…).
- **Perf/internal** (handled separately by the TSK-837 perf-subagent lane + filed tickets 826/827/829/830/543/574).
- **Build/CI** (F1 TSK-831 owner-gated; nextest 835 dep-gated; 836 needs profiling).
- **Owner-decision-blocked**: TSK-589 (session eviction), 810 (Stage-B carve-out), 508/498, 775 D1/D2/D3.
- **Research questions / spikes**: TSK-775/779/781/787/788/792–805.
- **Very-large / aspirational**: TSK-689/691/700/701/774 (Music), 687/693/697/699 (agent suites), browser (676),
  notebooks (717), tmux (690), docx/xlsx (682), RSS (955), AU/MIDI (956), macros (957), universal-paste (958).
  (See `docs/FEATURE_EXPLORATION_2026-06-16.md` for the 2026-06-16 feasibility/spike analysis.)
- **[PORT][WEB]/TUI front-end lane**: TSK-256/250/409 (last-resort per SOP).
- **Paint/Photo-editor epic**: TSK-320/380/403–406/285/287/286 (big, deprioritized).
- **Foreign (tasked-tool dev, NOT markdown_viewer)**: TSK-441/442/443/444/445.
- **prio-3 aspirational backlog**: TSK-277/278/288/289/369/370.
