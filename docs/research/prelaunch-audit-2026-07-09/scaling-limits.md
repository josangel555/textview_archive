# Pre-launch audit — Scaling bottlenecks & boundaries

**Dimension:** Behavior at extremes — 1 GB files, 10k-line docs, 500 tabs, giant
sessions, unbounded caches/history growth, memory ceilings. Where are the missing caps?

**Date:** 2026-07-10
**Reviewer:** scaling-limits agent (static analysis, read-only)

---

## Executive summary

The codebase is, on the whole, **unusually disciplined about caps** for a project of
this size. Almost every hot path I examined has an explicit, documented ceiling with a
rationale comment and (usually) a host test: the text loader stat-refuses before it
allocates (`TextFileLoader`), the automation/MCP surface truncates every list result and
`visible_text` payload, cross-file search halts the walk at `maxResults`, the CSV bridge
switches to windowed frame assembly above 4 MiB, the syntax-highlight and rendered-HTML
caches are LRU/insertion-order bounded, the source-view heavy `NSTextStorage` controllers
are held to an LRU-4 / 64 MiB budget, and per-tab caches are purged on close. This is a
strong baseline and most "obvious" extreme-input crashes are already defended.

The gaps that remain are concentrated in **long-horizon unbounded growth** and **a few
in-memory materializations with no cap** rather than in the acute single-open path:

- **No cap on the number of concurrently open tabs in a live session** — restore is
  capped at 200, but interactive opening (`openOrReveal`) appends without limit, and each
  `Tab` retains the file's **full `String` contents**. The 500-tab scenario is genuinely
  uncapped for raw-content memory (only the heavy laid-out glyph stores are LRU-bounded).
- **Local History has no *global* cap** — a strict 20 MiB *per-file* cap, but the number
  of per-file history directories grows one-per-file-ever-edited with no age/count sweep
  and no dead-file GC. Unbounded disk over months/years.
- **The sidebar file tree materializes *every* child of an expanded directory** with no
  cap — a `node_modules` / data dir with 100k+ entries builds 100k `FileNode`s (each doing
  symlink resolution) in one synchronous pass.
- **`git status` buffers up to 512 MiB** of subprocess output in memory.

Severity: **0 × P0, 0 × P1, 5 × P2, 2 × P3.** No ship-blockers found on this dimension —
the acute paths fail safe (clean refusal, not crash). The findings are quality/robustness
caps that matter for a tool that will be left running for weeks with hundreds of files.

---

## Methodology

Static analysis only (per constraints — no window-opening tests). What I examined:

- **File-open / read path:** `TextFileLoader.swift` (full read), `BinaryFileLoader.swift`,
  `TextDecoder`, `RustCSVAdapter.swift`, `Archive/ArchiveCatalog.swift`,
  `ClaudeSessionIndex.swift` (transcript streaming).
- **Display caps:** `TextFileLoader` (`sourceViewMaxBytes` / `readableMaxBytes` /
  `softWarnBytes`), `Highlight/HighlightRun.swift` (`markdownRenderMaxBytes`),
  `HTMLDocumentPolicy.swift`, `TextDisplayView.swift` (UTF-16 storage cost).
- **Tabs & retention:** `TabsState.swift`, `Tab.swift`, `Coordinators/TabCoordinator.swift`,
  `DocumentModel.purgeCaches`, `DocumentModel+TabCloseVariants.swift`.
- **Caches (eviction policy):** `InsertionOrderedCache.swift`, `SourceControllerCache.swift`,
  `DocumentModel+RenderedCache.swift`, `Highlight/HighlightCacheActor.swift`,
  `Highlight/TreeSitterEngine.swift`, `Highlight/GrammarLoader.swift`,
  `WarmWebViewCache.swift`. Confirmed **zero** `NSCache` usage repo-wide.
- **Persistent stores / growth:** `HistoryStore.swift`, `LocalHistoryStore.swift` +
  `LocalHistoryPolicy.swift`, `Sessions/SessionStore.swift`.
- **Walk / subprocess:** `FileTreeService.swift`, `CrossFileSearch.swift`,
  `Git/GitClient.swift`, `ProcessRunner.swift`.
- **Agent surface:** `Automation/MCPToolCatalog.swift`, `Automation/CodeNav.swift`.

Roughly ~40 source files read in whole or part; caps cross-checked against their
rationale comments and the `TSK-####` history embedded in them.

---

## Findings

### F1 — No cap on concurrently open tabs; each tab retains the full file `String`

- **Severity:** P2
- **File:** `Sources/ViewerCore/TabsState.swift:180-237` (`openOrReveal`, unconditional
  `tabs.append`), `:146` (`maxRestoredTabs = 200`, applies to *restore only*);
  `Sources/ViewerCore/Tab.swift:217` (comment: `state` contains `TextFile.contents`, a
  full-file `String`).
- **Evidence:** `maxRestoredTabs` (200) and `dedupedRestoreTabs` bound only the
  *restore-from-disk* path. The interactive open path (`openOrReveal`, `openPreview`,
  `TabCoordinator.append`) appends with no ceiling. Each `Tab.state` (a `DocumentState`)
  holds the loaded `TextFile`, whose `contents: String` is the entire file. The heavy
  laid-out `NSTextStorage`/`NSLayoutManager` glyph stores *are* LRU-capped
  (`SourceControllerCache`, 4 controllers / 64 MiB), but the raw content `String`s in each
  open `Tab` are **not** — they persist for every open tab.
- **Impact:** The "500 tabs" scenario. Open 500 files averaging 2 MiB and ~1 GiB of raw
  `String` content sits resident regardless of the glyph-store LRU. Also O(tabs) work on
  every tab-strip re-eval. Not a crash for typical sizes, but the exact "missing cap" the
  lens targets, and it degrades unbounded.
- **Suggested fix:** Add an interactive open-tab soft cap (e.g. auto-close the LRU
  *clean, non-pinned* tab past N, or evict the *contents* of far-offscreen tabs to a lazy
  `.empty` state that re-reads on reveal — the restore path already models lazy tabs).
- **Fix size:** M · **Risk:** careful (touches dirty/unsaved-tab lifecycle; must never
  evict a dirty buffer).

### F2 — Local History: strict per-file cap but **no global** disk cap or dead-file GC

- **Severity:** P2
- **File:** `Sources/ViewerCore/LocalHistoryStore.swift:82` (`maxFileHistoryBytes = 20 MiB`,
  *per file*), `:450` (`pruneUnderByteCap(in dir:)` — prunes *within one file's dir*);
  `Sources/ViewerCore/LocalHistoryPolicy.swift:29`. `allTrackedPaths()` (`:286`) enumerates
  every per-file dir but there is no corresponding global pruner.
- **Evidence:** History is keyed by a one-way hash of the file path → one directory per
  file ever edited under the history root. Pruning is entirely *per-directory* against the
  20 MiB cap. There is no global ceiling on the number of directories, no age-based sweep
  ("drop files not touched in N days"), and no dead-file GC (a directory survives after its
  source file is deleted — `clear(for:)` exists but is only called explicitly). `HistoryStore`
  (recents) has a `pruneMissing`; `LocalHistoryStore` has no equivalent.
- **Impact:** A user editing thousands of distinct files over months accumulates thousands
  of history dirs, each up to 20 MiB — potentially tens of GiB of Application Support disk,
  never reclaimed except via `File → Reset`. Silent, unbounded disk growth.
- **Suggested fix:** Add a global budget (total-bytes and/or dir-count cap, LRU by last
  snapshot mtime) run opportunistically at launch, plus a dead-file sweep that drops dirs
  whose `_path` sidecar no longer resolves.
- **Fix size:** M · **Risk:** careful (deletes user-recoverable history — must be
  conservative and keep newest-per-file).

### F3 — Sidebar file tree materializes *all* children of an expanded directory (no cap)

- **Severity:** P2
- **File:** `Sources/ViewerCore/FileTreeService.swift:50-84`.
- **Evidence:** `contentsOfDirectory(at:includingPropertiesForKeys:options:)` pulls the
  entire directory listing, then `contents.map { ... }` builds a `FileNode` for **every**
  child, each calling `standardizedFileURL.resolvingSymlinksInPath()` (a syscall) plus a
  `resourceValues` fetch. No `prefix`, no lazy windowing, no count guard.
- **Impact:** Expanding a directory with 100k+ entries (a `node_modules`, a
  build-output/data dir, `~/Downloads`) does 100k+ symlink-resolutions synchronously and
  holds 100k `FileNode`s in memory, per expand. Sidebar stall + memory spike. `CrossFileSearch`
  (the *search* walk) is capped at `maxResults`; the *tree display* walk is not.
- **Suggested fix:** Cap children per directory (e.g. first N, with a "… n more" sentinel
  row / "show all" affordance), or page the listing. Consider dropping the per-child symlink
  resolution to a lazy step.
- **Fix size:** M · **Risk:** safe (additive cap + sentinel; existing behavior below the cap).

### F4 — Large text files: ~2× resident cost, no paging; near-ceiling opens are heavy

- **Severity:** P2
- **File:** `Sources/ViewerCore/TextFileLoader.swift:149-168` (`readableMaxBytes = 512 MiB`
  hard ceiling; doc explicitly accepts "~1.5–2× file-size resident cost … as the documented
  v1 tradeoff"), `:163-167` (true mmap/paged pager is a *deferred* follow-up);
  `Sources/ViewerUI/TextDisplayView.swift:260-263` (`utf16Len * 16` bytes — the laid-out
  store is ~16 B/char).
- **Evidence:** The whole file is slurped into a single Swift `String`, then bridged into a
  UTF-16 `NSTextStorage`; the loader's own docs put the resident cost at 1.5–2× file size,
  and `TextDisplayView` estimates the *laid-out* store at ~16 B/char. There is no
  `Data(.mappedIfSafe)` / line-indexed pager — noted as deferred. The **1 GiB file** claim
  is *not* supported: files above 512 MiB are cleanly stat-refused (`:228`,
  `FileLoadError.tooLarge`) — good failure mode, but not "handled".
- **Impact:** A 300–500 MiB log opens read-only but costs ~0.6–1.2 GiB resident; on a
  memory-constrained machine this risks pressure/termination. The hard ceiling prevents the
  true OOM (multi-GB slurp), so this is degradation-at-extreme, not a crash. `isLargeReadOnly`
  (>64 MiB) correctly sheds the O(N)-per-interaction overlays, which mitigates interactivity
  but not the base resident cost.
- **Suggested fix:** Prioritize the deferred mmap/line-indexed pager for GB-class read-only
  viewing (bounded RAM + jump-to-line + SIGBUS lifecycle). Until then, consider lowering the
  512 MiB ceiling or surfacing the resident-cost expectation in the too-large UX.
- **Fix size:** XL (real pager) · **Risk:** careful (new SIGBUS/lifecycle surface).

### F5 — `git status` buffers up to 512 MiB of subprocess output in memory

- **Severity:** P3
- **File:** `Sources/ViewerCore/Git/GitClient.swift:1376` (`maxOutputBytes: 512 * 1024 * 1024`).
- **Evidence:** Status is invoked with a 512 MiB `maxOutputBytes` ceiling into
  `ProcessRunner`, which accumulates stdout/stderr in memory up to that cap
  (`ProcessRunner.swift:187-283`). `git log` is sensibly bounded (`maxEntries: 50`,
  `GitClient.swift:344`), but status is not row-capped — only byte-capped at a very high
  ceiling.
- **Impact:** On a pathological working tree (millions of untracked paths, a huge
  generated/`node_modules` tree not ignored) the status buffer can balloon to ~512 MiB
  resident before the overflow flag trips. Bounded, but the ceiling is far above any useful
  status payload.
- **Suggested fix:** Drop the status `maxOutputBytes` to a realistic ceiling (a few MiB) and
  treat overflow as "repo too large — status suppressed", or cap the parsed entry count.
- **Fix size:** S · **Risk:** safe.

### F6 — No global cap on the number of persisted sessions

- **Severity:** P3
- **File:** `Sources/ViewerCore/Sessions/SessionStore.swift:229-244` (`recoverableSnapshots`
  caps the *orphan-recovery UI* list at `maxCount: 24`, not the store);
  `:339-343` (`purgeTrash` drops *trashed* snapshots older than N days).
- **Evidence:** The index-file *size* is capped (`maxIndexFileSize = 4 MiB`, `:63`) and trash
  is age-pruned, but I found no cap on the count of *live* persisted sessions / per-session
  snapshot files nor an age sweep for non-trashed sessions. The 4 MiB index-size cap is an
  indirect backstop (a corrupt/huge index is refused) rather than a growth policy.
- **Impact:** "Giant sessions" scenario — a user who never manually deletes sessions
  accumulates unbounded per-session snapshot files on disk; eventually the index approaches
  its 4 MiB refusal ceiling (at which point restore may degrade). Slow-moving, low blast.
- **Suggested fix:** Add a session-count / total-bytes cap with LRU eviction of the oldest
  *non-pinned* sessions, mirroring the recents `maxEntries` policy.
- **Fix size:** M · **Risk:** careful (evicts user session state — needs a pin/keep concept).

### F7 — `FileTreeOps` rename/collision retry loop caps at 10,000 attempts (minor)

- **Severity:** P3
- **File:** `Sources/ViewerCore/FileTreeOps.swift:29` (`maxAttempts: Int = 10_000`).
- **Evidence:** The dedup-name generator ("file 2.txt", "file 3.txt", …) tries up to 10k
  suffixes. This is a *cap* (good — no infinite loop), but at the boundary it does up to 10k
  `fileExists` stats synchronously before giving up.
- **Impact:** Negligible in practice (nobody has 10k same-stem collisions); flagged only for
  completeness as an O(N)-stat boundary. The cap itself is correct.
- **Suggested fix:** None required; optionally switch to a random/uuid suffix past a small
  linear probe to avoid the stat storm at the boundary.
- **Fix size:** S · **Risk:** safe.

---

## Positive observations

The following are genuinely well-handled and should **not** be "fixed":

- **Text loader fails safe at the boundary.** Stat-first refusal (`TextFileLoader.swift:228`)
  throws `.tooLarge` *before* allocating; the ceiling is documented as an OOM backstop, and
  the error carries the ceiling for a truthful message. No multi-GB slurp is possible.
- **Two-tier soft/hard watermark.** `softWarnBytes` (64 MiB) → `isLargeReadOnly` sheds
  O(N)-per-interaction overlays (newline index, selection highlight, pretty-print) and forces
  the no-alloc plain path, keeping large logs interactive (`TextFileLoader.swift:35-51`).
- **Layered display caps that are the union at the funnel, min downstream** — `sourceViewMaxBytes`
  (64 MiB) ≥ `codeMirrorEditorMaxBytes` (50 MiB) ≥ `markdownRenderMaxBytes` (4 MiB) ≥
  `highlightMaxBytes` (512 KiB), with a rationale for why the loader cap must be the max
  (`TextFileLoader.swift:126-144`). Deliberate, not accidental.
- **Automation / MCP surface is thoroughly truncated** — every list result carries a
  `truncated` flag, `searchFilesResultCeiling` clamps agent-requested `maxResults`,
  `visible_text` byte-caps at a UTF-8 boundary, `CodeNav` caps callers/refs
  (`MCPToolCatalog.swift:540-760`, `CodeNav.swift`). Agents cannot firehose the process.
- **Cross-file search halts the walk at `maxResults`** and skips descendants of ignored dirs
  (`CrossFileSearch.swift:41-260`).
- **CSV bridge switches to windowed frame assembly above 4 MiB** to stay under the 16 MiB FFI
  frame cap, in bounded `assemblyChunkRows` (20k) windows (`RustCSVAdapter.swift:79-111`) —
  no giant single frame, no silent empty-grid degradation.
- **Caches are bounded with survivor-preserving eviction, not wipe-on-overflow** —
  `InsertionOrderedCache` (batch-evict to 2/3), `HighlightCacheActor` (LRU-8 per tab),
  rendered-HTML cache (mounted-aware LRU), `SourceControllerCache` (LRU-4 / 64 MiB byte
  budget with real `NSTextStorage` teardown on eviction). No unbounded plain dictionary in
  the hot display paths; **no `NSCache` reliance** (explicit, testable eviction instead).
- **Per-tab caches are purged on close** — `purgeCaches(forURL:tabID:)` drops the highlight
  actor, rendered-HTML entries, hosted views, LSP diagnostics, and the source controller
  (`DocumentModel.swift:3324-3380`), with a documented, deliberate exception (LSP version/hash
  bookkeeping left to a real `didClose`).
- **Recents (`HistoryStore`) is fully capped** — `maxEntries: 100`, a `maxStoreFileBytes`
  guard that refuses a tampered 10M-entry file *before* it inflates into memory, lenient
  per-entry decode, and a `pruneMissing` dead-file sweep (`HistoryStore.swift:52-135`).
- **Claude transcript index streams in fixed chunks** with a per-line `maxLineBytes` cap —
  bounded memory over arbitrarily large JSONL transcripts (`ClaudeSessionIndex.swift:231-313`).
- **Restore is deduped and count-capped** (`TabsState.dedupedRestoreTabs`, `maxRestoredTabs
  = 200`) — a corrupt/enormous persisted tab list cannot blow up launch.
- **`git log` is entry-capped** (`maxEntries: 50`), archive entries are byte-capped
  (`ArchiveCatalog.maxEntryBytes = 64 MiB`), hex/binary loader is byte-capped (4 MiB).

---

## Coverage gaps (not examined / examined only shallowly)

- **Rust core internals under extreme input** — I read the Swift-side bridges
  (`RustCSVAdapter`, FFI frame caps) but did **not** audit the `rust-core/crates/core`
  engines (markdown, formula, diff, nav, canvas DSL) for internal allocation ceilings on a
  10k-line / pathological input. The FFI *frame* is capped at 16 MiB; the engines' *internal*
  working-set on a huge parse tree (e.g. a deeply nested markdown/canvas doc) was not
  measured.
- **Runtime memory profiling** — this is static analysis only. Actual resident-memory
  behavior of the 500-tab / 400 MiB-file scenarios (F1, F4) was **not** measured on device;
  the numbers are derived from the code's own cost comments (`utf16Len * 16`, "1.5–2×").
- **Terminal scrollback** — I did not locate a single owning scrollback buffer with an
  explicit ring/line cap; terminal rendering appears delegated (tmux control-mode
  `TmuxControllerCore`) and I could not confirm a bounded scrollback within the time box.
  Worth a dedicated look for the "long-running terminal" extreme.
- **LSP server memory** — `LSPPool` per-file version/hash bookkeeping is intentionally not
  purged on tab close (documented in `purgeCaches`); I did not assess whether it grows
  unbounded over a long session with many files opened.
- **Canvas DSL** — the large `canvas/` engine and its MCP tools (`canvas_apply`, timeline,
  undo history) were not examined for undo-stack / timeline growth caps.
- **Mermaid / WebView diagram count** — no assessment of a markdown doc with thousands of
  mermaid blocks (per-diagram WebView cost).
- **Image editing** — `ImageDocument` op-stack / undo growth on a large image was not
  reviewed.
