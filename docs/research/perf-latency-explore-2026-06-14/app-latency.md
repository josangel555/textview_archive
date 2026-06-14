# App latency / responsiveness — measured exploration (2026-06-14)

Blank-slate exploration of the app's felt latency: startup, file-open, scroll/type,
view-mode switching, navigation, WebView paint, the FFI seam, and the SwiftUI
`body`/observation hot path. **MEASURE-don't-guess**: two release-build signpost
traces were captured on the UTM VM via `scripts/vm-profile.sh` (the only honest
WindowServer surface — host UI is off-limits per owner directive). Every finding is
tagged **MEASURED** (in a trace / self-evident from code) vs **SUSPECTED** (needs a
dedicated trace to rank).

## How this was measured

- **Trace A — source-open** (`vm-profile.sh Sources/ViewerUI/DocumentModel.swift 20 open release`):
  release `dist/TextView.app` launched with the file as argv, `MDV_SIGNPOSTS=1`,
  Time Profiler + `os_signpost`. 21 `com.markdownviewer.MarkdownViewer` intervals.
- **Trace B — nav sweep** (`vm-profile.sh … 22 nav release`): open the target + 5
  lazy-appended mixed-type files (workspace-restore shape), then `nav-sweep 2`
  (12 tab switches + sidebar/view toggles). 176 of our intervals + the AppKit /
  CoreAnimation / SkyLight lanes.
- Both traces parsed for our signposts AND for `com.apple.coreanimation`
  `Transaction.Stalls` (the WindowServer's own "this CA commit blocked the main
  thread" marker) — the most direct proxy for felt jank.

Raw trace: `$TMPDIR/mdv-vm-profile.trace` (overwritten per run; re-capture with the
commands above). Numbers below are from these two runs on the VM (Apple-VM, 6 GiB);
host hardware will be faster in absolute terms but the *shape* holds.

---

## Headline (the measured picture)

The model/logic layer is **fast** — the synchronous `navSweep.tabSwitch` model call
is **1.4–12.6 ms**, `DocumentModel.openResolved` is **9.6–20.5 ms**, `load`+decode is
**1–5 ms** for normal files. The observation discipline (per-tab `HighlightCacheActor`,
`SourceViewChannel`, narrow `@ObservedObject` wiring) is genuinely good and intact.

**The felt latency is almost entirely downstream of the model, in three places the
traces light up:**

1. **Rendered-Markdown WebView paint is multi-SECOND.** `WKWebView.loadToFinish`
   measured **2.0, 4.2, 4.8, 6.0, 8.9 s** in one nav sweep, and the loads *overlap*
   (a reload storm — a new `loadHTMLString` fires before the prior reached
   `didFinish`). This is the single biggest felt latency in the app.
2. **Every navigation action triggers a 30–366 ms main-thread CoreAnimation commit
   stall.** 43 `Transaction.Stalls` totaling **3.35 s** over a 17 s sweep; **12 of
   them > 100 ms**. This is the measured substance of "navigation/tab-switch is
   slow/janky."
3. **Launch fires a 15-grammar TreeSitter query-compile burst, serialized on ONE
   thread** — **231 ms of CPU** (first compile alone 114 ms) packed into a ~240 ms
   wall window that collides with the first window paint (a 283 ms CA stall lands
   right as it finishes). Other cores sit idle.

Everything else is second-order (per-element allocs, O(N) fingerprint walks).

---

## Ranked findings

Ranked by **(felt user impact × confidence)**. Effort S/M/L.

| # | Finding | file:line | Measured? | Impact | Effort | Suggested fix |
|---|---------|-----------|-----------|--------|--------|---------------|
| 1 | **Rendered-MD WKWebView `loadToFinish` = 2–9 s, and reloads overlap into a storm.** Each content/tab change calls `loadHTMLString(_:baseURL:)` which re-parses + re-lays-out the *whole* document in the WebContent process. 5 loads in one sweep: 8.86 / 5.95 / 4.77 / 4.17 / 1.99 s, time-overlapping. | `MarkdownRenderedView.swift:208-240` (`loadHTMLString` per change); `ContentView.swift:814-840` (cache-read + `.task` re-render) | **MEASURED** (Trace B) | **Very High** | **L** | Stop full-document reloads on every change: keep ONE persistent WebView page and patch the DOM via `evaluateJavaScript` (incremental innerHTML / morphdom-style), reserving `loadHTMLString` for first mount only. Coalesce/cancel superseded loads so they can't pile up. (Extends/quantifies TSK-624.) |
| 2 | **Every nav action → 30–366 ms main-thread CA commit stall.** The `navSweep.*` model call is cheap (≤12 ms) but each one re-renders the SwiftUI content tree, whose CoreAnimation commit blocks main. 43 stalls / 3.35 s / 12×>100 ms in 17 s. | SwiftUI re-render of `ContentView.content` + retained source/web panes; commit measured in `com.apple.coreanimation Transaction.Stalls` | **MEASURED** (Trace B) | **Very High** | **M** | Profile *which* subtree's commit stalls (Time-Profiler stacks under the stall window, debug config). Likely culprits: re-mounting a pane that fell out of the 4-slot `mountedPanes` LRU, or the rendered-MD WebView re-compositing. Candidate fixes: widen/retune `mountedPanes`, ensure the toggled chrome doesn't force the center pane to relayout, give occluded panes their own compositing layer (LESSONS compositor rule). MEASURE the stack first. |
| 3 | **Launch grammar warm is single-threaded + eager-for-ALL-languages: 231 ms CPU serialized in ~240 ms, colliding with first paint.** `warm()` loops `bundle(for:)` over every `HighlightLanguage` on one `.utility` task; the trace shows 15 back-to-back `ts.query-compile` (114 ms + 33 + 16 + …) finishing exactly as the window's first paint takes a 283 ms CA stall. | `TreeSitterEngine.swift:262-266` (serial `for` loop); `main.swift:124-126` (single detached task) | **MEASURED** (Trace A) | **High** (first-open stall + launch CPU) | **S** | Two cheap wins: (a) **parallelize** the warm across a `TaskGroup`/`concurrentPerform` — per-language compile locks already make it safe, compresses 231 ms serial → ~max-single ≈115 ms wall and frees cores for first paint; (b) **prioritize** the grammar of the file actually being opened + `markdown` (code-fence path) FIRST, warm the long tail after first paint. |
| 4 | **First-paint of the source view = 283 ms main-thread CA commit stall** (`SourceTextController.apply` 18.75 ms, but the commit that paints it stalls 283 ms). NSTextView builds full-document TextKit glyph layout inside the WindowServer commit. | `TextDisplayView.swift:870-885` (`apply` → `needsDisplay`); commit in `coreanimation Transaction.Stalls` | **MEASURED** (Trace A) | **High** (felt on first open of any source file) | **M** | Partly one-time window cost. To cut the per-open share: confirm TextKit isn't laying out off-screen glyphs (cap `NSTextContainer`/`maximumNumberOfLines` to viewport, lazy layout); consider TextKit2 for the read-only source view; ensure the first paint uses the empty-runs fast path (it does) so highlight arrives as the cheap in-place re-fix (confirmed: 2nd apply = 0.5–1.3 ms). MEASURE the TextKit share with a Time-Profiler stack under the stall. |
| 5 | **Files up to 64 MiB are read + UTF-8-decoded synchronously on the main thread.** `openResolved` only defers off-main above `softWarnBytes` (**64 MiB**); below it, `controller.open` → `Data(contentsOf:)` + `String(data:as:.utf8)` (O(N)) run on main before the tab mounts. A 40 MB log = a multi-hundred-ms main-thread stall with no `.loading` placeholder. | `DocumentModel.swift:4218-4229` (`shouldDeferOpenOffMain`); `TextFileLoader.swift:144,156` (64 MiB watermark); `:194-205` (sync read+decode) | **MEASURED** (code path is self-evidently sync; the 64 MiB threshold is the knob) — exact ms is **SUSPECTED**, needs a large-file open trace | **High** (felt on big logs/source) | **S** | Lower the off-main defer threshold dramatically (e.g. 1–4 MiB). The off-main machinery (`openLargeFileOffMain`, `.loading` placeholder, identity-guarded swap) already exists and is correct — just route more opens through it. The 64 MiB watermark conflates "read off-main" with "large-read-only mode"; split the two knobs. |
| 6 | **FFI response is copied whole into a Swift `[UInt8]` before decode** — `Array(UnsafeBufferPointer(start: buf.data, count: buf.len))` at the receive seam. Hex render returns ~18 MB → an 18 MB memcpy on the call thread per call. Recurs at ~7 sites. | `CoreClient.swift:102` (+ 302/401/564/588/621) | **MEASURED** (copy is self-evident); felt-ranking **SUSPECTED** | Medium→High (hex/large-MD/transcript) | M | Decode directly from the `MdvBuf` pointer (a `MsgPackReader` over `UnsafeRawBufferPointer` bounded by `buf.len`, before `mdvcore_buf_free`). The Rust side is already zero-copy; the cost is entirely Swift-receive. **(Already ticketed TSK-826 — this trace adds the hex blast-radius.)** |
| 7 | **`ContentFingerprint(text)` walks the whole UTF-8 view (`text.utf8.count`, O(N)) and is computed ≥2–3× per `apply`** — the "cheap change-check" that gates re-paint defeats itself on large files. Also `cachedTextByteCount = text.utf8.count` recomputed each apply. With 4 retained panes re-applying per nav action, several full-document byte walks per nav even when nothing changed. | `TextDisplayView.swift:362-370` (`ContentFingerprint`), `:840` (`cachedTextByteCount`), `:991/1137/1170` (3 call sites) | **MEASURED** (O(N) walk is certain); felt-ranking **SUSPECTED** (needs large-file nav trace) | Medium (large files) | S | Compute `utf8.count` once per content change and cache it on the controller keyed by object identity; have the fingerprint take the precomputed count. Or fingerprint from `String`'s identity/`count` cheaply. Removes the redundant O(N) walks from the nav hot path. |
| 8 | **Switching to a not-yet-materialized (lazy/restored) tab pays a full sync read+decode+first-paint on the switch.** `materializeIfNeeded` interval hit **45.9 ms / 91.7 ms**, with `load` 32–50 ms inside, then a 60–108 ms `apply`. The read is off-main but the switch still feels heavy because first-paint layout + CA commit land on main right after. | `DocumentModel.swift:5004-5067` (`materializeIfNeeded`); `:4870` (called from `selectTab`) | **MEASURED** (Trace B) | Medium-High | M | Prefetch/warm the *neighbouring* tabs' content off-main when a tab gains focus (so a left/right switch is already materialized), or eagerly materialize the active session's first N tabs at low priority after first paint. Cap by memory. |
| 9 | **TreeSitter tokenize bridges the whole file to `NSString` + `substring(with:)` per predicate match.** `text as NSString` (one-time O(N)) + a per-match `substring` for every `#match?`/`#eq?`-gated capture (TS/JS/Rust grammars). Off-main, so not a main-thread stall — but it delays highlight arrival on large predicate-heavy files. | `TreeSitterEngine.swift:94-99` | **SUSPECTED** (needs a predicate-heavy large-file tokenize trace) | Medium (large source) | S | Feed the predicate text provider from the UTF-8/UTF-16 view by range without the per-match `substring` alloc; memoize the bridge. **(Already ticketed TSK-827.)** |
| 10 | **Per-row `FileRowState.make(...)` runs for EVERY visible sidebar row on every `SidebarView` body re-eval** — it's an argument expression, so `.equatable()` short-circuits the child *body* but NOT `make`. Each is O(1) dict lookups (git status, tracked-repo, bookmarks, open-tabs), but ×(hundreds of rows)×(every model/sidebar republish). | `SidebarView.swift:581-595` (eager `make` in `ForEach`); `:1220-1245` (`make` body) | **MEASURED** (code path certain); felt-ranking **SUSPECTED** (needs a big-tree sidebar trace) | Low-Medium | M | Memoize the row-state vector keyed by `(selection, currentURL, gitStatusVersion, recencyVersion, trackedReposVersion)` so an unrelated republish reuses it; only recompute when an input version actually changed. (Relates to the still-open TSK-591 mouse-over-lag; the hover `@State` is row-local, so the lag is more likely this republish churn + `.help`/cursor-stack per row than the hover itself.) |
| 11 | **`NSCursor.pointingHand.push()/pop()` per row on every hover enter/leave** — adjacent-row enter/leave ordering isn't guaranteed, so the AppKit cursor stack can grow/shrink as the pointer sweeps the tree; plus `.help(node.url.path)` adds a tracking rect per row. | `SidebarView.swift:1450-1454` (`onHover` push/pop), `:1424` (`.help`) | **SUSPECTED** (needs a hover-sweep trace; relates to TSK-591) | Low-Medium | S | Use `.cursor(.pointingHand)` (declarative, no manual stack) or set the cursor once via a tracking area on the list, not per-row push/pop. Verify on the VM that hover sweep no longer churns the cursor stack. |

---

## Executive summary

**Where the time actually goes (measured).** The app's *logic* is fast — model
mutations for open/switch/toggle are single-digit-to-low-double-digit ms. What the
user *feels* is the rendering tail:

```
felt latency  =  WebView multi-second loads (#1)
              +  per-nav CA commit stalls 30–366 ms (#2)
              +  launch grammar-warm burst colliding with first paint (#3, #4)
              +  (large files) sync main-thread read at the 64 MiB cliff (#5)
```

- **#1 rendered-Markdown WebView (2–9 s, storming)** is the highest-leverage fix and
  the one users hit constantly (every MD file is the app's namesake use case). It's an
  L-effort architectural change (persistent page + DOM patch vs full `loadHTMLString`
  reload) but it dwarfs everything else. It extends TSK-624, which only *observed* the
  non-completion; this run *quantifies* it (2.0–8.9 s) and identifies the reload-storm
  overlap as the mechanism.
- **#2 CA commit stalls per nav** is the measured root of the long-standing
  "navigation/tab-switch is slow" complaints (TSK-108/266/273/591/603 — all marked
  validated, yet the stalls persist in a fresh release trace). The model fixes landed;
  the *compositor* cost did not. Needs a Time-Profiler stack under one stall window
  (debug config) to attribute the subtree before fixing — don't guess.
- **#3 launch grammar warm** is the cleanest win: S-effort, high-confidence,
  parallelize + prioritize. 231 ms serial CPU → ~115 ms wall and off the first-paint
  critical path.
- **#5 the 64 MiB sync-read cliff** is a one-line-ish knob change with existing,
  correct off-main machinery behind it — high value for big-file users, low risk.

**What's already good (don't re-file).** Verified resolved while exploring:
`LineNumberRulerView` byte-scan (TSK-828, `:124` now a single `utf8` pass);
status-bar memory sampler is change-gated (`StatusBarMemory.swift:84`) and
self-scoped; cold MD render is off-main with a spinner (TSK-611,
`ContentView.swift:808-839`); the plain→highlight 2nd `apply` is the cheap in-place
re-fix (`TextDisplayView.swift:1017-1051`, measured 0.5–1.3 ms); `refreshDiffMarks`
is off-main + debounced; lazy-tab materialize is off-main + identity-guarded;
`flatVisibleRows()` is memoized.

---

## Which to turn into board tickets

Dedup note: the parent (TSK-837) synthesizes across the unprimed agents + prior
audits. Net-NEW vs the existing board (TSK-826 FFI, 827 tokenize, 828 ruler done,
624 MD-WebView observed, 543/791 editor typing, 591/592/603 nav umbrella):

1. **NEW — Rendered-MD: persistent WebView page + incremental DOM patch (kill the
   `loadHTMLString` reload storm).** Promote from TSK-624's "observe" to a real fix.
   Highest felt impact. Effort L. *Measure baseline loadToFinish before/after.*
2. **NEW — Attribute the per-nav CoreAnimation commit stall (30–366 ms).** Spike:
   debug Time-Profiler stacks under a stall window during a nav sweep; then fix the
   identified subtree (pane re-mount / WebView re-composite). This is what TSK-591/603
   were *trying* to fix at the model layer; the real cost is the commit. Effort M.
3. **NEW — Parallelize + prioritize the launch grammar warm.** `TaskGroup` across
   languages; warm the opened file's language + markdown first. Effort S, high
   confidence. *Re-trace launch to confirm the burst compresses + first-paint stall
   shrinks.*
4. **NEW — Lower the off-main file-read threshold from 64 MiB.** Split "read off-main"
   from "large-read-only mode"; route ≥~2–4 MiB through the existing
   `openLargeFileOffMain` path. Effort S. *Trace a 20–40 MB open before/after.*
5. **NEW — `ContentFingerprint`/`cachedTextByteCount` O(N) `utf8.count` recomputed
   per apply.** Cache the byte count per content change. Effort S. Bundle with the
   source-view apply path.
6. **NEW — Memoize the sidebar per-row `FileRowState` vector** (version-keyed) +
   switch hover cursor to declarative `.cursor()`. Folds into the still-open TSK-591.
   Effort S–M. *Measure a big-tree sidebar republish + hover sweep first.*
7. Reference-only (already ticketed): #6→TSK-826 (add hex blast-radius note),
   #9→TSK-827, #4 source-paint relates to TSK-619.

**Caveat on the VM numbers.** Absolute ms are from a 6 GiB Apple-VM and run a bit
slower than host hardware, but the *ratios and shapes* (WebView seconds ≫ CA stalls
≫ model calls) are hardware-independent. Re-capture on demand:
`bash scripts/vm-profile.sh <file> 20 open release` /
`bash scripts/vm-profile.sh <file> 22 nav release`.
