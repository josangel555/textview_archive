# Memory & CPU Accounting — every byte, every cycle

**Date:** 2026-06-01 · **Platform verified:** `Darwin 25C56 / macOS 26.2`, arm64e · **Bundle:** `dist/TextView.app` · **Modules:** `ViewerKit ← ViewerCore (SwiftUI-free) ← ViewerUI ← MarkdownViewer`

> Scope: this is the **memory + cycle attribution** companion to the separate `os_signpost` speed-profiling workflow. It does **not** duplicate signpost timings; it accounts for *which bytes are resident and why* and *what runs when*, and specifies the regression harness to build after the speed lane lands. All `file:line` pointers were re-verified against the working tree on 2026-06-01; figures marked **(measured)** were read off the built bundle / on-disk assets this session.

---

## 0. The one mental model — three accounting layers, three owners

Two orthogonal questions, never conflate them:

**Who owns the byte?**
```
Is the byte in a com.apple.WebKit.* helper process?
   YES → WebKit's. Networking+GPU (~35 MB) unreclaimable until app quit.
         WebContent (30-80 MB/pool, up to 3 pools here) reclaimable only by closing
         all views in that pool AND WebKit deciding to reap. Activity Monitor SUMS it
         under our row — subtract before judging our heap.
   NO ↓
Is it a mapped page of a /System framework or /usr/lib/swift dylib (dyld shared cache)?
   YES → OS's. Shared COW across every process. Inflates `ps RSS`, ~excluded from
         phys_footprint. Effectively free; never "ours" to reclaim.
   NO ↓
Is it dirty malloc memory with no live object referencing it?
   reusable / madv_free → OURS but a CACHE. macOS-26 keeps it at idle; reclaimed on
                          pressure or reused by our next big alloc. Bounded by PEAK
                          (lever = #191), not idle footprint. NOT a leak.
   still referenced     → OURS, live. The only bytes a peak-bound / teardown moves.
```

**Which layer answers the question?**
```
 LAYER                WHAT IT MEASURES                          CANONICAL TOOL
 ──────────────────────────────────────────────────────────────────────────────
 Ledger / footprint   phys_footprint — what the kernel charges  footprint, task_vm_info,
                      you, incl. compressed+swapped, EXCL most  proc_pid_rusage,
                      shared/clean. THE budget number.          Activity Monitor "Memory"
 VM regions (pmap)    per-region dirty/resident/swapped/clean/  vmmap --summary,
                      reclaimable — WHERE footprint lives.      Instruments VM Tracker
 Heap (malloc)        individual live allocations + call stacks heap, leaks, malloc_history,
                      — WHO allocated it.                       Instruments Allocations
```

**Golden rule:** `phys_footprint` is what you budget and regress against. `resident_size` (and the Activity Monitor row) is a lie for budgeting — it counts shared-cache pages and double-counts XPC helpers, and it ignores compressed pages you *are* charged for. The other layers exist to *explain* a footprint number, not replace it.

The app already encodes this honest split in code — `Sources/ViewerCore/Observability/ProcessMemory.swift`:
- `appFootprintBytes()` (`:104`) reads `task_info(TASK_VM_INFO).phys_footprint` of **this** process only — explicitly excludes WebKit helpers.
- `webKitHelperFootprint()` (`:165`) walks every pid, matches the `com.apple.WebKit` exec-path marker, sums each helper's `ri_phys_footprint` via `proc_pid_rusage`, and reports it on a **separate** line — never folded into the app number.

---

## 1. The "~120 MB with 2 files" accounting

The trigger figure is almost certainly the **Activity Monitor row**, which sums the app's XPC children into the parent:

```
Activity Monitor "MarkdownViewer"  =  main proc  +  Networking  +  GPU  +  WebContent(s)
   (one collapsed row)                ~110 MB       ~10 MB        ~25 MB    ~30-80 MB each
                                      └─ OURS ──┘   └──────── NOT our heap ────────────┘
```

Two scenarios diverge sharply on whether WebKit is in play:

### Scenario (a): 2 plain source / text files — NO WebKit. If this is ~120 MB it is a REGRESSION.

Source/`.txt` tabs render in **NSTextView**, not WKWebView. No `WKWebView` is created, so **none** of the WebKit XPC floor exists. The honest breakdown:

| Bucket | Owner | Est. | Notes |
|---|---|---|---|
| dyld shared cache (AppKit/SwiftUI/Foundation/CoreGraphics + Swift runtime in `/usr/lib/swift`) | OS | counted in `ps RSS`, ~excluded from footprint | shared COW, effectively free |
| Main Mach-O `__TEXT`/`__LINKEDIT` (clean) | OS-ish | exec is **27,362,064 B (measured)** but mostly clean/file-backed | not in footprint |
| Main `__DATA_DIRTY`, SwiftUI/AppKit object graph (window+menu), CA/Metal window backing | ours (live) | ~30–45 MB | unavoidable AppKit window machinery |
| `TextFile.contents` × 2 (UTF-8 String) | ours (live) | ~1× file size each | trivial for typical source files |
| `NSTextStorage` UTF-16 glyph store, **visible tab only** | ours (live) | ~2× visible file in UTF-16 | released on deselect (`TextDisplayView.swift:150,454`) |
| TreeSitter grammar for the touched language (dlopen'd) | ours (live, permanent) | one grammar's pages, e.g. **478,912 B JS, 528,288 B Python (measured)** | only if source is a TS language ≤512 KiB |
| libmalloc dirty-reusable cache | ours (reclaimable) | bounded by peak | macOS-26 keeps at idle |

**Realistic footprint for 2 small source files with NO WebKit: roughly 40–70 MB `phys_footprint`.** If `footprint -j` on the **main process alone** shows ~120 MB for two plain text files, that is **a regression**, not the WebKit floor. Suspects to chase, in order:

1. **A WKWebView was created behind your back** — e.g. a markdown/HTML preview or the CM6 editor was instantiated for one of those "text" files (mode mis-detection), spawning Networking+GPU (~35 MB) you didn't expect. Confirm with `pgrep -f 'com.apple.WebKit'` — if any helper exists, this is the cause and it is *not* truly "2 plain files".
2. **A large file took the highlight/glyph path it should have skipped** — e.g. `isLargeReadOnly` not set, so the 512 KiB highlight cap (`TreeSitterEngine.swift:66`) and large-file `textView.string =` fast path (`TextDisplayView.swift:933`) didn't engage, leaving a full attributed-string allocation resident.
3. **The historical apply→publish→re-render RSS-growth loop** (`TextDisplayView.swift:302-309`) regressed — that bug grew RSS ~5 MB/s; it's dedup-guarded now (`:609`), but a guard regression would ratchet footprint. Check via repeated caret-move while watching `footprint --sample`.
4. **libmalloc dirty-page cache misread as live** — if footprint *plateaus* across open/close cycles it's the benign page cache, not a leak (see §3). Only a *ratcheting* footprint is a real regression.

> What the commands show: `footprint -j main.pid` → `total footprint` ≈ 40–70 MB and a `MALLOC_*` Dirty that doesn't climb across cycles. `vmmap --summary` → no `WebKit`/`com.apple.WebKit` regions, `__LINKEDIT` huge-but-clean (normal). `pgrep -f com.apple.WebKit` → **empty**. If any of those is violated, you've found the regression.

### Scenario (b): 1 rendered-markdown/HTML + 1 source — WebKit floor + WebContent dominate. ~120 MB is roughly in-envelope.

Opening the rendered markdown creates the first `WKWebView`, which spawns the WebKit XPC floor + a WebContent on first render:

| Bucket | Owner | Est. | Reclaimable? |
|---|---|---|---|
| Main process `phys_footprint` (window + both files' our-side state, §2) | ours | ~50–70 MB | live + bounded dirty cache |
| `com.apple.WebKit.Networking` | WebKit | ~10 MB | **NO** — app lifetime |
| `com.apple.WebKit.GPU` | WebKit | ~25 MB | **NO** — app lifetime |
| `com.apple.WebKit.WebContent` (markdown pool) | WebKit | +30–80 MB | only by closing all views in that pool *and* WebKit reaping |
| Mermaid runtime JS heap copy (WebKit side, per live web view) | WebKit | ~2.5 MB | with the WebContent |

Summed by Activity Monitor: `~60 (main) + ~35 (floor) + ~50 (WebContent startup) ≈ 145`, and a smaller resting WebContent lands the visible row near **~120 MB**. This matches `LESSONS.md:744-746` / `BACKLOG.md:325-328` ("TextView 230 MB" = ~110 main + ~35 helpers + ~80 WebContent; "only the 110 MB is in our code"). **Of the ~120 MB here, roughly a third (~35 MB) is the unreclaimable WebKit floor and a large chunk more is one WebContent's startup cost — neither is our heap.**

> What the commands show: `footprint -p MarkdownViewer -p com.apple.WebKit.WebContent -p com.apple.WebKit.GPU -p com.apple.WebKit.Networking -j out.json` → de-duplicated `total footprint` near the AM number, with each `phys_footprint` broken out so you can see the main process is the smaller share. `vmmap --summary` on the WebContent pid → DOM + JS heap in `MALLOC_*`, GPU helper shows `IOSurface`/`IOAccelerator` `iokit_mapped`.

**A real, under-documented finding for scenario (b): there are THREE independent `WKProcessPool`s, not one app-wide pool** (verified this session):
- `MarkdownRenderedView.swift:54` — `static let sharedProcessPool`
- `HTMLRenderedView.swift:71` — a **second** `static let sharedProcessPool`
- `CodeMirrorEditorView.swift:197` — a **third** (`config.processPool` assigned at `:159`)

WebContent processes are pooled **per pool**, not per app. A session that has touched a rendered `.md`, a raw `.html`, **and** the CM6 editor can be running **three** WebContent processes (+30–80 MB each) plus the shared floor — not the single WebContent the "2 files = 120 MB" mental model assumes. The "Shared WKProcessPool" note in `LESSONS.md:1015` is true *within* each view type but **overstated across the app**. A single app-wide `WKProcessPool` (e.g. on a `ViewerUI` namespace) would collapse the three WebContents into one. (For local `file://`-base `loadHTMLString` content — all three call sites — WebKit's site-isolation won't fork *additional* WebContents, so it really is one-per-pool.)

---

## 2. THE BYTE BUDGET — every significant consumer (our code)

> Phase-1 runs **one** `DocumentModel` for the whole app (`SessionsAppCoordinator.swift:16-27`); multi-session does **not** multiply per-tab state today. Per-session multiplication is a Phase-2 hazard (flag #6). The dominant resident cost of an open file is its `String` contents (per *open* tab) plus, for the *visible* tab only, the AppKit `NSTextStorage` UTF-16 glyph store.

### 2a. Per-open-tab state (retained for every tab, visible or not)

| Consumer | file:line | ~Cost | Bounded? | Purged when |
|---|---|---|---|---|
| `TextFile.contents` (full file, Swift `String`, UTF-8) | `TextFileLoader.swift:19` (loader at `Sources/ViewerCore/TextFileLoader.swift`), held in `Tab.state` (`Tab.swift:29`) | **~1× file size per open tab**; hard ceiling 512 MiB/file (`readableMaxBytes`, `:130`) | **YES** — 512 MiB hard cap; `softWarnBytes` 64 MiB (`:135`) flips `isLargeReadOnly` to skip O(N) overlays; tab COUNT capped 200 (`TabsState.maxRestoredTabs:146`) | `TabsState.close` releases `Tab`→`state`→String. Lazy tabs (`.empty`/`.loading`) hold no contents until selected (`appendLazyTab`, `DocumentModel.swift:2816`) |
| `BinaryFile.data` (HEX view raw bytes) | `BinaryFileLoader.swift:34,36` (`maxBytes` default 4 MiB) | **≤ 4 MiB per binary tab** (reads 1 byte past then drops, `:71-75`) | **YES** — 4 MiB cap, `isTruncated` banner | Tab close |
| `EditorBuffer` (`originalText` + live `text`) | `EditorBuffer.swift:28,31`; map `TabCoordinator.editorBuffers:117` | **~2× file size** for an *edited* tab (COW until first keystroke); load cap 32 MiB | **YES** — 32 MiB load cap; lazily seeded only in `.editor` mode | `cleanupAfterClose` (`TabCoordinator.swift:294`) `removeValue`; "Don't Save" discard |
| `NSTextStorage`/`NSLayoutManager` glyph store (UTF-16 + glyph runs) | `TextDisplayView.swift:150,454,478` | **~2× file size in UTF-16** for the **visible** source tab only — largest single cost for a big visible file | **YES (lifecycle)** — released on tab deselect (`:150,454`); large files take `textView.string =` fast path (`:933`) | Deselect releases glyph store; close releases NSTextView |
| Per-tab dicts: `csvFilterStates`, `hexBytesPerRow`, `languageOverrides`, `formattedTabIDs` | `TabCoordinator.swift:61-76` | Tiny (KB) | **YES** | `cleanupAfterClose:291` drops all four in lock-step |
| `materializeTasks` (in-flight file-read Tasks) | `TabCoordinator.swift:124` | Negligible | **YES** | `cancelMaterialize` in `cleanupAfterClose:292` |

### 2b. Per-tab caches (LRU / insertion-order bounded)

| Consumer | file:line | ~Cost | Bounded? | Purged when |
|---|---|---|---|---|
| `renderedHTMLCache` (rendered markdown HTML strings) | `DocumentModel.swift:1950`, cap `:1961` (`renderedHTMLCacheMax = 4`) | **~15–20 MB worst case** — each entry 2–5× source inflation | **YES** — cap 4, insertion-order evict to 2/3 (`:2059-2065`) | Evicts oldest at cap; `purgeCaches:2753` drops a closed tab's entries |
| `highlightCaches` (per-tab `HighlightCacheActor`, `[HighlightRun]`) | `DocumentModel.swift:1822`; actor `HighlightCacheActor.swift` | Small — runs are NSRange+kind; cap 8/tab; only files ≤512 KiB | **YES** — per-tab cap 8; engine refuses >512 KiB (`TreeSitterEngine.swift:66`) | `purgeCaches:2750` removes whole actor on close |
| `formattedTextCache` (pretty-printer output strings) | `TabCoordinator.swift:110`, cap `:112` (`= 8`) | **~1× formatted size × ≤8**; large read-only files skip formatting | **YES** — cap 8, insertion-order evict to 2/3 (`:436`) | `cleanupAfterClose:299` drops closed tab's entry |

### 2c. Subsystem singletons / engines (process-lifetime)

| Consumer | file:line | ~Cost | Bounded? | Purged when |
|---|---|---|---|---|
| `TreeSitterEngine.shared` per-language `Language` + compiled `Query` | `TreeSitterEngine.swift:31,39` | Compiled `Query` per touched language (tens–hundreds KB) | **NO explicit cap**, but bounded by fixed ~14-language enum; **never evicted** | **NEVER** — process-lifetime (flag #2) |
| **TreeSitter grammar dylibs (dlopen'd)** | `GrammarLoader.swift:97`; "intentionally never `dlclose` … for process lifetime" **`:167-171`** | **Each grammar's tables mapped on first use** — C# = **5,387,424 B (measured)**, the heaviest; total 11 lazy grammars ~16.9 MB on disk | **NO** — once dlopen'd, held for process lifetime by design (unmapping crashes parses) | **NEVER** — deliberate (flag #1) |
| `MermaidBundle.runtime` (mermaid.min.js as UTF-8 `String`) | `MermaidBundle.swift:17`; asset **2,571,900 B = 2.45 MiB (measured)** | **~2.45 MB resident**, lazy on first markdown render, held via `static let` | **YES (fixed)**, **NO purge** | **NEVER** once any markdown renders; each live WebView also holds its own JS-heap copy |
| CodeMirror `codemirror.js`/`.html` (`WKUserScript` source `String`) | `Resources/codemirror/codemirror.js` **622,203 B**, `.html` **48,591 B (measured)** | **~655 KB resident** once an editor tab opens | **YES (fixed)**, no purge | **NEVER** once any `.editor` tab opens |

### 2d. Stores (persisted, in-memory mirror)

| Consumer | file:line | ~Cost | Bounded? | Purged when |
|---|---|---|---|---|
| `HistoryStore.entries` | `HistoryStore.swift:47`, `maxEntries=100:52`, file cap 1 MiB | tens of KB | **YES** — 100 cap + 1 MiB decode guard | Trimmed on `record`; `clear()` |
| `BookmarksStore.entries` + `urlIndex` | `BookmarksStore.swift:15,21`, `maxEntries=200:25` | tens of KB | **YES** — 200 cap + 1 MiB guard | Trimmed on `add`; `clear()` |
| `RingBufferSink` (obs event ring) | `RingBufferSink.swift:34`, `defaultCapacity=5_000:53`, preallocated `:61,83` | **fixed ~5000 `ObsEvent` slots**, holds raw message strings (paths/LSP text) | **YES** — fixed-capacity ring, drop-oldest; never persisted | Wrap overwrites oldest; `reset()` |
| `LSPDiagnosticsStore.byURL` | `LSPDiagnosticsStore.swift:18` | diagnostics per file | **NO explicit cap** (flag #4) | `replace`/`clear(url:)`/`clearAll()` on reload/quit |
| `LSPNavigationStore.rows` | `LSPNavigationStore.swift:49` | refs/symbols rows | **NO explicit cap** (flag #4) | `clear()`; replaced per query |
| `LSPPool` live clients | `LSPPool.swift` (one server per `(lang, root)`); `idleTimeout=.seconds(5*60):34`, `reaperTick=.seconds(30):38` | one subprocess + pending continuations per server | **YES (time-bounded)** — reaper reaps idle | `reapIdle`; `shutdown` |
| `SessionStore.pending` (coalesce map, static) | `SessionStore.swift:50` | one snapshot per URL, transient | **YES** — drained by serial write queue | Drained per write |
| `repoStatsCache` (HEAD-keyed git stats) | `DocumentModel.swift:1141` (`RepoStatsCache()`) | per-repo aggregates | HEAD-keyed; **no entry-count cap** (flag #5) | Recompute on HEAD change |

### 2e. Other / transient (peak-bounded, not idle-resident)

| Consumer | file:line | ~Cost | Bounded? |
|---|---|---|---|
| `CSVParser` materialized `[[String]]` | `CSVParser.swift:159`, caps `Limits:45-74` | 32M-cell ceiling, 64 KiB/cell, 4096 cells/row, 256 MiB scalars; streams scalars (no doubling, `:148`) | **YES** — four-way caps |
| `SQLiteReader.QueryResult.rows` | `SQLiteReader.swift:212,224`, `maxRows=1_000` | ≤1000 rows × cols of `String?` | **YES** — `maxRows` cap, read-only conn, interrupt handler |
| `CrossFileSearch` results | `CrossFileSearch.swift:83`, `maxResults=500`, `maxFileBytes=2 MiB` | ≤500 full-line matches | **YES** — 500-result, 2 MiB/file skip, 50k-entry backstop |
| `hostedViews: [UUID: AnyView]` | `DocumentModel.swift:1833` | one `AnyView`+model per hosted tab | **YES (=hosted tabs)** — `purgeCaches:2770` sweeps to survivors |
| `RustCore` CsvSession + MsgPack frames | `CoreClient.swift:100`; frames freed via `defer:176` | Rust-side table; frame buffers freed immediately | **YES** — DEFAULT-OFF (`RustCSVGate`); ARC frees session on `deinit` |
| `HexDumpBuilder` output | `HexDumpBuilder.swift` | **chunked** — emits String chunks via callback, not one giant String | **YES** — chunked by design |
| `FileTreeRecencyCache` | `FileTreeRecency.swift:166` | LRU 2048 stat entries | **YES** |
| `newlineOffsets` per source view | `TextDisplayView.swift:540` | one `[Int]` ~`length/80`, rebuilt on text change | bounded by file size |

### 2f. Flags — UNBOUNDED, monotonic, or purge-path notes

1. **TreeSitter grammar dylibs never unmap (by design).** `GrammarLoader.swift:167` — dlopen without dlclose, process-lifetime. Monotonic growth bounded only by *how many distinct languages the user opens in a session*. **C# alone is 5,387,424 B (measured)**, the heaviest of 11 grammars; touch all → ~16.9 MB resident permanently. Correct tradeoff (unmapping crashes parses), but it's a one-way ratchet — the **only genuinely monotonic our-side line**, relevant to peak-bounding (#191).
2. **`TreeSitterEngine.shared` query cache never evicts** (`:39`). Bounded by the fixed ~14-language enum, so effectively capped, but **no purge path**. Low risk.
3. **Process-lifetime JS/CSS statics permanent once touched:** Mermaid **2.45 MB**, CodeMirror **~655 KB**. Open one `.md` + one editor tab → ~3.1 MB our-side for app life, *plus* a per-live-WebView WebKit-side copy.
4. **LSP `byURL` / `rows` have no explicit cap** (`LSPDiagnosticsStore.swift:18`, `LSPNavigationStore.swift:49`). Bounded only by server output; a misbehaving server publishing diagnostics for thousands of URLs grows unbounded. Purge paths exist but are event-driven, not size-driven. Worth a cap.
5. **`repoStatsCache` has no entry-count cap** (`DocumentModel.swift:1141`). Many tracked repos in a long session = unbounded entry count (each small). Minor.
6. **Phase-2 multi-session amplifier (not yet live).** `SessionState` wraps a full `DocumentModel` (`SessionState.swift:40`); today all sessions share ONE instance. When Phase-2 lands a per-session `DocumentModel` dictionary, **every cache above multiplies by session count** — and detached sessions keep caches *warm* on purpose (`SessionState.detach():94`). That warm-retention will become the single biggest memory multiplier the moment Phase-2 ships. No `maxSessions` cap exists.

**Verdict on the trigger:** our-side resident for 2 open markdown files is small and bounded — roughly `2× (file UTF-8) [open] + 2× (UTF-16) [visible glyph store] + ≤20 MB renderedHTMLCache + 2.45 MB Mermaid + grammar dylibs for touched languages`. For two typical small `.md` files: single-digit-to-low-tens of MB. The 120 MB is dominated by summed WebKit XPC, not our heap (§1b). The one monotonic our-side line is grammar residency (flag #1), by-design.

---

## 3. macOS-26 libmalloc dirty-page caching vs. a real leak

`commit 11d376a` added `SourceTextController.teardownStorage()` (`TextDisplayView.swift` `dismantleNSViewController` hook) to drop the glyph store **synchronously on tab close** rather than at a deferred autorelease drain. Verified observation: repeated open/close of a 5 MB file **plateaus rather than ratchets** — the signature of page-caching, not a leak.

**Mechanism:** macOS-26 `libmalloc` does not hand freed dirty pages back to the kernel while idle. Freed large allocations are marked **reusable** but left mapped and counted **dirty** — kept hot for the next large allocation (re-opening the same file reuses them instead of zero-fill faulting). RSS stays high at idle but is reclaimable on demand.

```
              freed but mapped, reusable, reclaimable     ← libmalloc page cache (NOT a leak)
   dirty  ┌── on pressure / next big alloc                  bounded by peak working set
 (in RSS) │
          └── still referenced by live objects            ← genuine live allocation (or a leak)
```

| Signal | Page-caching (benign) | Real leak |
|---|---|---|
| `footprint -summary <pid>` repeated open→close of same file | **plateaus** at peak | **ratchets** each cycle |
| `vmmap <pid>` region detail | `MALLOC_*` large but freed; shows `reusable`/`madv_free_reusable` | dirty grows, no reusable fraction |
| Under `memory_pressure -l critical` | **drops** toward live set | stays pinned |
| `leaks <pid>` | no roots | leaked nodes with backtraces |
| `phys_footprint` (`ProcessMemory.appFootprintBytes()`) | high but stable across cycles | monotonically climbing |

The operative rule (from `commit 11d376a` / `BACKLOG.md:630` #191): **idle footprint is the wrong metric; the lever is peak-bounding.** The render caps already enforce it on the way in — `markdownRenderMaxBytes = 4 MB` (refuses → placeholder), 512 KB source-highlight cap (`TreeSitterEngine.swift:66`), 50 MB CM6 → NSTextView fallback (`BACKLOG.md:343-350`). Bounding the *peak* bounds the cached-dirty floor — the cache can't exceed the high-water mark.

The ~60 MB empty-app baseline is **almost entirely mapped shared pages, not private heap:** the dyld shared cache (arm64e, multi-GB, COW across all processes), 29 system frameworks + the Swift runtime resolving to **`/usr/lib/swift/`** (ABI-stable, OS-resident — *not* shipped in the bundle, near-zero private RSS). Private-but-unavoidable: the 27,362,064 B main Mach-O's `__DATA` dirty pages, the window/menu object graph, and CA/Metal backing stores. The WebKit floor is **not** in a truly-empty app — it appears only after the first `WKWebView`.

---

## 4. THE CYCLE BUDGET — what runs, and when

**Headline:** The app is well-disciplined at idle. Nothing genuinely spins the CPU while idle. The real CPU lever is the **per-edit full-document TreeSitter reparse** (no incremental tree reuse) plus a couple of value-blind republishes that fan O(visible-tree) work per FSEvents burst.

| Work-item | file:line | Fires-when | Idle-silent? | Concern |
|---|---|---|---|---|
| **LSP idle-reaper loop** | `LSPPool.swift:152-155` (`while !Task.isCancelled { Task.sleep(tick); reapIdle() }`), started `main.swift:84` | Every **30s for app lifetime**, unconditionally from launch (even with zero servers) | **NO** (wakes at idle) | Low — `reapIdle()` is O(entries), ~0 when empty. **The one unconditional-from-boot idle wake.** Could lazy-start on first `acquire`. **Flag.** |
| **Git panel poll** | `GitPanelModel.swift:91-98` | Every **60s** *only while git panel visible* (`onAppear`/`onDisappear`, `GitPanelView.swift:36-37`) | **YES** (stops on disappear) | Each tick → one `git` subprocess (`refreshCurrent`→`Task.detached:201`) for the visible tab only, off-main, cancel-coalesced. Fine. |
| **Git refresh on focus** | `GitPanelView.swift:30-33` → `windowDidBecomeKey` → `refreshCurrent` | Per `didBecomeKey` while panel visible | **YES** | One git subprocess per refocus. Could debounce against the 60s cadence. |
| **Observability poll** | `ObservabilityProjection.swift:81-88`, `tick():107` | **1 Hz** *only while a tool window open* (`onAppear` gated) | **YES** | `ProcessMemory.sample()` walks every pid at 1Hz on main actor — only when the Memory tool is open; republishes only on change. Bounded. |
| **TreeSitter tokenize** | `TreeSitterEngine.tokenize:64-95`; scheduled `HighlightCacheActor.ensureTokenized`; driven from `ContentView.swift:705` | **Per edit** (CM6-debounced ~200ms) **+ per tab-switch** on miss | **YES** (off-main, coalesced) | **PRIMARY CPU COST.** Allocates a **fresh `Parser()` per call** (`:69`), `parser.parse(text)` over the **entire doc** (`:73`), re-runs whole query — **no incremental `Tree.edit`/reuse.** Cache key includes length so *every length-changing keystroke* misses → full reparse of up to 512 KiB. O(doc) per edit. **Flag: O(n)-per-edit.** |
| **Markdown HTML render** | `DocumentModel.renderedHTML:2039`, key `RenderedHTMLKey:1940` (`tabID,byteCount,mtime`) | Per open / external-edit reload / tab-switch on miss | **YES** | Memoized, LRU=4 (`:1961`). Read-only preview, not per-keystroke. Fine. |
| **CM6 `onTextChange`** | `EditorCoordinator.updateEditorText:241-259`; wired `ContentView.swift:404` | Per edit (~200ms debounced) | **YES** | O(1): identical-string short-circuit (`:246`), only `isDirty` diff. Clean. |
| **CM6 `onCursorChange`** | `EditorCoordinator.recordEditorCursor:266`; `ContentView.swift:410` | **Per keystroke / caret move** (not debounced) | **YES** | O(1) dict write + status-bar mirror. Cheap but full keypress cadence. |
| **CM6 `onScrollChange`** | `EditorCoordinator.recordEditorScroll:272`; `ContentView.swift:413` | Per scroll tick | **YES** | O(1) dict write. Cheap. |
| **Source-view selection-highlight** | `TextDisplayView.swift:556-571`, scheduled `:651-670`, throttle `:284` | Per selection/caret in NSTextView source mode | **YES** | Throttled 150ms, skipped for large read-only (`:565`), engine bails on >5 MB haystack. Well-guarded. |
| **Source-view `publishSelection`/newline-index** | `TextDisplayView.swift:556-611`, `newlineOffsetsRefreshed:540` | Per caret move (source) | **YES** | Binary-search over cached newline offsets; rebuild O(doc) but cached (`:549`), skipped for large read-only (`:577-591`). Dedup guard (`:609`) stops the historical ~5 MB/s growth loop (`:307`). |
| **Current-line backdrop** | `TextDisplayView.applyCurrentLineHighlight` (`:560`) | Per caret move (source) | **YES** | O(1) single-line range, equality-debounced. Cheap. |
| **CSV parse** | `CSVTableView.reparse:161`, `parsedCache:71`, `.onChange(of:text):130` | Per CSV text change (cached on `@State`) | **YES** | Recomputed only on text change. |
| **CSV filter apply** | `CSVTableView.swift:133`, `scheduleFilterCommit:143-159` | Per filter keystroke | **YES** | **200ms debounced** (`:139`), then O(rows) apply. Good. |
| **FSEvents folder watch → sidebar reload** | `FolderWatcher:203-255`; sink `SidebarModel.onFolderChange:140-170` | Per external FS change under open root | **YES** (event-driven) | Debounced + off-main resolve + realpath cache. **But** `onFolderChange` does a value-blind `expanded = snapshot` (`:168-169`) forcing a full sidebar re-body + per-dir `readdir` + recency invalidation. O(visible-tree) per burst. **Flag: value-blind republish per FS burst.** |
| **FSEvents → RepoFocusTracker** | `RepoFocusTracker.swift:135-187`, handler `:265` | Per tab-set change / selection / `.git` touch | **YES** | Equality-guarded (`:143`), selection debounced 200ms (`:103`). Strong discipline. |
| **Single-file watch (open doc)** | `FileWatcher` (DispatchSource on fd), debounced `:177` | Per external write to open file | **YES** (event-driven) | 100ms debounce, reattach-on-atomic-rename. Clean. |
| **Sessions autosave** | `SessionsAppCoordinator.scheduleAutosave:282`, fire `:296` | Per session-state change | **YES** | Debounced + token-coalesced + equality-guarded persisted-content check (`:300`). Only writes on real change. |
| **Walkthrough auto-advance** | `WalkthroughAutoAdvance.schedule:94-121` | Only while playing | **YES** | Single `Task.sleep` per step, cancelled on pause. Idle-silent. |
| **RingBufferSink emit** | `RingBufferSink.swift:34`, installed `main.swift:69` | Per `Obs.emit` (LSP parse, MCP stdio, grammar dlopen) | **YES** | Real sink installed at launch (not Noop). O(1) lock+ring, `os_log` outside lock. **Not** on the editor/highlight hot path (verified). |
| **`DocumentModel.objectWillChange` forwarding** | `DocumentModel.swift:309-362` | On observed child changes | **YES** | Deliberately narrow: sidebar/panelLayout/git `objectWillChange` are **NOT** forwarded (PERF #1, `:320-361`), preventing the historical republish storm. Pinned by invariant tests. Good. |
| **Window-title sink** | `main.swift:180-185` | Per `windowTitle` change | **YES** | O(1). Trivial. |
| **Finite UI animations** | `TabBar.swift:115,276`, `SidebarView.swift:454,575,925`, `CommandPaletteView.swift:74` | On user interaction | **YES** | Fixed-duration `easeInOut` (0.12–0.18s). **No `repeatForever`, no `TimelineView`, no `Canvas`.** No idle redraw loops. |
| **Indeterminate spinners** | `ContentView.swift:1039`, `CrossSearchPanel.swift:97`, `SQLiteBrowserView.swift:129/157`, etc. | Only while a load/search in flight | **YES** | Animate while visible only; gone once content arrives. |

### Idle-silence verdict

At true idle the **only** recurring CPU wake is the **LSP reaper Task** (1 wake / 30s, ~0 work when no servers — the one unconditional-from-boot wake, easily made lazy). Git poll and observability poll do **not** run at idle (both `onAppear`/`onDisappear`-gated). No timer, animation, Combine pipeline, or watcher does O(n) work while idle. The historical idle-RSS-growth loop (`TextDisplayView.swift:302-309`) is fixed and dedup-guarded.

### The two things to actually fix

1. **Per-edit full-document TreeSitter reparse** (`TreeSitterEngine.tokenize:64-95`) — the dominant per-keystroke CPU cost in source-editing mode. Correctly off-main + coalesced + LRU + 512 KiB-capped + 200ms-debounced, but the length-keyed cache means *every* length-changing keystroke re-parses the whole document with a freshly-allocated `Parser` (no `Tree.edit` + incremental reparse — the feature tree-sitter exists for). On a 400 KiB source, a typing burst is a stream of full reparses. **Highest-leverage CPU item;** the natural complement to the speed-profiling lane — have the signpost instrument `tokenize` duration vs doc size.
2. **Value-blind sidebar republish on FS bursts** (`SidebarModel.onFolderChange:168-169`, `expanded = snapshot`). Deliberate (re-assigning an equal `Set` is value-blind in Combine and forces a re-body), but every FSEvents burst touching a visible dir triggers a full subtree re-body + per-dir `readdir` + recency invalidation. Bounded by debounce, so not idle CPU — but O(visible-tree) on a channel (FS activity) the user doesn't control. A noisy repo (`node_modules`/build output under an *expanded* node) amplifies it.

---

## 5. MEASUREMENT METHODOLOGY — which tool answers which question

All invocations verified runnable on this machine (`macOS 26.2 / 25C56`, arm64).

| Accounting question | Tool | Layer |
|---|---|---|
| Single budgetable number? | `footprint` / `task_info(TASK_VM_INFO)→phys_footprint` | ledger |
| Dirty vs compressed/swapped vs clean vs reclaimable? | `footprint` cols / `vmmap --summary` | regions |
| *Where* does footprint live (zones, `__DATA_DIRTY`, IOSurface, stacks)? | `vmmap --summary` | regions |
| *Who* allocated a given live block? | `malloc_history` + `MallocStackLogging` | heap |
| What's leaked (live but unreachable)? | `leaks` | heap |
| Per-class/per-zone live census? | `heap` | heap |
| Growth over time / alloc hot paths? | Instruments **Allocations** + **VM Tracker** | heap+regions |
| Total across WKWebView XPC helpers? | `footprint` multi-target (de-dup) + per-process | ledger |
| CPU: user/sys time, instructions, cycles, wakeups? | `proc_pid_rusage(RUSAGE_INFO_V4+)` | kernel |
| CPU: which function is hot? | `sample` / Instruments **Time Profiler** | sampling |
| CPU: cost of *my* logical op (parse, render)? | `OSSignposter` intervals → **Points of Interest** | in-process |

### 5a. Memory — exact invocations

```bash
footprint <pid|name>                       # category breakdown + phys_footprint (Aux data)
footprint --swapped --wired <pid>          # add compressed/swapped + wired columns
footprint -j out.json <pid>                # machine-readable — THIS is your CI hook
footprint --sample 0.5 --sample-duration 60 -j ts.json <pid>   # peak time-series
vmmap --summary <pid>                      # totals per REGION TYPE (no per-region noise)
```
`footprint` columns: **Dirty** (= your footprint total), **(Swapped)** ⊂ Dirty (compressed/swapped, charged uncompressed), **Clean** (resident, restorable), **Reclaimable** (purgeable-volatile/`MADV_FREE`, kernel-yankable), **(Wired)** ⊂ Dirty. Reduction priority per the man page: **Dirty → Reclaimable → Clean → Wired** — only Dirty drives pressure against you. Parse `total footprint` / per-process `phys_footprint` **from JSON**, never scrape the text table.

In `vmmap --summary`, `SWAPPED` = original (uncompressed) size of compressed pages; `__LINKEDIT`/`__TEXT` being huge-but-clean is normal and *not* your problem.

Heap forensics — set stack logging **before launch** (it's opt-in and must precede allocation):
```bash
MallocStackLogging=1            # record alloc call stacks
MallocStackLoggingNoCompact=1   # keep freed-block history (UAF/churn forensics)
malloc_history <pid> <address>  # call stack that allocated that block
leaks <pid>                     # unreachable live blocks (names sites if logging on)
heap <pid>                      # live-block census by class/zone
```
`leaks` finds *unreachable*; it does **not** find abandoned-but-reachable growth — for that, diff two Allocations heap-generation snapshots in Instruments. **Caveat:** Allocations treats every allocation as fully dirty and can't see compression — it **over-counts** vs footprint; reconcile against VM Tracker. **Never set `MallocStackLogging` during budget runs** — it perturbs footprint and CPU; it's a *forensic* mode for when a gate fails.

### 5b. CPU — exact invocations

```bash
sample <pid> 5 -mayDie                                          # 5s statistical profile
xcrun xctrace record --template 'Time Profiler' --attach <pid> --time-limit 30s \
      --output cpu.trace --no-prompt
xcrun xctrace export --input cpu.trace \
   --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost-interval"]' --output sp.xml
```
`proc_pid_rusage(RUSAGE_INFO_V4)` is the under-used primitive — on Apple Silicon it gives **per-process hardware instruction and cycle counts** (`ri_instructions`, `ri_cycles`), plus per-QoS CPU buckets and wakeup counts. **Two traps, both confirmed live:**
1. **`ri_user_time`/`ri_system_time` are mach-absolute ticks, NOT ns.** Convert via `mach_timebase_info` (`numer/denom` = 125/3 here). Treating ticks as ns is ~41× wrong — the single most common Apple-Silicon CPU bug.
2. **`ri_instructions`/`ri_cycles` are populated only in V4+** and are *deterministic* — far more stable run-to-run than wall time. **Prefer instructions for regression gates** (±2–3% tolerance) over time (needs ±20% and still flakes).

> **In-app gap to fix:** `ProcessMemory.footprintBytes(of:)` (`:122`) reads helpers via `RUSAGE_INFO_V2` (`ri_phys_footprint`) — correct for footprint, but it means the per-helper *CPU instruction* counts (V4+) are **not** being read today. If the harness wants cross-helper CPU attribution, bump that call to `RUSAGE_INFO_V4`.

Per-subsystem CPU attribution → `OSSignposter` intervals in the always-on `.pointsOfInterest` lane (`render`, `treesitter-highlight`, `markdown→HTML`, `WKWebView load`, `mermaid`); the `os-signpost-interval` table **does** export via `xctrace export --xpath`.

### 5c. Attributing across WebKit XPC helpers

The helpers are **siblings, not children** of the app (reparented under `launchd`/WebKit), so `footprint -t <ui-pid>` (targetChildren) will **not** reliably sweep them up. Two robust approaches:

```bash
pgrep -f 'com.apple.WebKit.(WebContent|GPU|Networking)'        # discover helper pids
footprint -p MarkdownViewer -p com.apple.WebKit.WebContent \
          -p com.apple.WebKit.GPU -p com.apple.WebKit.Networking -j out.json
```
`footprint` with multiple targets **de-duplicates multiply-mapped objects, reports shared separately**, and prints a de-duplicated `total footprint` — the correct cross-process number. A naive sum of per-process resident double-counts shared regions. Alternatively, the UI process can poll `proc_pid_rusage(helperPid, …)` / `task_info` on helper pids (same user, no entitlement) continuously — which is what `ProcessMemory.webKitHelperFootprint()` already does.

> **Fidelity gap in the in-app readout (verified this session):** `webKitHelperFootprint()` only counts helpers whose `parentPID == me` (`ProcessMemory.swift` loop). Correct for *avoiding over-count*, but WebKit XPC helpers commonly **reparent to `launchd`** shortly after spawn — when they do, the sum drops them while `helpersComplete` still reports `true` (it only tracks pid-buffer saturation, **not** reparenting loss). So the readout can show "0 helpers / complete" with three WebContents live. The robust handle is matching on **responsible-pid** (`proc_pidinfo` / `responsible_pid`) rather than direct parent.

### 5d. The 10-second triage flow when a gate fails

```
footprint -j         → which process? which Category grew (Dirty)?
   ├─ malloc zone grew  → heap <pid>           (which class/zone)
   │                     → leaks <pid>          (unreachable?)
   │                     → malloc_history <pid> <addr>  (who allocated)
   ├─ __DATA_DIRTY / iokit_mapped grew → vmmap --summary <pid>  (WebKit GPU IOSurface?)
   └─ CPU gate failed   → proc_pid_rusage delta (instructions up?)
                        → xctrace Time Profiler + signpost intervals (which subsystem?)
                        → sample <pid> 5        (quick hot-stack)
```

---

## 6. THE HARNESS DESIGN (build AFTER the speed-profiling workflow lands, reusing its `os_signpost` instrumentation)

### 6a. Wire the WAVE2a "honest memory readout" — status: it is *partly* wired already

The "UNWIRED" memory is **stale.** Verified this session:
- The sink **is** installed at launch — `Obs.installIfNeeded { self.observabilitySink }` (`main.swift:69`, `private let observabilitySink = RingBufferSink()` at `:36`).
- The Memory/Logs/Metrics views **are** reachable via **Debug ▸ Instrumentation** (`main.swift:1232`, `showInstrumentationWindow:1548`, `InstrumentationWindowView(model:sink:):1556`).
- What gates it: `DiagnosticGate.isEnabled` (DEBUG build **or** `MDV_ENABLE_DIAGNOSTICS=1`) — `main.swift:1206,1219,1529,1549`. A stock release binary never grows the Debug menu.
- It polls at **1 Hz off any hot path** (`ObservabilityProjection.swift`, `interval = 1.0`; pid-walk gated to that cadence), republishing only on change.

So the harness doesn't need to *wire* it — it needs to (1) **fix the reparenting under-count** (§5c, responsible-pid matching), and (2) optionally surface the app-footprint/helper-sum on a separate always-on status line behind the same gate.

### 6b. Architecture

```
   ┌─ launch app/helper under a fixed workload (golden corpus markdown set)
   │    deterministic: same files, same window size, headless where the tier allows
   ├─ SETTLE (drain run loop N seconds; footprint right after launch is noise)
   ├─ MEASURE
   │    bytes:  footprint -j  (UI + WebKit helpers, de-duplicated total)  → phys_footprint
   │            task_info(TASK_VM_INFO).phys_footprint  (in-process, exact)
   │    cycles: proc_pid_rusage(V4).ri_instructions / ri_cycles / user_ns
   │            xctrace os-signpost-interval table → per-subsystem ns  (reuse speed lane)
   ├─ COMPARE to committed baselines.json with per-metric tolerance
   └─ ASSERT  → nonzero exit on any breach (CI gate)
```

### 6c. Byte budget — two complementary gates

- **Micro gate (in-process unit test, host-safe T1):** `task_info(mach_task_self_, TASK_VM_INFO, …).phys_footprint` before/after a specific operation, assert the **delta** against a budget. No window, no helpers — slots straight into `HeadlessUITestCase` (T1). Reuse the proven probe (`ProcessMemory.appFootprintBytes()`, `:104`):

```swift
func footprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                       / MemoryLayout<integer_t>.size)   // TASK_VM_INFO_COUNT
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(kr == KERN_SUCCESS)
    return UInt64(info.phys_footprint)
}
```
> Hardcode the count to `TASK_VM_INFO_COUNT` (REV5 on macOS 26). Asking for an older `TASK_VM_INFO_REV1_COUNT` silently leaves `phys_footprint` = 0 — a silent-zero trap. (The shipped `appFootprintBytes()` already sizes correctly.)

- **Macro gate (process/CI level, VM/nightly lane):** after settle, `footprint --sample 0.5 --sample-duration <T> -j` over the UI + 3 WebKit helpers, read de-duplicated `total footprint` and each `phys_footprint`, assert `≤ baseline × (1+tol)` with ~3–5% tolerance, and gate on **peak** across the window (catches transient spikes). This must spawn real `dist/TextView.app` + a window, so it belongs in the **VM/nightly lane** (`scripts/test-in-vm.sh`), alongside T4/T5 — not the headless merge gate.

### 6d. Cycle budget — prefer instructions over time

- **In-process (deterministic, host-green T1):** `proc_pid_rusage(getpid(), RUSAGE_INFO_V4)` before/after a target operation, assert `Δri_instructions ≤ budget` with tight ±2–3%; also assert `Δri_pkg_idle_wkups` (wakeup/battery budget) and `Δri_pageins`. **First regression target: the per-edit tokenize** (§4 item 1) — measure `Δri_instructions` for a fixed keystroke sequence on a fixed-size source fixture; this is exactly where an incremental-reparse change would show up.
- **Per-subsystem (trace-based, reuse the speed lane):** the speed workflow's `OSSignposter` intervals around `tokenize`/`render`/`markdown→HTML`/`WKWebView load`/`mermaid`; `xctrace export --xpath '…[@schema="os-signpost-interval"]'` → sum durations per name → assert each subsystem ≤ threshold. Catches "parse got 2× slower" even when total CPU is masked elsewhere.

### 6e. Baseline & regression mechanics

- Commit `baselines.json`: `{metric: {value, tol}}` keyed by `(workload, metric)`. Regenerate deliberately (`--update-baselines`), review the diff in PR — a baseline bump is a visible, reviewable event, not silent drift.
- Record **machine context** (chip, core count, OS build). **Gate `ri_instructions` hard; gate `user_ns` only as a soft warning** — instruction counts are machine-stable, wall time is not.
- **Wiring into the existing gate:** byte/cycle **micro-gates** go in the headless tier (`bash scripts/test-headless-gate.sh`, `HeadlessUITestCase`/T1 — no GUI). The cross-helper **macro-gate** (real WKWebView + 3 XPC processes, real window) belongs in the **VM/nightly lane** (`scripts/test-in-vm.sh`) alongside T4/T5.
- **Determinism checklist:** pin window size, disable animations, fixed markdown corpus, fixed allocator env, warm-then-measure (discard first run — dyld/first-touch faults), fixed QoS, pin to P-cores for stable cycle counts (`taskpolicy`), measure **peak** (`--sample`) not a single read for the macro byte gate. Do **not** set `MallocStackLogging` during budget runs.

---

## 7. RANKED reductions + suspected regressions to chase

### Memory / CPU reductions (highest leverage first)

1. **Incremental TreeSitter reparse** (`TreeSitterEngine.tokenize:64-95`) — **biggest CPU win.** Today every length-changing keystroke allocates a fresh `Parser()` and reparses the whole doc (no `Tree.edit`/tree reuse), up to 512 KiB. Holding the prior `Tree` per tab and applying `Tree.edit` + incremental reparse cuts per-keystroke cost from O(doc) toward O(edit). It's also the obvious first cycle-budget regression test (§6d).
2. **One app-wide `WKProcessPool`** instead of three (`MarkdownRenderedView.swift:54`, `HTMLRenderedView.swift:71`, `CodeMirrorEditorView.swift:197`) — **biggest semi-ours memory win.** Collapses up to 3 WebContent processes (+30–80 MB each) into one for a mixed `.md`+`.html`+editor session. Put it on a `ViewerUI` namespace.
3. **Value-blind sidebar republish** (`SidebarModel.onFolderChange:168-169`) — replace `expanded = snapshot` with a targeted invalidation of only changed subtrees so a noisy repo (`node_modules`/build output under an expanded node) doesn't trigger a full O(visible-tree) re-body per FSEvents burst.
4. **Lazy-start the LSP reaper** (`LSPPool.swift:150-155`) — only spin the 30s `while`-sleep loop on the first `acquire`, eliminating the one unconditional-from-boot idle wake. Tiny, but it's the *only* idle wake left.
5. **Cap the LSP stores** (`LSPDiagnosticsStore.byURL:18`, `LSPNavigationStore.rows:49`) — add a size/URL-count cap so a misbehaving server can't grow them unbounded (flag #4). Low likelihood, cheap insurance.
6. **Before Phase-2 ships: a `maxSessions` / warm-cache eviction policy** — `SessionState.detach()` keeps every cache warm by design (`:94`); with a per-session `DocumentModel` (`SessionState.swift:40`) this becomes the single biggest memory multiplier (flag #6). Decide an LRU on detached-session caches before, not after, multi-session lands.

### Suspected regressions to chase

1. **Scenario (a) ≈ 120 MB for 2 plain text files** would be a regression — chase in the order in §1a: (i) `pgrep -f com.apple.WebKit` to rule in/out an unexpected WebView; (ii) verify `isLargeReadOnly` + the highlight/glyph fast paths engaged for any large file; (iii) confirm the apply→publish dedup guard (`TextDisplayView.swift:609`) still holds via `footprint --sample` during repeated caret moves; (iv) confirm footprint *plateaus* (cache) vs *ratchets* (leak) across open/close cycles.
2. **`webKitHelperFootprint()` reparenting under-count** (`ProcessMemory.swift`, `parentPID == me`) — not a footprint regression but a **measurement** one: the "honest readout" can report 0 helpers with WebContents live, so it would mask a real WebKit-side regression. Fix with responsible-pid matching before trusting the in-app number for gating.
3. **`footprintBytes(of:)` uses `RUSAGE_INFO_V2`** (`:122`) — fine for footprint, but blocks per-helper *CPU instruction* attribution (V4+). Bump to V4 if the harness wants cross-helper cycle accounting.

### Housekeeping (per worktree-hygiene rule)

- A **locked stale worktree** exists: `/Users/me/Documents/workspaces/claude/markdown_viewer/.claude/worktrees/wf_13dee23e-3b2-6` (branch `worktree-wf_13dee23e-3b2-6`, locked). If its work is merged/abandoned, reap it (`git worktree unlock … && git worktree remove --force … && git worktree prune`) — stale locked worktrees with build dirs are the dominant disk-bloat source. (No code/RSS impact; noted because the review touched git state.)
