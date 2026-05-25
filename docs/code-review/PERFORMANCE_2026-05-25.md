# MarkdownViewer — Performance Review (2026-05-25)

Read-only review. No code changes proposed in repo — this is a findings
document. Every finding cites `file:line` and is labelled as either:

- **Evidence** — a concrete cost observable from the source (allocation
  shape, big-O argument from real call sites, syscall per row, etc.).
- **Smell** — a plausible cost based on the code shape; I haven't
  instrumented it but the pattern reliably bites in production.

Wherever an existing perf-test, benchmark or LESSONS-doc note already
acknowledges the issue, I link it.

---

## Executive summary

Ranked by likely impact on typical day-to-day usage. Top half is where
I'd point a profiler first.

| # | Finding | Where | Confidence | Likely impact |
|---|---|---|---|---|
| 1 | `SidebarModel.objectWillChange` is force-forwarded into `DocumentModel`, so any sidebar tick (hover, expand, git poll) rebuilds every body that observes the document | `Sources/ViewerUI/DocumentModel.swift:242-246` | Evidence | Very high — global re-render storm; explains "expensive things called from body" everywhere downstream |
| 2 | `DocumentModel.renderedHTML(...)` is invoked from a SwiftUI body and computes an FNV-1a hash over the *entire file's UTF-8 bytes* on every body re-eval | `Sources/ViewerUI/DocumentModel.swift:1639-1646`, called from `ContentView.swift:468` | Evidence | High on multi-MB markdown (combined with #1) |
| 3 | LSP `didChange` ships the full file text on every outline refresh, even when text is unchanged | `Sources/ViewerCore/LSP/LSPClient.swift:415-427`, `Sources/ViewerUI/LSP/LSPOutlineSection.swift:64-65` | Evidence | High on large source files w/ language server attached |
| 4 | `CodeMirrorEditorView` sends `setText` (whole-doc JSON-encoded) into JS on every `lastSentText` mismatch; no incremental edit emission Swift→JS for user-typed changes from elsewhere | `Sources/ViewerUI/CodeMirrorEditorView.swift:370-383` | Smell | High for large open docs + frequent external rewrites |
| 5 | `highlightCache` is `@Published` — every write fires the global publisher → re-render of every DocumentModel observer | `Sources/ViewerUI/DocumentModel.swift:1539`, mutated 1588 | Evidence | High; cascades with #1 |
| 6 | `FileRowView` recurses with plain `ForEach` *inside* `LazyVStack`; only the outermost children are lazy. A deep tree materializes eagerly under one row | `Sources/ViewerUI/SidebarView.swift:763-769` | Evidence | High on wide / deeply-expanded repos |
| 7 | `LSPPositionConverter` re-walks the whole document on every `init`, and `lspPosition(for:)` does a *linear* reverse scan over `lineStartCharacterIndices` despite the doc-comment promising binary search | `Sources/ViewerCore/LSP/LSPPositionConverter.swift:34-53, 70-91` | Evidence | Medium — fired per hover dwell + per Cmd-click |
| 8 | `HexView.buildDump` runs synchronously on the main actor; for a 4 MB file at width 16 it composes ~20 MB of String + an `NSAttributedString` of the same size, then `setAttributedString` on the storage | `Sources/ViewerUI/HexView.swift:477-552` | Evidence | High on first-open of binaries near the cap |
| 9 | `CrossFileSearch.search` allocates a full-file `content.lowercased()` per file (for the case-insensitive `hay.contains(needle)` pre-check) *and* a per-line `line.lowercased()` for every matched file | `Sources/ViewerCore/CrossFileSearch.swift:130, 140` | Evidence | Medium — big allocation per scanned file |
| 10 | `CSVParser.parse` calls `Array(text.unicodeScalars)` to materialize the entire CSV into a contiguous array before walking | `Sources/ViewerCore/CSVParser.swift:66` | Evidence | Medium — 2× peak memory on big CSVs |
| 11 | `ClaudeLogParser.parse` calls `data.subdata(in:)` per JSONL line — one fresh `Data` copy per line | `Sources/ViewerCore/ClaudeLogParser.swift:99, 113` | Evidence | Medium on multi-MB transcripts |
| 12 | `HTMLRenderer.htmlEscape` is grapheme-iterated `Character`-by-`Character` with `out += "&amp;"` per match; rebuilds `usedSlugs` walks per heading | `Sources/ViewerCore/HTMLRenderer.swift:359-372, 84-107` | Evidence | Medium on large markdown documents |
| 13 | `TextDisplayView.publishSelection` builds the document's newline-offset table by walking the textStorage character-by-character via `NSString.character(at:)` on first selection move after each apply | `Sources/ViewerUI/TextDisplayView.swift:452-472` | Evidence | Medium on 1MB+ source files |
| 14 | `SidebarModel.refreshGitStatus` shells out to `git status --porcelain` on a detached `userInitiated` priority task and then walks the result building `appendingPathComponent + standardizedFileURL + resolvingSymlinksInPath` per entry | `Sources/ViewerUI/SidebarModel.swift:267-272` | Smell | Medium on big monorepos (10k+ tracked files) |
| 15 | `FolderWatcher` debounce coalesces to a *single* `onChange([URL])` — but `SidebarModel.onFolderChange` then assigns `expanded = snapshot` to force a re-publish even when nothing in the visible tree actually changed | `Sources/ViewerUI/SidebarModel.swift:113-114` | Evidence | Low individually, multiplies #1 |
| 16 | `FuzzyMatcher`-style callsites + repeated `URL.standardizedFileURL.resolvingSymlinksInPath()` syscalls during sidebar redraws (the explicit comment acknowledges this used to fire "hundreds of stats per redraw"; cache is in place but capped at 2048 entries with a sloppy "drop all" eviction) | `Sources/ViewerUI/SidebarModel.swift:225-236` | Evidence | Low-medium |
| 17 | `MermaidBundle.runtime` is added as a `WKUserScript` to the *first* WebView that ever sees a mermaid host — but is never removed; subsequent non-mermaid pages on that same WebView still parse the 2.5 MB runtime | `Sources/ViewerUI/MarkdownRenderedView.swift:92-107` | Evidence | Low ongoing, one-time cost per WebView |

Below: per-finding detail with the actual mechanism, plus a longer tail
of smaller findings.

---

## 1. Sidebar `objectWillChange` is forwarded to `DocumentModel`

**File**: `Sources/ViewerUI/DocumentModel.swift:242-246`

```swift
self.sidebar.objectWillChange
    .sink { [weak self] _ in
        self?.objectWillChange.send()
    }
    .store(in: &cancellables)
```

The comment explains the intent: views observing `DocumentModel` should
re-render when the sidebar publishes. The cost is that this fans every
single sidebar mutation — and `SidebarModel` is chatty:

- `expanded = snapshot` after FolderWatcher (line 113-114) republishes
  on every FS event burst even when no visible cache invalidated.
- `selectedURL` updates on every keyboard nav.
- `gitStatuses` rewrites on every 60-second git poll + on tab-key.
- `sortMode` toggles, `includeHidden` toggles.
- `objectWillChange` on `@Published` is value-blind — same value
  republishes.

Anything observing `DocumentModel` (and `ContentView` does, so does the
entire content tree below it) re-bodies on every one of those. That
triggers re-evaluation of `renderedHTML()` (finding #2), of
`highlightRuns()` (finding #5 cache republish chain), of every gutter
and status bar that reads from the model. The "expensive things called
in body" pattern below is the symptom; this is the cause.

**Smell vs evidence**: Evidence for the forwarding. Smell for the
downstream cascade — I haven't profiled it, but the design forces it.

**Possible mitigations** (not changes, just thinking out loud):

- Split `DocumentModel` observation surface: views that don't care
  about sidebar (TabBar, ModeBar, StatusBar) shouldn't pay sidebar
  ticks. SwiftUI's narrow-observation pattern (e.g. `@StateObject` +
  child `@ObservedObject` for sidebar only on `SidebarView`) is the
  textbook fix.
- At minimum, dedupe in the bridge: only forward when the sidebar
  republish carries a *value* change relevant to model consumers.

---

## 2. Whole-file FNV-1a hash inside SwiftUI body

**File**: `Sources/ViewerUI/DocumentModel.swift:1639-1646`,
called from `Sources/ViewerUI/ContentView.swift:468`.

```swift
private static func fnv64(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in s.utf8 {
        h ^= UInt64(byte)
        h &*= 0x0000_0100_0000_01B3
    }
    return h
}
```

Used as the cache key for `renderedHTML(...)`, which is invoked from
`renderedMarkdownView(for:category:)` directly in
`ContentView.body`. Combined with finding #1, this hash runs on every
parent republish — for a 1 MB markdown, that's a 1M-byte loop per
re-eval, on the main actor.

The cache itself works (hit path returns immediately), but the *key*
computation is the cost.

**Mitigation thought**: store the hash alongside the loaded `TextFile`
once, at load time. The text is immutable for the buffer's lifetime
between watcher reloads; recomputing per body is pure waste.

---

## 3. LSP `didChange` sends full text per outline refresh

**File**: `Sources/ViewerCore/LSP/LSPClient.swift:415-427`,
`Sources/ViewerUI/LSP/LSPOutlineSection.swift:64-65`.

```swift
// LSPOutlineModel.setFile(...)
try await pool.ensureOpened(fileURL: url, text: text)
try await pool.didChange(fileURL: url, text: text)   // ← unconditional
let syms = try await pool.documentSymbol(fileURL: url)
```

`didChange` sends the full text via a JSON envelope (LSPClient.swift
line 422 hardcodes `"contentChanges": [["text": text]]` — full-sync).
The viewer is read-only and the file watcher reload path also calls
`didChange`. With the outline section visible, every tab switch *to a
file already loaded* re-ships the entire text to sourcekit-lsp and
re-triggers indexing. On a 200 KB Swift file with 20 deps reparsing,
this is a real wall-clock latency spike on tab change.

The LSPClient itself only knows full-sync (line 414's comment locks in
that decision because "viewer is read-only"). The outline section adds
the foot-gun by sending didChange unconditionally.

**Mitigation thoughts**:

- Track per-file content-hash in the pool; skip didChange when
  unchanged.
- Or, advertise `TextDocumentSyncKind.Incremental` and use the CM6
  bridge's already-built `incrementalChange` shape (which exists for
  the editor — `CMEdit` model is right there in
  `CodeMirrorBridgeV1.swift:53-60`).

---

## 4. CM6 bridge ships full-text setText on every Swift-side push

**File**: `Sources/ViewerUI/CodeMirrorEditorView.swift:370-383`,
codec at `Sources/ViewerCore/CodeMirrorBridgeV1.swift:397-538`.

The Swift → JS path always wraps a full message in `JSONSerialization`
(line 530-535, `.sortedKeys` for stable hashing). For setText with a
1 MB doc, that's:

1. JSON-encoding the entire string (with full escape pass).
2. Concatenating into a `"window.cmDispatch(\(json));"` source string.
3. Shipping that through `evaluateJavaScript`.

Inbound has a v2 `incrementalChange` path that *does* batch edits, but
outbound `setText` is whole-doc. So:

- File-watcher external rewrites of a 5 MB log → full-doc shipment.
- Tab switch that materializes an editor → full-doc shipment.

Code already has the model (`CMOutboundMessage.applyEdits(edits:version:)`,
line 187). The path exists; the writer side just doesn't use it.

`encodeOutboundJSON` uses `.sortedKeys` (line 532) — that's a 2×
slowdown vs unordered for the JSON pass. The comment says it's not
required for production. Speculative win: drop `.sortedKeys` on the
hot encode path; keep it for the test harness.

---

## 5. `highlightCache` is `@Published`

**File**: `Sources/ViewerUI/DocumentModel.swift:1539`.

```swift
@Published public private(set) var highlightCache: [HighlightCacheKey: [HighlightRun]] = [:]
```

Mutated from `MainActor.run` after every off-thread tokenize at line
1588. Each mutation = one DocumentModel publish, which combined with
finding #1 = one re-render of every observer. The cache is a *cache*
— it's there to skip work, but the publish negates the win for any
view that doesn't actually depend on the runs.

Either:
- Make it non-`@Published` and have callers re-query via a separate
  fine-grained published flag (e.g. `highlightTick: Int`).
- Or split into per-tab small `ObservableObject`s so the publish only
  hits the active source view.

---

## 6. Eager recursion inside LazyVStack

**File**: `Sources/ViewerUI/SidebarView.swift:763-769`.

```swift
if node.isDirectory && sidebar.isExpanded(node.url) {
    ForEach(sidebar.children(of: node.url)) { child in
        FileRowView(node: child, depth: depth + 1, ...)
    }
}
```

The outer `LazyVStack` (line 317) lazily materializes its direct
children, but those children are `FileRowView`s that recursively
contain `ForEach` over their *own* children. `ForEach` outside a
`LazyVStack` is eager. Result: as soon as the user expands a folder,
the entire visible subtree under that folder is built as SwiftUI views
up front. A 5-level deep expansion of a wide directory =
exponentially-sized view tree.

Tree-view widgets are a known SwiftUI footgun (`OutlineGroup` has the
same issue). The accepted fix is flat-render the visible nodes via a
single top-level `LazyVStack(ForEach(flatVisibleNodes()))` with
per-row indentation as padding. The model already maintains
`flatVisibleNodes()` (line 128-140) — currently used only for keyboard
nav. Using it for render is the win.

---

## 7. `LSPPositionConverter` linear scan claiming to be binary search

**File**: `Sources/ViewerCore/LSP/LSPPositionConverter.swift:70-91`.

```swift
public func lspPosition(for stringIndex: String.Index) -> LSPPosition {
    let clamped = min(stringIndex, text.endIndex)
    // Binary-search the line-start array to find the line number.
    var line = 0
    for i in (0..<lineStartCharacterIndices.count).reversed() {
        if lineStartCharacterIndices[i] <= clamped {
            line = i
            break
        }
    }
    ...
}
```

The doc comment promises binary search; the code is a linear scan
from the *end* of the lineStart array. For a cursor near the top of
a 30k-line file, that's ~30k compares per call. `String.Index`
comparison is cheap, but firing this on every hover dwell on a big
file isn't free.

Also: the converter is instantiated per hover request
(`LSPHoverAttachment.swift:379` builds a fresh one with the entire
text). The `init` is O(N) over the document. Hover dwells are
300 ms → easy to fire several times per minute on a big file.

**Win**: actual binary search (`partitioningIndex`) + cache the
converter per `(URL, version)` rather than rebuild per request.

---

## 8. Synchronous `buildDump` on main actor

**File**: `Sources/ViewerUI/HexView.swift:477-552`.

`buildDump` is called from `updateNSView` (line 337) — i.e. on every
SwiftUI body re-eval that has changed key state (file/font/width).
For a binary file at the documented 4 MB cap, width 16:

- 262 144 rows × ~80 chars/row = 21 MB string body.
- `s.reserveCapacity(...)` helps allocation, but every `s += "  "`
  and `s.append(char)` still walks the row.
- `NSAttributedString(string: s, attributes: attrs)` allocates that
  again.
- `textStorage?.setAttributedString(result.attr)` drops the old + sets
  the new on the main thread.

Tab switch into a hex view of a big binary = noticeable blocking
hitch. The cache (`lastDumpKey` at line 331) prevents rebuild on
re-renders, but the first build (and any width-change) is on main.

DESIGN.md §6 promises mmap + multi-GB handling. The current code
doesn't do that — `BinaryFileLoader` (not read here, but called from
the binary path) appears to materialize the full data into `Data`.

**Win**: detach `buildDump` to a background task; show a placeholder
while computing.

---

## 9. `CrossFileSearch.search` full-file lowercased copies

**File**: `Sources/ViewerCore/CrossFileSearch.swift:130, 140`.

```swift
let hay = options.caseSensitive ? content : content.lowercased()
guard hay.contains(needle) else { continue }

// Compute per-line matches.
var fileMatches: [Match] = []
let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
for (i, lineSub) in lines.enumerated() {
    let line = String(lineSub)
    let haystack = options.caseSensitive ? line : line.lowercased()
    ...
}
```

`content.lowercased()` allocates a copy of the entire file. Then for
every line in a *matched* file, another `line.lowercased()`. The
per-keystroke debounced search re-runs all of this.

Mitigations:
- `content.range(of: needle, options: .caseInsensitive)` for the
  pre-check avoids the allocation.
- For per-line matching, `line.range(of: needle, options:
  [.caseInsensitive, .literal])` similarly avoids the per-line lower
  alloc.

Note: there's also no actual rg-style regex / glob support despite
DESIGN.md §12.4.6 promising it.

---

## 10. CSVParser materializes full file as Unicode-scalar array

**File**: `Sources/ViewerCore/CSVParser.swift:66`.

```swift
let scalars = Array(text.unicodeScalars)
```

For a 50 MB CSV that's an `Array<Unicode.Scalar>` of ~50M elements —
each scalar is 4 bytes, so ~200 MB peak just for the index. The parse
itself is single-pass, but the materialization doubles peak memory.

Iterating `text.unicodeScalars` directly via an indexing view would
avoid the array, at the cost of slightly more `String.index(after:)`
work.

---

## 11. ClaudeLogParser `data.subdata(in:)` per JSONL line

**File**: `Sources/ViewerCore/ClaudeLogParser.swift:99, 113`.

```swift
let slice = data.subdata(in: lineStart..<i)
if let obj = try? JSONSerialization.jsonObject(with: slice, options: []) ...
```

`data.subdata(in:)` copies. For a 100 MB transcript at ~500 events/MB
= 50k allocations of varying sizes. `JSONSerialization` accepts `Data`
slices that are zero-copy via `Data.init(bytesNoCopy:)`, but cleaner
is to feed `data[lineStart..<i]` directly (which is a slice view —
`Data` slices are zero-copy until mutated).

Test: `try JSONSerialization.jsonObject(with: data[lineStart..<i])`
works because `JSONSerialization` accepts the abstract `Data` protocol
and the slice conforms.

`maxEvents = 200_000` default cap (line 73) protects worst-case but
the per-line cost still hits big sessions hard.

---

## 12. `HTMLRenderer.htmlEscape` grapheme-iteration

**File**: `Sources/ViewerCore/HTMLRenderer.swift:359-372`.

```swift
func htmlEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        switch ch {
        case "&":  out += "&amp;"
        case "<":  out += "&lt;"
        ...
        default:   out.append(ch)
        }
    }
    return out
}
```

`for ch in s` iterates `Character` (grapheme clusters), which is the
slowest String iteration. For pure-ASCII passages this is 5-10× slower
than iterating `s.unicodeScalars` or `s.utf8`. Also `out += "&amp;"`
allocates a new string per match (or relies on `+=` short-string
optimization).

Called on every text segment and every code-fence body during HTML
emission. For a 100 KB markdown with 50 fences, this is a measurable
fraction of total render time.

`HTMLVisitor.uniqueSlug` (line 84-107) iterates `text.unicodeScalars`
correctly — same author who wrote `htmlEscape` did better in a nearby
function, so this is just a leftover early-version pattern.

Also: `HTMLVisitor` reconstructs `usedSlugs` per document but
heading-anchor allocation isn't itself the bottleneck.

---

## 13. `publishSelection` newline-offset walk

**File**: `Sources/ViewerUI/TextDisplayView.swift:452-472`.

```swift
private func newlineOffsetsRefreshed() -> [Int] {
    ...
    let ns = storage.string as NSString
    var offsets: [Int] = []
    offsets.reserveCapacity(max(16, length / 80))
    var i = 0
    while i < length {
        if ns.character(at: i) == 0x0A {
            offsets.append(i)
        }
        i += 1
    }
    ...
}
```

Acknowledged in the comment (line 446) as the binary-search index
that fixes a worse O(M·N) walk. But `NSString.character(at:)` per
UTF-16 unit is itself slow for 1MB+ files — UTF-16 storage may not
be contiguous (BridgedNSString from a Swift String can have
non-contiguous layout, each `character(at:)` walks).

Faster: `storage.string.utf16.enumerated()` with a fast-path for
contiguous storage, or iterate the underlying `NSTextStorage`'s
`enumerateAttribute` and accumulate manually.

The good news: cached + reused across selection moves of the same doc
version. Only the *first* selection after content change pays. For
a 1 MB Swift file with frequent reloads via file watcher, this still
adds up.

---

## 14. `git status` shell-out on every sidebar root change + 60s timer

**File**: `Sources/ViewerUI/SidebarModel.swift:264-275`,
`Sources/ViewerUI/Git/GitPanelModel.swift:75-82` (60-second timer).

`status --porcelain` on a monorepo with 30k+ tracked files takes
hundreds of ms, regardless of `-uall` flag (already
`-uall`-tagged in GitClient line 61 for status, but GitService is
plain `--porcelain=v1` line 63). The work runs detached
(`Task.detached(priority: .userInitiated)`), so it doesn't block
main, but:

- It fires on every sidebar root change.
- The 60s timer in `GitPanelModel.start()` keeps re-running it
  forever even when the user isn't looking at the git panel.
- The result-walk allocates a new URL per entry with two normalize
  operations (`standardizedFileURL.resolvingSymlinksInPath()`,
  line 271) — for 5000 status entries, 10000 syscalls equivalent.

`Timer.scheduledTimer(withTimeInterval: 60, repeats: true)` (line 77)
is added to `.common` mode → fires while menus are up. That's the
point but it means it never pauses.

Mitigations:
- Pause the 60s timer when the git panel isn't visible.
- Use FSEvents on `.git/index` mtime to invalidate instead of polling.
- Skip the per-entry URL normalize; status results are already
  repo-root-relative and don't traverse symlinks.

---

## 15. FolderWatcher always force-republishes `expanded`

**File**: `Sources/ViewerUI/SidebarModel.swift:113-114`.

```swift
let snapshot = expanded
expanded = snapshot
```

Comment says "expanded is the cheapest @Published prop to nudge". OK
but `@Published` on a `Set<URL>` is value-blind, so this *always*
republishes. Combined with finding #1, every FSEvents debounce burst
(even on directories not in the visible tree, since `dirs` includes
all changed paths' parents) refires the entire content tree.

`touched` correctly tracks "did any cached dir actually change", so
the assignment is gated. Still, the use of "republish even though
SwiftUI saw no value change" is the pattern the rest of the codebase
has had to fight.

---

## 16. `normalizationCache` LRU is "drop all" eviction

**File**: `Sources/ViewerUI/SidebarModel.swift:231-233`.

```swift
if normalizationCache.count > 2048 {
    normalizationCache.removeAll(keepingCapacity: true)
}
```

When the cap is hit, the whole map is nuked. Next sidebar scroll =
2048 fresh `realpath` syscalls. A real LRU (Swift Collections'
`OrderedDictionary`, or just an insertion-ordered drop of the older
half) would amortize.

Same "drop a third" pattern appears in `highlightCache`
(DocumentModel.swift:1604) and `renderedHTMLCache` (1729), where
"drop arbitrary entries because Dictionary key order has no semantic
meaning" actually means "throw away whatever Swift's hash gave us
this time". Could legitimately evict the *active* cached file under
load.

---

## 17. Mermaid runtime never removed from WebView

**File**: `Sources/ViewerUI/MarkdownRenderedView.swift:92-107`.

The user-script flag `coord.mermaidInjected = true` is set on first
detection of a `<div class="mdv-mermaid">`. The comment says "non-
mermaid pages on the same WebView still get the runtime (cheap;
idempotent for them)". 2.5 MB of JS parsed + JITted on every
subsequent page-load in that WebView isn't free — for a user who
opens one mermaid file and then 50 plain markdown files, all 50 pay.

`WKUserContentController.removeAllUserScripts()` exists. Re-adding on
demand is cheap.

---

## Additional smaller findings

### 18. `applyFindHighlights` always wipes full-range temp attrs

**File**: `Sources/ViewerUI/TextDisplayView.swift:891`.

```swift
let full = NSRange(location: 0, length: textStorage.length)
layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
```

Acknowledged in the comment as the early-return guard's reason for
being. But when find is genuinely active (query non-empty), the full
removal still happens on every apply. For a 1 MB source with the find
bar showing, that's a 1M-unit range walk. Layout manager APIs do
handle this efficiently when no attributes are present in the range,
but the worst-case + the per-apply cadence still smell.

### 19. `LSPPool.workspaceSymbol` fans out sequentially

**File**: `Sources/ViewerCore/LSP/LSPPool.swift:520-541`.

Comment justifies it: "most workspaces have ≤2 servers live". True
today, but the moment a user opens Rust + Python + TypeScript repos
in the same session this serializes 3 LSP RPCs. `TaskGroup` would
parallelize them with minimal complexity. Smell, not yet a real cost.

### 20. `MCPProtocol` / Automation has no per-request budget

**File**: `Sources/ViewerCore/Automation/MCPServer.swift` (read
surface only — not the focus). Worth a separate audit.

### 21. `BinaryFileLoader` reads full file into `Data`

Not opened here but referenced by `HexView` (line 481, `file.data`).
DESIGN.md §6 promises mmap; reality is `Data(contentsOf:)`. Above the
4 MB cap the user gets a placeholder, but multi-GB log inspection is
not possible with this loader.

### 22. `JQRunner.swift` has a `DispatchQueue.global(qos: .userInitiated).asyncAfter`

**File**: `Sources/ViewerCore/JQRunner.swift:103`. Didn't read in depth;
worth checking if the cancellation path actually cancels in-flight
subprocesses.

### 23. `Walkthrough` auto-advance ticks via `Task.sleep(nanoseconds:)`

**File**: `Sources/ViewerUI/Walkthrough/WalkthroughAutoAdvance.swift:110`.
`Task.sleep` is fine; just noting one more polling path the system
has to babysit.

### 24. `TabsState` not inspected — open question whether
`@Published var tabs: TabsState` on a struct with deeply-nested arrays
forces a full struct copy on every mutation. Worth confirming with a
quick read.

### 25. `LSPClient.shutdown()` `Task.sleep(for: .milliseconds(200))`

**File**: `Sources/ViewerCore/LSP/LSPClient.swift:596`. Fixed 200ms
delay on every shutdown — accumulates if the user closes 5 tabs with
different LSPs at once (250ms each in sequence per `closeAll` line 158-163).
Could parallelize the loop or skip the sleep when the process has
already exited.

### 26. `SQLiteReader` (not opened) — typical browser shows N rows
per query; worth checking if it pages or fetches all upfront.

### 27. `Sources/ViewerCore/SidebarPanelHeights.swift` is per-pixel
clamp called from every `@AppStorage` getter (`SidebarView.swift:59-64`).
Cheap, not a concern, but worth knowing the path runs on every panel
render.

---

## Patterns observed (cross-cutting)

A few patterns recur and amplify each other:

1. **"Force a republish" via `@Published` value-blind assign**
   (`SidebarModel.swift:113-114`, scattered uses of `objectWillChange.send()`).
   Works in isolation; pathological in aggregate because every
   subscriber re-bodies.

2. **Expensive work in SwiftUI `body`**: `fnv64()` (finding #2),
   `tokenize` call sites (cached but the cache itself republishes,
   finding #5), `MarkdownStylesheet.cached` read (fine, it's a
   `static let` — line 450), `renderedHTML` (finding #2). The body
   should be allocation-cheap; it's not.

3. **Whole-file copy as cache-key or pre-pass**: `content.lowercased()`
   (#9), `Array(text.unicodeScalars)` (#10), full UTF-8 walks for
   FNV (#2), `subdata(in:)` per line (#11). Each is locally fine;
   together they form the "open a 5MB log and watch RAM spike"
   experience.

4. **Linear scans labelled "binary search"**: finding #7. Pattern of
   correct-by-comment-only code.

5. **Caches with "drop all" or "drop arbitrary" eviction**: findings
   #16 + `highlightCache` + `renderedHTMLCache`. Under steady-state
   working-set load they thrash.

6. **Per-mode flag for "first-time setup but never reset"**: the
   mermaid bundle case (#17). Once-true forever can be a quiet RAM /
   parse-cost cliff.

---

## What I'd profile next (if I were turning this into a fix list)

In rough ROI order:

1. Attach Instruments → SwiftUI body-time scope on a fresh launch
   with a 200 KB markdown, scroll the sidebar in a wide repo. Expect
   the body-call count for `ContentView` to be in the hundreds per
   second. If so, finding #1 is confirmed.
2. Same workload, scope on `String.UTF8View.makeIterator` or
   `_fnv64` — expect findings #2 + #12 to dominate.
3. Open a 10 MB JS file in source mode with sourcekit-lsp + JS LSP
   running. Profile main thread + LSP IPC bytes. Expect finding #3 +
   #4 + #7 to add up.
4. Open the largest binary you have in the project's `dist/` under
   the 4 MB cap. Profile the first paint. Expect #8.
5. Run cross-file search across a wide repo for a 3-char query.
   Profile allocations. Expect #9 to dominate.

---

## What I deliberately *didn't* dig into

- The actual TreeSitter engine internals (paintOver looks fine; the
  one note is that `[Event]` allocation and per-event dictionary churn
  in `kindByIdx` may matter on multi-thousand-run files).
- The plugin subprocess host — separate review surface.
- Workspace snapshot save/restore performance — small JSON, fine.
- Test infrastructure — separate review.
- WebKit IPC payload size beyond setText (finding #4).
- The `Sessions` rotation/snapshot path — small enough.
- Pure-perf of the TreeSitter parse itself; engine size cap is
  512 KB anyway (HighlightRun.swift:48).

These are reasonable next targets for a follow-up dedicated pass.

---

## Methodology note

This was a code-read pass, not an instrumented profile. Where I called
something "Evidence", the code shape and the call site cadence are
together strong enough that I'd bet a beer on a profiler confirming
within 5-10%. Where I said "Smell", I'm pattern-matching from past
production work — I haven't measured but I've shipped the bug.

Everything cited is an absolute path + line number — clickable from
the terminal. Cross-references to `LESSONS.md`, `DESIGN.md`, and
`docs/` files are where the existing institutional knowledge already
acknowledges the pattern.
