# Pre-Launch Product Review — Inefficiencies & Bottlenecks

**Repo:** `/Users/me/Documents/workspaces/claude/markdown_viewer`
**Dimension:** Algorithmic complexity traps (O(n²) on file size / tab count), N+1 IO, repeated whole-buffer scans, unnecessary copies, chatty polling.
**Reviewer:** automated static review (read-only)
**Date:** 2026-07-10

---

## Executive summary

The codebase is, for this dimension, **unusually disciplined**. The hot engines that matter
most for a document viewer/editor are explicitly engineered against the classic traps: the
find engine is a single O(N) sweep (not O(M·N)); the line-diff is Myers O(N·D) linear-space
(no O(n·m) matrix); persistence uses an off-main, coalescing, durable-write queue; the
markdown preview uses an incremental block-level DOM patch instead of full reloads; and the
periodic pollers are fingerprint-guarded so an idle app does near-zero work. Many files carry
comments proving the authors already reasoned about complexity ("O(N), not O(M·N)", "no O(n·m)
matrix", "O(1) size check"). This is a mature codebase.

The one genuinely significant finding is in the **live editor keystroke path**: every CM6 edit
batch reconstructs the *entire* document by round-tripping the whole `base` string through the
Rust FFI via MessagePack (`cm_apply`), producing roughly five whole-document
allocations/copies per edit batch, then re-walks the full result and re-propagates it to host
reducers. For large files this is an O(n)-per-edit → O(n²)-over-a-session cost plus heavy
allocation churn, and the round-trip through Rust is avoidable (a local splice would remove ~4
of those passes). Everything else is P2/P3: bounded polling that could be event-driven,
whole-file slurps in cross-file search, a coarse block-diff follow-on, and a handful of
double-scans.

**No P0 (ship-blocker) inefficiencies found.** Nothing here loses data or crashes; the worst
case is editing-latency / memory churn on large files and mild battery/IO cost from timers.

---

## Methodology

**What I examined (static analysis via `rg`/`grep`/`sed`; no tests run that open windows):**

- **Polling / timers:** every `Timer.scheduledTimer`, `Timer.publish`, `asyncAfter`, and
  `while true { sleep }` site across `Sources/` (~22 sites). Read the tick bodies for
  `StatusBarMemory`, `ObservabilityProjection`, `GitPanelModel`, `SessionsAppCoordinator`,
  `ClaudeMonitorView`, and `MCPSocketBridge`.
- **The live editor edit path** end-to-end: `CodeMirrorEditorView` (WKScriptMessage handler) →
  `RustCMEditAdapter.apply` → `mdvCoreApplyCMEdits` (`CoreClient.swift`) → `CoreDocShadow`.
- **Core engines** for algorithmic shape: `find_engine.rs` (search + line mapping),
  `LineDiff.swift` (Myers), `html_patch.rs` (`block_patch`), `DependencyGraph.swift`,
  `CrossFileSearch.swift` / `CrossFileReplace.swift`, `SecretDetector.swift`,
  `FoldLineMap.swift`, `SourceWrapPolicy.swift`, `MarkdownOutlineModel.swift`.
- **IO patterns:** `JSONFileStore.swift` (session/history/bookmark writes),
  `FolderSizeStats.swift`, `ClaudeSessionIndex.swift` / `ClaudeMonitorListState.swift`,
  `TextFileLoader` boundaries, `ClaudeTranscriptSearch`.
- **Whole-buffer scans & copies:** grepped for `components(separatedBy:)`, `+=` in loops,
  `insert(at: 0)` / `removeFirst()` in loops, per-call `NSRegularExpression(pattern:)` compiles,
  repeated `.utf16.count` / `.count`, and FFI MessagePack encode sites that carry whole-document
  strings.
- **Tab-count scaling:** every `tabs.firstIndex(where:)` / `tabs.filter` / `tabs.map` site in
  `ViewerUI` (~40 sites) to check for O(tabs²) patterns.

**Coverage depth:** ~816 Swift + ~85 Rust source files exist; I read in full or in the relevant
region roughly 35 files and grep-triaged the rest. I prioritized the paths that scale with
**document size** (editor, find, diff, render, highlight) and with **collection size** (tabs,
sessions, tree walks), since those are where this dimension's defects hide.

---

## Findings

### F1 — Every CM6 edit batch round-trips the WHOLE document through the Rust FFI
**Severity:** P2 (significant perf on large files; not a crash/data-loss)
**Files:**
- `Sources/ViewerUI/CodeMirrorEditorView.swift:929-937`
- `Sources/ViewerCore/RustCMEditAdapter.swift:16-34`
- `Sources/RustCore/CoreClient.swift:716-745`

**Evidence.** The incremental-edit bridge was explicitly built to avoid marshalling the whole
document across the JS→Swift IPC on every keystroke (only `edits` cross the WKWebView bridge —
good). But the handler then immediately re-inflates to the full document:

```swift
// CodeMirrorEditorView.swift:929
let base = lastSentText ?? ""
if let applied = RustCMEditAdapter.apply(edits, to: base),
   contentLength < 0 || applied.utf16.count == contentLength {
    lastSentText = applied
    docShadow.mirror(edits: edits, base: base, applied: applied)
    onTextChange?(applied)
}
```

`RustCMEditAdapter.apply` calls `mdvCoreApplyCMEdits(base:edits:)`, which puts the *entire*
`base` document into the request frame and decodes the *entire* returned `text`:

```swift
// CoreClient.swift:729
let request = MsgPackValue.map([
    MsgPackPair(.string("base"), .string(base)),          // whole doc → MessagePack
    MsgPackPair(.string("edits"), .array(editVals)),
])
... let body = try CoreTransportRegistry.current.call("cm_apply", request: request)
... return try v.stringValue()                            // whole doc ← MessagePack
```

So per edit batch, for a document of length *n*: (1) MessagePack-encode the whole `base`
(O(n) UTF-8 encode + full-doc `Data` alloc); (2) FFI transport copy across the boundary (O(n));
(3) Rust decodes base (O(n) alloc), applies edits (O(n) alloc), re-encodes the result (O(n));
(4) FFI return copy (O(n)); (5) Swift decodes the result String (O(n) alloc); then
`applied.utf16.count` (O(n) walk, line 934) and `onTextChange?(applied)` (propagates the whole
doc). That is ~5 whole-document allocations/copies plus several full-length scans **per edit
batch**, where a local `String.replaceSubrange` splice of the (from,to,insert) ranges would be a
single allocation and zero FFI copies.

**Impact.** For interactive editing of large files (a 5 MB minified bundle, a big log, a large
Markdown doc), each debounce batch does O(n) work with a high constant factor and churns
multiple megabyte-scale allocations, feeding GC/malloc pressure and adding latency on the edit
path. Over a typing session this is O(n) per edit → O(n²) aggregate. The Swift twin engine was
deleted (TSK-649), so *all* CM edits now take this FFI round-trip; there is no lighter path.

**Suggested fix.** Apply the edits to the host mirror locally instead of via the FFI: a
`String.replaceSubrange` over the UTF-16 offset ranges keeps `lastSentText` authoritative with a
single allocation and no MessagePack/FFI cost. The Rust `cm_apply` engine can remain as the
*shadow* verifier (already `CoreDocShadow`'s job, and already gated) rather than the primary
reducer. Longer term, a piece-table/rope mirror would make edits O(edit-size) instead of O(n),
removing the last full-document rebuild.

**Fix size:** L · **Fix risk:** careful (it's the core edit reducer; needs the drift-guard and
shadow-compare paths kept, and VM editor UAT).

---

### F2 — Whole-document String re-propagated to all host reducers on every edit batch
**Severity:** P2
**File:** `Sources/ViewerUI/CodeMirrorEditorView.swift:918, 936-937`

**Evidence.** Both edit paths hand the full document downstream: the v1 fallback
`case .change(let text …): onTextChange?(text)` (line 916-918) and the v2 path
`onTextChange?(applied)` (line 937). `onTextChange` fans out to dirty-tracking, the autosave
snapshot pipeline, and the outline/breadcrumb consumers — each of which then re-scans the full
String (e.g. dirty comparison, `utf16.count`, heading re-parse). The delta saved over the JS
bridge is immediately lost at the Swift boundary.

**Impact.** Compounds F1: even after the FFI cost, the whole-doc String is walked again by each
subscriber per edit batch. On large files this multiplies the per-edit constant factor.

**Suggested fix.** Propagate a change *descriptor* (edited range + the mirror handle) alongside
(or instead of) the full String, so subscribers that only need "what changed" (dirty flag,
incremental outline) don't each re-scan the entire buffer. This is the same architectural lever
as F1 — treat the mirror as authoritative and pass deltas.

**Fix size:** L · **Fix risk:** careful (touches every `onTextChange` consumer's contract).

---

### F3 — CoreDocShadow does a full-document UTF-16 count every edit batch (+ full compare every 16)
**Severity:** P3
**File:** `Sources/ViewerCore/CoreDocShadow.swift:80, 86-88, 157-166`

**Evidence.** When the shadow is active, `mirror(edits:base:applied:)` runs
`result.lenUTF16 != UInt64(applied.utf16.count)` (line 80 — a full O(n) UTF-16 walk of the whole
`applied` doc) on every batch, and `if localBatches % fullCompareStride == 0 { fullCompare(…) }`
(line 86) reads the entire core text and compares it byte-for-byte to the host every 16 batches
(O(n)). This is *in addition* to the `applied.utf16.count` already computed at
`CodeMirrorEditorView.swift:934` — the same full walk twice per batch.

**Impact.** Bounded and gated behind `Self.shadowActive` (guard at line 56 short-circuits when
off), so this only bites when the shadow verifier is enabled. When on, it adds an O(n)-per-edit
walk plus a periodic O(n) full compare to the edit path.

**Suggested fix.** Have the caller pass the already-computed `applied.utf16.count` into `mirror`
instead of recomputing it; keep the periodic full-compare but consider tying its stride to bytes
edited rather than batch count so huge idle-length docs don't pay it on tiny edits.

**Fix size:** S · **Fix risk:** safe.

---

### F4 — ClaudeMonitor polls the transcript tree every 5 s with a full stat sweep
**Severity:** P2
**Files:**
- `Sources/ViewerUI/ClaudeMonitor/ClaudeMonitorView.swift:418, 190-200`
- `Sources/ViewerCore/ClaudeMonitorListState.swift:61-72`
- `Sources/ViewerCore/ClaudeSessionIndex.swift:116-145`

**Evidence.** A `Timer.publish(every: 5, …)` fires `refreshIfChanged()`, which (off-main)
computes a fingerprint over `ClaudeSessionIndex().transcriptURLs(root:)`. `transcriptURLs` does a
`contentsOfDirectory` on `~/.claude/projects`, then a per-project `contentsOfDirectory`, then a
`resourceValues(forKeys: [.isRegularFileKey])` **per `.jsonl` file**. `fingerprint(of:)` then
does a *second* `resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])` per URL.
So every 5 s, for a heavy Claude user with hundreds of sessions across many projects, the app
walks the whole tree and stats every transcript **twice**, forever, while the window is open.

**Impact.** Repeated O(files) filesystem sweep + double stat on a 5 s cadence. It is off-main and
short-circuits the reload when the fingerprint is unchanged, so it doesn't churn the UI — but it
is real, unbounded (scales with the user's session history), redundant IO and battery/disk-wake
cost. This is the app's own author (Jos) as the "heavy user" — the MEMORY notes reference
hundreds of sessions.

**Suggested fix.** Replace the polling fingerprint with a `DispatchSource`/FSEvents watcher on
`~/.claude/projects` so idle cost is O(0) and a change fires a single rescan. If keeping the
poll, fold the two stat passes into one (`transcriptURLs` already opens each URL — return the
mod-date+size it reads so `fingerprint` doesn't re-stat), and back the interval off when the
window loses key focus.

**Fix size:** M · **Fix risk:** careful (FSEvents coalescing/debounce needs care; keep the poll
as a fallback).

---

### F5 — Cross-file search slurps each file fully into memory (inconsistent with the streaming transcript search)
**Severity:** P2
**File:** `Sources/ViewerCore/CrossFileSearch.swift:297-323`

**Evidence.** `matchFile` does `guard let data = try? Data(contentsOf: url)` then
`TextDecoder.decodeToString(data)` — the *entire* file is read into memory and decoded to a
String before matching, for **every** file in the tree, run in parallel via
`DispatchQueue.concurrentPerform` (line 199). By contrast `ClaudeTranscriptSearch` is documented
as "streams line-by-line + caps matches, so it's safe over a directory of large transcripts"
(`ClaudeMonitorView.swift:445`). The cross-file path has no per-file size guard visible at the
slurp site.

**Impact.** Searching a tree that contains a few large files (a big log, a vendored bundle, a
data dump) allocates the full file *and* its decoded String simultaneously, ×N in parallel —
a memory spike proportional to the largest concurrently-processed files. For a viewer that opens
arbitrary folders this is a realistic pathological case.

**Suggested fix.** Stream the file line-by-line (as `ClaudeTranscriptSearch` does) or add a
`maxFileBytes` guard (the `Options` type already carries caps elsewhere) and skip/partial-scan
oversized files. `memchr::memmem` (already in-tree per CLAUDE.md, used in `hex_search_find`)
would give a fast pre-filter without a full String decode.

**Fix size:** M · **Fix risk:** careful (must preserve line-number correctness and the
CRLF/CR-aware `splitLines` semantics).

---

### F6 — Cross-file non-regex match scans each matching line twice
**Severity:** P3
**File:** `Sources/ViewerCore/CrossFileSearch.swift:316-322`

**Evidence.**
```swift
guard lineSub.range(of: needle, options: containsOpts) != nil else { continue }
line = String(lineSub)
range = line.range(of: needle, options: containsOpts)   // second scan of the same line
```
Each line that contains a match is scanned by `range(of:)` twice — once to decide to keep it,
once to capture the range (against a freshly-materialized `String(lineSub)`).

**Impact.** Doubles the per-hit scan cost on matching lines. Minor (only matching lines pay it),
but trivially avoidable.

**Suggested fix.** Capture the range from the first `range(of:)` on `lineSub` and reuse it; only
materialize `String(lineSub)` once.

**Fix size:** S · **Fix risk:** safe.

---

### F7 — Git panel spawns a `git` subprocess every 60 s regardless of change
**Severity:** P3
**File:** `Sources/ViewerUI/Git/GitPanelModel.swift:168`

**Evidence.** `Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { … refreshCurrent() }`
on `RunLoop.common` refreshes the git panel every 60 s unconditionally while it is open, which
spawns `git` subprocess(es). There is no `.git`-index/HEAD watcher gating the refresh.

**Impact.** Low-frequency (60 s) but unconditional process spawn + IO even when the repo hasn't
changed. Battery/process-churn cost for an always-open panel; not user-visible.

**Suggested fix.** Watch `.git/index`, `.git/HEAD`, and `.git/refs` via FSEvents and refresh on
change; keep a long (e.g. 5 min) safety-net poll. Or at minimum stat the index mtime before
spawning `git`.

**Fix size:** M · **Fix risk:** careful.

---

### F8 — DependencyGraph adjacency queries are O(E) per node (O(N·E) if the view iterates)
**Severity:** P3
**File:** `Sources/ViewerCore/DependencyGraph.swift:76-82`

**Evidence.**
```swift
public func dependencies(of id: String) -> [String] { edges.filter { $0.from == id }.map(\.to) }
public func dependents(of id: String)  -> [String] { edges.filter { $0.to == id }.map(\.from) }
```
Each call is a full O(E) linear scan of the edge list. A view that renders per-node adjacency
(the natural use for a dependency-graph panel) would be O(N·E). The graph *build* itself
(`importGraph`, line 143-215) is fine — it dedups via a `Set<Edge>`. `packageGraph` uses
`if !edges.contains(edge)` (line 252, O(E) per insert → O(E²)) but only over package-manifest
dependencies (small N).

**Impact.** Only bites the dependency-graph visualization feature on large repos; not a core
flow. Included for completeness.

**Suggested fix.** Precompute `[nodeID: [neighborID]]` forward/reverse adjacency maps once when
the `Graph` is constructed and serve `dependencies(of:)`/`dependents(of:)` from them in O(1). Use
a `Set` for the `packageGraph` dedup too.

**Fix size:** S · **Fix risk:** safe.

---

### F9 — Automation find serializes the whole document per search call
**Severity:** P3
**Files:**
- `Sources/RustCore/CoreClient.swift:1262-1298`
- `Sources/ViewerCore/RustFindAdapter.swift:38-51`

**Evidence.** `mdvCoreFindSearch` puts the entire document into `MsgPackPair(.string("text"),
.string(text))` (line 1270) and ships it across the FFI per call. Confirmed sole caller is
`DocumentModel+AutomationHost.swift` (the agent-driven find), **not** the interactive find bar
(interactive find runs in CM6/JS), so this is bounded to automation.

**Impact.** An agent issuing repeated find-all queries over a large open document re-copies the
entire buffer (UTF-8 encode + `Data` alloc + FFI copy) on each call. Bounded (not per-keystroke),
but redundant given the core can already hold the document by id (`CoreDocStore`).

**Suggested fix.** If the automation find is over a doc the core already mirrors (editable docs
have a `CoreDocStore` handle), route find by `docId` rather than re-sending `text`. Otherwise
cache the last-sent text keyed by a content hash so back-to-back searches skip re-serialization.

**Fix size:** M · **Fix risk:** careful.

---

### F10 — Markdown preview block-diff re-inserts the entire span between two distant edits
**Severity:** P3
**File:** `rust-core/crates/core/src/html_patch.rs:163-201`

**Evidence.** `block_patch` is a prefix/suffix-trim differ: it `Keep`s matching leading blocks,
`Keep`s matching trailing blocks, and `Delete`s-then-`Insert`s the *entire differing middle*.
The doc comment acknowledges this: "OPTIMAL for the common case … A minimal-middle LCS refinement
(fewer ops when blocks move) is a documented follow-on (TSK-838)." So editing block 2 *and* block
998 of a 1000-block document breaks the prefix/suffix match window and churns blocks 2..998 in
the DOM even though only two changed.

**Impact.** The common case (a single localized edit → prefix+suffix match → only the changed
block churns) is optimal, so this is rarely hit. The pathological case (two separated edits in
one render, or block reordering) does an oversized DOM patch. Coarse-grained and already tracked.

**Suggested fix.** The documented LCS refinement over the block lists (the `LineDiff` Myers
linear-space differ already in-tree is a ready model) would make the middle minimal.

**Fix size:** M · **Fix risk:** safe (guarded by the existing round-trip correctness property
`apply_block_patch(old, block_patch(old, new)) == new`).

---

## Positive observations

The following are genuinely well-done and worth *not* regressing:

- **Find engine — single O(N) sweep.** `find_engine.rs:141-231` (`single_sweep`) converts byte
  ranges → UTF-16 + line/column in one monotonic walk, explicitly "O(N), not O(M·N)", and breaks
  early once all matches are resolved. The wire request borrows `text` as `Cow<str>` to avoid an
  owned copy on the Rust side (`find_engine.rs:236`).
- **Line diff — Myers O(N·D), linear space.** `LineDiff.swift:16-36, 271-362` trims common
  prefix/suffix first, interns lines to ints, and runs the divide-and-conquer §4b middle-snake —
  "NO O(n·m) matrix is ever allocated." Output-sensitive: a small save is near-linear.
- **Persistence writes — off-main, coalescing, durable.** `JSONFileStore.swift:120-141` moves the
  encode + disk hit off the main thread with a coalescing queue (a burst collapses to one write),
  and `writeDurably` (line 94-118) does temp-write → fsync → atomic rename → dir fsync.
- **Incremental markdown preview.** `html_patch.rs` + `MarkdownRenderedView.swift` patch the live
  DOM block-by-block instead of `loadHTMLString`-reloading the whole (multi-MB) page on each
  change; a no-change reload is a documented no-op.
- **Delta IPC over the JS↔Swift bridge.** `CodeMirrorEditorView` v2 `incrementalChange` ships only
  edits over the WKWebView boundary (the whole-doc marshalling was deliberately removed there).
- **Fingerprint-guarded pollers.** `StatusBarMemory` / `ObservabilityProjection` / the
  ClaudeMonitor refresh all short-circuit when nothing changed; `SessionsAppCoordinator`'s
  autosave is token-debounced and equality-guarded ("an idle period costs one snapshot compare
  and zero writes").
- **Precompiled regexes.** `SecretDetector.swift:50-72` compiles its rule set once in a `static let`
  (not per-line/per-call), scanning per-line incrementally.
- **Streaming transcript scan.** `ClaudeSessionIndex.summary`/`ClaudeTranscriptSearch` explicitly
  "never slurps the file" — line-streamed with match caps.
- **memchr in hot byte paths.** `hex_search_find` uses `memmem` for substring scans (per CLAUDE.md
  rust-tooling policy) rather than a hand-rolled byte loop.
- **Tab lookups are O(tabs), tabs are few.** The ~40 `tabs.firstIndex(where:)` sites are each O(tabs)
  with tabs numbering in the tens; no O(tabs²) pattern found (bulk ops like
  `TabCoordinator.swift:277` build a `Set(tabs.map)` for O(1) membership).

---

## Coverage gaps (what I did NOT examine)

- **Runtime profiling.** This is a static review only — no instruments/xctrace captures, no
  large-file editing latency measurement, no allocation profiling. F1/F2's real-world impact
  should be confirmed with `scripts/vm-profile.sh` on a multi-MB file before sizing the fix.
- **The Rust `cm_apply` engine internals.** I confirmed the Swift-side whole-doc marshalling but
  did not read the Rust `cm_apply` handler to see whether it does any rope/piece-table trick
  internally (it still must return the whole `text` over the wire, so the copy cost stands
  regardless).
- **CodeMirror / Mermaid / Canvas bundled JS assets** (`Resources/`). The editor's *own*
  incremental-highlighting and layout complexity lives in CM6's JavaScript, which I did not audit.
- **The `serve` / `tui` / `web` / `pm` Rust front-ends** and the `canvas/` DSL crate — I focused on
  the `core` engines reached by the macOS app's hot paths.
- **LSP, Terminal (beyond `ANSIParser` param parsing), Git blame/log parsing, ImageEditing, Audio,
  Plugins, Walkthrough** feature subsystems — triaged by grep, not read in depth. `GitClient.swift`
  parses records via `components(separatedBy:)` on process output (bounded by output size, not
  reviewed for large-repo `git log` streaming).
- **Terminal render throughput** and the `MountedPanesLRU`/pane-retention machinery under many
  panes.
- **Concurrency-cost angles** (lock contention, main-thread hops, actor hop overhead) — out of
  scope for this dimension (algorithmic/IO/copy/poll), reviewed only where it intersected a
  whole-buffer scan.
