# Swift core / parsers notes

Covers `CSVParser`, `FuzzyMatcher`, `CrossFileSearch`, `HTMLRenderer`,
`SelectionHighlightEngine` (logic side), and the Swift `MsgPackReader`. These
are the pure-logic engines (some with approved Rust ports — see the
migration-policy caveat).

## Already good (do NOT re-file)

- **`CSVParser` streams scalars via an iterator**, not `Array(text.unicodeScalars)`
  — the docstring at `CSVParser.swift:148-153` explicitly calls out that
  materializing the scalar array would double peak RSS on a 50 MB CSV. It also
  tracks `fieldScalarCount` explicitly (`:160-166`) precisely *because*
  `field.unicodeScalars.count` is O(N) per call and naive use would make field
  building O(N²). This is textbook-correct.
- **`CrossFileSearch.splitLines` scans the scalar view** (`:374-403`) to handle
  CRLF/CR without grapheme fusion, and the per-line literal path probes the
  `Substring` directly (shared index space, no per-line `String` alloc) and only
  materializes a `String` on a hit (`:257-276`). Good.
- **`HTMLRenderer.exceedsLeadingBlockNesting`** scans `markdown.utf8` (contiguous,
  no grapheme segmentation) and bails on the first offending line — O(n), single
  pass (`HTMLRenderer.swift:95-110`).
- **`FuzzyMatcher`** keeps the index domain on the *original* target (no whole-
  string `lowercased()` that would shift indices), and sorts stably with an
  explicit input-index tiebreak (`FuzzyMatcher.swift:90-98`).

## Findings

### #5 — `CrossFileSearch.search` is single-threaded
`Sources/ViewerCore/CrossFileSearch.swift:128-290` — **suspected, profile to
confirm I/O- vs CPU-bound.**

The whole project-wide search — `FileManager.enumerator` walk, per-file
`Data(contentsOf:)`, `TextDecoder.decodeToString`, the file-level prefilter, and
the per-line `range(of:)` scan — runs in one `for` loop on a single worker. On a
large repo (the cap is 50k entries, 2 MiB/file, 500 results) this leaves N-1
cores idle while one core does all the read+decode+match.

**Fix:** the per-file work is embarrassingly parallel. Collect the candidate
file URLs from the (cheap, serial) enumerator walk, then fan the read+decode+scan
across a `TaskGroup` or `DispatchQueue.concurrentPerform`, with a lock only
around result accumulation + the `maxResults` early-exit. The symlink-loop guard
and skip-dir logic stay in the serial walk (they mutate shared `visitedDirs`).

**Measure first:** if the tree is on a cold/network volume the walk is I/O-bound
and parallelism helps less; on a warm SSD the decode+`range(of:)` match is
usually CPU-bound and parallelizes near-linearly. The `cancelCheckStride` /
`isCancelled` plumbing already exists, so cancellation survives the refactor.
Effort M, risk M (concurrency correctness around the shared result accumulator +
the early-exit ordering — results are currently in deterministic walk order,
which a parallel version must re-sort to preserve).

### #8 — `FuzzyMatcher.match`: two `String` allocs per character compare
`Sources/ViewerCore/FuzzyMatcher.swift:39` — **bugfix-only under migration
policy; suspected felt impact on sidebar filter.**

```swift
if ch.lowercased() == q[qi].lowercased() {   // two String allocations per char
```

`Character.lowercased()` returns a `String` (a heap allocation). The inner loop
runs over every character of every target, so a sidebar filter over a large file
tree allocates `O(targets · avg_len · 2)` transient `String`s **per keystroke**.

**Status:** the *batch* path (`filterWithMatches`, used by the command palette)
is routed through the Rust core by default (`RustFuzzyAdapter`), so this Swift
code is a fallback there. BUT `FileTreeFilter` / sidebar per-node matching
**deliberately stays Swift-side** — the adapter doc (`RustFuzzyAdapter.swift:8-11`)
keeps it Swift because one bridge round-trip *per tree node* is wire-hostile.
So `FuzzyMatcher.match` is **still the live per-keystroke path for sidebar/tree
filtering.**

Under the 2026-06-11 migration policy, fuzzy is a ported engine (TSK-633) and
the Swift twin takes **user-facing bugfixes only** — no perf refactor. *However*,
if this is shown to cause felt sidebar-filter lag on a big tree, a fix that
pre-lowercases the target's scalars once per node (or compares scalar case
without allocating, e.g. via `Unicode.Scalar.properties.lowercaseMapping` /
an ASCII fast-path) is **behavior-preserving** and arguably bugfix-shaped.
**Measure first** (profile a 10k-node tree filter), then decide. Effort S.

### #11 — `MsgPackReader`: pair-array → dict rebuild per response
`Sources/RustCore/MessagePack.swift:195-204` — **micro, obvious.**

Every response map decodes to an *ordered* `[(MsgPackValue, MsgPackValue)]`
(`decode()` → `.map`), then `mapValue()` re-walks it into a
`[String: MsgPackValue]` so `require(_:)` can do dict lookups. The maps are tiny
(≤~10 fields), so the dict build is cheap per call — but it's pure overhead vs
scanning the pair-array in place for the handful of keys each decoder needs.
Bundle into the micro-opt cleanup ticket. Risk: low (the reader is heavily
tested; keep the `mapValue()` accessor for callers that genuinely want a dict).

### CSV detect-delimiter `counts.max(by:)` — fine, noted for completeness
`Sources/ViewerCore/CSVParser.swift:130-132` allocates a 3-tuple array and runs
`.max(by:)`. Three elements — irrelevant. Not a finding; documenting that it was
checked.

### `HTMLRenderer.spanned` — see FFI/render notes (#7)
The per-run `run.kind.rawValue.lowercased()` + `NSString.substring(with:)` in
the code-fence highlight splice (`HTMLRenderer.swift:331-336`) is covered as
finding #7. The `lowercased()` is the same `TokenKind` rawValue every time for a
given kind — precompute a `[TokenKind: String]` class-name table once.
