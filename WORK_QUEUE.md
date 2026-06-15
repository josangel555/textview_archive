# Work Queue — next ~50 (curated 2026-06-14)

Owner ask: scan the whole `tasked` board, pick the next ~50 to work on — **features + bug fixes**,
ignore the validation tail. Tracked HERE (check the box when done) for now; the board lifecycle is separate.

**Ordering = execution order.** Top = do-first (small, host-buildable, user-facing → host-test the model,
ship to `review`). Lower = bigger / heavier. `[VM]` = render/interaction validation is the VM tail (build +
host-test the model anyway). `[slice]` = umbrella with concrete gaps already partly done this session.

Mark `[x]` when shipped (commit + board → at least `review`).

---

## ★ Intake 2026-06-14 (owner batch — analyzed, de-duped, triaged → TSK-887..945)

Fresh owner bug/improvement batch. 59 new tickets filed (`[INTAKE-0614]` prefix); dupes linked onto
existing tickets, not re-filed (see "De-duped" note at the bottom). Ranked below; **felt-perf + broken
user-facing behavior first** (SOP rule 1). These pre-empt the older sections once worked. Parents set:
git→TSK-537, split→TSK-714, csv→TSK-711, agent→TSK-687, cli→TSK-353.

**P0 — user-felt latency (owner reports lag everywhere — fix first; most need a VM/Instruments trace):**
- [ ] **TSK-892** — File-nav hover is slow (constant friction; find per-hover compute) `[trace]`
- [ ] **TSK-887** — Command palette typing laggy `[trace]`
- [ ] **TSK-888** — Global search typing + result-scroll laggy `[trace]`
- [ ] **TSK-890 / 891 / 895** — CM6 editor feel: drag-select slow / Page-Up janky / h-scrollbar flicker on type (MD≫Swift; ties TSK-791) `[trace]`
- [ ] **TSK-889** — ~699KB JSON open laggy (warm path; distinct from TSK-842 cold/iCloud) `[trace]`
- [ ] **TSK-908** — Right-click commit very slow (menu build) `[trace]`

**P1 — broken user-facing behavior (host-fixable bugs; ship model + leave render at review):**
- [x] **TSK-900** — Plain-text file locked in HEX, Editor can't show it `[a64c52a → review; off-main open upgraded hex→source on text verdict, 4 teeth tests]`
- [x] **TSK-907** — Git log: same entry opens a duplicate tab (de-dupe/focus existing) `[a1de1b7 → review; open-or-focus by URL + 2 teeth tests]`
- [ ] **TSK-910** — Git diff: only one line selectable → multi-line selection `(537)`
- [ ] **TSK-905** — Preview ↑/↓ broken unless tab is last (first-responder by tab position)
- [ ] **TSK-906** — Palette dismiss loses editor focus (restore prior first-responder)
- [ ] **TSK-893 / 894 / 896** — Editor: cursor pointer↔I-beam flip / current-line highlight stuck after drag / hovered-row offset
- [ ] **TSK-917** — Gutter selectable + cursor-icon confusion (hand/pointer/I-beam)
- [ ] **TSK-921 / 922** — Split: can't close pane / open-split slow+doesn't appear `(714)`
- [x] **TSK-914** — "Open in Terminal" opens macOS Terminal.app, not the in-app terminal `[06c04d1 → review; in-app terminal at node folder + 3 teeth tests; also covers TSK-769 PWD]`
- [x] **TSK-920** — drag-to-Terminal pastes the file path (not capture) `[review; TerminalDropFormatter + drag-dest, 7 teeth tests]`
- [x] **TSK-919** — File-nav: sub-folder self-drag trap `[review; DropReRootPolicy guards openMultiple re-root for root/descendant drops, 6 teeth tests; drag gesture=VM]`
- [x] **TSK-902** — Preview tab title italic not bold `[30f672c → review; TabTitleStyle host-tested, pixel=VM]`
- [x] **TSK-903** — Rendered MD doesn't check/strike GFM `[x]` task items `[review; rust+swift emit disabled checkbox (byte-matched A/B), CSS strike; NO sanitizer change needed (structural html); rust+swift gates green]`
- [ ] **TSK-912** — Code-review comments: how to add + where listed (discoverability/missing UI) `(537)`
- [ ] **TSK-929** — External rename → tab shows "file not found"; should follow the rename `(fs.watch TSK-662)`

**P2 — quick-win features / UX (host-buildable, [VM] render at review):**
- [ ] **TSK-898 / 899** — Render|Editor|HEX segmented button group + mode shortcuts
- [ ] **TSK-913** — File-nav right-click → Rename
- [ ] **TSK-915 / 916** — File tree auto-refresh on disk change + "Reload from disk" action
- [x] **TSK-932** — Unsaved blue dot on modified tab `[review — ALREADY BUILT: TabBar accent dirty-dot on tab.isDirty]`
- [ ] **TSK-936 / 937 / 938** — Toggle-View-only shortcut · Focus Terminal/Nav/Git/File · Esc→current tab
- [ ] **TSK-918** — Remove max-width cap on horizontal panel resize (cf TSK-440)
- [x] **TSK-925** — CSV: sort by column header `[review; CsvSort type-aware comparator + 11 teeth tests; header click=VM]`
- [ ] **TSK-924** — CSV: multi-cell select + copy/paste `(711)` (view-coupled selection — VM)
- [ ] **TSK-911 / 909** — Commit-diff summary header (uses TSK-514 DiffStat) · Reviews submenu `(537)`
- [ ] **TSK-933 / 934** — Footer filename as breadcrumb · breadcrumb right-click = file-nav menu
- [x] **TSK-928** — Rename URL scheme markdownviewer:// → textview:// `[review; textview primary + markdownviewer alias, router+plist+gate, teeth tests]`
- [ ] **TSK-935** — New Tab → Paste / virtual-paste clipboard to a scratch buffer
- [x] **TSK-931** — Rename a session (menu + right-click tab) `[review; right-click existed, added Session ▸ Rename Session… + SessionRename.sanitize host-tested]`
- [x] **TSK-904** — "Format JSON" discoverability `[answered: Pretty-Print (View) + Minify JSON (Edit) exist; optional label follow-up = owner's call]`
- [ ] **TSK-901** — Auto-detect content type (CSV/JSON/language) for unknown/misnamed files

**P3 — bigger / design-first / epics:**
- [ ] **TSK-926 / 927** — CLI: open file/folder in TextView · pipe stdin → tab `(353)`
- [x] **TSK-930** — Named saved sessions (save/list/delete + tool-window state) `[review — ALREADY BUILT: sessions persist tabs+panelLayout, list/rename/delete/restore]`
- [ ] **TSK-939** — Parity audit: Feature × View-only × Editor × Cmd-K × Menu (+ deprecate own Viewer?) `[audit]`
- [ ] **TSK-897** — Editor missing many languages' highlighting (reopen TSK-362) `[triage]`
- [ ] **TSK-940..945** — Agent integration: review/approve agent diffs · line-ref-to-agent · LSP/diag sharing · browser MCP · security audits `(687, epic→slices)`

**De-duped (owner re-reports linked onto existing tickets — NOT re-filed):**
- Slow to type CM6/MD + MD selection slow → **TSK-791** (commented; symptoms split to 890/891/895)
- Console / JS-manipulation of JSON → **TSK-698** (JQ-style script window epic; owner wants the design — auto-approved)
- Open-in-Terminal PWD → **TSK-769** (open-in-pwd; re-verify) — distinct from TSK-914
- Multi-file refactoring engine → **TSK-697** (Agent Services suite — Refactor)
- Feature parity View-only vs Editor (highlighting) → **TSK-602** (validated); broader parity → TSK-939

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
- [~] **TSK-845** — Micro-bundle: `ContentFingerprint` utf8.count ×3/apply (cache), MsgPackReader always-builds-tree, lazy-tab materialize.
      `[PROFILE-GATED]` — spike found (a) is a likely NO-OP: `utf8.count`/`first`/`last` are O(1) on a native UTF-8 String;
      the ×3 cost only bites if `text` is NSString-bridged (UTF-16). Needs a profile of `text` provenance before it's worth a
      (behaviorally-invisible, untestable) commit. (b)/(c)/(d) all need profiling too. Mechanical fix recorded on the ticket.
- [x] **TSK-841** — Highlight wire → positional arrays + integer kind (4× smaller, 5.3× faster decode; like
      diff-lines wire-v2). Rust+Swift wire change; hits every highlighted open + markdown fence.
      `[validated e99ca14]` — positional `[start,len,kind]` array landed (kind stays String; integer-kind = deferred follow-up).
- [x] **TSK-844** — CSV open: parse straight into the arena (skip the throwaway `Vec<Vec<String>>`; 140 ms open).
      `[validated 3d75f39]` — single CSV tokenizer now drives a `CsvSink` trait: `VecSink` keeps the wire DTO path, new `ArenaSink` writes cells straight into the arena buffer with a reused field scratch (no per-cell `String`, no second byte-copy). All caps stay in the shared tokenizer (byte-identical by construction); parity tests + teeth referee. rust-core gate green.
- [x] **TSK-842** — Files ≤64 MiB read + UTF-8-decode SYNC on main (softWarnBytes cliff) → off-main `[needs trace]`
      `[validated a9103b3]` — measured: warm read+decode is fast (~8ms/64MB), so the real risk is a SYNC read on main of a COLD/iCloud-stubbed file (the repo is iCloud-hosted → a not-downloaded file blocks main on the download). Split the defer threshold from the isLargeReadOnly watermark: new `TextFileLoader.deferReadOffMainBytes` (default **4 MiB**, was the 64 MiB cliff) routes moderate+ files through the existing off-main path; small files stay instant-sync. Pure `shouldDeferOpen` routing seam host-tested + teeth.
- [ ] **TSK-839** — Attribute + fix the 30–366 ms per-nav main-thread CoreAnimation commit stall (the REAL felt
      'nav slow' root; 598/591/266 fixed the model, not the compositor) `[Time-Profiler attribution first]`
- [ ] **TSK-838** — Rendered-MD WebView: persistent page + DOM-patch instead of full `loadHTMLString` reload
      (2–9 s reload storm; quantifies TSK-624) `[architectural — spike + slices]`

---

## A. Quick wins — small features, host-buildable (do these first)

- [x] **TSK-755** — Session menu: a "Tab operations" section (new/close/next/prev/move) `[VM]`
      `[review 25b732a]` — section added to buildSessionMenu (compile-guarded selectors); menu appearance = VM/owner gate.
- [x] **TSK-756** — Top-right toolbar button that opens the command palette (discoverability) `[VM]`
      `[review e31bc99]` — ⌘ button in ContentToolbar → model.showPalette(); action host-tested, button render = VM gate.
- [x] **TSK-753** — Dedicated menu item for the current file's type `[VM]`
      `[review 192211b]` — View → Language Mode (current language checkmarked + override submenu); model accessor host-tested, menu = VM gate.
- [~] **TSK-751** — Organize the menu items properly (review/reorganize the menu bar) `[VM]`
      `[PARKED→owner]` — "properly" undefined; a speculative reorg churns muscle memory. Asked which specific menus/items feel wrong; will execute to that.
- [~] **TSK-746** — Open dialog: show recents
      `[LOW-VALUE]` — NSOpenPanel can't cleanly host the app's custom recents (only an accessoryView hack); File → Open Recent already exists. Deferred unless owner wants the in-panel variant.
- [x] **TSK-747** — New-tab: offer other types (blank Sheet, Image) `[VM]`
      `[review 5ed9d51]` — NewFileType (txt/md/csv/json) + typed New File submenus (sidebar + File menu); model+mapping host-tested, menu render = VM gate. Blank-image deferred (needs format/size dialog).
- [x] **TSK-762** — Wrap / special-char toggles on the details pane (toggle buttons, not checkboxes) `[VM]`
      `[review a1dadb5]` — all 4 BottomAttributesBar toggles → .toggleStyle(.button); pure-visual, VM/owner glance.
- [x] **TSK-707** — Command palette: double-Shift shortcut (IntelliJ-style)
      `[review da10ae9]` — pure `DoubleTapModifierDetector` (ViewerCore, 10 host tests) + flag→event classifier (`DoubleShiftMonitor.detectorEvent`, 8 host tests) + a `flagsChanged` NSEvent monitor mounted app-wide in ContentView → `model.showPalette()`. The otherKey-reset rule stops typing-capitals from firing. Live gesture firing = VM/owner glance.
- [x] **TSK-720** — Cmd+P / Cmd+Shift+P palette bindings (VS Code parity)
      `[validated b4c4c20]` — ⇧⌘P → command palette (nav.showPalette), routing host-tested; ⌘P left for Print (Mac HIG, not VS Code's override).
- [~] **TSK-709** — Unify Cmd+K and Cmd+G (palette/goto)
      `[PARKED→owner]` — "unify" ambiguous + overlaps TSK-727/677; ⌘G is the standard Find-Next chord (risky to rebind). Asked for intended behavior / whether it's a dup.
- [x] **TSK-710** — Hover symbol info on identifiers (LSP textDocument/hover) `[VM]`
      `[review — ALREADY BUILT]` — hover is shipped in the CM6 editor (stale entry): codemirror.js `hoverTooltip` → `CodeMirrorEditorView` posts `CMHoverRequest` → `DocumentModel.respondToEditorHover` → `lspPool.hover` → `sendEditorHoverResponse`. The unwired `LSPHoverAttachment` NSTextView path is a separate PoC. Proof: `CodeMirrorBundleTests` (hoverTooltip export + bridge strings) + `LSPUATTests`. Column-correctness/popover geometry = VM/manual tail. No code change.
- [ ] **TSK-708** — Preview definition (IntelliJ Quick Definition / Cmd+Y) `[VM]`
- [x] **TSK-719** — Sticky scroll (pin the enclosing scope header) `[VM]`
      `[review cf9ac7c]` — pure StickyScrollHeaders (enclosing chain from fold regions; code+markdown) + DocumentModel recompute on scroll; helper+glue host-tested. Pinned-bar overlay over the CM6 WebView = VM render tail (compositor zone, not built blind).
- [x] **TSK-718** — Hot exit (restore unsaved buffers on relaunch)
      `[review 8ba2a2f]` — additive-optional TabSnapshot.unsavedText (1 MiB cap) captured at snapshot boundaries + overlaid on materialize → tab reopens dirty; round-trip/capture/restore host-tested, dirty-dot render = VM tail.
- [x] **TSK-726** — Project-wide replace (cross-file search is read-only today)
      `[review 3b5724b]` — CrossFileReplace engine (encoding-faithful, atomic, symlink-safe) + Replace row in ⌘⇧F panel; literal+regex, engine+model host-tested, panel render = VM tail.
- [ ] **TSK-704** — Markdown side-by-side editor + live preview `[VM]`
- [x] **TSK-759** — Drag to reorder tabs `[VM]`
      `[review — already shipped]` — TabBar .onDrag/.onDrop → reorder (resolves by tab ID at drop time) → moveTab; payload+moveTab host-tested. No code change; board reconciled from `reported`.
- [ ] **TSK-766** — Editor: git-diff text style match Edit/View `[VM]`
- [x] **TSK-757** — Catalog every keyboard shortcut + compare with Mac apps (audit → gap-fill bindings)
      `[review 664a8d1]` — audit doc (docs/KEYBOARD_SHORTCUTS_AUDIT.md) + bound ⇧⌥F → Format Document (VS Code standard); divergent/conflicting candidates flagged for owner pick (not imposed). Registry binding host-tested.
- [x] **TSK-355** — "Open in" — Reveal in Finder / Open in external app
      `[review c84e8bf]` — Reveal-in-Finder already existed; added Open-in-Default-App (NSWorkspace.open) to sidebar + tab menus. (board reconcile pending — MCP was down)

## B. [PARTIAL] slice continuations (chip the remaining gaps)

- [ ] **TSK-769** — Terminal UX bundle: remaining slices (command history + favorites + search, colors, tab shoulder border). `[slice]` done: open-in-pwd, tab-rename, copy-trimmed.
- [x] **TSK-348** — Deep metadata: remaining (richer PDF + AV/video fields; XMP). `[slice]` done: FS perms/owner/inode, image EXIF/GPS.
      `[validated 575c1c5]` — PDF: +Subject/Keywords/Creator/Created/Modified/Page-Size/Encrypted; AV: +Video/Audio codec (FourCC→name). Pure host-tested builders (pdfRows + MediaCodecName) + real-PDF fixture test; panel auto-renders (no new UI). XMP still remaining (separate parse).
- [x] **TSK-352** — NotePad++ tools: remaining (column/block select, macro record/replay, encoding convert). `[slice]` done: 15 clipboard transform tools.
      `[review 0686526]` — **encoding-convert** slice shipped: Edit ▸ Convert Encoding ▸ {UTF-8/UTF-16/Windows-1252/Latin-1} re-saves the active file in the chosen encoding (write-through + reload; non-representable refused). Host-tested. Remaining (column/block select, macro record/replay) are editor-render-coupled — separate slices.
- [x] **TSK-350** — Formatting: any remaining formatter gaps. `[slice]` done: JSON/XML/JS/CSS pretty-print.
      `[review 8449333]` — added markdown table alignment as an in-place **Align Markdown Tables** Edit-menu command (md has no format VIEW lens by design — FormatToggleTests). Spike finding: the other detect() absences (.jsonl/.svg/.scss/.less/.jsx/.ts) are DELIBERATE exclusions — no further clean gaps; new types (YAML/TOML/SQL) = separate from-scratch tickets if wanted.
- [ ] **TSK-343** — History, Revert (revert a file to a previous saved version)
- [~] **TSK-358** — Absolute content font-size picker in settings (today only the zoom multiplier) + window-size control
      `[review 6a045e0, 2ad2518]` — FONT-SIZE slice shipped across ALL content types: Settings → Appearance "Text Size" slider (8–32pt) sets an absolute content base. Editor/source/gutter use base × zoom (ContentFontSizing.effective → DocumentModel.effectiveContentFontSize); rendered-markdown uses a live --mdv-content-scale CSS var (markdownScale = base/13, behaviour-neutral at default; cache-safe via evaluateJavaScript like pageZoom). PreferencesStore.contentFontSize (clamped, default 13). base×zoom + markdownScale + prefs-clamp host-tested; slider/font render = VM tail. REMAINING: the "window sizing" half (separate slice).
- [x] **TSK-360** — Source-view line-age coloring (git-blame DarkBlue→LightBlue heatmap) `[VM, CM6-render]`
      `[review 933737b]` — pure BlameHeatmap (timestamps→dark/light-blue gradient, normalized over the file's history) tints the blame gutter via an additive CMGutterMarker.color + a small CM6 toDOM background. Model/feeder/encode host-tested; on-screen tint = VM render tail.
- [~] **TSK-382** — Squeeze DocumentModel memory footprint to bare bones
      `[triaged — needs VM profile]` — investigated: NO host-visible structural leak (heavy per-tab caches all dropped via the central purgeCaches; hexDirtyBytes cleaned on every dirty-close path; URL-scroll dicts tiny/intentional). A real squeeze needs a VM memory-profile to find the actual large consumers (measure-don't-guess) — VM-gated, not a host structural fix.

## C. Medium features

- [x] **TSK-524** — Surface the image-editor UI + Save-As-with-settings dialog (engine exists) `[VM]`
      `[review — ALREADY BUILT]` — found fully implemented (prior session; stale queue entry): MediaPreviewView Edit button (:229/:711) → ImageEditorView overlay (rotate/flip/crop) → "Save a Copy…" → NSSavePanel + format Picker + quality Slider → host-tested ImageEditorViewModel.export / Exporter. 42 host tests green (ImageEditorViewModel 10 + ImageEditing engine 32). On-screen render = VM tail. No code change — reconciled stale entry.
- [x] **TSK-533** — Audio spectrum panel (SpectrumAnalyzer → Canvas) `[VM]`
      `[review fb2ada6]` — optional FFT spectrum panel below the waveform: AudioWaveform.spectrumWindow/spectrum(at:) (playhead-centred, buffer-clamped) → existing host-tested SpectrumAnalyzer; VM showSpectrum toggle + playhead-tracking state; toggle button + linear-freq spectrumCanvas. SpectrumBins carries floorDB. Pure window/spectrum teeth (sine→peak) + VM toggle-state teeth host-tested; Canvas render = VM tail. PRIOR-FIRING CORRECTION: the "viewModel keeps peaks not the float buffer" blocker was wrong — AudioWaveform.samples holds the full mono buffer, so this WAS a clean leaf.
- [x] **TSK-534** — Audio draggable trim + fade handles `[VM]`
      `[review dc17ac8]` — trim + fade + Save-a-Copy over the ALREADY-BUILT host-tested edit backend (AudioDocument/AudioEditOp/AudioExporter). New pure AudioTrimFade maps the selection (trim range + fade-in/out secs) → ordered ops; VM loads the full PCM source, holds selection state, exports rendered() via AudioExporter. Edit bar (Set Start/End at playhead, Reset, fade sliders, shape) + trim overlay; "Save a Copy…" → NSSavePanel. Selection→ops + export-round-trip host-tested (8+5 teeth); draggable waveform handles = VM render tail.
- [ ] **TSK-463** — Wire LSP completion to the editor (request implemented, never invoked) `[VM]`
- [ ] **TSK-470** — Zoom split: UI-chrome zoom vs document zoom (currently unified) `[VM]`
- [ ] **TSK-495** — Unified tool-window placement: any tool window → any shoulder, drag-and-drop `[VM]`
- [ ] **TSK-506** — Folder-stats treemap (bundle-analyzer) Canvas render (TreemapLayout exists) `[VM]`
- [ ] **TSK-668** — Wire CSV table view to windowed-snapshot paging (backend exists, make O(window) visible) `[VM]`
- [ ] **TSK-280** — Dependency graph view
- [ ] **TSK-319** — Dependency Package explorer
- [ ] **TSK-318** — Ask the agent questions about a Code Review (CR Q&A)
- [~] **TSK-705** — Snippets
      `[epic: slices 1-5 @ 667f8ba/8de8b2c/08d4e28/9393706, review]` — parser + built-ins + Insert command + user JSON store + tab-stop navigation MODEL (SnippetSession). MODEL LAYER COMPLETE + host-tested (parse→insert→store→navigate). Remaining = pure render/VM: CM6 Tab-key wiring (apply SnippetSession) + management UI. Still `[~]`.
- [~] **TSK-727** — Unified "Goto Anything" (one box, @/: operators)
      `[epic: slices 1-5 @ a4022b9/283d894/55129eb/224b7b9/651eaca, CORE COMPLETE, progress]` — unified operator set DELIVERED: bare→files, `>`→commands, `:`→go-to-line, `#`→in-file text (`InFileSearch`), `@`→Markdown-heading jump (`SymbolJump`), and `#`/`@` now render an arrow-navigable LIST (slice 5). Operator models pure + host-tested (34 host tests + teeth); gate green. Remaining = ENHANCEMENT: code-file `@` via LSP `documentSymbols` (markdown-only today). Palette visuals/nav = VM validation tail.
- [ ] **TSK-677** — Unify search types (Global search / Recents / Command search)

## D. Bigger features / epics (slice them; P0–P2 first)

- [~] **TSK-675** — Text Edit: plain-text editing [P0 epic — spike → slices]
      `[spike done + slices 1-5 @ f472ad6,90196d2,2a8b111,d07a815, triaged]` — owner scope: full robust plain-text editor on the existing CM6 stack. SPIKE: most foundations already exist (CM6 edit+undo, EditorWriter atomic save + encoding/BOM + dirty, line-ending detection, find/replace + project-replace, go-to-line, Convert Encoding, hot-exit, snippets). SHIPPED (all pure models host-tested; menus/alert = VM tail): (1) **Convert Line Endings** LF/CRLF/CR (TSK-862); (2) **Document Statistics** (TSK-863); (3) **Trim Trailing Whitespace + Ensure Final Newline** (TSK-863); (4) **Convert Indentation** Tabs↔Spaces (TSK-864); (5) **Insert Table of Contents** Markdown (TSK-865, d07a815). REMAINING (render/CM6-coupled, VM/later): line ops (duplicate/move/delete — caret-dependent), column/block select, macro record-replay, insert/overwrite, optional auto-cleanup-on-save.
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
