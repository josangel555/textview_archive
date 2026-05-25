# Correctness review — 2026-05-25

Read-only review focused on **bugs, defects, and behaviour that diverges
from intent**. Scope: `Sources/` across all packages (`ViewerCore`,
`ViewerKit`, `ViewerUI`, app target). Recently-landed and old code both
fair game. No code changes.

## Severity scale

| Level | Meaning |
|---|---|
| **S1 / Critical** | Wrong behaviour users will hit in everyday use, or potential data loss / crash. Fix near-term. |
| **S2 / High** | Wrong behaviour in a realistic but non-default scenario, OR a clean code-path that silently swallows / mishandles a class of input. |
| **S3 / Medium** | Edge case or low-probability input that produces wrong output but isn't dangerous. Documented limitations also live here. |
| **S4 / Low** | Theoretical / latent / nit. Worth knowing about; not worth dropping other work for. |

Counts (this report): **S1 ×4, S2 ×9, S3 ×11, S4 ×7**.

---

## S1 — Critical

### S1-A. `presentExternalEditConflict` "Keep My Edits" resets dirty baseline incorrectly

`Sources/ViewerUI/DocumentModel.swift:1877-1912`.

When the user chooses **Keep My Edits** after an on-disk-changed-while-
dirty alert, the code:

1. Calls `buf.markSaved(...)` on a local `var buf` (does not store back).
   `markSaved` sets `originalText = text` — i.e. clears dirty.
2. Then constructs a *fresh* `EditorBuffer` initialised with
   `original: buf.originalText`, which at that point is the **post-mark**
   `originalText` — i.e. the user's current text, not the pre-existing
   baseline. (`buf.originalText` was overwritten in step 1.)
3. Then calls `setText(buf.text)` on the freshly built buffer.

End state: `originalText == text` → `isDirty == false`. The tab's
**dirty flag stays true** because `Tab.isDirty` is mirrored separately
(line 1417 path of `saveEditor`), but `EditorBuffer.isDirty` returns
false. A subsequent ⌘S has nothing to do (saveEditor still writes, but
the conceptual baseline is wrong). More importantly: if the user makes
*more* edits then chooses Revert / a future "compare original" feature,
the baseline is gone.

The comment block on lines 1897–1909 acknowledges the issue but the
implementation does the wrong thing — it captures `buf.originalText`
**after** mutating it.

Recommended fix: capture `originalText` into a local **before** calling
`markSaved`, or skip `markSaved` entirely and just update the
fingerprint fields directly.

### S1-B. `closeTabsToRight(of:)` crashes on out-of-range index

`Sources/ViewerUI/DocumentModel.swift:2046-2050`.

```swift
public func closeTabsToRight(of index: Int) {
    let toClose = (index + 1)..<tabs.tabs.count   // CRASHES if index+1 > count
    ...
```

If `index >= tabs.tabs.count`, this is `N+1 ..< N` which trips
`Range`'s precondition (`lowerBound <= upperBound`). The bounds-check
on line 2061 (`tabs.tabs.indices.contains(index)`) runs **after** the
range is constructed. Callable via menu/script verbs with stale state
(e.g. a deferred user gesture firing after a tab was closed by the
file watcher / another window).

Recommended fix: guard at the top: `guard tabs.tabs.indices.contains(index)
else { return }`.

### S1-C. JSON over `evaluateJavaScript` can break on U+2028 / U+2029

`Sources/ViewerCore/CodeMirrorBridgeV1.swift:529-538` (encoder) +
`Sources/ViewerUI/DocumentModel.swift:1239` (one of many call sites:
`webView.evaluateJavaScript("window.cmDispatch(\(json));")`).

`JSONSerialization` does **not** escape `U+2028 LINE SEPARATOR` /
`U+2029 PARAGRAPH SEPARATOR`. Both are valid JSON string contents but
are **line terminators in JavaScript** (pre-ES2019; even modern engines
honour them inside source text). Embedding raw JSON into JS source via
string interpolation therefore breaks parsing the moment file contents
contain one of these.

Realistic triggers:
* `setText` payload from a PDF→markdown export, Word paste, Unicode-
  heavy notes app.
* `hoverResponse` content from sourcekit-lsp when the symbol doc
  contains a `\u{2028}`.
* `setDiagnostics` message strings.

Same risk in `MarkdownRenderedView.Coordinator.jsEscape`
(`Sources/ViewerUI/MarkdownRenderedView.swift:246-254`), used to embed
the find-bar query into a generated JS function call. A query like
`"foo\u{2028}bar"` produces a syntax error in the generated script
(user input → silent find failure, not crash).

Recommended fix: post-process the JSON output to escape ` ` →
`\\u2028` and ` ` → `\\u2029`. (Single-line `String.replacingOccurrences`
on the encoded JSON string before interpolation.)

### S1-D. `LSPClient.request` race: timeout `Task` armed before continuation registered

`Sources/ViewerCore/LSP/LSPClient.swift:266-282`.

```swift
let timeoutTask = Task { [weak self] in
    try? await Task.sleep(for: timeout)
    await self?.timeoutFire(id: id, method: method)
}
defer { timeoutTask.cancel() }

return try await withCheckedThrowingContinuation { cont in
    self.pending[id] = cont
    ...
}
```

The timeout task is created **before** `pending[id] = cont` runs. The
client is an actor, so the timeout task can only fire when the actor
is free — which happens between the `Task { ... }` creation and the
continuation hop. The continuation registration is *also* on the actor,
so in practice both run atomically before the timeout's sleep finishes.

However: `Task.sleep(for: .nanoseconds(0))` or a very small timeout
would fire immediately on actor entry. `timeoutFire` would call
`pending.removeValue(forKey: id)` → returns nil → no resume. The
continuation then gets registered and is **never** resumed.
`CheckedContinuation` produces a leak warning in debug builds and an
indefinite hang in release.

Timeouts in current code are ≥3s so this is latent. But if any caller
ever passes a sub-millisecond timeout (tests, throttle), it bites.

Recommended fix: register pending **first**, then arm the timeout.

---

## S2 — High

### S2-A. `SessionsCoordinator.activate` doesn't bump the newly-active session's `lastActiveAt`

`Sources/ViewerCore/Sessions/SessionsCoordinator.swift:156-169`.

Only the **outgoing** session's `lastActiveAt` is bumped (line 164).
The newly-activated session keeps its prior timestamp. The LRU sort
used by `close` (line 188) and `restore` (line 102) consequently
under-ranks the session the user just re-engaged with.

User-visible effect: after A → B → A, closing A activates B (because B
has a newer `lastActiveAt` than A's stale value).

### S2-B. Multi-screen wrong-coords in `showEditorContextMenu`

`Sources/ViewerUI/DocumentModel.swift:1211-1218`.

```swift
let mainScreen = NSScreen.screens.first { screen in
    screen.frame.contains(NSPoint(x: webkitPoint.x, y: 0))
} ?? NSScreen.main
let screenHeight = mainScreen?.frame.height ?? 0
let appkitY = screenHeight - webkitPoint.y
```

Two problems:
1. `screen.frame.contains(NSPoint(webkitPoint.x, 0))` only matches
   screens whose frame includes the y=0 row of the global coordinate
   space. If the user has a portrait/secondary monitor below the main
   one, the picked screen is wrong.
2. The conversion assumes the chosen screen's frame is anchored at
   y=0 in the global coord space. With multi-monitor setups the
   secondary's `frame.origin.y` is non-zero, so
   `screenHeight - webkitPoint.y` is the wrong flip.

Correct conversion: `appkitY = NSScreen.screens[0].frame.maxY - webkitPoint.y`
(the **primary** screen's `frame.maxY` is the universal flip pivot for
WebKit-to-AppKit y).

User-visible effect: editor right-click on a non-primary monitor pops
the menu at the wrong location, sometimes off-screen.

### S2-C. `ClaudeLogParser.transcriptDirectory` path encoding has collisions

`Sources/ViewerCore/ClaudeLogParser.swift:258-269`.

```swift
let encoded = ... .path.replacingOccurrences(of: "/", with: "-")
```

`/a/b-c` and `/a-b/c` both encode to `-a-b-c`. The result is two
distinct projects' transcripts pointing at the same directory, or one
being mistakenly considered to have transcripts because of the other.

Claude Code's own encoding rule (which this is mirroring) does in fact
do this — but the bug is real on Claude's side too, and is worth
documenting / migrating off. At minimum, surface a warning when two
distinct sidebar roots resolve to the same encoded dir.

### S2-D. `CrossFileSearch` lower-cased-vs-original index mapping returns nil for "ß"-class lines

`Sources/ViewerCore/CrossFileSearch.swift:142-191` (`mapRange`).

`String.lowercased()` can change character count (German `ß` → `ss`,
Greek `Σ` → `σ/ς`). The `lowered.distance(...)` offsets don't map
back to valid `original` positions. The function falls into the
`limitedBy` failure path and returns `nil`, so the match is still
*surfaced* but with `matchRange == nil` — the result row in
`CrossSearchPanel` cannot highlight the matched substring.

Lower-severity: the actual line still shows; user knows their query
hit something on this line. But the visual highlight is gone for
exactly the locales most likely to need it.

### S2-E. `FindEngine.search` line/column counting misses `\r` and counts `\r\n` wrong

`Sources/ViewerCore/FindEngine.swift:71-88`.

```swift
while cursor < target && cursor < nsText.length {
    if nsText.character(at: cursor) == 0x0A { line += 1; lineStart = cursor + 1 }
    cursor += 1
}
```

* CR-only files (Mac classic, occasional Windows-tool output): every
  match is reported as `line: 1, column: <doc-offset>`.
* CRLF files: line numbers are correct (LF still counted), but
  `column = target - lineStart + 1` doesn't subtract the `\r`. Off-
  by-one on every column.

This data feeds the `FindMatchMinimapView` ticks and the source-view
"go to match" gutter scroll. The gutter is line-based so the CRLF
miscount is invisible; the column miscount affects status-bar readouts.

### S2-F. `TabsState.close(at:)` doesn't `cancelMaterialize` the same way `DocumentModel.closeTab` does

`Sources/ViewerUI/DocumentModel.swift:1972-2000` (`closeTab`) +
similar paths in `closeOthers` and `closeToRight`.

`closeTab` *does* call `cancelMaterialize(forTabID:)`. But `closeOtherTabs`
(line 2008-2044) and `closeTabsToRight` (line 2046-2078) iterate
`closedTabs` and call cancelMaterialize too — looks fine.

However, **`reload(url:at:)`** (line 1914-1920) re-sets `tab.state =
state` even when a materialize Task for this tab id is in flight. If
materialize completes after reload, line 2200's `guard case
.loading(let pendingURL)` check correctly drops the stale result —
but only because `reload` overwrites the state to a non-loading
value. If a programmer extends `reload` to leave state as
`.loading(...)` temporarily, the race re-opens.

S2 because the safety net is real but fragile. A regression test would
help.

### S2-G. `DocumentModel.renderedHTML` cache key drops on dictionary-key order

`Sources/ViewerUI/DocumentModel.swift:1727-1735`.

```swift
if renderedHTMLCache.count > Self.renderedHTMLCacheMax {
    let drop = renderedHTMLCache.count - Self.renderedHTMLCacheMax * 2 / 3
    for k in renderedHTMLCache.keys.prefix(drop) {
        renderedHTMLCache.removeValue(forKey: k)
    }
}
```

`Dictionary.keys` order is implementation-defined. The "drop oldest"
intent isn't met — the cache may evict the entry we just inserted,
making the next render a miss. Same pattern in `pruneHighlightCacheIfNeeded`
(line 1600-1608) and `displayText`'s formatted cache eviction (line
1511-1519).

Functionally cache-correct (no wrong content), just defeats the
caching strategy. Use an explicit insertion-ordered structure or
track per-key access timestamps.

### S2-H. `LSPPositionConverter.stringIndex(for:)` walks past a multi-code-unit char on a fractional `remaining`

`Sources/ViewerCore/LSP/LSPPositionConverter.swift:96-110`.

```swift
while remaining > 0 && idx < text.endIndex {
    let ch = text[idx]
    if ch == "\n" { break }
    let units = Self.codeUnitCount(of: ch, in: encoding)
    remaining -= units                  // can go negative
    idx = text.index(after: idx)
}
```

If an LSP position lands "inside" a surrogate pair / emoji
(`character` count > what would line up with a char boundary), the
loop overshoots: `remaining` becomes negative, `idx` advanced past
the character. The returned `idx` is one character past the intended
position. Realistic only for malformed servers, but a real client
should clamp.

Pair this with the comment at line 73-79 — the "binary-search" line
lookup is actually a reverse linear scan, an explicit `O(N)` per
position lookup. Perf for big files: not great, but not a correctness
bug.

### S2-I. `LSPClient.dispatchInbound` blindly drops server-originated requests with `id`

`Sources/ViewerCore/LSP/LSPClient.swift:208-227`.

Per LSP spec, server requests (id + method) MUST get a response —
either result or error. The PoC drops them silently. Affected
methods include `workspace/configuration`, `client/registerCapability`,
`window/showMessageRequest`. sourcekit-lsp is tolerant. clangd /
rust-analyzer / pyright / typescript-language-server are not — they
log timeouts and eventually degrade or refuse further requests.

Comment acknowledges this. S2 because it bites the moment we expand
language support beyond sourcekit-lsp.

---

## S3 — Medium

### S3-A. `DiffParser.parseDiffGitPaths` fails on paths containing spaces or ` b/`

`Sources/ViewerCore/Git/DiffParser.swift:186-202`. `split(separator:
" ", maxSplits: 1)` splits `a/foo bar.txt b/foo bar.txt` into
`["a/foo", "bar.txt b/foo bar.txt"]`. Second token lacks the `b/`
prefix at the start, so `stripPathPrefix` returns the whole junk
string. Fallback `range(of: " b/")` would find the inner ` b/` too
early on `a/x b/y b/z`.

Spaces in paths are rare; quoted paths from git aren't supported here
at all (the comment claims they are but only handles surrounding
double-quotes for the *stripped* component, not the diff-line
detection).

### S3-B. `BookmarksStore.move(from:to:)` silently clamps wildly out-of-range indices

`Sources/ViewerCore/BookmarksStore.swift:119-127`. Negative `from`
clamps to 0, huge `to` clamps to last index. Drag-drop sources that
deliver malformed indices get a no-op or arbitrary reorder instead of
an error. Cosmetic; would surface a real bug somewhere upstream that
this swallows.

### S3-C. `ClaudeLogParser.parse` exceeds `maxEvents` by one block

`Sources/ViewerCore/ClaudeLogParser.swift:88-124`. The `events.count
>= self.maxEvents` early-exit check runs only at the end of a line
loop iteration; `parseRecord` may have appended several events in one
go. The final `prefix(maxEvents)` clamp covers it, but the doc comment
says hard ceiling — and the closure return doesn't actually halt
parsing, since the trailing-line block at line 110-118 runs after.

### S3-D. `Tab` Equatable misses `.loading(URL)` payload equality

`Sources/ViewerCore/Tab.swift:67-77`. `case (.loaded, .loaded)`,
`case (.binary, .binary)`, `case (.error, .error)` ignore payloads.
`.loading(URL)` falls into `default → false` because no explicit case
exists. Two adjacent `.loading(sameURL)` Tabs compare unequal even
though they shouldn't differ; flips view-side diff equality in a way
that *should* be inert but produces extra SwiftUI work. Cosmetic, but
trivially fixable by adding the case.

### S3-E. `FuzzyMatcher.match` uses `Character.lowercased()` (returns String)

`Sources/ViewerCore/FuzzyMatcher.swift:39`. `ch.lowercased() ==
q[qi].lowercased()` compares two `String` values per character per
target. For Turkish `İ → i̇` (i + combining dot above), the lowercased
String has length 2; query `"i"` won't match. Niche.

### S3-F. `CSVParser` always strips trailing single-empty row

`Sources/ViewerCore/CSVParser.swift:131-133`. The "drop terminal
all-empty row that a trailing newline causes" trims `[""]` rows. A
legitimate `,` ending — single-column CSV whose last row is genuinely
empty — gets dropped. Documented intent vs realistic input is borderline.

### S3-G. `DiffHunkParser` deletion+addition counts not symmetric

`Sources/ViewerCore/Git/DiffHunkParser.swift:79-82`. Multiple `-`
lines followed by multiple `+` lines: the first `+` upgrades the
matching `lineInNew+1` to `.modified`. Subsequent `+` lines mark as
`.added`. Geometrically the changed region is N→M lines; treating the
prefix as modified and the rest as added is a reasonable heuristic
but doesn't match the typical IDE rendering ("all M new lines marked
as modified").

### S3-H. `CSVParser` doesn't allow quoted strings to start mid-field

`Sources/ViewerCore/CSVParser.swift:88`. `if c == quoteScalar,
field.isEmpty { inQuotes = true }`. Strict RFC 4180-ish reading says
a quote inside an already-started unquoted field is part of the data.
Some real-world CSVs do start a quoted span after some leading
whitespace, e.g. ` "value"`. The parser keeps the leading spaces and
then literal quotes inside the field. Documented limitation; would
surprise some users.

### S3-I. `ColumnExpression.parse` "long-prefix first" misses spaced operators

`Sources/ViewerCore/CSVFilter.swift:122-132`. `> = 5` (with space) is
parsed as `.greaterThan("= 5")` instead of `.greaterOrEqual("5")`.
Edge case but the parser is intended to be permissive.

### S3-J. `WorkspaceSnapshot` restore: `selectedTabIndex` of 0 used when nil

`Sources/ViewerUI/DocumentModel.swift:1704`. `let target = snap.selectedTabIndex ?? 0`.
A workspace persisted with NO selection (deliberate empty state)
still focuses tab 0 on restore. Hard to hit but breaks "I closed all
tabs before quitting" cleanly.

### S3-K. `JSONFileStore.read` size check has a TOCTOU window

`Sources/ViewerCore/JSONFileStore.swift:27-34`. The
`attributesOfItem` size check and the subsequent `Data(contentsOf:)`
+ post-read `data.count <= maxSize` check are both there, which is
good. But the post-read check happens AFTER the full data is in
memory — for the malicious-tampering case (cap is to defend against
an attacker-controlled file inflating into RAM), if the file grew
between stat and read, we've already allocated the whole thing
before refusing. The size-cap discussion is about defence-in-depth;
the post-read check should ideally read with a length-capped reader.

---

## S4 — Low / latent

### S4-A. `DocumentModel.revealInSidebar` rel-path splits on `/` after a string-replace

`Sources/ViewerUI/DocumentModel.swift:300-314`. `target.path
.replacingOccurrences(of: rootStd.path + "/", with: "")` only strips
the FIRST occurrence (replacingOccurrences default replaces all,
actually). If a path contains `rootStd.path + "/"` twice (only possible
with self-referential symlinks, which `resolvingSymlinksInPath` should
have collapsed), things get strange. Unreachable in practice.

### S4-B. `FolderWatcher.handleEvents` debounce work captures `self` weakly but `pendingPaths` mutation isn't atomic across multiple events

Line 147-167 of `Sources/ViewerCore/FolderWatcher.swift`. The lock is
correctly held around `pendingPaths` mutation, but the
`queue.asyncAfter(deadline: .now() + debounce, execute: work)` runs
the work without re-acquiring the lock around the `captured = ...;
pendingPaths.removeAll()` snapshot inside — wait, it does acquire it
on line 155. OK, this is correct. Confused on first read; flagging
that the locking dance is subtle and would benefit from a comment.

### S4-C. `FileWatcher.reattachSoon` increments `attempts` before knowing if attach succeeds

`Sources/ViewerCore/FileWatcher.swift:123-155`. The `attempts`
counter goes to 1 even when `attach()` would have succeeded on the
first probe. The exponential delay `reattachDelay * 2^(attempt-1)`
on attempt=1 = base delay, so the user-visible effect is nil — but the
counter naming is misleading.

### S4-D. `LSPClient.cancelRequest` only acts if pending entry still present

`Sources/ViewerCore/LSP/LSPClient.swift:306-323`. If a late server
response arrives between the `$/cancelRequest` send and the local
resume, the pending entry is gone and the resume is dropped silently.
Cancellation token resolves as "no result" rather than "cancelled".
Caller can't distinguish. Probably fine for the current UI.

### S4-E. `HexSearchEngine.parse(mode: .hex, query: "")` returns `[]` (empty pattern)

`Sources/ViewerCore/HexSearchEngine.swift:40`. Caller `search`
returns `[]` so user sees no hits. Reasonable, but the `parse`
function returns `[]` (success, empty) while invalid hex returns
`nil` (failure). The HEX find bar's "invalid query" UI state depends
on the distinction; whitespace-only queries are reported as valid
empty. Cosmetic.

### S4-F. `MarkdownRenderedView.runFind` `documentReady` gate fires "no result" on first call before load

Line 218 of `Sources/ViewerUI/MarkdownRenderedView.swift`. `guard
documentReady else { return }` early-returns silently. The find-bar's
`onFindResult?(nil)` isn't called in this path; UI shows stale match
state until the document finishes loading and `webView(_:didFinish:)`
replays the pending find. If the user toggles between rendered and
source quickly, the find-bar match count can lag a frame.

### S4-G. `Formatter` cache eviction uses `Dictionary.keys.prefix(...)`

Same `Dictionary.keys` issue as S2-G but in `formattedTextCache`
eviction (line 1511-1519 of `DocumentModel.swift`). Lower severity
because formatted-text reset is cheaper than HTML re-render.

---

## Cross-cutting observations

### Tests miss the "stale `Dictionary.keys` eviction" class of bugs

The three caches that grow without bound and self-prune via
`keys.prefix(...)` (S2-G, S4-G) don't have tests that assert the
prune *picks the oldest entry*. Easy gap to close: insert N+1
entries with distinct keys, force a prune, assert the very first
entry inserted is the one missing (or use an ordered cache type).

### Tests don't exercise the LSP encoding race or timeout-pathologies

`LSPClientTests` (looking at file list) appear to cover the
happy-path framing/decode. Nothing seems to exercise:
* Multiple concurrent requests with concurrent timeouts.
* Server crash mid-request (transport close while pending).
* Server-originated request handling.

### Bridge JSON escaping is uniformly under-tested

Every `evaluateJavaScript("…\(json)…")` site shares the U+2028/U+2029
risk. There's no centralised "safe JS embed" helper. The find-bar's
`jsEscape` does its own thing; the CM bridge does its own thing; the
mermaid bundle injector does its own thing. Recommend a single
`String.jsSafeJSONEmbedded` helper in `ViewerKit` and tests against
the line-separator inputs.

### `nonisolated(unsafe)` is sprinkled liberally

`BookmarkEntry.iso8601`, `ClaudeLogParser.iso{Fractional}`,
`FindEngine.lastRegex(Key)`, all marked `nonisolated(unsafe)` with
"documented thread-safe" rationale. `ISO8601DateFormatter`
`date(from:)` IS documented thread-safe; `NSRegularExpression` is
*also* documented thread-safe. But the two static vars in
FindEngine — `lastRegexKey` and `lastRegex` — are mutated under
`NSLock`, which is correct, but the `nonisolated(unsafe)` is a hand
wave. Swift 6 strict-concurrency would prefer an actor or a `Mutex`.
Not a correctness bug; flagging because the pattern is repeated.

### Same-byte-length file watcher reload was historically a bug

The `renderedHTMLCache` was upgraded from `length`-keyed to
`FNV-1a(content)`-keyed (good). The **`highlightCache`** is still
`(URL, length, language)`-keyed (line 1534-1538 of `DocumentModel`).
A same-length file watcher reload (`# Hello\n` → `# World\n`)
serves stale highlight spans. Less visible than HTML staleness
(spans are roughly positional), but the inconsistency between the
two caches is a smell.

---

## Notes for the orchestrator

* No deep dive into `MarkdownViewer/main.swift` (1882 lines) yet —
  AppDelegate / menus / app-lifecycle / open-handlers are likely to
  contain a few S2-class bugs around document state transitions but
  weren't sampled in this pass. Recommend a follow-up review focused
  there.
* `CodeMirrorEditorView` and `TextDisplayView` (the two view
  representables wrapping NSView + WKWebView) weren't read in depth.
  Both are large (821 / 1108 lines) and the NSViewRepresentable
  lifecycle is where the existing project history says bugs hide
  (per `DESIGN.md` §7). Worth a targeted second pass.
* `Sources/ViewerUI/Resources/codemirror/codemirror.html` is the
  JS-side counterpart to the bridge — auditing the JS for `cmDispatch`
  reentrancy would be a separate exercise.
