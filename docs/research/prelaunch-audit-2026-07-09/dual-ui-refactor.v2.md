# Pre-launch Audit — Dual UI Implementations (native AppKit/SwiftUI vs WKWebView/CM6) — v2

> Note: a prior `dual-ui-refactor.md` exists in this directory from an earlier pass. This v2 is
> an independent re-review of the same dimension (not a merge); it corroborates the prior
> findings and is kept as a separate file to avoid clobbering that work.

**Dimension:** Map every duplicated surface, divergence, and inconsistency between the two
rendering stacks; propose a consolidation strategy.
**Date:** 2026-07-09 · **Scope:** `Sources/ViewerUI/` (presentation) + ThemeDefinition /
HighlightLanguage seams in `ViewerCore`/`ViewerKit`.
**Verdict:** Dimension **applies strongly**. The app carries two parallel text/document
rendering stacks that overlap on the most-used surfaces. The overlap is deliberate mid-migration
state (TSK-1530 / WEB-MIGRATE), but it is *live, shipped* debt: both stacks are maintained and
they diverge in user-visible ways.

---

## Executive summary

The presentation layer renders document content through **two independent engines**:

| Surface | Native AppKit stack | WebView stack |
|---|---|---|
| Read-only source (`.source`) | `TextDisplayView` (NSTextView) + `SourceGutterView` + `LineNumberRulerView` + `SourceInvisiblesView` + `SelectionHighlightEngine` (~2.4K LOC) | `CodeMirrorEditorView` behind `WebSourceViewGate` (ships OFF) |
| Editable buffer (`.editor`) | — (was an NSTextView PoC, retired) | `CodeMirrorEditorView` (CM6, ~3.0K LOC + 1.1 MB `codemirror.js`) |
| Markdown rendered (`.rendered`) | `LSPMarkdownRenderer` (NSAttributedString, hover only) | `MarkdownRenderedView` (WKWebView) — the file viewer |
| Raw HTML | — | `HTMLRenderedView` (WKWebView, sandboxed) |
| Canvas / Mermaid | — | `CanvasWebViewHost` / mermaid WebView |
| CSV / Hex / Spreadsheet / Image | native only | — |
| Find | `SourceFindBar` → NSTextView search | `EditorFindBar`/`MarkdownFindBar` → CM6/WebView JS search |

Headline: **the same text file, viewed in `.source` vs `.editor`, is drawn by two different
engines with two different syntax tokenizers** (tree-sitter runs vs CM6 Lezer/legacy-mode JS),
producing observably different highlighting for the same bytes. The migration that would collapse
this (`WebSourceViewGate`, TSK-1530 M6) is coded but **ships OFF and is not at parity** (drops
bookmark pins, diff marks, source find-bar wiring), so the native stack remains the shipped
default and both must be maintained.

Secondary clusters: **three near-identical warm-WKWebView caches** with no shared base; **three
theme representations** derived from one `ThemeDefinition` that can drift; **three typed
scroll-persistence channels** that don't share a position across lenses of the same file; and
**find execution reimplemented per surface** (4 backends) under a centralized state coordinator.

No P0 (no data loss / crash traced to the split). The refactor itself is a one-way door (→
NEEDS_OWNER); findings below are the concrete duplication/divergence instances.

---

## Methodology

- Enumerated every `WKWebView` user (`rg -l WKWebView Sources/ViewerUI` → 41 files) and every
  `NSTextView`/`NSTextStorage`/`NSLayoutManager` user (33 files); mapped which surfaces each owns.
- Read the content-dispatch switch in `ContentView.swift:880-1220` that selects the engine per
  `viewMode`/`category`, incl. the `WebSourceViewGate` fork (1274–1289) and both
  `CodeMirrorEditorView` instantiations (editor @927, read-only source @1275).
- Read `WebSourceViewGate.swift`, `DocumentModel+Theming.swift`, `DocumentModel+Folding.swift`,
  `FindBarRouting.swift`, `LSPMarkdownRenderer.swift`, the `jsLanguageName` map in
  `CodeMirrorEditorView.swift`, and the three `Warm*WebViewCache.swift`.
- Cross-checked highlight paths (`HighlightCacheActor`/tree-sitter runs vs CM6 `setLanguage`) and
  the three scroll channels (`sourceScrollState`/`editorScrollByTab`/`renderedScrollOffset`).
- Static analysis only; no UI/window-opening tests; no live `MDV_WEB_SOURCE=1` VM run.
- Coverage: ~15 files read whole/part, focused on the text/markdown content-dispatch surfaces.

---

## Findings

### F1 — Two live text-display engines for the same content (`.source` NSTextView vs `.editor` CM6)
- **Severity:** P1 · **Fix size:** XL · **Fix risk:** one-way-door
- **Files:** `Sources/ViewerUI/ContentView.swift:927` (CM6), `:1299` (NSTextView);
  `Sources/ViewerUI/TextDisplayView.swift` (1538 LOC); `Sources/ViewerUI/CodeMirrorEditorView.swift` (1673 LOC)
- **Evidence:** `.editor` instantiates `CodeMirrorEditorView` (CM6 in WKWebView); read-only
  `.source` instantiates `TextDisplayView` (NSTextView) + `SourceGutterView`. CM6 header
  (`ContentView.swift:898-899`) confirms the editor was migrated off an "NSTextView PoC". The app
  maintains ~2.4K LOC AppKit text stack **and** ~3.0K LOC CM6 stack (+1.1 MB JS) that display the
  same file, differing only by read-only vs editable.
- **Impact:** Every text feature (gutter, folding, invisibles, find, scroll, caret, selection,
  theming) is built and tested twice; behavior diverges between lenses (F2). Largest driver of
  the dual-UI cost.
- **Suggested fix:** Consolidate onto CM6 (TSK-1530's direction) by bringing the read-only path
  to parity and retiring NSTextView, OR make an explicit owner decision to keep NSTextView for
  read-only (large-file perf) and stop investing in the CM6 source path. Don't leave both alive.

### F2 — Divergent syntax highlighting between the two text engines (tree-sitter vs CM6 Lezer)
- **Severity:** P1 · **Fix size:** L · **Fix risk:** careful
- **Files:** `Sources/ViewerUI/CodeMirrorEditorView.swift:1472` (`jsLanguageName`);
  `Sources/ViewerUI/ContentView.swift:1260-1265` + `Highlight/HighlightCacheActor.swift`
  (tree-sitter `runs`); `ContentView.swift:930,1279` (CM6 gets `language:` only, no runs)
- **Evidence:** The NSTextView source path computes tree-sitter highlight `runs` via
  `HighlightCacheActor` → `NSAttributedString`. CM6 is handed only `language:` and highlights with
  its own tokenizers — official Lezer packs where available, `@codemirror/legacy-modes` stream
  parsers for Swift/Kotlin/C#/Lua/Shell/YAML/Ruby (`jsLanguageName` 1495–1503). Different token
  boundaries/scopes for identical bytes.
- **Impact:** The same file is highlighted differently in `.source` vs `.editor`. Rendered-markdown
  code fences add a third tokenization (tree-sitter → HTML classes → `tokCSS`) — one file, up to
  three distinct syntax-highlight results.
- **Suggested fix:** Feed CM6 the tree-sitter runs as decorations instead of re-tokenizing in JS,
  so highlighting has one source of truth; or standardize fence highlighting + editor on one engine.

### F3 — `WebSourceViewGate`: half-migrated read-only source lens, not at parity, ships OFF
- **Severity:** P2 · **Fix size:** M · **Fix risk:** careful
- **Files:** `Sources/ViewerCore/WebSourceViewGate.swift:10-13,27`; `ContentView.swift:1274-1289`
- **Evidence:** Gate doc: *"the web route uses CM6's own line numbers, folding and find; the
  AppKit `SourceGutterView` extras (bookmark pins, diff marks) and the source find-bar wire up in
  the M6 follow-on slices before the default can flip."* The gated CM6 instantiation (1275–1288)
  passes no diff marks, no bookmark lines, no find-state — strictly less capable, defaults `false`.
- **Impact:** Maintained-but-dark path that isn't a drop-in replacement. `MDV_WEB_SOURCE=1`
  silently loses bookmark pins, git diff gutter, source find. Dead weight until finished; a trap
  for anyone flipping it expecting parity.
- **Suggested fix:** Finish the M6 parity slices (bookmarks/diff/find in CM6 read-only) and flip
  the default, or park the gate explicitly with parity gaps tracked as blocking subtasks.

### F4 — Three near-identical warm-WKWebView caches with no shared base
- **Severity:** P2 · **Fix size:** M · **Fix risk:** safe
- **Files:** `WarmWebViewCache.swift` (161), `WarmHTMLWebViewCache.swift` (157),
  `WarmEditorWebViewCache.swift` (197); plus native `SourceControllerCache.swift` (239)
- **Evidence:** `WarmHTMLWebViewCache` header: *"the exact analogue of `WarmWebViewCache` for the
  RAW-HTML render pane."* Three copies of the park/re-attach-by-file-path lifecycle differing only
  in parked coordinator type + WebView security posture; a 4th cache does the analogous thing for
  the NSTextView controller.
- **Impact:** Warm-pane lifecycle fixes (leaks, eviction, re-attach races) must be made 3–4×;
  divergence risk when a fix lands in one but not siblings.
- **Suggested fix:** Extract a generic `WarmWebViewPool<Coordinator>` parameterized by config +
  coordinator factory; the caches become thin configs.

### F5 — Find execution reimplemented per surface (4 backends under one state coordinator)
- **Severity:** P2 · **Fix size:** L · **Fix risk:** careful
- **Files:** `FindBarRouting.swift:8-33` (rendered/editor/pdf/source); `MarkdownFindBar.swift:381,424,455,481`
  (4 find-bar wrappers); `DocumentModel+FindBarForwarders.swift` (per-surface query/next/prev)
- **Evidence:** `FindCoordinator` centralizes find *state* and the four find-bars share a common
  `FindBar`, but search runs in four engines: WebView JS (rendered), CM6 JS (editor), NSTextView
  (source), PDFKit (pdf). Match counting, next/prev, case/regex, highlight each reimplemented.
- **Impact:** Find behavior (regex, match-count semantics, wrap, highlight) differs across
  surfaces; four codepaths to sync; a feature added to one doesn't reach the others.
- **Suggested fix:** Unify the match-model/next-prev/regex behind a `FindEngine` protocol so
  surfaces implement only "find ranges in my content".

### F6 — Three theme representations from one `ThemeDefinition` (drift risk)
- **Severity:** P2 · **Fix size:** M · **Fix risk:** safe
- **Files:** `DocumentModel+Theming.swift:17-40`
- **Evidence:** One `ThemeDefinition` fans out to `SyntaxTheme` token colors for NSTextView `runs`
  (`activeTheme`, 17), `cmPalette` `[String:String]` for CM6 (`activeThemeCMPalette`, 28), and
  `pageCSS()`/`tokCSS()` for the rendered WebView (`themedExtraStylesheet`, 35). Three mappings of
  one theme onto three rendering models.
- **Impact:** A theme is correct only if all three agree; adding a token category/new theme
  requires three edits; a miss looks right in one lens, wrong in another. (Mitigated: single
  upstream source — controlled duplication, 3 fan-out points.)
- **Suggested fix:** Derive the CM palette and rendered CSS *from* the same token-color table the
  NSTextView path uses — one authored map, two derived serializations.

### F7 — Three typed scroll-persistence channels that don't share a position across lenses
- **Severity:** P2 · **Fix size:** L · **Fix risk:** careful
- **Files:** `DocumentModel+ScrollPersistence.swift:341-378` (rendered, pixel Y);
  `DocumentModel+EditorState.swift:24-33` (`editorScrollByTab`, `CMScrollPosition`/line);
  `DocumentModel.swift:329-331` + `SourceScrollState` (source, `topVisibleLine`)
- **Evidence:** Rendered persists pixel `scrollY` keyed by URL; CM6 editor persists
  `CMScrollPosition` keyed by tab id; NSTextView source persists `topVisibleLine`. Three position
  types, three keys (URL vs tab id), three restore paths.
- **Impact:** Toggling a file between `.source`/`.editor`/`.rendered` doesn't preserve a shared
  reading position. The documented restore races (TSK-1046/1047/821 in surrounding comments) are
  symptoms of this fragmented three-channel design.
- **Suggested fix:** As part of F1, unify on a single line-based reading position on the Tab that
  all lenses read/write, converting to pixel offset only at the WebView boundary.

### F8 — Multiple markdown parsers/renderers with divergent CommonMark support
- **Severity:** P2 · **Fix size:** M · **Fix risk:** safe
- **Files:** `LSP/LSPMarkdownRenderer.swift:1-45` (Foundation `AttributedString`, hover);
  `Sources/ViewerCore/HTMLRenderer.swift` (markdown→HTML, file viewer); `swift-markdown` also in graph
- **Evidence:** `LSPMarkdownRenderer` renders hover markdown with Foundation's
  `AttributedString(markdown:)` — *"only handles inline markup"* — plus a hand-rolled fenced-code
  pass, deliberately NOT the file-viewer renderer (its own comment 12–21). The file viewer uses
  the Rust/`HTMLRenderer` CommonMark path in a WebView.
- **Impact:** Markdown renders differently in hover vs the document pane (no list/table/heading
  structure in hover; hover fenced code is monospaced but **unhighlighted**, unlike the viewer).
  Two parsers = two dialects of "markdown".
- **Suggested fix:** Route hover markdown through the same renderer, or document the reduced hover
  subset explicitly. Low urgency (small surface) but a genuine second markdown engine.

### F9 — CM6 source path doc claims "rust highlights" but code uses CM6 JS highlighting
- **Severity:** P3 · **Fix size:** S · **Fix risk:** safe
- **Files:** `WebSourceViewGate.swift:4-8` ("rust highlights") vs `ContentView.swift:1275-1288`
  (passes only `language:`, no runs)
- **Evidence:** The gate header advertises "rust highlights" but the instantiation hands CM6 only
  `language: lang`, so it highlights with CM6's JS tokenizer (identical to the editor, F2), not
  tree-sitter runs. Doc/code divergence on which highlighter the migration target uses.
- **Impact:** Misleads the migration plan; anyone flipping the gate expecting tree-sitter fidelity
  gets CM6 JS highlighting. Confirms the migration hasn't fixed its highlight source of truth.
- **Suggested fix:** Decide whether CM6 source consumes rust runs (F2 fix) or CM6 JS highlighting;
  reconcile doc + code.

### F10 — Per-WebView hand-rolled JS bridges (no shared bridge abstraction)
- **Severity:** P3 · **Fix size:** M · **Fix risk:** safe
- **Files:** `CodeMirrorEditorView.swift:274,297` (`"mdvEditor"`); `CanvasWebViewHost.swift:46`
  (canvas handler); plus MarkdownRenderedView / HTMLRenderedView message handlers
- **Evidence:** Each WebView registers its own `WKScriptMessageHandler` with a bespoke
  message-name protocol and coordinator wiring; no shared typed bridge — each pane reinvents
  message dispatch, JSON encoding, reply routing.
- **Impact:** Boilerplate + a new ad-hoc protocol per WebView; cross-cutting concerns (error
  surfacing, versioning, teardown) re-solved per pane as the WebView count grows.
- **Suggested fix:** Introduce a shared `WebViewBridge` (typed message enums + reply handling +
  lifecycle) adopted by each coordinator.

### F11 — Folding dispatched to two independent implementations
- **Severity:** P3 · **Fix size:** S · **Fix risk:** careful
- **Files:** `DocumentModel+Folding.swift:24-31` (`FoldDispatchTarget.editor` vs `.source`)
- **Evidence:** Fold All/Unfold All routes to either the CM6 editor (JS folding) or the read-only
  source NSTextView (its gutter draws tree-sitter `FoldRegion` chevrons) — two collapse
  implementations for the same `FoldRegion` data.
- **Impact:** Folding UX/behavior can differ between lenses; two rendering paths for one model.
  Subsumed by F1 when the text engines merge.
- **Suggested fix:** Falls out of F1 consolidation; no standalone action.

---

## Positive observations

- The split is **intentional and documented** (`WebSourceViewGate`/TSK-1530, CM6 header,
  warm-cache comments) — managed debt with a direction, not chaos.
- **Native-only surfaces are cleanly native** (CSV/Hex/Spreadsheet/image use no WebView); the
  dual-stack cost is confined to text/markdown/HTML/canvas.
- **Find state + find-bar UI already consolidated** (`FindCoordinator` + `FindBarRouting` + shared
  `FindBar`), with host-tested routing to prevent regressions, even though engines differ (F5).
- **Theme has a single upstream source** (`ThemeDefinition`) despite three representations (F6).
- **Size caps guard the WebView paths** (`codeMirrorEditorMaxBytes`, `markdownRenderMaxBytes`,
  `HTMLDocumentPolicy.renderMaxBytes`) with native placeholders — bounded memory profile.

## Coverage gaps (not examined)

- Automation/MCP view of the two stacks (how `set_view_mode`/`visible_text`/AX treat NSTextView
  vs CM6) — only the routing edges spot-checked.
- Canvas + Mermaid engine internals (confirmed WebView-only, not audited for internal duplication).
- Terminal/PTY surface.
- Runtime behavior: no live `MDV_WEB_SOURCE=1` VM run; no pixel comparison of the two engines'
  highlighting — F2/F9 divergences inferred from data-flow, not captured on-screen.
- Test-target duplication between the two stacks.
- Exact decommission LOC of the "loser" stack (approximated ~2.4K native + ~3.0K CM6).
