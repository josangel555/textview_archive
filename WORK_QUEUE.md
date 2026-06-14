# Work Queue — next ~50 (curated 2026-06-14)

Owner ask: scan the whole `tasked` board, pick the next ~50 to work on — **features + bug fixes**,
ignore the validation tail. Tracked HERE (check the box when done) for now; the board lifecycle is separate.

**Ordering = execution order.** Top = do-first (small, host-buildable, user-facing → host-test the model,
ship to `review`). Lower = bigger / heavier. `[VM]` = render/interaction validation is the VM tail (build +
host-test the model anyway). `[slice]` = umbrella with concrete gaps already partly done this session.

Mark `[x]` when shipped (commit + board → at least `review`).

---

## 0. Perf — user-felt latency (HIGH priority; from the 2026-06-14 perf-explore, measured)

These are what makes the app *feel* slow (measured on the VM with signpost + CA-stall traces — NOT the model,
which is fast at ≤12 ms; the editor/CM6 is fine). Ordered cheapest-felt-win first.

- [x] **TSK-840** — Parallelize launch grammar-warm (231 ms serial on one thread) + warm the opened file's
      language + markdown FIRST; warm the *Rust* highlight path too. **Cleanest S-effort win.**
      `[validated 64d4c3d]` — parallelize + markdown-first done; opened-file-lang + Rust-path warm deferred (see ticket).
- [x] **TSK-843** — Cache the per-call gate decision — `ProcessInfo.environment` allocates the whole environ
      (~19 µs) on every routed FFI call. Cheap. `[validated 9c4eb01]` — `getenv` fast-path across the 11-file
      gate chain; dict test-seam preserved.
- [ ] **TSK-845** — Micro-bundle: `ContentFingerprint` utf8.count ×3/apply (cache), MsgPackReader always-builds-tree, lazy-tab materialize.
- [ ] **TSK-841** — Highlight wire → positional arrays + integer kind (4× smaller, 5.3× faster decode; like
      diff-lines wire-v2). Rust+Swift wire change; hits every highlighted open + markdown fence.
- [ ] **TSK-844** — CSV open: parse straight into the arena (skip the throwaway `Vec<Vec<String>>`; 140 ms open).
- [ ] **TSK-842** — Files ≤64 MiB read + UTF-8-decode SYNC on main (softWarnBytes cliff) → off-main `[needs trace]`
- [ ] **TSK-839** — Attribute + fix the 30–366 ms per-nav main-thread CoreAnimation commit stall (the REAL felt
      'nav slow' root; 598/591/266 fixed the model, not the compositor) `[Time-Profiler attribution first]`
- [ ] **TSK-838** — Rendered-MD WebView: persistent page + DOM-patch instead of full `loadHTMLString` reload
      (2–9 s reload storm; quantifies TSK-624) `[architectural — spike + slices]`

---

## A. Quick wins — small features, host-buildable (do these first)

- [ ] **TSK-755** — Session menu: a "Tab operations" section (new/close/next/prev/move) `[VM]`
- [ ] **TSK-756** — Top-right toolbar button that opens the command palette (discoverability) `[VM]`
- [ ] **TSK-753** — Dedicated menu item for the current file's type `[VM]`
- [ ] **TSK-751** — Organize the menu items properly (review/reorganize the menu bar) `[VM]`
- [ ] **TSK-746** — Open dialog: show recents
- [ ] **TSK-747** — New-tab: offer other types (blank Sheet, Image) `[VM]`
- [ ] **TSK-762** — Wrap / special-char toggles on the details pane (toggle buttons, not checkboxes) `[VM]`
- [ ] **TSK-707** — Command palette: double-Shift shortcut (IntelliJ-style)
- [ ] **TSK-720** — Cmd+P / Cmd+Shift+P palette bindings (VS Code parity)
- [ ] **TSK-709** — Unify Cmd+K and Cmd+G (palette/goto)
- [ ] **TSK-710** — Hover symbol info on identifiers (LSP textDocument/hover) `[VM]`
- [ ] **TSK-708** — Preview definition (IntelliJ Quick Definition / Cmd+Y) `[VM]`
- [ ] **TSK-719** — Sticky scroll (pin the enclosing scope header) `[VM]`
- [ ] **TSK-718** — Hot exit (restore unsaved buffers on relaunch)
- [ ] **TSK-726** — Project-wide replace (cross-file search is read-only today)
- [ ] **TSK-704** — Markdown side-by-side editor + live preview `[VM]`
- [ ] **TSK-759** — Drag to reorder tabs `[VM]`
- [ ] **TSK-766** — Editor: git-diff text style match Edit/View `[VM]`
- [ ] **TSK-757** — Catalog every keyboard shortcut + compare with Mac apps (audit → gap-fill bindings)
- [ ] **TSK-355** — "Open in" — Reveal in Finder / Open in external app

## B. [PARTIAL] slice continuations (chip the remaining gaps)

- [ ] **TSK-769** — Terminal UX bundle: remaining slices (command history + favorites + search, colors, tab shoulder border). `[slice]` done: open-in-pwd, tab-rename, copy-trimmed.
- [ ] **TSK-348** — Deep metadata: remaining (richer PDF + AV/video fields; XMP). `[slice]` done: FS perms/owner/inode, image EXIF/GPS.
- [ ] **TSK-352** — NotePad++ tools: remaining (column/block select, macro record/replay, encoding convert). `[slice]` done: 15 clipboard transform tools.
- [ ] **TSK-350** — Formatting: any remaining formatter gaps. `[slice]` done: JSON/XML/JS/CSS pretty-print.
- [ ] **TSK-343** — History, Revert (revert a file to a previous saved version)
- [ ] **TSK-358** — Absolute content font-size picker in settings (today only the zoom multiplier) + window-size control
- [ ] **TSK-360** — Source-view line-age coloring (git-blame DarkBlue→LightBlue heatmap) `[VM, CM6-render]`
- [ ] **TSK-382** — Squeeze DocumentModel memory footprint to bare bones

## C. Medium features

- [ ] **TSK-524** — Surface the image-editor UI + Save-As-with-settings dialog (engine exists) `[VM]`
- [ ] **TSK-533** — Audio spectrum panel (SpectrumAnalyzer → Canvas) `[VM]`
- [ ] **TSK-534** — Audio draggable trim + fade handles `[VM]`
- [ ] **TSK-463** — Wire LSP completion to the editor (request implemented, never invoked) `[VM]`
- [ ] **TSK-470** — Zoom split: UI-chrome zoom vs document zoom (currently unified) `[VM]`
- [ ] **TSK-495** — Unified tool-window placement: any tool window → any shoulder, drag-and-drop `[VM]`
- [ ] **TSK-506** — Folder-stats treemap (bundle-analyzer) Canvas render (TreemapLayout exists) `[VM]`
- [ ] **TSK-668** — Wire CSV table view to windowed-snapshot paging (backend exists, make O(window) visible) `[VM]`
- [ ] **TSK-280** — Dependency graph view
- [ ] **TSK-319** — Dependency Package explorer
- [ ] **TSK-318** — Ask the agent questions about a Code Review (CR Q&A)
- [ ] **TSK-705** — Snippets
- [ ] **TSK-727** — Unified "Goto Anything" (one box, @/: operators)
- [ ] **TSK-677** — Unify search types (Global search / Recents / Command search)

## D. Bigger features / epics (slice them; P0–P2 first)

- [ ] **TSK-675** — Text Edit: plain-text editing [P0 epic — spike → slices]
- [ ] **TSK-670** — PDF reader: view/open PDFs in-app [P2 epic]
- [ ] **TSK-264** — Sessions optional (run without the session system)
- [ ] **TSK-265** — Multi-window session support
- [ ] **TSK-711** — CSV table editor (editable cells)
- [ ] **TSK-679** — VIM modal editing in the editor [P6 epic]

## E. Owner-input-needed (bugs/decisions — surface, don't autonomously guess)

- [ ] **TSK-733** — Save-prompt on session switch despite autosave [bug; waiting:human — needs repro confirmation]
- [ ] **TSK-791** — Editor feels slow / "was CM6 a mistake?" [bug/perf; the perf subagents (TSK-837) will inform]

---

## Excluded (and why) — not in this queue

- **Validation tail** (per owner): the `fixed`/`review`-lane VM-render validations (TSK-806/743/468/734/730/…).
- **Perf/internal** (handled separately by the TSK-837 perf-subagent lane + filed tickets 826/827/829/830/543/574).
- **Build/CI** (F1 TSK-831 owner-gated; nextest 835 dep-gated; 836 needs profiling) — see the build-speedup audit.
- **Owner-decision-blocked**: TSK-589 (session eviction), 810 (Stage-B carve-out), 508/498, 775 D1/D2/D3.
- **Research questions / spikes**: TSK-775/779/781/787/788/792–805 (investigations, not shippable features).
- **Very-large / aspirational**: TSK-689/691/700/701/774 (Music), 687/693/697/699 (agent suites), browser (676), notebooks (717).
- **[PORT][WEB]/TUI front-end lane**: TSK-256/250/409 (last-resort per SOP).
- **Paint/Photo-editor epic**: TSK-320/380/403–406/285/287/286 (big, deprioritized).
- **Foreign (tasked-tool dev, NOT markdown_viewer)**: TSK-441/442/443/444/445.
- **prio-3 aspirational backlog**: TSK-277/278/288/289/369/370 (debuggers, vector store, AWS, Linux/Win port).
</content>
