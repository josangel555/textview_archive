# Swift UI / render-path notes

Covers the SwiftUI `body` hot path, status bar, line-number ruler, selection
highlight, CSV table, and the WKWebView reload. The render path is **already the
most-optimized part of the codebase** — most of the structural wins are done.

## Already good (do NOT re-file)

- **Narrow observation is intact.** `StatusBar` observes `tabCoordinator`,
  `sourceView`, and `helpSink` *directly* rather than via `DocumentModel`
  (`StatusBar.swift:33-42`), so a caret tick or editor keystroke re-bodies only
  the bar + source subtree. `HighlightCacheActor` publishes a per-tab `version`
  counter (`HighlightCacheActor.swift:35`) so a tokenize completion never
  republishes `DocumentModel`. This is the load-bearing perf architecture and
  it's healthy.
- **Status-bar metrics are cached.** `metrics(for:)` memoizes by `(url, byteCount)`
  (`StatusBar.swift:516-543`); preview size + file dates are TTL-cached by
  `(url, mtime)` (`:553-605`). So `body` doesn't re-walk the file or `stat` on
  every re-eval — exactly right.
- **`lineCount` scans `s.utf8` for `0x0A`** (`StatusBar.swift:615-623`), not an
  `NSString` bridge — good.
- **CSV table caches the parse on `@State`** and only rebuilds on `text` change,
  not per body re-eval (`CSVTableView.swift:71`), with a 200 ms filter debounce.
- **WKWebView reload is deduped.** `updateNSView` only calls `loadHTMLString`
  when the HTML actually changed vs `coordinator.lastHTML`
  (`MarkdownRenderedView.swift:208-240`) — kills the "vanishing tabs" reload
  storm. Good.
- **File loading is off-main.** Open routes through `Task.detached` →
  `controller.open(url:)` → `MainActor.run` to store the result
  (`DocumentModel.swift:4280`, `:5022`, `:5272`, `:5314`). No sync `Data(contentsOf:)`
  on the main path. The `materializeTask` registry coalesces/cancels lazy reads.

## Findings

### #3 — `LineNumberRulerView.ensureCacheBuilt`: O(N) ObjC message-send per char
`Sources/ViewerUI/LineNumberRulerView.swift:112-125` — **measured/obvious, no
profiling needed.**

```swift
let ns = text as NSString
var i = 0
while i < ns.length {
    if ns.character(at: i) == 0x0A { offsets.append(i) }
    i += 1
}
```

`ns.character(at:)` is an Objective-C message send **per UTF-16 unit**. For a
100k-line log (the exact case the surrounding docs cite as the reason the cache
exists) that's millions of dispatched calls to build the table — on the first
draw after the text changes, on the main thread. The binary-search read side is
already O(log N); the *build* is the cost.

**Fix:** build the offset table from `text.utf8.enumerated()` (newline `\n` is a
single UTF-8 byte `0x0A`, and `\r\n`'s `\n` is still `0x0A`, so the byte scan
gives the same UTF-16 offsets only if you accumulate UTF-16 width — *careful*:
the offsets here are **UTF-16 indices**, so a pure byte-index won't match for
non-ASCII files). The correct cheap form is a single `for unit in text.utf16`
pass with a running index (the `UTF16View` is contiguous on native strings and
avoids the per-call ObjC dispatch), or `enumerateSubstrings(in:options:.byLines)`.
Either is one O(N) walk with no per-element message send. **Risk:** low — pure
internal table build, well covered by the gutter's own line-number tests.

### #4 — Memory sampler publishes unconditionally every 1.5 s
`Sources/ViewerUI/StatusBarMemory.swift:73-75` — **measured/obvious.**

```swift
private func sampleNow() {
    appFootprintBytes = ProcessMemory.appFootprintBytes()  // always assigns
}
```

`@Published` fires `objectWillChange` on every assignment, even when the value
is identical. So while the app sits idle, the `StatusBarMemorySampler` re-bodies
the entire `StatusBar` (git chip read, metrics group, date chips, the whole
HStack) every 1.5 s, forever. The footprint barely moves at idle, so almost all
of these publishes are no-ops that still cost a body pass + a timer wakeup.

**Fix:** guard the assignment — `let v = ProcessMemory.appFootprintBytes(); if v
!= appFootprintBytes { appFootprintBytes = v }`. Trivial, high-confidence, kills
the idle churn. **Risk:** none. (Note: the ByteFormat label only renders to MiB
granularity, so you could even compare at MiB resolution to suppress sub-MiB
jitter publishes.)

### #10 — `SelectionHighlightEngine.otherOccurrences`: O(matches·N) NSString scan
`Sources/ViewerUI/SelectionHighlightEngine.swift:98-111` — **suspected, needs a
trace to confirm cadence.**

Each selection change re-scans the whole text with `ns.range(of: needle,
options: .literal, range: cursor)` advancing a cursor. That's `NSString.range(of:)`
(an ObjC/ICU call) once per found occurrence over the full document. The 5 MB
`maxHaystackBytes` cap bounds the worst case, and the shape rules (word-like,
2–100 chars) filter most selections out before the scan. But on a 5 MB file with
a frequently-occurring short token, a caret-drag could re-run this per
selection-change tick on the main actor.

**Confirm first:** whether this actually runs on the main actor and how often
(it may already be debounced/off-main in the controller wiring —
`SourceTextController`). If main + per-caret-move, consider (a) debouncing to
selection-settle, and (b) capping the number of occurrences collected (the UI
can only show what's on-screen + a minimap density). Low priority given the cap.

### #12 — git chip reads `.git/HEAD` on every body re-eval
`Sources/ViewerUI/StatusBar.swift:166-208` — **suspected, needs cadence trace.**

The size/date/preview chips all learned to TTL-cache their filesystem reads
(`StatusBar.swift:553-605`). The git chip's *label* path
(`SessionGitInfo.footerLabel(for: root)` at `:167`, and `badge(for:)` in the
menu builder at `:208`) reads `.git/HEAD` (and likely a packed-refs / branch
file) from disk — and the comments explicitly say it does so "on the body hot
path" deliberately to avoid a subprocess. That's correct re: avoiding the
subprocess, but it's still an uncached disk read per `body`. Given `StatusBar`
re-bodies on caret tick / tab switch / metrics change, the `.git/HEAD` read
repeats a lot.

**Fix:** give it the same `(root, mtime-of-HEAD)` TTL cache the other chips use.
**Confirm first** that the read cost is non-trivial (HEAD is tiny; the OS page
cache likely serves it) and that body cadence is high enough to matter — this
may be sub-noise. Low priority.

### #11 — MessagePack response maps double-handled (see also FFI notes)
`Sources/RustCore/MessagePack.swift:195-204` — touched here because it's on the
render path for the markdown/highlight responses. `mapValue()` walks the decoded
pair-array and rebuilds a `[String: MsgPackValue]`. The decode already allocated
the pair-array; this re-hashes it. For the field-by-field `require()` access
pattern, scanning the (small, ≤10-entry) pair-array in place would skip the dict
build entirely. Micro — only matters because it's per-response on a hot port.
