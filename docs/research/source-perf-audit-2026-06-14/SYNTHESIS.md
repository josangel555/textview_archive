# Source Performance + Inefficiency Audit — 2026-06-14

Read-only audit of `Sources/**` (Swift) and `rust-core/**` (Rust) for hot-path
allocations, quadratic/superlinear loops, redundant recomputation, unnecessary
copies/conversions, main-thread blocking, missing change-detection guards,
inefficient data structures, and FFI/serialization overhead.

**Method.** Read the real code on the hot paths the task named (file open/load,
tree-sitter highlight, the SwiftUI `body` re-eval path, the FFI boundary,
find/search, status-bar metrics, CSV/JSON parsing) plus a broad grep sweep for
the classic anti-patterns. Each finding cites `file:line` and is tagged
**measured/obvious** vs **suspected (needs a profiler trace)**, per the project's
MEASURE-don't-guess rule.

**Headline.** The codebase is already unusually perf-disciplined — narrow
observation, per-tab caches, single-allocation frame encode, borrowed wire
decode, sweep-line paint-over, scalar-streaming parsers. The remaining wins are
mostly **second-order**: a systematic FFI response double-copy (one already
filed as TSK-564, but it recurs at 7 sites the ticket doesn't enumerate), a few
**per-element heap allocations inside tokenize/render loops**, one **per-draw
O(N) ObjC message-send loop** in the line-number ruler, an **always-publishing
1.5 s memory timer** that wakes the status-bar body, and a **single-threaded
cross-file search** that leaves cores on the floor. None are five-alarm; several
are clear, low-risk, low-effort wins.

---

## Prioritized findings

Ranked by (impact × confidence). "Felt" = user-perceivable; "micro" = real but
sub-perceptual without a magnifier. Effort/risk are S/M/L.

| # | Finding | file:line | Impact | Effort | Risk | Needs profiling? |
|---|---------|-----------|--------|--------|------|------------------|
| 1 | **FFI response double-copy is systemic** — every `MdvBuf`→`Array(UnsafeBufferPointer)`→`unframe`→`MsgPackReader([UInt8])` path copies the response frame **twice** (buf→Array, then borrowed-decode re-walks). 7 sites, not just TSK-564's one. Hex render returns ~18 MB → copied whole. | `Sources/RustCore/CoreClient.swift:102,302,401,564,588,621` | Felt (large hex/markdown/transcript) | M | M | No (obvious copy; profile to rank vs #2) |
| 2 | **`TreeSitterEngine.tokenize` bridges the whole file to `NSString` + `substring(with:)` per predicate match** | `Sources/ViewerCore/Highlight/TreeSitterEngine.swift:94-99` | Felt on predicate-heavy grammars (TS/JS/Rust), large files | S | L | Yes (cost scales with predicate-gated capture count) |
| 3 | **`LineNumberRulerView.ensureCacheBuilt` walks the buffer with `ns.character(at: i)` per UTF-16 unit** — an ObjC message-send per character to build the newline table | `Sources/ViewerUI/LineNumberRulerView.swift:112-125` | Felt (first scroll of a large Source-lens file: visible hitch) | S | L | No (obvious; the O(N) msg-send loop is the cost) |
| 4 | **Status-bar memory sampler publishes every 1.5 s unconditionally** — `appFootprintBytes = …` fires `objectWillChange` even when the value is unchanged, re-bodying the whole `StatusBar` every 1.5 s forever | `Sources/ViewerUI/StatusBarMemory.swift:73-75` | Felt-ish (idle CPU/wakeups; steady body churn) | S | L | No (obvious unconditional publish) |
| 5 | **`CrossFileSearch.search` is single-threaded** — the entire tree walk + read + decode + per-line match runs on one worker; large repos leave N-1 cores idle | `Sources/ViewerCore/CrossFileSearch.swift:128-290` | Felt (project-wide search latency on big trees) | M | M | Yes (confirm I/O- vs CPU-bound first) |
| 6 | **`highlight::runs_utf16` allocates a `String` per run via `kind.to_string()`** — the kind is a `&'static str`; a 5 k-token file makes 5 k throwaway `String`s | `rust-core/crates/highlight/src/runs.rs:188` | Micro→felt on large files | S | L | No (obvious; `Cow`/intern fixes it) |
| 7 | **`HTMLRenderer.spanned` calls `run.kind.rawValue.lowercased()` per run** + `NSString.substring(with:)` per run during code-fence highlight splice | `Sources/ViewerCore/HTMLRenderer.swift:331-336` | Micro→felt (markdown with many/large code fences) | S | L | No (obvious per-run alloc) |
| 8 | **`FuzzyMatcher.match` allocates two `String`s per character compare** (`ch.lowercased() == q[qi].lowercased()`) — still the live path for `FileTreeFilter`/sidebar per-node matching | `Sources/ViewerCore/FuzzyMatcher.swift:39` | Micro (bugfix-only under migration policy; see notes) | S | L | Yes (per-keystroke sidebar filter on big trees) |
| 9 | **`CSVTableView` lowercased-rows cache rebuilds the entire `[[String]]` on every reparse** even when only the filter changed; doubles peak CSV memory ≥256 KB | `Sources/ViewerUI/CSVTableView.swift:175-182` | Micro (already debounced; memory more than CPU) | S | L | Yes (memory attribution) |
| 10 | **`SelectionHighlightEngine.otherOccurrences` re-runs `NSString.range(of:)` from offset 0 each selection** — O(matches·N) ObjC scan on the main actor per caret move (capped at 5 MB) | `Sources/ViewerUI/SelectionHighlightEngine.swift:98-111` | Micro (5 MB cap bounds it) | S | L | Yes (does it run on main? confirm cadence) |
| 11 | **`MsgPackReader.mapValue()` rebuilds a `[String:MsgPackValue]` dict on every decode** — every response map is decoded to an ordered pair-array, then re-hashed into a dict; `require()` then does dict lookups | `Sources/RustCore/MessagePack.swift:195-204` | Micro | S | L | No (obvious extra hashing) |
| 12 | **`StatusBar.gitChip` reads `.git/HEAD` from disk on every body re-eval** via `SessionGitInfo.footerLabel` (no TTL cache like the size/date chips have) | `Sources/ViewerUI/StatusBar.swift:166-208` | Micro (small file read, but on the body hot path) | S | M | Yes (confirm body cadence + read cost) |

---

## Executive summary

**What's already good (so we don't re-file it).** The team has clearly done
real perf work and it shows:

- **Narrow observation discipline** — `HighlightCacheActor` (per-tab `version`
  channel), `SourceViewChannel`, `TabCoordinator` are all observed directly so a
  caret tick / tokenize completion / terminal byte doesn't republish
  `DocumentModel`. This is the single biggest structural win and it's intact.
- **Status-bar metrics are cached** by `(url, byteCount)` and `(url, mtime)`
  with TTLs, so the body path doesn't re-walk the file or `stat` per re-eval
  (`StatusBar.swift:511-605`). Good.
- **Rust wire layer**: `encode_frame` is single-allocation (length placeholder +
  serialize-in-place, `wire.rs:194`); `decode_frame_borrowed` lets whole-document
  request fields point into the frame (`wire.rs:163`); `snapshot_frame` /
  `table_frame` serialize straight from arena borrows (no owned-row clone).
- **Parsers stream scalars** (`CSVParser`, `CrossFileSearch.splitLines`) instead
  of materializing `Array(text.unicodeScalars)`; CSV tracks `fieldScalarCount`
  explicitly to dodge the O(N²) `unicodeScalars.count` trap.
- **`paintOver`** is a sweep-line O(K log K) overlap resolver, not the old
  per-character canvas.
- **`renderedHTMLCache`** keys on `(tab, byteCount, mtime)` — O(1), no content
  hash walk per body.

**The recurring theme in the remaining findings** is **per-element work inside a
loop that runs over a whole document**: a `String`/`NSString` allocation per
token, per run, per character, per response frame. Individually small; in
aggregate they're the bulk of what's left. The FFI double-copy (#1) is the one
with the biggest single-payload blast radius (hex/markdown/transcript responses
are multi-MB).

**The FFI boundary (#1, #11) is the highest-leverage area** because *every*
ported engine (find, markdown, transcript, highlight, fuzzy, diff, hex) funnels
through it, and the Rust migration is actively moving more load there. A copy
saved at the seam is a copy saved for all of them. The Rust SIDE is already
zero-copy on encode/decode; the COST that remains is entirely on the **Swift
receive side** (`Array(UnsafeBufferPointer…)`).

**Nothing here is a correctness risk or a regression.** These are optimizations
on a healthy base. Most are S-effort; the ones worth a ticket-and-measure cycle
are #1, #2, #3, #5.

---

## Suggested next actions (which to turn into board tickets)

Ordered by recommended sequence:

1. **TSK — FFI receive-side single-copy (extends TSK-564).** Today TSK-564 only
   tackled the `frame[4...]` body copy via `frameBodyStart`. The bigger copy is
   `Array(UnsafeBufferPointer(start: buf.data, count: buf.len))` at 7 sites
   (`CoreClient.swift:102/302/401/564/588/621`). Decode **directly from the
   `MdvBuf` pointer** (a `MsgPackReader` over an `UnsafeBufferPointer<UInt8>` or
   `UnsafeRawBufferPointer`, bounded by `buf.len`, decoded before `mdvcore_buf_free`)
   so the response frame is never copied into a Swift `[UInt8]` at all. Biggest
   win on hex-render (~18 MB) and large markdown/transcript. **Measure first**
   with `PerfSignpost`/xctrace to rank vs #2. Confidence high, effort M.

2. **TSK — tokenize predicate text provider without the full-file NSString
   bridge.** `TreeSitterEngine.tokenize` does `text as NSString` then
   `ns.substring(with:)` per predicate match (`TreeSitterEngine.swift:94-99`).
   The `as NSString` is a one-time O(N) bridge; the per-match `substring` is the
   churn. Profile a TS/JS/Rust file with many `#match?`-gated captures to confirm
   the predicate path dominates, then feed the provider from the UTF-16 view
   directly (or memoize the bridge). Confidence medium (needs trace), effort S.

3. **TSK — `LineNumberRulerView.ensureCacheBuilt` byte scan.** Replace the
   `ns.character(at: i)` per-unit loop with a single `text.utf8`/`enumerateBytes`
   pass (newline is a single UTF-8 byte `0x0A`, safe to scan at the byte level)
   to build the offset table. Felt on first scroll of a large Source-lens log.
   Confidence high, effort S, risk low. **No profiling needed** — the per-char
   ObjC message-send is self-evidently the cost.

4. **TSK — gate the memory sampler publish on change.** `StatusBarMemorySampler.sampleNow`
   should only assign `appFootprintBytes` when the (rounded) value actually
   changed, so an idle app stops re-bodying the status bar every 1.5 s. Trivial,
   high-confidence, low-risk.

5. **TSK — parallelize `CrossFileSearch`.** Split the file list across a
   `TaskGroup` / `concurrentPerform` (the per-file read+decode+scan is
   embarrassingly parallel; only result accumulation needs a lock). **Measure
   whether the walk is I/O- or CPU-bound first** — on an SSD the decode+match is
   usually CPU-bound and parallelizes well. Confidence medium, effort M.

6. **Small-batch cleanup ticket** (one commit, all S-effort, all
   high-confidence): #6 (`kind.to_string()`→`&'static str`/`Cow` in
   `runs_utf16`), #7 (`HTMLRenderer.spanned` per-run `lowercased()` →
   precompute the class string once per `TokenKind`), #11 (decode response maps
   that are accessed by key straight into a dict, skipping the pair-array
   round-trip — or have `require()` scan the pairs in place). These are pure
   micro-opts; bundle them so each gets a behavior test and the gate stays green.

**Migration-policy note (do NOT mass-fix the Swift twins).** #8
(`FuzzyMatcher`) and parts of #9 sit on Swift engines with an approved Rust port
(fuzzy = TSK-633). Per the 2026-06-11 owner directive those take **user-facing
bugfixes only** — no perf refactor on the Swift twin. The Swift `FuzzyMatcher`
is now only a fallback for `filterWithMatches`, but `FileTreeFilter`'s per-node
`FuzzyMatcher.match` is *still the live path* (the adapter explicitly keeps tree
filtering Swift-side: `RustFuzzyAdapter.swift:8-11`). If the per-character
`.lowercased()` allocation there is shown to cause felt sidebar-filter lag on a
big tree, that's a **bugfix-shaped** fix (cache a lowercased scalar, no behavior
change) — file it, but measure first.

See the per-area notes for the full reasoning and the "already good, don't
re-file" inventory:

- `notes-swift-ui-render.md` — SwiftUI body path, status bar, line ruler,
  selection highlight, webview reload.
- `notes-swift-core-parsers.md` — CSV, fuzzy, find/search, HTML render,
  cross-file search, MessagePack reader.
- `notes-rust-core-ffi.md` — wire encode/decode, dispatch, the engine ports,
  highlight runs, the FFI receive-side copy.
- `notes-large-file-io.md` — file open/load, large-read path, sync I/O on the
  main path, folder walks.
