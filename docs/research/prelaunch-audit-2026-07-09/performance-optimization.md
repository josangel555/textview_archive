# Pre-launch audit — Extreme performance optimization

**Date:** 2026-07-09 · **Dimension:** hot paths, main-thread blocking, UI-thread IO, redundant parsing/allocations, missing caching/laziness, startup, measurement coverage.
**Reviewer:** performance-lens subagent (static analysis + targeted code reads; no tests executed).

---

## Executive summary

The codebase shows **strong, deliberate perf engineering** on the paths that were already burned once: file open is deferred off-main above a 4 MB watermark, the main-pane rendered-markdown output is LRU-cached with mounted-aware eviction, JSON persistence is a coalesced off-main write queue, TreeSitter grammars are prewarmed at launch, the sidebar readdir/sort runs off-main with a sorted-cache, and the NSTextView source view has receipts for several past body-re-eval hot paths.

The remaining exposure clusters in **three places**:

1. **The per-keystroke editor pipeline** — each CM6 change flush (200 ms debounce) round-trips the **entire document** over the FFI (`cm_apply` ships full `base`, returns full text) on the **main thread**, then runs a **full-document synchronous spell pass** (≤200 KB prose), a full-doc fold re-parse, and two O(n) string equality checks. An O(delta) FFI variant (`mdvCoreApplyCMEditsDelta`) was built and has **zero callers**.
2. **The split pane** — a markdown file in the split pane runs the full `HTMLRenderer().renderPage` (markdown parse + fence highlighting) **inside SwiftUI `body`, on the main thread, on every body invalidation**, and the view is deliberately re-bodied **per keystroke**. This is the exact pattern TSK-611 measured at **~927 ms** on the main pane and fixed there with a cache the split pane does not use.
3. **Measurement coverage** — the purpose-built `InteractionProfiler` (TSK-1488) has **no production call sites**; `PerfSignpost` has only ~29 call sites and none on the keystroke, palette, CSV-parse, or save paths. The hottest interactive paths are currently unmeasured, so regressions there are caught by vibes.

No P0s: nothing found is a data-loss/crash-class perf defect. Two P1s degrade core editing flows at realistic document sizes.

---

## Methodology

- Static review via `rg`/`sed`/Read over `Sources/` (ViewerKit / ViewerCore / ViewerUI / MarkdownViewer / RustCore). No repo files modified except this report; no tests run; no windows opened.
- Traced end-to-end: file open (`DocumentModel.openResolved` → `DocumentController.open` → `TextFileLoader`), tab switch (`updateDerived` fan-out), the CM6 keystroke pipeline (JS debounce → `CMBridgeCodec` → `RustCMEditAdapter` → `EditorCoordinator.updateEditorText`), markdown render (main pane `DocumentModel+RenderedCache` vs split pane), save (`EditorCoordinator.saveEditor` → `EditorWriter` + `LocalHistoryStore`), find (source view, diff view, palette fuzzy), persistence (`JSONFileStore`, `SessionStore`), startup (`main.swift` `applicationDidFinishLaunching`, `SessionsAppCoordinator.bootstrap`), sidebar (`SidebarModel`), timers/pollers, and the measurement infra (`PerfSignpost`, `InteractionProfiler`, `FrameRateMonitor`).
- Examined ~45 files in depth; line numbers cited against the working tree as of 2026-07-09.

---

## Findings

### F1 (P1) — Split pane renders markdown → HTML inside `body`, on main, per keystroke

- **Files:** `Sources/ViewerUI/SplitPaneView.swift:184-198` (render in body), `:27-35` (observation), `:59-63` (stat in body); contrast `Sources/ViewerUI/DocumentModel+RenderedCache.swift:16-50`.
- **Evidence:**
  - `SplitPaneView.textContent` (a `@ViewBuilder` computed inside `body`) calls `HTMLRenderer().renderPage(body, stylesheet:extraStylesheet:)` inline (`SplitPaneView.swift:191`). This is the full markdown→HTML pipeline — pulldown-cmark via FFI **plus per-code-fence syntax highlighting** — synchronous on the main thread, re-executed on **every SwiftUI invalidation** of the split pane.
  - The view intentionally observes `TabCoordinator` so that it "re-bodies the split on each keystroke so unsaved edits appear here" (`SplitPaneView.swift:29-34`). So with a dirty markdown buffer open in the main pane and the same file in the split, **every 200 ms change flush re-runs the whole markdown render on main**.
  - The main pane learned this lesson already: `DocumentModel+RenderedCache.swift:57-63` documents TSK-611 — "the inline cold render — markdown→HTML plus the per-language TreeSitter `ts_query_new` compile for code fences — blocked the main thread for ~927 ms inside a layout pass". The split pane bypasses that cache entirely (the header comment at `SplitPaneView.swift:18` even admits "State is recomputed on every render (no caching)").
  - Bonus: `isSplitFileTooLargeForSyncRead` (`SplitPaneView.swift:59-63`) performs a `FileManager.attributesOfItem` stat syscall inside `body` per re-eval.
- **Impact:** with split view + markdown, typing latency degrades linearly with document size; a few-hundred-KB markdown file with code fences makes every debounce window a multi-frame main-thread stall (same mechanism as the measured 927 ms cold case). Even without editing, any DocumentModel/TabCoordinator publish re-renders the split's HTML.
- **Suggested fix:** route the split pane through the existing `renderedHTMLIfCached`/`requestRenderedHTML` machinery (key by URL + content hash instead of tabID), or memoize `(text, stylesheet) → html` in a `@State` cache updated in `.task(id:)`/`.onChange` — never inside `body`. Move the stat into the existing `.task(id: url)` load.
- **Fix size:** M · **Fix risk:** careful (cache keying must respect the dirty-buffer text path, TSK-806/922 history here).

### F2 (P1) — CM6 keystroke path round-trips the ENTIRE document over FFI per change flush; the O(delta) API exists but is dead code

- **Files:** `Sources/ViewerUI/CodeMirrorEditorView.swift:920-947`; `Sources/RustCore/CoreClient.swift:716-741` (`mdvCoreApplyCMEdits` — used) vs `:765-` (`mdvCoreApplyCMEditsDelta` — **zero call sites**); `Sources/ViewerCore/RustCMEditAdapter.swift:16-35`; JS debounce `Sources/ViewerUI/Resources/codemirror/codemirror.html:121` (200 ms).
- **Evidence:**
  - On every `.incrementalChange` (one per 200 ms typing window), the WKScriptMessage handler — **on the main thread** — calls `RustCMEditAdapter.apply(edits, to: base)` where `base` is the full document (`CodeMirrorEditorView.swift:929-933`). `mdvCoreApplyCMEdits` MessagePack-encodes the **entire base string** into the request frame (`CoreClient.swift:730`), Rust decodes it, applies the edits, and returns the **entire new document**, which Swift decodes into a new `String`. That is ≥4 full-document copies + 2 full-document msgpack passes per keystroke window, all on main.
  - The incremental protocol exists precisely to avoid "marshalling the entire doc on every keystroke debounce" across the JS→Swift IPC (`CodeMirrorEditorView.swift:924-926`) — but the saved IPC cost was re-spent on the Swift→Rust seam.
  - `mdvCoreApplyCMEditsDelta` (`CoreClient.swift:765`) returns only a changed region + length — built for exactly this — and `rg` finds **no callers anywhere in Sources/**.
  - Downstream of the apply, the same flush does: `lastSentText` full-string replace, `CoreDocShadow.mirror` (plus a **full text equality compare every 16th batch**, `Sources/ViewerCore/CoreDocShadow.swift:86-87`), `onTextChange` → `EditorCoordinator.updateEditorText` with `buf.text == newText` (O(n) when lengths match) and `buf.isDirty` (`text != originalText`, O(n) when lengths match — `Sources/ViewerCore/EditorBuffer.swift:67-69`), then the spell pass (F3) and the fold re-parse.
  - Amplifier: when `MDV_REMOTE_SOCKET` attaches a remote core (`RemoteCoreAttach`), this full-document frame goes over a **unix socket** per flush.
- **Impact:** typing in a large source file (the app advertises multi-hundred-MB text support; the editor path realistically sees multi-MB files) costs O(document) CPU + allocations on the main thread per 200 ms window instead of O(edit). This is the "keeps feeling laggy on big files" class.
- **Suggested fix:** keep the authoritative document in the core (rope/piece-table, seeded once per open/resync), send only edits, and adopt `mdvCoreApplyCMEditsDelta` (or a stateful `cm_apply_stateful`) so Swift patches its `String` locally from the changed region. The full-text `change` path stays as the drift-recovery fallback.
- **Fix size:** L · **Fix risk:** careful (doc-shadow S3 integrity checks and drift-recovery semantics must be preserved; good test surface exists in `EditorPerfBench` and shadow tests).

### F3 (P2) — Full-document synchronous spell-check on the main actor per change flush

- **Files:** `Sources/ViewerUI/Coordinators/EditorCoordinator.swift:731-748` (pass), `:711-713` (200k cap); `Sources/ViewerCore/SpellCheckEngine.swift:97-101`; `Sources/ViewerCore/MarkdownSpellMask.swift`.
- **Evidence:** `updateEditorText` (`EditorCoordinator.swift:565`) calls `runEditorSpellPass` on every text change. For prose files ≤200 000 UTF-16 units it synchronously runs `SpellCheckEngine(...).misspelledSpans(in: text)` — an `NSSpellChecker.checkSpelling` **iteration over the whole document** — plus `MarkdownSpellMask.filterProse` (another full-text scan) — on the `@MainActor` coordinator, once per 200 ms typing window. No off-main hop, no incrementality (only the edited region needs re-checking), no cancellation.
- **Impact:** on a 200 KB markdown file, each flush spends main-thread milliseconds-to-tens-of-ms in spell-checking; stacked on F1/F2 in the same flush this is a visible typing hitch on exactly the app's core document type. The 200 KB cliff also means files just over the cap silently lose spell-check entirely rather than degrade.
- **Suggested fix:** debounce separately (spell can lag typing by 500 ms+), run the sweep off the main actor (NSSpellChecker's async `requestChecking(of:...)` or a detached task with the string value), and re-check only a window around the edit, merging with prior diagnostics.
- **Fix size:** M · **Fix risk:** careful (NSSpellChecker threading contract; diagnostic offsets must be remapped against concurrent edits).

### F4 (P2) — InteractionProfiler is built but wired to nothing; keystroke/tab-switch/palette/CSV/save paths carry no signposts

- **Files:** `Sources/ViewerCore/InteractionProfiler.swift` (whole file, TSK-1488); `Sources/ViewerUI/Observability/FrameRateMonitor.swift:54-98`; adoption evidence: `rg "InteractionProfiler\." Sources/` → **zero call sites** outside its own file (tests only: `Tests/ViewerCoreTests/InteractionProfilerTests.swift`).
- **Evidence:** the file header promises "which INTERACTION was janky … the live CADisplayLink feed, the on-screen debug HUD, and the vm-profile.sh capture are the render/VM tail" — none of that tail exists: `FrameRateMonitor` computes window-level `FrameStats` but never marks interactions; `InteractionKind` (openFile / switchTab / paletteKeystroke / searchScroll / renderUpdate / uiNavigation) is never instantiated in the app. Separately, `PerfSignpost` has only ~29 call sites app-wide; the per-keystroke pipeline (F2/F3), `CommandPaletteView.recomputeFiltered` (sync FFI rank per keystroke, `CommandPaletteView.swift:483-509`), `CSVTableView.reparse`, and the ⌘S save path have **no** signposts, so none of the issues in this report would show up in an `os_signpost` trace today.
- **Impact:** the owner's stated bar ("flag <60 fps interactions", "MEASURE, don't guess") cannot be met on the paths most likely to hitch; perf regressions land silently.
- **Suggested fix:** wire `InteractionProfiler` marks at the six `InteractionKind` seams (openResolved, tab select, palette onChange, CM6 change flush, renderedHTML request/land) fed by `FrameRateMonitor`'s CADisplayLink; add `PerfSignpost.withInterval` around `cm_apply`, the spell pass, `reparse()`, and `saveEditor`.
- **Fix size:** M · **Fix risk:** safe (measurement only; the no-op-when-disabled pattern already exists).

### F5 (P2) — DocumentModel god-observable: 90 `@Published` properties fanning out to 44 observing views

- **Files:** `Sources/ViewerUI/DocumentModel.swift` (90 `@Published`, count via `rg -c`); 44 files in `Sources/ViewerUI/` declare `@ObservedObject … DocumentModel`; `Sources/ViewerUI/ContentView.swift:7`.
- **Evidence:** `DocumentModel` is one `ObservableObject`, so **any** of the 90 published properties changing fires a single `objectWillChange` that invalidates every one of the 44 observing views' bodies. The team has already had to hand-sever hot channels (e.g. `editorBuffers` deliberately NOT forwarded into `DocumentModel.objectWillChange`, per `SplitPaneView.swift:29-32` "PERF #1 severed that to kill a republish storm"; `HighlightCacheActor` results deliberately bypass model publishing, `DocumentModel+Highlighting.swift:28-30`) — each severance is a bespoke patch on a structural problem.
- **Impact:** unrelated state changes (a status-bar field, a find count, a git chip) re-evaluate large view subtrees; each new `@Published` silently taxes every observer. Body re-evals are cheap-ish individually but this is the multiplier under F1's inline render.
- **Suggested fix:** migrate to the Observation framework (`@Observable`, macOS 14+) for per-property dependency tracking, or continue the SRP-slice direction by moving cohesive `@Published` clusters onto the existing sub-coordinators (the TabCoordinator/EditorCoordinator/FindCoordinator pattern is already proven here).
- **Fix size:** XL · **Fix risk:** careful (broad, mechanical, but publish-ordering bugs are this codebase's recurring race class — migrate slice by slice with the existing probes like `updateDerivedCalls`).

### F6 (P2) — CSV parse runs synchronously on the main thread per appear/text change

- **Files:** `Sources/ViewerUI/CSVTableView.swift:559-565` (`reparse()` → `RustCSVAdapter.parse(text)`), `:286-291` (`.onAppear { reparse() }` + onChange).
- **Evidence:** `reparse()` is called from `onAppear` and on `text` change and runs `RustCSVAdapter.parse(text)` inline on the main actor — the full CSV crosses the FFI and the full parsed result marshals back before the next frame. There is no size gate on this path (the 4 MB open watermark defers the *read*, but once loaded, the parse itself is main-thread). The row cache work after it (pre-lowercasing every cell for the global filter, `:140-145`) is likewise synchronous.
- **Impact:** opening a 10-50 MB CSV blocks main for the full parse + lowercase pass; every external file-watcher reload repeats it. The planned windowed-snapshot contract (Phase 1, BACKLOG) is the real fix; until then this is the biggest single-shot main stall left in the open path.
- **Suggested fix:** move parse to a detached task with a `.loading` placeholder (the split pane's TSK-922 pattern), keyed/cancelled by text identity; defer the lowercase index until the first filter keystroke.
- **Fix size:** M · **Fix risk:** safe (established off-main + identity-guard pattern exists in `materializeIfNeeded`).

### F7 (P2) — ⌘S save path does all IO + Local History snapshot work on the main actor

- **Files:** `Sources/ViewerUI/Coordinators/EditorCoordinator.swift:915` (`EditorWriter.save` sync write), `:980-981` (`localHistoryStore.snapshot` sync); `Sources/ViewerCore/LocalHistoryStore.swift:183-208`.
- **Evidence:** `saveEditor(forTabID:)` is `@MainActor` and synchronously: stats for the no-clobber guard, writes the whole buffer to disk, then calls `LocalHistoryStore.snapshot`, which does `createDirectory`, reads **all existing history records** in the dir, FNV-hashes the full content, **reconstructs the newest prior version through its diff chain** for the dedup compare (`:206-208`), scans the content twice more (`isProbablyBinary`, `looksLikeSecret`), and writes the record — all before ⌘S returns.
- **Impact:** save latency grows with file size *and* history-chain depth; on a slow/cloud-backed disk this is a visible beachball on a high-frequency user action (and `saveEditorOnBlur` makes it implicit).
- **Suggested fix:** keep the disk write synchronous (correctness), but move the entire Local History snapshot (explicitly best-effort by contract — "a snapshot failure must NEVER fail a save") to a detached task with a copied string.
- **Fix size:** S · **Fix risk:** safe (the store is already best-effort and self-contained).

### F8 (P2) — Dirty formatted buffers pretty-print on every body evaluation

- **Files:** `Sources/ViewerUI/DocumentModel+DisplayText.swift:26-44`; caller `Sources/ViewerUI/ContentView.swift:1257`.
- **Evidence:** `displayedText(for:)` is called from `ContentView.body`. For a **dirty** buffer in a formatted tab it deliberately bypasses the format memo ("its cache key is the on-disk (length, mtime)") and runs `Formatter.prettyPrint(live, as: format)` — a full parse+re-serialize of the document — on the main thread on **every body re-eval**, plus `live.utf8.count`/`pretty.utf8.count` O(n) walks.
- **Impact:** editing a formatted JSON/XML view of a multi-MB file turns every publish into a full pretty-print; combined with F5's fan-out this compounds.
- **Suggested fix:** extend the memo key with a cheap content version (the editor buffer generation counter or text length + a mutation counter) so dirty text is memoized too.
- **Fix size:** S · **Fix risk:** careful (key must invalidate on every real edit; a stale pretty-print is a correctness bug).

### F9 (P3) — Diff view: undebounced per-keystroke find recompute + on-main diff parse

- **Files:** `Sources/ViewerUI/Git/DiffView.swift:114-126`.
- **Evidence:** `.onChange(of: findQuery) { recomputeFind(query:) }` runs `DiffFind.matches(in: files, query:)` — a linear scan over every line of every parsed file — synchronously per keystroke with no debounce (contrast `CSVTableView`'s `findDebounceTask`). `.onAppear`/`.onChange(of: text)` run `RustDiffAdapter.parse(text)` on main.
- **Impact:** find-as-you-type in a large diff (monorepo-scale `git show`) hitches per character; the parse stall happens once per diff open.
- **Suggested fix:** copy the CSV find debounce (150-250 ms task) and parse off-main with a loading placeholder.
- **Fix size:** S · **Fix risk:** safe.

### F10 (P3) — Hex dump chunk pipeline builds NSAttributedString inside the main-thread hop

- **Files:** `Sources/ViewerUI/HexView.swift:767-799`.
- **Evidence:** the chunked builder's backpressure `DispatchQueue.main.sync` block constructs the `NSFont` and the `NSAttributedString(string:attributes:)` for each chunk **on main** (`:782-789`) before appending; only the `appendChunk` needs the main actor. The attributed-string construction (string copy + attribute dict) is pure and could run on the producer thread.
- **Impact:** for a large binary the main thread absorbs the attributed-string build cost of every chunk during the initial dump build — background scrolling jank while a hex tab loads.
- **Suggested fix:** hoist the font once and build the `NSAttributedString` on the detached task; `main.sync` only the append.
- **Fix size:** S · **Fix risk:** safe (NSAttributedString construction without a layout manager is thread-safe).

### F11 (P3) — Local History "current content" closure reads the file from disk inside `DispatchQueue.main.sync`

- **Files:** `Sources/ViewerUI/DocumentModel+FileHistory.swift:85-100` and `:136-148`.
- **Evidence:** the `currentContent` closure hops to main and, when no live buffer exists, runs `try? String(contentsOf: url, encoding: .utf8)` **inside** the main-thread block — a full synchronous disk read on the UI thread each time the history diff loads the "current" side.
- **Impact:** user-invoked (history viewer), so frequency is low — but a large file on a slow volume beachballs the whole app while a background task waits on main doing its IO for it. Inverted priorities: main should only be used for the buffer lookup.
- **Suggested fix:** read the buffer text on main; fall back to the disk read **outside** the main.sync (the URL is Sendable).
- **Fix size:** S · **Fix risk:** safe.

### F12 (P3) — `.diff`/`.patch` highlight runs recomputed on every call, bypassing the highlight cache

- **Files:** `Sources/ViewerUI/DocumentModel+Highlighting.swift:37-44`.
- **Evidence:** `highlightRuns(...)` returns `DiffHighlighter.highlight(text)` for diff/patch files **before** the `HighlightCacheActor` lookup — an O(n) line-prefix walk re-run on every SwiftUI body re-eval that asks for runs, while every other language gets the actor cache.
- **Impact:** large `.patch` files re-highlight per body invalidation (per F5, that's frequent). Bounded by the source-view's own attr-key dedupe downstream, but the runs array is still rebuilt + rediffed each time.
- **Suggested fix:** cache the diff runs under the same `(url, length, mtime)` key (no actor needed — a small dictionary beside the memo patterns already in this file).
- **Fix size:** S · **Fix risk:** safe.

### F13 (P3) — Fold re-parse fires per change flush without a debounce of its own

- **Files:** `Sources/ViewerUI/DocumentModel+EditorBuffer.swift:47-49`; `Sources/ViewerUI/DocumentModel.swift:1230-1265`.
- **Evidence:** `updateEditorText` calls `refreshEditorFolds()` on every CM6 flush; it cancels the prior task and kicks a detached **full-document tree-sitter parse** (Rust fold engine) per 200 ms window. Off-main (good), but the work is O(doc) per flush and the result is only consumed by the fold gutter + sticky headers — cancellation helps only if the next flush arrives before the parse finishes.
- **Impact:** background CPU burn proportional to doc size during continuous typing (battery/thermals; contends with the same cores the highlighter needs). Not a main-thread stall.
- **Suggested fix:** add a ~500 ms debounce inside `refreshEditorFolds` (folds lagging typing by half a second is imperceptible), or reuse the core's incremental parse state once F2's stateful doc lands.
- **Fix size:** S · **Fix risk:** safe.

---

## Positive observations (keep doing these)

- **Off-main large open with identity guards** — `DocumentModel.openResolved` stats first and defers reads >4 MB (`TextFileLoader.deferReadOffMainBytes`, `TextFileLoader.swift:194`) to a detached task with cancel + re-find-by-id (`DocumentModel.swift:2307-2360, 2539+`). The split pane got the same treatment (TSK-922).
- **Rendered-HTML pipeline** — cache-only body reads + off-main cold render (TSK-611), LRU with mounted-aware eviction that avoids WKWebView dismantle churn (TSK-621/108), morphdom patch instead of `loadHTMLString` when eligible (`MarkdownRenderedView.swift:347-361`).
- **Persistence** — `JSONFileStore` coalesced serial write queue with off-main encode and terminate-only `flushSync` barriers; `SessionStore`'s fixpoint drain is a textbook quit-flush (`SessionStore.swift:302+`); session trash GC explicitly deferred off the launch path (`SessionsAppCoordinator.swift:180-188`).
- **Startup** — grammar query compiles prewarmed off-main, markdown first then parallel (TSK-619/840, `main.swift:280-297`); LSP pool start fire-and-forgotten; plugin grant prompts deferred past first frame.
- **Source view discipline** — receipts for fixed body-re-eval hot paths: attribute-only repaint instead of `setAttributedString` (`TextDisplayView.swift:1155+`), find temp-attr skip gating (`:369-378`), selection-highlight throttle (`:412-418`), O(1) `utf8.count` over `NSString.length` (`DocumentModel+Highlighting.swift:46-49`).
- **Sidebar** — off-main readdir/stat/sort (`SidebarModel.swift:303, 323`) with a bounded sorted-cache (`:598-615`); FSEvents (not polling) via `FolderWatcher`.
- **Diff gutter** — debounced, cancellable, timeout-bounded off-main `git diff` per quiescent window (`DocumentModel+GitDiffGutter.swift:63-74`).
- **Terminal** — a dedicated `FrameThrottle` exists for output coalescing.
- **Perf culture artifacts** — `PerfSignpost` no-op-by-default design, `EditorPerfBench`, `NavSweep`, `vm-profile.sh`, and bench-in-gate wall-clock asserts.

## Coverage gaps (not examined)

- **Runtime measurement:** no profiling was run (VM lanes out of scope for this pass); every "cost" above is code-shape reasoning plus the codebase's own recorded measurements (e.g. TSK-611's 927 ms). The F1/F2/F3 cluster deserves an `xctrace` capture on the VM to size wins before/after.
- **Rust core internals** (`rust-core/crates/*`): algorithmic complexity inside the engines (find, csv, markdown, cm_edit rope-vs-string internals) was not audited — only the FFI boundary shape.
- **WKWebView/JS side**: CM6 extension costs, mermaid render, morphdom patch cost profiles — only the Swift-visible seams were reviewed.
- **LSP client traffic**, **MCP automation path** (`MCPSocketBridge` has uncommitted working-tree changes — deliberately not reviewed), **Canvas**, **Terminal PTY read loop internals**, **memory footprint** (this pass was latency-focused; `process_memory`/footprint budgets not audited).
- **Startup wall-clock**: `sessions.bootstrap()`/`core.restore()` synchronous snapshot decode at launch looked bounded (single index + one snapshot, size-capped) but was not measured; no launch→first-frame signpost exists to check it (folded into F4).
