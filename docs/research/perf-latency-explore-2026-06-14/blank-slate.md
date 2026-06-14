# Blank-slate perf/latency exploration — 2026-06-14

Scope: free-range hunt for the biggest speed / latency / responsiveness /
efficiency wins across the whole app (SwiftUI/AppKit front-end + Rust core over
the MessagePack-framed FFI). MEASURED where I could run code on the host;
SUSPECTED where the path is VM/AppKit-only or I read rather than benchmarked.

Measurement rig (this session, host = M-series, `dist`-equivalent release builds):
- Rust engine wire round-trips timed via a throwaway `cargo run --example` in
  `mdvcore-highlight` (now removed — not committed), on synthetic-but-realistic
  inputs (generated Rust source, CSV, markdown).
- Swift-side MessagePack decode timed with a standalone `swiftc -O` harness that
  vendors the real `Sources/RustCore/MessagePack.swift` and replays the exact
  `mdvCoreHighlightRuns` decode shape.
- `ProcessInfo.environment` / `UserDefaults` access timed the same way.

All temp benches were deleted after capture; nothing was committed.

---

## Executive summary — the 3–5 biggest opportunities

1. **Highlight runs wire format is named-map + per-run `String` kind — 4× the
   bytes and ~5× the Swift decode it should be.** A 320 KB Rust file tokenizes to
   68 000 runs → a **1981 KB** response frame that the Swift side decodes in
   **33.3 ms** (building a 68k-element `MsgPackValue` tree, then re-walking it).
   Re-encoding runs as **positional arrays with an integer kind** (exactly the
   wire-v2 change already shipped for diff lines) shrinks the frame to **505 KB**
   and drops Swift decode to **6.3 ms** — MEASURED 5.3× on decode, ~4× on bytes,
   and a proportional cut to the Rust encode side. This is the single biggest
   cheap win on the FFI boundary, and it compounds: every highlighted source open
   and every markdown code-fence pays it.

2. **The Rust highlighter's query-compile cache is never warmed at startup — the
   default-ON path starts cold and the first markdown code-fence compiles a
   grammar SYNCHRONOUSLY on the main actor.** Cold compile is **38 ms (Rust),
   30 ms (TS), and 375 ms (Swift grammar)**. The existing TSK-619 startup warm
   only warms the *Swift* `TreeSitterEngine` — but `.highlight` ships ON, so the
   path actually used (`RustHighlightAdapter` → `mdvcore_highlight_runs`, whose
   process-wide `config_cache` lives in the Rust crate) is cold until first
   touch. `HTMLVisitor.visitCodeBlock` runs that first touch synchronously on the
   main thread. Result: a first markdown open with a Swift fence can stall main
   ~375 ms. Fix: warm the Rust cache off-main at launch (mirror the Swift warm),
   covering the grammars actually routed to Rust.

3. **Every routed Rust call snapshots the entire process environment.**
   `RustCoreFallback.run` defaults `environment: ProcessInfo.processInfo
   .environment`, which allocates a fresh `[String:String]` of the whole environ
   on **every** call — MEASURED **~19 µs/call** (48-entry env; larger shells cost
   more). It's invoked per highlight tokenize, per find, per markdown render, and
   **once per markdown code fence**. On a fence-heavy doc that's dozens of full
   environment snapshots per render. Cache the gate decision (or read the env var
   once at process start) — pure waste on a hot path.

4. **CSV open parses into a throwaway `Vec<Vec<String>>` DTO, then copies it all
   into the arena.** `CsvSession::open` on 100 000×8 is **140 ms**; the parser
   allocates ~800k `String`s building the wire `Table`, `TableArena::from_table`
   re-copies every cell into the two-block arena, then the DTO is dropped. The
   resident store is already optimal (the arena); the transient double-allocation
   is the avoidable half. Parsing straight into the arena removes ~800k transient
   allocs + the copy pass. Medium impact (open is one-shot, not per-keystroke).

5. **Automation/MCP whole-document find re-sends and re-searches the full
   document text over the FFI on every call, uncached.** `find_search_wire` on a
   3.2 MB file is **285 ms**, and the entire text crosses the boundary each
   invocation (`RustFindAdapter.search(in: text, …)`). Today this is the
   automation path (`automationFind`), not the interactive find bar, so it's
   lower-frequency — but an automation loop or agent driving find repeatedly pays
   full document re-cross + re-search each time with no session/caching.

The headline pattern: **the Rust engines themselves are already well-optimized**
(arena store, borrowed request decode, single-alloc frames, windowed CSV
snapshots, linear-time PikeVM find). The remaining fat is at the **boundary** —
wire shape, the Swift-side intermediate-tree decode, cold caches, and per-call
gate overhead — not in the algorithms.

---

## Ranked findings

| # | Finding | Location | Measured? | Impact | Effort |
|---|---------|----------|-----------|--------|--------|
| 1 | Highlight runs wire = named-map + `String` kind/run → 1981 KB frame, 33.3 ms Swift decode (vs 505 KB / 6.3 ms positional+int-kind) | `rust-core/crates/highlight/src/runs.rs:106` (`Run`/`runs_wire`) + `Sources/RustCore/CoreClient.swift:1030` (`mdvCoreHighlightRuns` decode) | **MEASURED** (4× bytes, 5.3× decode) | **High** — every highlighted open + every MD fence | Low–Med (mirror the diff wire-v2 positional change) |
| 2 | Rust highlight `config_cache` not warmed at startup; first MD fence compiles grammar **synchronously on main** (cold: 375 ms Swift / 38 ms Rust / 30 ms TS) | `rust-core/crates/highlight/src/lib.rs:27` (`config_cache`), startup warm only in `Sources/MarkdownViewer/main.swift:124` (Swift engine), sync call at `Sources/ViewerCore/HTMLRenderer.swift:278` | **MEASURED** (cold-vs-warm per grammar) | **High** — first-open main-thread stall, user-felt | Low (add an off-main Rust warm at launch) |
| 3 | `RustCoreFallback.run` snapshots full `ProcessInfo.environment` per call (~19 µs), incl. once per MD code fence | `Sources/ViewerCore/RustCoreFallback.swift:45`; gate read `Sources/ViewerCore/RustCoreGates.swift:101` | **MEASURED** (19 µs/call) | **Med** — multiplies on fence-heavy docs | Low (cache gate decision / read env once) |
| 4 | CSV parse builds `Vec<Vec<String>>` DTO (~800k transient `String`s) then copies into arena; `open(100k×8)` = 140 ms | `rust-core/crates/core/src/csv.rs` (`parse` → `Table`) + `rust-core/crates/core/src/table_arena.rs:51` (`from_table` copy) | **MEASURED** (140 ms open) | **Med** — one-shot per open | Med (parse directly into arena layout) |
| 5 | Automation whole-doc find re-crosses + re-searches full text each call, uncached; `find_search_wire(3.2 MB)` = 285 ms | `Sources/ViewerCore/RustFindAdapter.swift:26`, `rust-core/crates/core/src/find_engine.rs:209` | **MEASURED** (285 ms / 3.2 MB) | **Med** (automation path; would be High if wired to interactive find-as-you-type) | Med (session handle / cache compiled pattern + last text) |
| 6 | Markdown code fences each take a SEPARATE FFI round-trip (per-chunk `RustHighlightAdapter.tokenize`): N fences = N ABI asserts + N frame encodes + N tree decodes + N env snapshots | `Sources/ViewerCore/RustMarkdownAdapter.swift:58`, `Sources/ViewerCore/HTMLRenderer.swift:278` | SUSPECTED (per-call costs measured individually; multiplication not end-to-end timed) | **Med** | Med (batch all fences into one highlight call, or let the core highlight fences inline) | 
| 7 | Swift `MsgPackReader` always materializes a full `MsgPackValue` tree before typed extraction — 2× walk + per-element enum alloc on every structured FFI return (table/snapshot/runs/find/transcript) | `Sources/RustCore/MessagePack.swift:51` (`decode`/`mapValue`/`stringMatrix`) | **MEASURED** indirectly (the 33 ms in #1 is dominated by tree-build) | **Med** (broad — touches all structured returns) | Med–High (add a streaming typed reader for the big-array shapes) |
| 8 | `runs_utf16` allocates `kind.to_string()` per run (68k small heap allocs ≈ 1.1 ms) even though kinds are a tiny static set | `rust-core/crates/highlight/src/runs.rs:188` | **MEASURED** (1.1 ms / 68k) | **Low** (subsumed by #1 if kinds go integer/`&'static str`) | Low |
| 9 | Find adapter `whole_word`/literal builds regex via `format!`/`escape_literal` allocations per search; minor next to the O(N) sweep | `rust-core/crates/core/src/find_engine.rs:51,79` | SUSPECTED | **Low** | Low |
| 10 | `highlight_lines` (TUI/web front-ends) clones every segment's text into an owned `String` per line | `rust-core/crates/highlight/src/lib.rs:498` | SUSPECTED | **Low** (front-end-only, not the macOS app) | Low |

---

## Detail per finding

### #1 — Highlight runs wire shape (the headline)

`runs.rs` `Run` serializes as a named MessagePack map `{start, len, kind:String}`
per run. For 68 000 runs the field-name keys (`"start"`,`"len"`,`"kind"`) repeat
68k times — ~950 KB of pure key text in a 1981 KB frame — and each run carries an
owned `kind` String.

MEASURED on the host:

```
highlight 320 KB Rust source → 68000 runs
  runs_utf16 (tokenize only)            162.5 ms
  runs_wire (decode+tokenize+ENCODE)    241.1 ms   (≈ 80 ms is the encode)
  response frame                        1981 KB

Swift decode (mdvCoreHighlightRuns shape):
  decode NAMED 68k-run frame             33.3 ms
  decode POSITIONAL (int kind) frame      6.3 ms   ← 5.3× faster
  named frame 1981 KB  →  positional 505 KB        ← 3.9× smaller
```

The diff path already did exactly this (`CoreClient.swift:714` "wire v2: diff
per-element records are POSITIONAL arrays — the per-line field keys were ~41
bytes/line of pure key text"). Applying the same to highlight runs (positional
`[start, len, kindIndex]`, with a fixed kind-index table shared by both sides) is
a known, low-risk pattern that cuts the frame ~4×, the Swift decode ~5×, and the
Rust encode proportionally. Because highlight runs ride the hottest open path AND
every markdown fence, this is the highest impact-per-effort item found.

### #2 — Cold Rust highlight cache + synchronous main-thread compile

The Rust crate keeps its own process-wide `config_cache` (query
parse+compile, "tens of ms on the big grammars", paid once per language). The
TSK-619 startup warm at `main.swift:124` warms only `TreeSitterEngine.shared`
(the **Swift** engine). But `.highlight` defaults ON (`RustCoreGates.swift:90`),
so production routes to the Rust highlighter, whose cache the warm never touches.

MEASURED cold-vs-warm (release):

```
Rust:        cold 38.1 ms   warm 0.018 ms
TypeScript:  cold 30.5 ms   warm 0.086 ms
Python:      cold  9.0 ms   warm 0.075 ms
Go:          cold  2.8 ms   warm 0.102 ms
Swift:       cold 375.0 ms  warm 0.087 ms
```

`HTMLRenderer.visitCodeBlock`/`RustMarkdownAdapter.enrich` call
`RustHighlightAdapter.tokenize` **synchronously** (the comment says "calling
synchronously here is fine"). So the first markdown open containing a Swift code
fence can block main ~375 ms on the cold compile. Fix: at launch, fire an
off-main warm that calls `mdvCoreHighlightRuns(text:"", lang:…)` (or a dedicated
warm export) for the common grammars, mirroring what the Swift path already does.

### #3 — Per-call environment snapshot in the gate

`RustCoreFallback.run(..., environment: ProcessInfo.processInfo.environment, …)`
evaluates the default argument on every call. `ProcessInfo.processInfo
.environment` rebuilds a `[String:String]` of the whole environ each access.

MEASURED: **0.0194 ms (19 µs) per access** for a 48-entry env; `UserDefaults
.object(forKey:)` is ~0.27 µs by comparison. The gate is consulted per tokenize,
per find, per render — and per markdown code fence. The env read dwarfs the
actual gate logic. The gate decision is effectively constant for a process
(env-var override is fixed at launch; the UserDefaults toggle changes rarely), so
cache it (e.g. resolve each capability once and invalidate on the Settings
toggle), or at minimum stop snapshotting the whole environment when only one var
matters.

### #4 — CSV parse → DTO → arena double allocation

`csv::parse` returns a wire `Table` (`Vec<Vec<String>>`, one `String`/cell), then
`CsvSession::from_table` → `TableArena::from_table` copies every cell into the
contiguous arena and drops the DTO. The arena is the right resident shape; the
transient `Vec<Vec<String>>` (~800k Strings for 100k×8) and the copy pass are
avoidable. MEASURED open = 140 ms (100k×8, 10.6 MB). Parsing directly into the
arena's `bytes`+`offsets` would remove the intermediate allocations and the copy.
(The windowed snapshot path is already excellent: 0.05 ms/window — no action.)

### #5 — Automation whole-document find

`mdvCoreFindSearch` takes the full `text: String` and frames it whole on every
call; `find_search_wire(3.2 MB)` = 285 ms, all of it re-crossing + re-searching
from scratch. Only `automationFind` uses it today (not the interactive find bar,
which lives in NSTextView/CM6), so frequency is low — but an agent/automation
loop calling find repeatedly on a large file pays the full cost each time. A
stateful find session (hold the text + compiled pattern, re-search incrementally)
or at least caching the last (text, pattern)→matches would help if this becomes
interactive. **If interactive find-as-you-type is ever routed here, this jumps to
High** — it would re-cross multi-MB per keystroke.

### #6 — Per-fence FFI multiplication on markdown render

The core returns code fences as chunks; the host then calls
`RustHighlightAdapter.tokenize` once per `code` chunk. Each call = one ABI
assert + one request frame encode + one MsgPack tree decode (finding #7) + one
env snapshot (finding #3) + a possibly-cold grammar compile (finding #2). A
tutorial/changelog with dozens of fences serializes all of that. Options: batch
all fence bodies into a single highlight call, or have the core highlight fences
inline (it already owns the markdown parse and the highlighter) and return the
spans in the render response — eliminating the N round-trips entirely. Fixing #1
and #3 already de-fangs most of the per-fence tax.

### #7 — Swift MsgPackReader always builds the full value tree

`MsgPackReader.decode()` produces a recursive `MsgPackValue` enum (maps as
`[(MsgPackValue, MsgPackValue)]`, arrays as `[MsgPackValue]`), and the typed
accessors (`mapValue()` builds a `Dictionary`; `stringMatrix()` re-walks
array-of-arrays) consume it in a second pass. For the big-array returns
(CSV table/snapshot rows, highlight runs, find matches, transcript events) this
is 2× the walk plus a heap enum box per element. The 33 ms in finding #1 is
dominated by this tree-build. A streaming typed decoder for the hot shapes
(read the array length, then pull fields per element directly into the target
struct, no intermediate tree) would cut decode time and allocation across **all**
structured FFI returns — the broadest, if not the single largest, win. Finding #1
(positional+int) is a cheaper down-payment on the same cost.

---

## Things checked and found already-good (no action)

- **Rust wire encode**: single-allocation `encode_frame` (placeholder + backfill,
  byte-identical to legacy), borrowed request decode (`decode_frame_borrowed`,
  `Cow<str>`) so the inbound document is not copied. Solid.
- **CSV session**: arena store (two heap blocks, not 2M), indices-only filter
  cache (no resident row duplicate), windowed snapshot (`snapshot_window_frame`
  0.05 ms/window). The interactive filter-as-you-type path is already O(window).
- **NSTextView apply**: in-place attribute re-fix on the plain→highlight
  transition (no second full `setAttributedString`/relayout); large-read-only
  files skip per-interaction O(N) overlays.
- **Find engine**: single O(N) byte→UTF-16+line/col sweep (not O(M·N));
  worst-case-linear PikeVM (`regex-lite`) so no ReDoS guard tax.
- **FFI handle model**: registry lookup + Arc keeps a handle alive past a racing
  free; `try_lock` → `Busy` instead of blocking. Sound, not a perf concern.

## Suggested order of attack (impact × confidence ÷ effort)

1. **#1** positional+int-kind highlight wire — biggest cheap win, proven pattern.
2. **#2** warm the Rust highlight cache off-main at launch — removes a 375 ms
   first-open main stall, trivial change.
3. **#3** cache the gate decision — removes per-call env snapshot, trivial.
4. **#7 / #4 / #6** the structural items (streaming decode, parse-into-arena,
   per-fence batching) — bigger refactors, real but more effort.
5. **#5** find session/caching — only if find is ever made interactive.

## Validation caveats (project rules)

- All numbers above are **host** microbenchmarks (engine logic + wire + Swift
  decode), not live-app captures. Per the project's MEASURE-don't-guess rule, the
  *end-to-end* open latency (incl. AppKit layout / WebView) must be confirmed on
  the **UTM VM** with `scripts/vm-profile.sh` + the `os_signpost` lane before/
  after any fix — the `highlight`/`render` signpost intervals already exist for
  exactly this. The findings here identify *where* the cost is; the VM trace is
  the authority on the user-felt delta.
