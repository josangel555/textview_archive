# Pre-launch product review — Extreme performance optimization (v2)

**Date:** 2026-07-09 · **Reviewer:** perf-lens audit agent · **Repo state:** `main` @ `92c72206`
(v2 pass — independent of the earlier `performance-optimization.md`; written as a sibling per
safe-write policy.)

## Executive summary

This codebase has clearly absorbed multiple serious performance passes (TSK-611 off-main
markdown render, TSK-842 deferred large-file reads, TSK-922 split-pane off-main load,
TSK-971 status-bar metric caching, TSK-1042 warm-WebView cache, TSK-619 grammar warm-up,
frame-throttled terminal, actor-isolated highlighting). The *default* hot paths — open,
tab switch, main-pane rendered markdown, source display, highlight — are in good shape.

The remaining exposure clusters into three themes:

1. **Secondary surfaces missed the optimizations the primary surface got.** The split
   pane re-renders markdown→HTML **synchronously inside `body` on every keystroke**
   (the exact bug TSK-611 fixed for the main pane, including the missing 4 MB render
   cap); the CSV table view parses the whole file **on the main thread with no size
   gate**; the source-view find bar runs an **undebounced O(document) scan on main per
   query keystroke** with no large-file gate.
2. **Per-keystroke O(buffer) work on the main actor.** Status-bar metrics hash the full
   buffer per body eval and marshal the **entire buffer across the FFI** per edit for
   indent detection (Rust samples only 50 lines; Swift ships all 50 MB). Session
   autosave copies every dirty buffer and deep-compares full snapshots on main per
   quiescent window.
3. **The felt-perf measurement layer is unwired.** `InteractionProfiler` (TSK-1488) has
   **zero production call sites** — no CADisplayLink feed, no HUD — so none of the
   interactions above is graded against its budget. PerfSignpost coverage (46 sites) is
   good on open/materialize/render but absent on exactly the per-keystroke paths where
   the remaining problems live (CM6 bridge, find, CSV reparse, autosave fire, FFI seam).

No P0s. Two P1s (split-pane markdown render; ungated main-thread find). Eleven further
findings P2–P3. All are localized fixes; none requires architectural change.

## Methodology

Static review (read code, no repo mutation, no UI tests run) focused on:

- **File-open / load path:** `TextFileLoader.swift` (all 515 lines), `DocumentModel+TabLoading.swift`,
  `DocumentModel+TabMaterialize.swift` (spot), `DocumentModel.swift` (~600 lines around open/
  reload/disk-state/watcher), `DocumentModel+LazyTabOpen.swift` (spot).
- **Render path:** `HTMLRenderer.swift`, `DocumentModel+RenderedCache.swift` (full),
  `MarkdownRenderedView.swift` (structure + cache flow), `WarmWebViewCache.swift`,
  `SplitPaneView.swift` (full), `ContentView.swift` (routing branches).
- **Per-keystroke paths:** `CodeMirrorEditorView.swift` (bridge/inbound), `StatusBar.swift`
  (metrics, ~300 lines), `RustIndentAdapter.swift`, `TextDisplayView.swift` (find/selection/
  newline-index, ~400 lines), `CSVTableView.swift` (parse/filter).
- **Background/IO discipline:** `SidebarModel.swift` (grep), `DocumentModel+GitDiffGutter.swift`,
  `GitChipStore.swift`, `TerminalModel.swift` (grep), `SessionsAppCoordinator.swift` (autosave,
  ~150 lines), `SessionsCoordinator.swift` + `SessionStore.swift` (persist plan), `HotExitSpill.swift`,
  `ArchiveCatalog.swift`, `ArchiveBrowserView.swift`.
- **Startup:** `main.swift` (module scope + `applicationDidFinishLaunching`, ~450 lines),
  `DocumentModel.init` (full).
- **Measurement infra:** `PerfSignpost.swift` call-site census (46 begin/end/event sites in
  14 files), `InteractionProfiler.swift` (full) + call-site census (zero).
- **Rust core:** size/structure census of `markdown.rs`, `csv.rs`, `find.rs`, `fuzzy.rs`;
  per-char/clone anti-pattern grep only (the 2026-06-09 rust-core production audit already
  covers this tier in depth).

Greps used: sync-IO census (`Data(contentsOf`/`String(contentsOf`/`attributesOfItem` per file),
main-sync patterns (`DispatchQueue.main.sync`, `waitUntilExit`, `Thread.sleep`, `while true`),
republish census (`objectWillChange.send`), timer census, line-split census.

---

## Findings

### F1 — Split pane renders markdown→HTML synchronously inside `body`, on every keystroke, with no size cap  · **P1**

**Where:** `Sources/ViewerUI/SplitPaneView.swift:190-198`; re-body trigger documented at
`SplitPaneView.swift:30-34`; missing cap: contrast `Sources/ViewerUI/ContentView.swift:1050`.

**Evidence:** The markdown/mermaid branch of the split pane builds its HTML inline in the
view body:

```swift
MarkdownRenderedView(
    html: HTMLRenderer().renderPage(          // ← synchronous, main thread, per body eval
        body,
        stylesheet: MarkdownStylesheet.cached,
        extraStylesheet: MermaidBundle.shimCSS
    ),
    ...
)
```

`renderPage` → `RustMarkdownAdapter.render` is a full markdown→HTML structural render via
the Rust FFI (plus sanitizer + fence handling). The header comment at lines 30-34 states
the design explicitly: *"Observing the coordinator DIRECTLY re-bodies the split on each
keystroke so unsaved edits appear here."* And `splitPaneText(for:fallback:)` (line 183)
deliberately feeds the **live dirty editor buffer** into this branch — so **typing in the
editor while a markdown file is open in the split re-runs a full synchronous markdown
render on the main thread per keystroke**.

Compounding it: the split's only size gate is `softWarnBytes` = **64 MiB**
(`SplitPaneView.swift:57-64`), while the main pane caps rendered markdown at
`markdownRenderMaxBytes` = **4 MB** (`ContentView.swift:1050`). A 30 MB markdown file is
refused rendered mode in the main pane but happily sync-rendered per body eval in the
split. This is the exact class TSK-611 fixed for the main pane (measured **~927 ms**
main-thread stall for an inline cold render, per the comment at
`DocumentModel+RenderedCache.swift:55-57`) — the split surface never got the fix. There
is also no render caching at all on this path (a fresh full render even when the text
didn't change; every unrelated tab mutation that ticks `TabCoordinator` re-renders it).

**Impact:** Typing latency proportional to split-file size whenever a markdown/mermaid
split is open; multi-hundred-ms per-keystroke stalls for MB-scale documents; a 30–60 MB
markdown in split is a multi-second per-body-eval freeze.

**Fix:** Route the split through the same memoized machinery as the main pane
(`renderedHTMLIfCached` + `requestRenderedHTML`, keyed by URL + content fingerprint
rather than tabID), or at minimum: memoize on `@State` keyed by (url, text length,
mtime/dirty-fingerprint), render off-main via `.task(id:)` (the TSK-922 `diskLoad`
pattern already in this file), and apply `markdownRenderMaxBytes` to the split branch.

**Fix size:** M · **Fix risk:** careful (cache keying must account for dirty-buffer text,
not just mtime — the main pane's tabID+mtime key is not directly reusable).

---

### F2 — Source-view find: undebounced O(document) synchronous scan on the main thread per query keystroke; ungated for large files; O(matches) attribute repaint  · **P1**

**Where:** `Sources/ViewerUI/TextDisplayView.swift:1318-1333` (scan trigger),
`:1496-1530` (`findRanges`), `:1347-1357` (repaint); undebounced forwarding chain:
`Sources/ViewerUI/DocumentModel+FindBarForwarders.swift:119-122` →
`ContentView.swift:1306-1308`; large-file gate absent (contrast the gated selection
highlight at `TextDisplayView.swift:755-765`).

**Evidence:**
- Every find-bar keystroke mutates `sourceFindQuery` (a plain forwarded `@Published`
  setter — no debounce anywhere in the chain), which re-bodies →
  `applyFindHighlights` → cache-key miss → `Self.findRanges(in: text, ...)` runs
  **synchronously on the main thread** over the entire document.
- The literal path (`:1516-1529`) is an `NSString.range(of:options:)` loop with
  `.caseInsensitive` ICU compare — no wall-clock bound (only the regex path has
  `RegexComplexityGuard.boundedMatches`, `:1512`).
- `applyFindHighlights` has **no `isLargeReadOnly` gate**. The neighboring
  selection-highlight path explicitly skips large files (`:759`, "engine policy already
  bails above 5 MB") and the newline-offset index is skipped too (`:771-785`) — find was
  missed. Files up to `readableMaxBytes` = **512 MiB** reach the source view
  (`TextFileLoader.swift:192`).
- After the scan, `:1347-1357` paints **every** match with
  `addTemporaryAttribute` — O(total matches), unbounded. A short query on a large file
  (e.g. `e` in a 100 MB log) produces millions of matches → allocation + layout-manager
  churn on top of the scan.
- Irony: a memchr/`memmem`-accelerated Rust find engine exists and is the mandated engine
  (find port TSK-630), but the interactive find path doesn't use it —
  `RustFindAdapter.search` is called only from the automation host
  (`Sources/ViewerUI/Automation/DocumentModel+AutomationHost.swift:197`).

**Impact:** Find-as-you-type on files ≥ ~10 MB produces per-keystroke main-thread stalls
of hundreds of ms; on a 100–500 MB `isLargeReadOnly` file, multi-second freezes per
keystroke — the one surface deliberately built to keep huge files interactive loses
interactivity the moment ⌘F is used.

**Fix:** (a) debounce the query ~100–150 ms (the `scheduleSelectionHighlightRefresh`
throttle pattern at `:845-865` is right there); (b) run the scan off-main (or via
`RustFindAdapter`) and commit results on main; (c) cap painted matches to the visible
range ± a window, with count-only summary beyond; (d) gate or bound the scan for
`isLargeReadOnly` files the same way selection-highlight is gated.

**Fix size:** M · **Fix risk:** careful (find-next/prev nonce logic and the
`lastFindKey` idempotence dance are subtle; regression tests exist — `RenderedFindBarTests`,
find-bar host tests).

---

### F3 — Status bar does O(buffer) main-thread work per editor keystroke, including a full-buffer FFI copy for a 50-line indent sample  · **P2**

**Where:** `Sources/ViewerUI/StatusBar.swift:666` (hash), `:680` (line count), `:689`
(indent detect), `:527-539` (live-buffer read per body eval);
`Sources/ViewerCore/RustIndentAdapter.swift:23-25`.

**Evidence:** In editor mode `currentMetrics` reads the live buffer and calls
`Self.metrics(forText: buf.text, ...)`:
- `let contentHash = text.hashValue` (`:666`) — SipHash over the **entire** UTF-8
  contents. This runs on **every** StatusBar body eval (typing, caret move, scroll,
  hover), including cache **hits** — the O(N) hash is the cache key. On a 50 MB CM6
  buffer (the `codeMirrorEditorMaxBytes` cap) that alone is tens of ms per body eval.
- On every real edit (hash miss): `lineCount(in:)` full UTF-8 scan (`:767-775`),
  `text.utf16.count` (O(N) first touch on a fresh string — and each CM6 change delivers
  a fresh string), and `RustIndentAdapter.detect(in: text)` (`:689`).
- `RustIndentAdapter.detect(text:sampleLines: 50)` marshals the **whole buffer** across
  the MessagePack FFI (full UTF-8 copy into the request frame) even though the Rust side
  samples only the first 50 lines (`RustIndentAdapter.swift:23`).

The TSK-971 content-hash cache correctly killed redundant *re-scans*, but the remaining
steady-state cost is still Θ(N) per keystroke **and** per caret move, on the main actor.

**Impact:** Typing and caret movement in large editor buffers pays 2–4 full-buffer passes
plus a full-buffer heap copy across the FFI per edit. At 10 MB this is ~10–30 ms per
keystroke of pure status-bar overhead; at the 50 MB cap it is a visible per-keystroke
hitch — attributed to "the editor is slow" though the editor itself is fine.

**Fix:** (a) key the cache on a cheap version token instead of a content hash — the CM6
bridge already has a monotonic change stream, and `EditorBuffer` can carry an edit
counter; (b) slice the indent-detect input Swift-side (first 64 KB is far more than 50
lines); (c) compute the miss-path scans on a utility task with a stale-value display, or
throttle to the 150 ms pattern used elsewhere.

**Fix size:** S–M · **Fix risk:** safe (display-only metrics; TSK-971 teeth tests pin
the caching behavior and will catch key regressions).

---

### F4 — CSV table view: full parse + full-grid lowercase copy + editable-model build, all on the main thread, with no size gate  · **P2**

**Where:** `Sources/ViewerUI/CSVTableView.swift:559-591` (`reparse()`), `:287-292`
(called from `.onAppear` / `.onChange(of: text)`); ungated routing at
`Sources/ViewerUI/ContentView.swift:876-880`.

**Evidence:** `reparse()` runs `RustCSVAdapter.parse(text)` — a full-document FFI
round-trip (request copy + parse + response decode) — **synchronously on the main
actor**, then for files ≥ 256 KB builds `lowercasedRowsCache` = a second full copy of
every cell lowercased (`:573-576`), then (gate on) a third copy for `EditableCSVModel`
(`:587-588`). The `.table` branch in ContentView passes `file.contents` with **no byte
cap** — unlike editor mode (50 MB cap, `ContentView.swift:886`) and rendered markdown
(4 MB cap, `:1050`). CSVs load through `TextFileLoader` whose hard ceiling is 512 MiB.

**Impact:** Opening (or watcher-reloading) a multi-ten-MB CSV freezes the UI for the
whole parse + two copy passes — easily 1 s+ at 50 MB, worse on first open because the tab
body appears before `.onAppear` completes the parse. External tools appending to a
watched CSV re-pay the full cost per reload tick.

**Fix:** (a) add a table-mode byte cap with a placeholder (mirroring
`LargeEditorPlaceholderView`), routing oversized CSVs to source mode; (b) move
`reparse()` to a detached task with a `.loading` state and latest-wins guard (the
TSK-922/TabLoading pattern); (c) build the lowercase cache lazily on first filter
keystroke instead of eagerly per parse.

**Fix size:** M · **Fix risk:** careful (reparse also resets edit/formula/filter state —
the async hop must not let a stale parse clobber a newer edit session; latest-wins token
needed).

---

### F5 — InteractionProfiler (TSK-1488) is unwired: zero call sites, so no interaction is graded against its frame budget  · **P2**

**Where:** `Sources/ViewerCore/InteractionProfiler.swift` (defined, incl. per-kind p95
budgets at `:55-60`); `rg "InteractionProfiler\." Sources/` → **no callers**.

**Evidence:** The type ships `FramePercentiles`, `InteractionKind` budgets
(paletteKeystroke 16.7 ms, switchTab 33.3 ms, openFile 50 ms) and its header says "the
live CADisplayLink feed, the on-screen debug HUD, and the `vm-profile.sh` capture are the
render/VM tail" — that tail was never built. Meanwhile the PerfSignpost census (46 sites)
shows good coverage of open/materialize/session-switch/highlight/HexView, but **none** on
the paths where this audit found the problems: the CM6 inbound bridge
(`CodeMirrorEditorView.swift:904-947`), the find scan (F2), CSV reparse (F4), the status
bar metrics miss path (F3), the autosave fire (F6), or the FFI seam
(`Sources/RustCore/CoreClient.swift:110` — no signpost around `call`).

**Impact:** The "flag <60fps interactions with numbers not vibes" goal is structurally
unmet; regressions in exactly the per-keystroke class this report flags would ship
silently. A measurement gap, not a user-visible bug — but it is why F1–F4 survived to a
pre-launch audit.

**Fix:** Wire a display-link frame recorder started/stopped by interaction markers; add
PerfSignpost intervals to the six unmeasured paths above (one line each); surface
p95-over-budget through the existing observability ring (`Obs`).

**Fix size:** M · **Fix risk:** safe (additive instrumentation).

---

### F6 — Session autosave copies every dirty buffer and deep-compares full snapshots on the main actor per fire; persist re-writes ALL sessions  · **P2**

**Where:** `Sources/ViewerUI/Sessions/SessionsAppCoordinator.swift:549-567`
(`fireAutosave`), `:443` + `:556-559` (capture calls);
`Sources/ViewerCore/Sessions/SessionsCoordinator.swift:434-444` (`persist()`).

**Evidence:** Any tick of the merged publishers (`$tabs` fires on every tab mutation —
including the per-keystroke dirty-flag/buffer replace) schedules a 0.5 s-debounced
`fireAutosave` on the **main actor**, which runs `captureUnsavedTextForAllTabs()` (copies
every dirty buffer's full text into its Tab), `makeSnapshot()` (assembles all tab state
incl. hot-exit text), and `prev.hasSamePersistedContent(as: snap)` — an equality walk
that compares **full unsaved buffer strings**. That is O(total dirty bytes) of main-actor
work per quiescent typing window, plus the same again from the periodic flush timer even
when idle-with-dirty-buffers. On a real change, `persist()` then enqueues a snapshot
write for **every** session (`persistPlan` emits all sessions + index), so N-1 unchanged
sessions get re-encoded to JSON and atomically rewritten per fire (off-main via the
serial store queue, but redundant encode/IO churn; the store coalesces bursts by URL,
not across fires).

**Impact:** With a few MB of unsaved edits, every typing pause costs a few–tens of ms of
main-thread capture+compare; with several sessions, each real change rewrites every
session file. Not a visible freeze at typical sizes, but a standing per-pause tax that
scales with exactly the case hot-exit exists for (large unsaved buffers).

**Fix:** (a) short-circuit the compare with cheap per-tab fingerprints (buffer edit
counter / length) before any full-string equality; (b) mark-dirty per session and have
`persist()` enqueue only dirty sessions + the index; (c) move snapshot assembly off-main
with an immutable capture.

**Fix size:** M · **Fix risk:** careful (the snapshots-before-index crash-safety
invariant (TSK-1029) must be preserved; equality-guard teeth tests exist).

---

### F7 — External-edit reconcile / conflict resolution read the whole file synchronously on the main actor  · **P2**

**Where:** `Sources/ViewerUI/DocumentModel.swift:2988` (`reconcileExternalEdit`),
`:3022` (`beginConflictResolution`); invoked per file-watcher external-change event via
`applyExternalAutoMerge` (`:3001-3012`).

**Evidence:** Both paths do `try? String(contentsOf: url, encoding: buf.encoding)` on the
`@MainActor` `DocumentModel`, then run a 3-way merge (`ExternalEditReconciler.reconcile` /
`ThreeWayMerge.merge` — O(N) diff3) still on main. The watcher fires this on **every**
external modification of a dirty-buffer file: an external tool appending to a file the
user has open-and-dirty (log follower, formatter, `git checkout`) triggers a full
synchronous disk read + merge per event. A cold or iCloud-stubbed file makes the read a
blocking download (the same class the TSK-842 defer threshold was built to avoid — this
path bypasses it).

**Impact:** Repeated UI hitches during external-edit storms on large files; unbounded
stall if the file is network/iCloud-backed. Frequency-bounded by the watcher debounce,
but each fire is a full O(file) main-thread read+merge.

**Fix:** Hop the read + merge to a detached task; commit the `.autoMerged`/conflict
outcome on main with a latest-wins guard against a newer buffer edit (the codebase's
standard token pattern).

**Fix size:** S–M · **Fix risk:** careful (merge-vs-live-typing race needs the guard;
the decision half is host-tested so behavior is pinned).

---

### F8 — Off-main-read decision is size-only: a small iCloud-evicted (dataless) file still reads synchronously on main and blocks on its network download  · **P2**

**Where:** `Sources/ViewerUI/DocumentModel.swift:2504-2512` (`shouldDeferOpenOffMain`),
threshold at `Sources/ViewerCore/TextFileLoader.swift:194` (`deferReadOffMainBytes` = 4 MiB).

**Evidence:** The defer decision is `bytes > threshold` from a stat. A dataless/evicted
iCloud (or FileProvider) file reports its full logical size but reading it materializes
the download; any such file **under 4 MiB** takes the synchronous main-thread path in
`openResolved`, so `Data(contentsOf:)` blocks the UI for the entire network fetch. The
loader's own doc comment (`TextFileLoader.swift:178-180`) identifies "cold / iCloud-
stubbed" reads as the motivating stall — the guard only fixes the large-file half.

**Impact:** Multi-second UI freeze opening a small cloud-evicted file on a slow
connection — likely reported as "app hangs opening my file" and unreproducible locally.

**Fix:** In `shouldDeferOpenOffMain`, also defer when the URL's resource values indicate
not-downloaded/dataless (`ubiquitousItemDownloadingStatus != .current`, and the
FileProvider/dataless flags where available). Stat + resource-value read stays cheap.

**Fix size:** S · **Fix risk:** safe (worst case: an extra `.loading` flash on files
that would have read fast).

---

### F9 — Split pane stats the file synchronously inside `body` on every invalidation  · **P3**

**Where:** `Sources/ViewerUI/SplitPaneView.swift:57-64`
(`isSplitFileTooLargeForSyncRead` → `FileManager.attributesOfItem`), evaluated from
`textContent` (`:160`) on every body eval — which per `:30-34` is every keystroke while
a split is open.

**Evidence:** One `stat` + a fresh `TextFileLoader()` per body eval. Locally ~µs; on
SMB/NFS/FileProvider volumes each `attributesOfItem` can block on network round-trips —
inside `body`, per keystroke. The StatusBar solved this exact problem with a 1 s TTL stat
cache (`StatusBar.swift:697-721`).

**Fix:** Compute once per URL alongside the existing `.task(id: url)` load and store in
`@State`.

**Fix size:** S · **Fix risk:** safe.

---

### F10 — Interactive find duplicates the ported Rust find engine with a slower Swift/ICU loop  · **P3**

**Where:** `Sources/ViewerUI/TextDisplayView.swift:1516-1529` vs
`Sources/ViewerCore/RustFindAdapter.swift:26` (memchr/`memmem`-backed, TSK-630 port;
only caller is the automation host, `DocumentModel+AutomationHost.swift:197`).

**Evidence:** The migration policy names the Rust find engine as the engine of record,
with `memmem` explicitly wired for find-all hot paths (owner-approved 2026-06-27). The
interactive path re-implements literal search as an `NSString.range(of:)` loop (ICU
compare per window) — the slower engine sits on the hottest path. Fold into the F2 fix:
routing through `RustFindAdapter` gets the SIMD scan for free (note the adapter's
`memmem` is case-sensitive; case-insensitive needs the engine's dedicated path, so option
mapping needs care).

**Fix size:** S (as part of F2) · **Fix risk:** careful (NSRange/UTF-16 vs byte-offset
mapping for match ranges must be exact — highlight painting consumes NSRanges).

---

### F11 — ArchiveCatalog subprocess wait busy-polls  · **P3**

**Where:** `Sources/ViewerCore/Archive/ArchiveCatalog.swift:211-220`.

**Evidence:** `while p.isRunning, Date() < deadline { Thread.sleep(0.02) }` then
`while !reader.isFinished { Thread.sleep(0.005) }`. Callers are off-main
(`ArchiveBrowserView.swift:226,255,274` use detached tasks), so this only burns a
background thread at 50–200 Hz for the duration of `unzip`/`tar` — wasteful but not
user-visible. `terminationHandler` + a semaphore-with-timeout removes the polling.

**Fix size:** S · **Fix risk:** safe.

---

### F12 — Dead synchronous render API invites regression of the TSK-611 fix  · **P3**

**Where:** `Sources/ViewerUI/DocumentModel+RenderedCache.swift:25-50`
(`renderedHTML(forTabID:...)`).

**Evidence:** The sync build-on-miss variant ("Call from a SwiftUI body — it's
main-thread, sync") has **zero callers** (census: only the definition). It is exactly the
API whose inline use caused the 927 ms body-eval stall TSK-611 removed. Leaving a
documented-as-body-callable sync render around is a footgun; the split pane (F1)
demonstrates the pattern recurring.

**Fix:** Delete it (or deprecate + assert-on-main-with-large-input) once F1 stops
needing a sync path.

**Fix size:** S · **Fix risk:** safe.

---

### F13 — No shared buffer-version token: three per-keystroke consumers each re-derive O(N) facts from the fresh full-buffer String  · **P3** (architectural note)

**Where:** `Sources/ViewerUI/CodeMirrorEditorView.swift:916-947` (each inbound change —
incremental or full — materializes a complete new `String` via
`RustCMEditAdapter.apply` and fans it out through `onTextChange`).

**Evidence:** The v2 incremental protocol saves the **IPC** cost (good), but Swift-side
consumers then each re-derive O(N) facts from the fresh String: F3's hash+scans, F6's
capture/compare, dirty-diff checks. A monotonically-increasing buffer version (already
implicit in the edit stream) attached to `EditorBuffer` would let every consumer key its
cache on `(tabID, version)` instead of content hashing — turning three O(N)
per-keystroke consumers into O(1). This is the umbrella fix for the caching halves of
F3/F6.

**Fix size:** M · **Fix risk:** careful (version must bump on *every* mutation path:
CM6 change, reload, merge-apply, transforms).

---

## Positive observations

Genuinely strong work worth preserving through the fixes above:

- **File-open path is exemplary:** stat-before-read refusal, two-tier caps, a dedicated
  4 MiB off-main-defer threshold distinct from the 64 MiB degradation watermark, mtime
  captured once as the derived-product cache key (`TextFileLoader.swift` throughout);
  latest-switch-wins guards on every async load commit (`DocumentModel+TabLoading.swift`).
- **Rendered-markdown pipeline:** cache-only body reads + off-main cold render (TSK-611),
  mounted-aware LRU eviction (TSK-621), warm-WKWebView parking bounded at 4 (TSK-1042),
  block-level patch instead of full reloads where alignment holds
  (`MarkdownRenderedView.swift:150-166`).
- **Per-keystroke discipline where it was measured:** status-bar metric cache with teeth
  (TSK-971), find-highlight idempotence keys killing hover-driven repaints (TSK-736),
  selection-highlight 150 ms throttle with large-file bail, terminal 60 Hz leading-edge
  frame throttle (`TerminalModel.swift:142-145`), CSV filter lowercase cache with a
  256 KB crossover threshold.
- **Off-main IO discipline:** sidebar enumeration off-main, git diff-gutter (debounced,
  3 s timeout, payload built off-main), git chip caching to kill the
  `waitUntilExit`-nested-runloop trap, session store's single serial coalescing write
  queue with crash-safe snapshot-before-index ordering.
- **Startup:** TreeSitter grammar warm-up off-main at utility priority prioritizing
  markdown (TSK-619/840), LSP pool started fire-and-forget, no module-scope IO beyond the
  launch-config probe; `DocumentModel.init` reads only small JSON stores.
- **Measurement infra exists and is real:** PerfSignpost categories map to the actual
  pipeline stages; `vm-profile.sh` + EditorPerfBench + perf benches in the host gate. The
  gap is coverage (F5), not capability.

## Coverage gaps (what this pass did NOT examine)

- **Rust crate internals** beyond a size/anti-pattern census: `markdown.rs`, `csv.rs`,
  `find.rs`, `fuzzy.rs`, the `canvas/` DSL, and the `serve`/`tui`/`web`/`highlight`/`pm`
  crates. The 2026-06-09 rust-core production audit covers this tier; its perf claims
  were not re-verified here.
- **FFI seam micro-costs** (MessagePack encode/decode allocation profile in
  `Sources/RustCore/MessagePack.swift`, frame copies in `CoreClient.call`) — flagged only
  where a whole buffer crosses per keystroke (F3).
- **WKWebView/JS side:** `codemirror.js` bundle internals (JS-side debounce windows,
  decoration churn), mermaid render scheduling, canvas web assets.
- **LSP subsystem** (pool scheduling, diagnostics push volume), **Terminal PTY**
  throughput beyond the throttle, **Git panel** refresh cost beyond timer cadence,
  **ImageEditing / Audio / PDF** pipelines, **Automation/MCP** tool dispatch latency
  (only a polling-pattern grep of `MCPSocketBridge` was done).
- **Runtime measurement:** no profiling was run (static review only, per constraints).
  The ms figures quoted from code comments (927 ms, ~8 ms warm read) are the codebase's
  own measurements; my per-size stall estimates are order-of-magnitude reasoning, not new
  measurements. F1–F4 should be confirmed with a signpost capture on the VM
  (`scripts/vm-profile.sh`) as part of the fix tickets.
- **Memory footprint** (phys_footprint under many-tab / warm-cache load) — out of scope
  for this latency-focused pass.
