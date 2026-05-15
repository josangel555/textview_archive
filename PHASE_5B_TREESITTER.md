# Phase 5b — TreeSitter syntax highlighting

**Status:** APPROVED — proceeding with spike. Decisions locked, see §12.

## TL;DR

Replace the regex highlighter (parked in `_parked/phase5b-regex-stash/`) with
TreeSitter. Use [`tree-sitter/swift-tree-sitter`](https://github.com/tree-sitter/swift-tree-sitter)
(first-party, transferred from ChimeHQ, BSD-3-Clause) as the binding and pull
each language grammar as its own SwiftPM package (`tree-sitter-swift`,
`tree-sitter-json`, …). Tokenize off-main with task-based cancellation, map
captures to colors through a small in-repo theme system (no extra packages),
apply attributes per-line in the existing SwiftUI source view.

**Cost:** ~3–6 MB added to the final binary, ~10 s one-time cold-build hit,
1 new direct dependency + 7 grammar packages.

**Why TreeSitter over regex:** real grammars correctly handle nested
structure (strings containing keywords, comments containing strings,
markdown with embedded code, JSX tags). The regex stack hits a quality
ceiling fast; this one doesn't. Earlier "50k LOC of generated C" framing
was misleading — that code is auto-generated, never read, compiled once.

---

## 1. How TreeSitter works (quick primer)

TreeSitter is a parser generator. Grammar authors write a JS-DSL grammar;
the `tree-sitter` CLI generates a self-contained `parser.c` (sometimes plus
a hand-written `scanner.c`). The runtime is pure C11 with no external deps.

Core objects (we'll see all of these in the Swift bindings):

| C type           | Role                                                        | Thread story                            |
|------------------|-------------------------------------------------------------|------------------------------------------|
| `TSLanguage`     | Immutable static parse tables                               | Sendable; share freely                   |
| `TSParser`       | Stateful parser; bind a language, feed bytes, get a tree    | Single-threaded; one per worker          |
| `TSTree`         | Concrete syntax tree; refcounted, `ts_tree_copy` is atomic  | Copy before crossing thread boundaries   |
| `TSNode`         | Lightweight cursor into a tree (value type)                 | Safe, but **dangles** if the tree drops  |
| `TSQuery`        | Compiled S-expression query                                 | Immutable, share freely                  |
| `TSQueryCursor`  | Iteration state                                             | Single-threaded                          |

Highlighting is **not built into the parser.** We run a `highlights.scm`
query against the tree; each match binds a capture name (`@keyword`,
`@string`, `@function`, …) to a node range. We map capture → color.

For Markdown specifically the grammar is *two* parsers (block + inline)
chained via "injections," and code fences inject yet again into per-language
parsers. We need a layered model to handle that correctly.

Sources:
- https://tree-sitter.github.io/tree-sitter/
- https://tree-sitter.github.io/tree-sitter/3-syntax-highlighting.html
- https://tree-sitter.github.io/tree-sitter/using-parsers/3-advanced-parsing.html

---

## 2. Package choice

**Picking `tree-sitter/swift-tree-sitter`.** First-party under the tree-sitter
org (transferred from ChimeHQ — same repo, BSD-3, v0.10.0 from Mar 2026,
19 releases, actively maintained). Vendors the C runtime, so we don't take
a second package for it. Provides both a low-level wrapper and the
higher-level `SwiftTreeSitterLayer` for nested languages / injections —
which is exactly what Markdown-with-code-fences needs. The repo move to
first-party tightens the provenance story; nothing changes API-side.

**Not picking ChimeHQ/Neon.** Neon is the "drop into a `NSTextView` and get
flicker-free highlighting" layer. Our source view is pure SwiftUI; we don't
have an `NSTextView` to feed Neon's `TextViewHighlighter`. The lower-level
SwiftTreeSitter API maps cleanly to our per-line `AttributedString` model.
If we later add an editor, revisit.

**Not picking Runestone.** Full editor framework; we're a viewer. Way too
much surface area, and it pulls its own copy of the C runtime.

**Not picking Splash / Highlightr / Sourceful.** Splash is Swift-only.
Highlightr runs highlight.js inside `JSContext` (works, but a JS engine on
the hot path for a viewer is wrong). Sourceful is regex-based and stale.

Audited alternatives + sources in
`/_parked/phase5b-research-notes.md` (research transcript, not shipped).

---

## 3. Languages we'll ship

**v1 (must work):** Swift, JSON, XML, Python, JavaScript, TypeScript,
Markdown, Shell/Bash.

**v1.5 (stretch, low effort once the pipeline works):** YAML, HTML, CSS,
SQL, Go, Rust, C, C++, Ruby, Java, Kotlin.

Each grammar ships its own `Package.swift` exposing a `TreeSitter<Lang>`
product, with `queries/highlights.scm` as a resource. Confirmed pattern
from `tree-sitter/tree-sitter-json`:

```swift
.target(
    name: "TreeSitterJSON",
    dependencies: ["SwiftTreeSitter"],
    path: ".",
    sources: ["src/parser.c"],
    resources: [.copy("queries")],
    publicHeadersPath: "bindings/swift",
    cSettings: [.headerSearchPath("src")]
)
```

Each exposes one C symbol: `const TSLanguage *tree_sitter_<lang>(void);`.

License audit: every grammar in scope is MIT or Apache-2.0. Clean.

**Special case: Markdown** is two grammars (`tree-sitter-markdown` block
+ `tree-sitter-markdown-inline`) with injections. `SwiftTreeSitterLayer`
handles the layering for us.

---

## 4. Vendoring cost (honest estimates)

| Grammar       | parser.c size  | Notes                          |
|---------------|----------------|--------------------------------|
| JSON          | ~10–30 KB      | Trivial                        |
| XML           | ~0.5 MB        |                                |
| Bash          | ~0.5–1 MB      | Has external scanner           |
| Markdown      | ~1 MB combined | Block + inline + scanner       |
| Python        | ~1–2 MB        |                                |
| JavaScript    | ~2 MB          |                                |
| Swift         | ~2–4 MB        |                                |
| TypeScript    | ~8.7 MB        | Confirmed                      |
| **Total v1**  | **~15–20 MB**  | of generated C source          |

After clang `-Os` for universal arm64 + x86_64: **~3–6 MB added to the
final binary**. Runtime itself is ~150–200 KB.

**Build-time:** cold `swift build` gains ~5–15 s. Warm rebuilds unaffected
(SwiftPM caches object files).

I will not commit to a number; these are derived from the tree-sitter#1041
discussion and grammar repo file listings, not from cloning each one. We
should measure once during the spike (§9) and update this doc.

---

## 5. Performance (what to expect)

- Cold parse 10k-line Swift/TS file: **30–80 ms** on M-series.
- Cold parse 10k-line JSON: **5–15 ms**.
- Query execution (`highlights.scm`) over the same tree: **10–30 ms**.
- Incremental edit one keystroke into an existing tree: **<1 ms** (we're
  read-only, so this doesn't matter, but useful for re-parsing on file
  change).

For our viewer, files are almost always <5k lines. Total parse + highlight
budget: **<50 ms** off-main, well under the user-perceptible threshold.

---

## 6. Threading model

Doc-scoped pattern:

```
┌─ DocumentModel (main actor) ──────────────────┐
│   loaded TextFile + language                  │
│   highlightTokens: [HighlightRun]? (published)│
└───────────────────┬───────────────────────────┘
                    │ Task { await … }
                    ▼
┌─ HighlightTask (off-main, serial) ────────────┐
│   1. parser.parse(text)                       │
│   2. query.execute(rootNode)                  │
│   3. flatten captures → [HighlightRun]        │
└───────────────────┬───────────────────────────┘
                    │ await MainActor.run
                    ▼
                publish back to model
```

One `Parser` per active document (cheap; lives in the task). `TSLanguage`
and `TSQuery` are shared singletons keyed by `HighlightLanguage`. We
cancel an in-flight task if the file content changes underneath us — same
pattern as the cross-file search.

`HighlightRun` is `[start: Int, length: Int, kind: TokenKind]` arrays —
just plain `Sendable` data, no tree pointers crossing the boundary. This
sidesteps the "Node dangles after Tree drop" footgun cleanly.

---

## 7. Integration into the source view

The pure-SwiftUI `TextDisplayView` (post-NSTextView-removal) renders each
line as a separate `Text` view inside a `LazyVStack`. The natural fit:

1. Tokenize once when text+language is loaded → `[HighlightRun]`.
2. Build a `lineRuns: [[HighlightRun]]` table indexed by line number
   (single pass; runs that cross a newline get split at the newline).
3. Each `Text` becomes `Text(AttributedString)` built from that line's
   runs against the theme.

`SyntaxTheme` (matches what we already had in the parked work) maps
`TokenKind → NSColor`. Default theme uses `NSColor` system colors so it
follows light/dark automatically.

**Capture-name → TokenKind table.** TreeSitter capture names are a loose
convention (`@keyword`, `@keyword.control`, `@string`, `@string.escape`,
`@function`, `@function.call`, `@type`, `@variable`, `@number`, `@comment`,
`@punctuation`, `@operator`, …). We collapse to our existing `TokenKind`
enum at the boundary. Unknown captures fall through to default color.
Table lives in one place so we can iterate.

**Files >2 MB:** skip highlighting (same cap as the parked engine had).
Tokenization remains fast above that but query execution on giant trees
can dominate; not worth the variance.

---

## 8. Code fence injection (HTMLRenderer)

When we render markdown via WKWebView, code fences come from
`HTMLRenderer`. Today they get `<pre><code class="lang">…</code></pre>`
with no highlighting. Plan:

- Server-side highlight: tokenize the fence body using the same TreeSitter
  pipeline, emit `<span class="tok-keyword">…</span>` spans. CSS in the
  stylesheet maps `tok-*` → colors that match the source-view theme.
- The fence info-string (`swift`, `bash`, `js`) maps through
  `HighlightLanguage.detect(fromInfoString:)` — that helper already exists.
- Unknown info-strings → plain `<pre><code>` (no spans).

This is the same pipeline as the source view, just emitted as HTML
instead of `AttributedString`. Sharing the capture→TokenKind mapping is
the point of having `TokenKind` in the first place.

---

## 9. Spike results (DONE — proceeding)

Spike landed on branch `phase5b-treesitter-spike` (commit pending).

**Setup:** added `tree-sitter/tree-sitter-json@0.24.8` + `ChimeHQ/SwiftTreeSitter@0.25.0`
(GitHub redirects ChimeHQ→tree-sitter org). SwiftTreeSitter 0.25.0 no
longer bundles the C runtime — pulls `tree-sitter/tree-sitter@0.25.10`
as a separate package. Cleaner provenance, one place to track ABI.

**Smoke test:** `Tests/ViewerCoreTests/Phase5bSpikeTests.swift`, 3 cases:
parse-walk, ABI binding, highlight-capture firing. All pass.

| Measurement                | Baseline | With JSON grammar | Delta    |
|----------------------------|----------|--------------------|----------|
| `swift build -c release`   | 20.93 s  | 21.79 s            | +0.86 s  |
| Binary `MarkdownViewer`    | 3.8 MB   | 4.3 MB             | +0.5 MB  |
| Strict-concurrency clean   | yes      | yes                | (no new warnings from TreeSitter) |

JSON is the smallest grammar so this isn't a full-set extrapolation, but
the trend is reassuring — runtime + 1 grammar costs ~0.5 MB of binary
and ~1 s of cold-build time. Even at 10× for the full v1 set we'd come
out under 10 MB of binary delta. **Comfortably acceptable.**

**Findings (one design-impacting bug, one cosmetic):**

1. `LanguageConfiguration(_, name:)` initializer looks for queries at
   `Contents/Resources/queries/` — that's the iOS resource bundle
   layout. SwiftPM bundles on macOS are *flat* (`<bundle>/queries/`),
   so this initializer fails on macOS with `queryDirectoryNotReadable`.
   Workaround in the real engine: use the `queriesURL:` initializer
   and discover the path ourselves. Easy.
2. The version numbers in the original research (0.10.0 / 0.24.0) are
   stale — current is 0.25.0 / 0.24.8. No API change; just bump our
   `from:` requirements.

**Decision: proceed.** No blocker found; binary cost is well under the
ceiling; Swift 6 strict-concurrency is clean. Moving to integration in
§10 without stopping per user instruction.

---

## 10. Rollout plan

After approval:

1. **Spike branch.** Items in §9. Tear down or merge.
2. **`HighlightEngine` module.** Lives in `ViewerCore`. Exposes:
   ```swift
   public protocol HighlightEngine {
       func tokenize(_ text: String, language: HighlightLanguage) async -> [HighlightRun]
       func supportedLanguages: Set<HighlightLanguage>
   }
   public final class TreeSitterEngine: HighlightEngine { … }
   ```
   `HighlightRun` is `(NSRange, TokenKind)`. The protocol lets us mock in
   tests + lets us keep `HighlightLanguage` engine-agnostic (it already is).
3. **`SyntaxTheme`.** Re-add the parked theme verbatim.
4. **Wire into `DocumentModel`.** Owns a `highlightTask`. Tokenizes on
   text-load and on file-watch reload. Publishes
   `lineRuns: [Int: [HighlightRun]]`.
5. **Update `TextDisplayView`.** Each `Text` becomes attributed using
   the runs for that line.
6. **Update `HTMLRenderer`.** Fence highlighting via the same engine.
7. **Update `ModeBar`.** Show `language.displayName` badge when source
   mode is active.
8. **Tests.**
   - `ViewerCoreTests/TreeSitterEngineTests.swift`: golden tokenization
     for a snippet per language. Stable because grammar versions are
     pinned in `Package.resolved`.
   - `ViewerUITests`: a per-language script that opens a sample file,
     dumps `model.lineRuns`, asserts the first keyword/string/comment
     show up at the expected ranges. Reuses the existing dump-JSON test
     harness.
9. **Remove the parked regex code** once the new engine ships green
   (`rm -rf _parked/phase5b-regex-stash/`). Keep
   `Sources/ViewerKit/HighlightLanguage.swift` — it's engine-neutral.

Per-task subtasks will land in TaskCreate after approval.

---

## 11. Risks & footguns

1. **ABI version drift.** SwiftTreeSitter bumps its bundled runtime
   version → some old grammar packages refuse to bind. Mitigation: pin
   all of (SwiftTreeSitter + every grammar) in `Package.resolved`, bump
   in lockstep, smoke-test on every upgrade.
2. **`.scm` queries change between grammar versions.** Capture names
   shift. Mitigation: **vendor our own copies** of `highlights.scm` for
   each language under `Sources/ViewerCore/Highlight/Queries/` rather
   than relying on `Bundle.module` from upstream. Painful one-time copy,
   stable forever after.
3. **`Node` dangling after `Tree` drops.** Pure Swift footgun. Mitigation:
   the engine boundary returns `[HighlightRun]` (plain integers + enum) —
   no tree-borrowed pointers cross into our code.
4. **UTF-16 vs byte offsets.** TreeSitter is byte-oriented; AppKit is
   UTF-16. SwiftTreeSitter has helpers (`Tree.rangeProvider`). Stick to
   them; don't hand-roll.
5. **Universal binary build cost.** Compile time × 2 for arm64+x86_64.
   For our project this is fine; for distribution we should profile and
   consider arm64-only if x86_64 demand is zero.
6. **External scanners.** Bash, Markdown, Python, Ruby, HTML have a
   `scanner.c`. The `Package.swift` of each grammar must list it in
   `sources:`. Verify per-grammar at integration time.
7. **Markdown injections complexity.** `SwiftTreeSitterLayer` does the
   heavy lifting. If it has bugs, fenced code rendering quality suffers.
   Mitigation: layered `XCTSkip`-guarded tests for each fence language.

---

## 12. Decisions (locked)

- **(A) Engine**: `tree-sitter/swift-tree-sitter` only. No Neon/Runestone.
- **(B) v1 language set**: Swift, JSON, XML, Python, JS, TS, Markdown,
  Bash. Confirmed.
- **(C) Query vendoring**: yes — copy `highlights.scm` into our repo per
  language under `Sources/ViewerCore/Highlight/Queries/`.
- **(D) Spike first**: yes, but proceed without stopping. Evaluate the
  results and continue unless the spike actually fails.
- **(E) Architecture**: **arm64-only**, latest macOS (drop the `.v14`
  floor to the current latest). Halves compile time, halves the §4
  binary delta.
- **(F) Rollout §10**: approved as-is.

---

## 13. Coloring plan (no package dependency)

**Question:** "any guidelines/best practices/conventions, or do we pick what
makes sense?"

**Short answer:** TreeSitter has a *capture-name convention*, not a color
convention. Colors are the editor's call. We pick what makes sense and
build it ourselves — no theme package.

### The capture-name convention

`.scm` highlight queries emit captures with names from a loose,
community-maintained hierarchy (see the
[nvim-treesitter highlights reference](https://github.com/nvim-treesitter/nvim-treesitter/blob/master/CONTRIBUTING.md#highlights)
and the [tree-sitter highlighting doc](https://tree-sitter.github.io/tree-sitter/3-syntax-highlighting.html#highlights)).
Names are dot-separated and "fall back" left-to-right: a renderer that
doesn't know `@keyword.control.return` falls back to `@keyword`. The set
we'll handle (most-specific first; coarse fallbacks last):

| Capture                                    | Our TokenKind   |
|--------------------------------------------|-----------------|
| `@keyword`, `@keyword.*`                   | `.keyword`      |
| `@string`, `@string.special`               | `.string`       |
| `@string.escape`                           | `.escape`       |
| `@string.regexp`                           | `.regex`        |
| `@comment`, `@comment.*`                   | `.comment`      |
| `@number`, `@constant.numeric`             | `.number`       |
| `@constant`, `@constant.builtin`           | `.builtin`      |
| `@type`, `@type.builtin`                   | `.type`         |
| `@function`, `@function.*`, `@method.*`    | `.function`     |
| `@variable`, `@variable.*`, `@parameter`   | `.variable`     |
| `@attribute`, `@annotation`                | `.attribute`    |
| `@operator`                                | `.operator`     |
| `@punctuation`, `@punctuation.*`           | `.punctuation`  |
| `@tag`                                     | `.tag`          |
| `@tag.attribute`                           | `.tagAttribute` |
| `@text.title`, `@markup.heading`           | `.heading`      |
| `@text.uri`, `@markup.link.url`            | `.link`         |
| `@text.emphasis`, `@markup.italic`         | `.emphasis`     |
| `@text.strong`, `@markup.bold`             | `.strong`       |
| (anything else)                            | default color   |

The fall-back walk is dumb-simple: split capture name on `.`, walk
right-to-left dropping a segment at a time, look up in a `[String: TokenKind]`
dict. First hit wins. Lives in one ~50-line file, well-tested.

### Color choices

Two well-known palettes anchor the field:
- **Xcode default / Xcode dark** — Apple's source-editor colors. Bias for
  Mac-native consistency. Documented informally; close approximations are
  trivial.
- **One Dark** (Atom heritage, now in VS Code, JetBrains, etc.) — the
  community baseline for dark themes.

We pick *Xcode-ish* by default: it's what a Mac user expects, and the
colors are tuned for AppKit's `.textBackgroundColor` (the same background
our source view uses). Hex values are not standardized — we hand-pick to
match.

**Light theme (Xcode default-ish):**

| Kind         | NSColor                            | Hex (light)  |
|--------------|------------------------------------|--------------|
| default      | `.labelColor`                      | `#1C1C1C`    |
| keyword      | `NSColor(0xAD, 0x3D, 0xA4)`        | `#AD3DA4`    |
| string       | `NSColor(0xC4, 0x1A, 0x16)`        | `#C41A16`    |
| comment      | `NSColor(0x53, 0x71, 0x6A)`        | `#53716A`    |
| number       | `NSColor(0x1C, 0x00, 0xCF)`        | `#1C00CF`    |
| type         | `NSColor(0x70, 0x30, 0xA0)`        | `#7030A0`    |
| function     | `NSColor(0x4B, 0x21, 0xB0)`        | `#4B21B0`    |
| variable     | `.labelColor`                      | `#1C1C1C`    |
| attribute    | `NSColor(0x70, 0x30, 0xA0)`        | `#7030A0`    |
| builtin      | `NSColor(0x27, 0x37, 0x8E)`        | `#27378E`    |
| heading      | `NSColor(0x1F, 0x6F, 0xEB)`        | `#1F6FEB`    |
| link         | `NSColor(0x1F, 0x6F, 0xEB)`        | `#1F6FEB`    |
| tag          | `NSColor(0xAD, 0x3D, 0xA4)`        | `#AD3DA4`    |
| tagAttribute | `NSColor(0x83, 0x6C, 0x28)`        | `#836C28`    |

**Dark theme (Xcode dark-ish):**

| Kind         | Hex (dark) |
|--------------|------------|
| default      | `#DFDFE0`  |
| keyword      | `#FC5FA3`  |
| string       | `#FC6A5D`  |
| comment      | `#6C7986`  |
| number       | `#D0BF69`  |
| type         | `#9EF1DD`  |
| function     | `#67B7A4`  |
| variable     | `#DFDFE0`  |
| attribute    | `#D0BF69`  |
| builtin      | `#9EF1DD`  |
| heading      | `#41A1C0`  |
| link         | `#41A1C0`  |
| tag          | `#FC5FA3`  |
| tagAttribute | `#D9C97C`  |

These are illustrative — the spike pass produces actual files and we
visually tune side-by-side against Xcode.

**No package dependency.** Themes live as Swift structs in
`Sources/ViewerCore/Highlight/Theme/`. No JSON parsing, no plist, no TextMate
`.tmTheme` import. If we ever want VS Code theme import that's an additive
feature; out of scope for v1.

---

## 14. Theme system

```swift
public struct SyntaxTheme: Sendable {
    public let name: String
    public let appearance: NSAppearance.Name   // .aqua or .darkAqua
    public let background: NSColor             // matches NSColor.textBackgroundColor
    public let defaultText: NSColor
    public let colors: [TokenKind: NSColor]
    public func color(for kind: TokenKind) -> NSColor {
        colors[kind] ?? defaultText
    }
}
```

Built-ins shipped in v1:

- `SyntaxTheme.xcodeLight`
- `SyntaxTheme.xcodeDark`

**Theme selection** lives on `DocumentModel` (or a new
`AppearanceModel`, if it gets bigger):

```swift
@Published var themeOverride: SyntaxTheme.Name? = nil   // nil = follow system
var activeTheme: SyntaxTheme {
    if let o = themeOverride { return o == "dark" ? .xcodeDark : .xcodeLight }
    return NSApp.effectiveAppearance.bestMatch(
        from: [.aqua, .darkAqua]
    ) == .darkAqua ? .xcodeDark : .xcodeLight
}
```

We subscribe to `NSApplication.didChangeAppearanceNotification` (or
observe `effectiveAppearance` via KVO) and republish — so a system Light↔
Dark toggle re-themes the visible source view immediately.

User override later: a "Settings → Appearance" picker writing
`themeOverride` to `UserDefaults`. Out of scope for the spike; the model
field is the hook.

**Theme also drives HTMLRenderer code-fence CSS.** Same `TokenKind`
table, just emitted as `:root { --tok-keyword: #AD3DA4; … }` with a
`@media (prefers-color-scheme: dark)` block. Single source of truth.

---

## 15. Async / blocking story

**Question:** "It's async, right? No blocking?"

**Yes — non-blocking on the main thread, with task cancellation.** Spelled
out concretely:

```swift
@MainActor
public final class DocumentModel: ObservableObject {
    @Published private(set) var highlightRuns: [Int: [HighlightRun]] = [:]
    private var highlightTask: Task<Void, Never>?

    func setText(_ text: String, language: HighlightLanguage) {
        // 1. Cancel any in-flight task for the previous text/lang.
        highlightTask?.cancel()
        // 2. Clear runs immediately so the view never paints stale colors.
        highlightRuns = [:]
        // 3. Capture by value, hop off main.
        let snapshot = text
        let lang = language
        highlightTask = Task.detached(priority: .userInitiated) { [weak self] in
            let engine = await SharedHighlightEngine.shared
            let runs = engine.tokenize(snapshot, language: lang)
            try? Task.checkCancellation()
            await MainActor.run {
                self?.highlightRuns = runs
            }
        }
    }
}
```

Properties of this:

- **Main actor never blocks on parse.** Even a 100ms parse on a huge file
  is invisible to the UI; the view shows plain text for that long, then
  pops to colored. Same trick the cross-file search uses today.
- **Cancellation.** A file-watcher reload or a tab-switch immediately
  cancels the prior task. The engine itself can't be interrupted
  mid-`ts_parser_parse_string`, but the post-parse query stage and the
  publish-back-to-main step both check `Task.isCancelled`. Worst case is
  one wasted parse, ~50ms.
- **No re-entrancy.** Only one highlight task per document is live; the
  old one is cancelled before the new one starts.
- **The engine itself.** `TreeSitterEngine` is an `actor` so parser state
  (per-language `Parser`s, compiled `Query`s) can't race. Inside the
  actor we use a single `Parser` instance per language, reused across
  parses — cheap; just a state machine.

For the initial spike (§9) we skip the actor and run synchronously in the
test — simpler, and the test isn't UI-bound.

---

## 16. Reactivity (file watch, language change, theme change)

**Question:** "Is it reactive? Like file change → re-run/refresh?"

**Yes.** Three trigger paths, all flowing through the same
`setText(_:language:)` entry point in §15:

1. **Initial load.** `TextFileLoader` reads → `DocumentModel.setText(...)`.
2. **File-watcher fires** (file changed on disk). `FileWatcher` already
   re-reads the file and replaces `currentTab.contents`; the same
   `setText` call re-tokenizes. Cancellation handles the case where two
   saves fire in quick succession.
3. **Language change** (user manually picks language from a future
   menu, or `detect(from:)` returns a different language after rename).
   Just calls `setText` again with the new language argument.

**Theme change** is *not* a re-tokenize — same `[HighlightRun]`, just
different `NSColor`s applied. The view re-renders because the published
`activeTheme` value changes; we don't touch the highlight task. Cheap.

**Debounce.** File-watcher already debounces filesystem events; we
inherit that. We do *not* debounce inside the highlight task — first-byte
keystroke responsiveness doesn't matter for a viewer.

**Live edit?** Out of scope: we're read-only. If/when we add edit, the
incremental tree update path (§1) is what makes per-keystroke
re-highlighting cheap.

---

## 17. Catching version drift in tests

**Question:** "How can we catch version drift during testing?"

Version drift = SwiftTreeSitter bumps its runtime, a grammar package
bumps its tables, or an `.scm` capture name we depend on gets renamed.
Defenses in order from cheapest to strongest:

### Defense 1 — `Package.resolved` is committed

Standard SwiftPM. Already in the repo. Pins exact versions across the
whole dependency graph. Any unintended bump shows up in a `git diff
Package.resolved`.

### Defense 2 — Vendored queries (decision C)

We copy `highlights.scm` per language into our repo. Upstream renaming a
capture from `@function` to `@function.call` no longer silently changes
our highlighting — *we* control the query string.

When we choose to upgrade a query, we do it as a deliberate edit, run
tests, see what changes, decide.

### Defense 3 — Golden tokenization tests

For each v1 language, a test file in `Tests/ViewerCoreTests/Highlight/`:

```swift
func testJSONHighlighting() throws {
    let source = #"""
    { "name": "alice", "age": 30, "tags": ["a","b"], "x": null }
    """#
    let runs = TreeSitterEngine.shared.tokenize(source, language: .json)
    let pairs = runs.map { (source.nsrange($0.range), $0.kind) }
    XCTAssertEqual(pairs, [
        (NSRange(location:  2, length:  6), .string),    // "name"
        (NSRange(location: 10, length:  7), .string),    // "alice"
        (NSRange(location: 19, length:  5), .string),    // "age"
        (NSRange(location: 26, length:  2), .number),    // 30
        (NSRange(location: 30, length:  6), .string),    // "tags"
        (NSRange(location: 39, length:  3), .string),    // "a"
        (NSRange(location: 43, length:  3), .string),    // "b"
        (NSRange(location: 49, length:  3), .string),    // "x"
        (NSRange(location: 55, length:  4), .keyword),   // null
    ])
}
```

Per language, ~one such snippet covering: keywords, strings (incl. escape),
comments (where applicable), numbers, types, functions. **These break
loudly on any upstream change** that affects highlights — exactly the
signal we want.

### Defense 4 — ABI smoke test

A single fast test that loads every shipped language and confirms
`parser.setLanguage(lang)` succeeds:

```swift
func testEveryLanguageBinds() throws {
    for lang in HighlightLanguage.allCases where lang != .plainText {
        let parser = Parser()
        XCTAssertNoThrow(try parser.setLanguage(TreeSitterEngine.shared.tsLanguage(for: lang)),
                         "ABI mismatch for \(lang)")
    }
}
```

This is the test that catches a SwiftTreeSitter major bump that broke an
old grammar — it fails immediately, no need to wait for someone to open
the file.

### Defense 5 — CI rule

Add to `.github/workflows/test.yml` (we don't have one yet, but as soon as
we do): "If `Package.resolved` changed, the golden tests must pass." That's
mechanically true already — what we want is to make the *signal* visible
when a routine `swift package update` is run locally. We add a comment in
README explaining the convention.

### Combined coverage

| Drift scenario                          | Caught by             |
|------------------------------------------|------------------------|
| SwiftTreeSitter major bump, ABI break    | Defense 4              |
| Grammar package bump, parse output shift | Defense 3              |
| Upstream renames capture in their .scm   | Defense 2 (we ignore)  |
| We choose to update our .scm             | Defense 3 (intentional)|
| Accidental version bump in resolved      | Defense 1 + 3 in CI    |

This stack is cheap (~one test file per language + one smoke test) and
sufficient. We don't need anything more elaborate.

---

## Appendix: minimal integration sketch

This is illustrative — final code lives in `TreeSitterEngine.swift` after
approval.

```swift
// Package.swift additions
dependencies: [
    .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter",       from: "0.10.0"),
    .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", from: "0.7.0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-json",  from: "0.24.0"),
    // … one per language …
]
// In the ViewerCore target dependencies:
.product(name: "SwiftTreeSitter",       package: "SwiftTreeSitter"),
.product(name: "SwiftTreeSitterLayer",  package: "SwiftTreeSitter"),
.product(name: "TreeSitterSwift",       package: "tree-sitter-swift"),
.product(name: "TreeSitterJSON",        package: "tree-sitter-json"),
```

```swift
import SwiftTreeSitter
import TreeSitterSwift

func highlightSwiftSource(_ source: String) throws -> [(NSRange, String)] {
    let language = Language(language: tree_sitter_swift())
    let parser = Parser()
    try parser.setLanguage(language)
    guard let tree = parser.parse(source) else { return [] }

    // Our vendored highlights.scm, not Bundle.module from upstream:
    let url = Bundle.module.url(
        forResource: "swift-highlights", withExtension: "scm")!
    let query = try language.query(contentsOf: url)

    var out: [(NSRange, String)] = []
    for match in query.execute(node: tree.rootNode!, in: tree) {
        for capture in match.captures {
            let r = capture.node.range          // byte range
            let nsRange = NSRange(location: r.location, length: r.length)
            out.append((nsRange, capture.name ?? ""))
        }
    }
    return out
}
```

That's the entire highlighter, modulo the capture→TokenKind table and the
off-main task harness.

---

## Sources

Research was done by a sub-agent against current upstream state. Key
links:

- https://github.com/ChimeHQ/SwiftTreeSitter
- https://github.com/ChimeHQ/Neon
- https://tree-sitter.github.io/tree-sitter/
- https://tree-sitter.github.io/tree-sitter/3-syntax-highlighting.html
- https://tree-sitter.github.io/tree-sitter/using-parsers/3-advanced-parsing.html
- https://github.com/tree-sitter/tree-sitter-json (canonical Package.swift shape)
- https://github.com/alex-pinkus/tree-sitter-swift (current Swift grammar)
- https://github.com/tree-sitter-grammars/tree-sitter-markdown
- https://github.com/tree-sitter/tree-sitter-bash
- https://github.com/tree-sitter/tree-sitter#1041 (parser size discussion)
- https://github.com/simonbs/Runestone (alternative, considered)
- https://github.com/JohnSundell/Splash (alternative, considered)
- https://github.com/raspu/Highlightr (alternative, considered)

Honest uncertainty:
- Exact byte/binary sizes in §4 are estimates; §9 nails them down.
- Swift 6 strict-concurrency clean build is community-reported; §9
  confirms.
- `TSQueryCursor` API name in SwiftTreeSitter 0.10 may differ slightly
  from the sketch above; the spike will surface that.
