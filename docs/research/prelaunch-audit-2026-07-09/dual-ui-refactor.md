# Pre-launch product review — Two-UI-implementations refactor analysis

**Dimension:** dual native (SwiftUI/AppKit) vs web (WKWebView/CodeMirror 6) rendering stacks —
duplicated surfaces, divergences, inconsistencies, and a consolidation strategy.
**Date:** 2026-07-09 · **Repo:** `/Users/me/Documents/workspaces/claude/markdown_viewer` (read-only review)

---

## Executive summary

The app renders the *same text lens* through two full stacks: the read-only `.source` mode is a
native `NSTextView` pipeline (`TextDisplayView` + `SourceGutterView` + four SwiftUI overlay views +
Rust tree-sitter highlights), while the editable `.editor` mode is CodeMirror 6 in a `WKWebView`
(1,729-line JS host page, ~80 inbound bridge message types, 1.1 MB vendored bundle, Lezer/legacy-mode
highlights). Rendered markdown, raw HTML, Mermaid, and Canvas are four more separately-wired WebView
hosts. The cost of this split is visible everywhere in the code's own archaeology: **five find
runtimes** behind four state bags with divergent capabilities, **three scroll-persistence channels**
with three different keyings (the recurring "position lost on switch" bug family: TSK-821/1037/1041/
1046/1047), **two syntax-highlight engines** that classify tokens differently, **two fold-region
engines**, **two warm-WebView caches**, a per-surface theming matrix with a user-reachable
inconsistency, a compositor-occlusion bug class (TSK-488) that spawned a whole host-testable policy
layer, and a **save-path freshness gap** where Swift-initiated saves can persist text up to 200 ms
staler than what the user typed.

The good news: the repo has already chosen a consolidation direction. The **CH-I "Web-migrate"
epic** (`BACKLOG.md` §CH-I, parent TSK-1524) migrates source view (M6/TSK-1530, gate already in-tree
but OFF), CSV grid, hex, logs, and git-log/blame onto the CM6/web stack, and an owner decision card
for "surface consolidation" (TSK-1449) already exists. The main strategic problems found are:
(1) the gated M6 web-source route is far from feature parity and the parity gap is not written down
as a checklist anywhere; (2) an older, opposite-direction design doc
(`docs/WEBKIT_MARKDOWN_ELIMINATION.md` — replace the markdown WebView with native TextKit) is still
live in `docs/` with no superseded marker; (3) a set of concrete, user-visible divergences (column
off-by-one, split-pane fork, find capability matrix, ReDoS-guard asymmetry, theme-override gap,
save-flush gap) are shippable fixes *now*, independent of the one-way-door refactor.

**Recommended strategy** (detail in §Consolidation strategy): freeze the direction on CH-I (web),
land the 8 independent parity/correctness fixes below pre-launch, turn this report's surface
inventory into the M6 parity checklist, and only then flip `WebSourceViewGate` — that flip plus
deletion of the NSTextView stack is the one-way-door and stays NEEDS_OWNER.

**25 findings: 3 P1, 16 P2, 6 P3.** No P0 — nothing here is a data-destroying or crash-class
ship-blocker on its own, but the P1 save-flush gap is the closest call.

---

## Methodology

- Static review, read-only. No UI tests run; no repo files modified except this report.
- Entry points read in full or in large part: `Sources/ViewerUI/ContentView.swift` (routing,
  2,090 LOC), `TextDisplayView.swift` (1,538), `CodeMirrorEditorView.swift` (1,673),
  `MarkdownRenderedView.swift` (1,312), `HTMLRenderedView.swift`, `SplitPaneView.swift`,
  `MarkdownFindBar.swift`, `Coordinators/FindCoordinator.swift`, `Coordinators/EditorCoordinator.swift`,
  `DocumentModel+{Theming,ScrollPersistence,ViewModeSwitch,DisplayText,Folding,PrintExport,Spelling,
  EditorState,RenderedCache,FindBarForwarders}.swift`, `DocumentModel.swift` (targeted sections),
  `StatusBar.swift`, `WarmWebViewCache.swift`, `WarmEditorWebViewCache.swift`,
  `PaneCompositingPolicy.swift`, `WebSourceViewGate.swift`, `ViewerKit/ViewMode.swift`,
  `ViewerCore/Highlight/{SyntaxTheme+CMPalette,ThemeDefinition,HighlightParityHarness}.swift`,
  `ViewerCore/HTMLRenderer.swift`, `ViewerCore/Automation/MCPToolCatalog.swift`.
- Web-side assets: `Sources/ViewerUI/Resources/codemirror/codemirror.html` (1,729 LOC, targeted),
  `scripts/codemirror-build/entry.js` + `package.json`, `Resources/markdown.css`,
  mermaid bundle layout, `Walkthrough/WalkthroughMermaidWebView.swift`.
- Process docs consulted: `docs/WASM_WEBUI_DUPLICATION_2026-06-19.md`,
  `docs/WEBKIT_MARKDOWN_ELIMINATION.md`, `docs/TEST_PYRAMID.md` (targeted), `BACKLOG.md`
  (read-only, §CH-I / §2), `docs/CM6_INTEGRATION_DESIGN_2026-05-23.md` (referenced, not re-read).
- Every finding cites file:line verified against the working tree on 2026-07-09.

### The surface inventory (what renders where)

| Surface | Stack | Host view | Notes |
|---|---|---|---|
| `.source` (read-only text) | **Native** | `TextDisplayView` (NSTextView) + `SourceGutterView` + `SourceHoverHighlight` + `SourceInvisiblesView` + `MarkdownOverviewView` | Rust tree-sitter highlights; "chokes at 1 MB" per `WebSourceViewGate.swift:5` |
| `.editor` (editable text) | **Web** | `CodeMirrorEditorView` (WKWebView + CM6) | Lezer + CM5 legacy-mode highlights; 50 MB cap |
| `.source` behind `MDV_WEB_SOURCE` | **Web (gated OFF)** | `CodeMirrorEditorView` read-only | TSK-1530 M6; parity gaps below |
| `.rendered` markdown/mermaid | **Web** | `MarkdownRenderedView` | Rust core markdown→HTML; custom JS find |
| `.rendered` raw HTML | **Web** | `HTMLRenderedView` | separate sanitized/CSP path |
| Canvas | **Web** | `CanvasWebViewHost` / `CanvasTabView` | |
| Walkthrough mermaid | **Web** | `WalkthroughMermaidWebView` | standalone, deliberately unwired (occlusion) |
| `.formatted` | **Native** | `SourceModeView` → `TextDisplayView` | pretty-print memo |
| `.table` (CSV/xlsx) | **Native** | `CSVTableView` / `SpreadsheetView` | CH-I M3/M4 target web |
| `.diff`, `.hex`, `.preview` | **Native** | `DiffView` / HexView / `MediaPreviewView` | CH-I M7 targets hex → web |
| Split pane | **Mixed fork** | own routing in `SplitPaneView.swift` | diverges from main pane (finding 4) |
| Terminal, sidebar, tabs, status bar, panels | **Native** | SwiftUI/AppKit | not duplicated |

---

## Findings

Severity: P0 ship-blocker · P1 major · P2 quality · P3 polish.
Fix size: S <½day · M ~1-2d · L ~1wk · XL epic. Risk: safe · careful · one-way-door.

---

### F1 · P1 — Swift-initiated saves don't flush the CM6 edit debounce: ≤200 ms of typed text can miss the save
**Files:** `Sources/ViewerUI/Resources/codemirror/codemirror.html:888`,
`Sources/MarkdownViewer/main.swift:994-1000`, `Sources/ViewerUI/ContentView.swift:1011-1015`,
`Sources/ViewerUI/CodeMirrorEditorView.swift:938-947`
**Evidence.** CM6 edits are debounced 200 ms in JS before posting to Swift
(`CodeMirrorEditorView.swift:14-16` header). The JS-side save paths correctly flush first —
⌘S keybinding `run: () => { emitChangeImmediate(); post("save", {}); ... }` (`codemirror.html:817`)
and vim `:w` (`codemirror.html:693`). But every **Swift-initiated** read of the buffer does not:
- Menu `File → Save` → `model.saveActiveEditor()` directly (`main.swift:994-1000`), no
  `flushChanges` round-trip.
- The blur handler posts `editorBlurred` **without** `emitChangeImmediate()`
  (`codemirror.html:888`), and `ContentView.swift:1011-1015` maps `onBlur` →
  `saveActiveEditor()` when `saveEditorOnBlur` is on.
- `dispatch(.flushChanges, ...)` exists in Swift but is invoked **only** on incremental-edit drift
  recovery (`CodeMirrorEditorView.swift:945`).
- Hot-exit unsaved-text persistence (`DocumentModel+ScrollPersistence.swift` header) reads the same
  `editorBuffers`, so a fast ⌘Q inside the debounce window persists stale text.
**Impact.** Type → within 200 ms click away / hit menu-Save / quit ⇒ the write (or hot-exit
snapshot) misses the last keystrokes. The dirty dot re-appearing right after a save (late debounce
landing) is also a visible glitch. This gap does not exist on a native editor — it is purely a cost
of the async WebView bridge.
**Fix.** (a) `emitChangeImmediate()` inside the JS blur listener before posting `editorBlurred`;
(b) Swift-side save entry points dispatch `.flushChanges` and complete the save on the resulting
`change` callback (or synchronously re-read after a bounded wait); (c) same for the hot-exit
snapshot path. The `docShadow.verifyOnSave` hook (`CodeMirrorEditorView.swift:950`) is the natural
place to assert the invariant.
**Size:** M · **Risk:** careful (save path; needs WV-lane test + VM validation).

---

### F2 · P1 — The read-only source lens still rides the NSTextView stack that "chokes at 1 MB"; the sanctioned replacement is gated OFF and far from parity
**Files:** `Sources/ViewerCore/WebSourceViewGate.swift:1-29`,
`Sources/ViewerUI/ContentView.swift:1274-1288`, `BACKLOG.md:111` (§CH-I)
**Evidence.** `WebSourceViewGate.swift:3-8`: the CM6 read-only route exists to kill "the
'chokes at 1MB' pain" of `TextDisplayView`, ships OFF pending the VM slice (TSK-1550). The gated
branch (`ContentView.swift:1274-1288`) instantiates `CodeMirrorEditorView` with **only** text/theme/
wrap/invisibles — it wires **none** of: the source find channels (the `SourceFindBar` rendered above
it at :1267-1269 drives `find.sourceQuery`, which this branch never forwards — find silently does
nothing), `scrollLineRequest` (goto-line/outline-click dead), `onScrollChange` (scroll persistence
dead), `onSelectionChange`/`onCursorChange` (status-bar Ln/Col dead), bookmarks/diff gutter
(`SourceGutterView` extras), hover highlight, markdown overview minimap, `cacheKey` (no warm
reattach). The gate header admits gutter extras + find are "M6 follow-on slices", but the full gap
list above is not recorded anywhere.
**Impact.** Today every user pays the NSTextView large-file penalty on the *default* text lens; the
replacement cannot flip until ~10 channels reach parity, and without a written parity contract the
flip risks repeating the terminal-tab-strip class of "shipped but not actually working" regressions.
**Fix.** Turn the channel inventory above into the M6 acceptance checklist on TSK-1530 (evidence
classes named per the grooming mandate); implement slices; flip only after the VM render slice +
a side-by-side behavior matrix is green. The flip + subsequent NSTextView-stack deletion is the
**one-way-door** → NEEDS_OWNER (TSK-1449 card already exists).
**Size:** XL · **Risk:** one-way-door.

---

### F3 · P1 — Split pane is a stale fork of the main-pane routing: synchronous main-thread markdown render, no highlighting, hardcoded font/wrap, unthemed
**Files:** `Sources/ViewerUI/SplitPaneView.swift:183-213`,
`Sources/ViewerUI/DocumentModel+RenderedCache.swift:54-57`
**Evidence.** The split re-implements the content routing with divergences the main pane already
fixed:
- `MarkdownRenderedView(html: HTMLRenderer().renderPage(...))` **inline in the view body**
  (`SplitPaneView.swift:190-198`). The main pane moved this render off-main precisely because it
  "blocked the main thread for ~927ms inside a layout pass" (TSK-611,
  `DocumentModel+RenderedCache.swift:54-57`). Opening a large markdown in the split re-introduces
  that hang, on every body re-eval that changes the key inputs.
- `runs: []` (`:210`) — no syntax highlighting in split source view ("split v1" comment).
- `fontSize: 13 * zoom` (`:207`) — ignores the user's content-font-size preference
  (main pane: `model.effectiveContentFontSize`).
- `wordWrap: false` (`:212`) — ignores `model.sourceWordWrap`.
- `extraStylesheet: MermaidBundle.shimCSS` (`:194`) — ignores the selected catalog theme; main pane
  captures `themedExtraStylesheet`. A themed user gets a main pane in their theme and a split in
  system default.
- No find bar, no scroll persistence, no invisibles, no gutter — silently absent rather than
  deliberately gated.
**Impact.** User-visible inconsistency the moment the split opens, plus a re-introduced P1-class
main-thread hang for big markdown.
**Fix.** Route the split's markdown leg through `requestRenderedHTML`-style off-main render (or the
same cache), and thread `effectiveContentFontSize` / `sourceWordWrap` / `themedExtraStylesheet`
through. Highlighting in split can stay a follow-up but should be a tracked ticket, not a comment.
**Size:** M · **Risk:** careful (touches the render cache keying; needs WV/VM check).

---

### F4 · P2 — Status-bar column readout is 1-based in Source mode and 0-based in Editor mode (off-by-one for the same caret)
**Files:** `Sources/ViewerUI/TextDisplayView.swift:800` (and doc `:274-278`),
`Sources/ViewerUI/Resources/codemirror/codemirror.html:206`,
`Sources/ViewerUI/DocumentModel.swift:584-590`, `Sources/ViewerUI/StatusBar.swift:336-338`,
`Sources/ViewerUI/CodeMirrorEditorView.swift:1155-1158`
**Evidence.** Native path computes `column: loc - lineStart + 1` (1-based; `SourceSelection` docs
say "line and column are 1-based"). CM6 posts `column: head - line.from` (0-based; documented as
such on `CMCursorPosition`). The status-bar mirror copies it raw:
`sourceSelection = SourceSelection(line: pos.line, column: pos.column, length: 0)`
(`DocumentModel.swift:587-589` — comment even says "so the L:C readout works uniformly"), and
`StatusBar.swift:338` prints `sourceSelection.column` unconverted. Caret at line start reads
"Col 1" in Source, "Col 0" in Editor.
**Impact.** Core chrome shows different coordinates for the same position depending on lens; also
poisons anything downstream that treats the mirrored value as 1-based.
**Fix.** `column: pos.column + 1` at the mirror (single line), plus a host test pinning both
channels' convention at the `SourceSelection` boundary.
**Size:** S · **Risk:** safe.

---

### F5 · P2 — Two syntax-highlight engines: Rust tree-sitter (Source) vs Lezer + CM5 legacy regex modes (Editor); seven languages fall to the weakest tier
**Files:** `scripts/codemirror-build/entry.js:61-86,124-129`,
`Sources/ViewerCore/Highlight/HighlightParityHarness.swift:1-27`,
`Sources/ViewerKit/HighlightLanguage.swift:8-30`
**Evidence.** The native lens highlights via the Rust tree-sitter engine (predicates evaluated;
Swift twin deleted per `HighlightParityHarness.swift:12-15`). The editor bundles official Lezer
packs for 12 languages and falls back to **CM5-era regex "legacy modes"** for
`swift, lua, shell, yaml, ruby, kotlin, csharp` (`entry.js:81-86`). Palette parity is enforced
(TSK-602/641 `cmPalette`), and the harness pins *tag reachability*, but by its own admission it
"can't produce [the CM6] sequence here" — tokenization differences are structurally unpinnable on
the host (`HighlightParityHarness.swift:16-22`).
**Impact.** Toggling View↔Edit re-colors the document structurally (different token boundaries/
classifications), worst for Swift — the app's own dogfood language — which gets a regex-mode
approximation in the editor vs full tree-sitter in source.
**Fix (strategic).** This is the strongest argument for the M6 gate's stated plan ("rust
highlights" for the web route — `WebSourceViewGate.swift:4`): ship Rust-engine decorations over the
bridge for the read-only route first, then reuse for the editor, retiring Lezer/legacy for
highlight duty. Interim: none worth doing.
**Size:** L (bridge decoration protocol) · **Risk:** careful.

---

### F6 · P2 — Find is five runtimes with a divergent capability matrix and inconsistent dismiss semantics
**Files:** `Sources/ViewerUI/Coordinators/FindCoordinator.swift:25-283`,
`Sources/ViewerUI/MarkdownFindBar.swift:392-393,433,464,490`,
`Sources/ViewerUI/TextDisplayView.swift:1496+`, `Sources/ViewerUI/MarkdownRenderedView.swift:747-780`,
`Sources/ViewerCore/Automation/MCPToolCatalog.swift:492-560`
**Evidence.** Runtimes: (1) native `TextDisplayView.findRanges` (NSRegularExpression);
(2) CM6 `SearchQuery` in JS; (3) a custom DOM-walking `<mark>` engine for rendered markdown
(`MarkdownRenderedView.swift:747-757` — "WKFindConfiguration is a black box");
(4) PDFKit `findString`; (5) `FindEngine`(→Rust) for the model/automation layer. Four state bags
(`rendered/source/editor/pdf`) on `FindCoordinator`. Capability matrix:

| | regex | replace | whole-word | match n/N | match minimap/list |
|---|---|---|---|---|---|
| Source | ✓ (ReDoS-guarded) | – | – | ✓ | ✓ (`sourceMatchLines`) |
| Editor (CM6) | ✓ (**unguarded**, F7) | ✓ | – | ✓ | – |
| Rendered | **✗** (`isRegex: .constant(false)`, `MarkdownFindBar.swift:392`) | – | – | ✓ | – |
| PDF | ✗ (PDFKit literal) | – | – | ✓ | – |
| MCP `find` tool | ✓ guarded | – | **✓** | n/a | n/a |

Whole-word exists only for agents (`MCPToolCatalog.swift:497-504`), never for users. Dismiss
semantics differ per bag: rendered/source clear the query but keep a draft to restore
(`FindCoordinator.swift:53-58,162-168`); editor *keeps* the query live (`:220-232`) — deliberate
(TSK-770) but now three different behaviors for "close find, reopen".
**Impact.** ⌘F behaves differently in each lens of the same document; the regex asymmetry is an
owner-visible feature gap (BACKLOG §2 card 1549 "find-regex expressiveness" already tracks part of
this).
**Fix.** Near-term: unify dismiss semantics; add whole-word to the UI bars (the engines all support
it or can trivially). Strategic: as surfaces migrate to CM6 (CH-I), collapse bags 1-3 onto the CM6
search bridge fed by the Rust `find_engine` (the TSK-800 WASM plan) — one engine, one bag, one
semantics.
**Size:** M (near-term) / L (strategic) · **Risk:** safe / careful.

---

### F7 · P2 — ReDoS guard protects native find but not the CM6 editor find (security-posture divergence)
**Files:** `Sources/ViewerUI/TextDisplayView.swift:1470-1481`,
`Sources/ViewerUI/Resources/codemirror/codemirror.html:1579-1586`
**Evidence.** SEC-003 added `RegexComplexityGuard.reject(pattern)` on the source-view find because
it "fires per keystroke against the full document" (`TextDisplayView.swift:1470-1478`). Grep of
guard call sites: `TextDisplayView`, `FindEngine`, `CrossFileSearch`, `ClaudeTranscriptSearch`,
`MCPToolCatalog`, `HighlightedText` — **nothing in the editor path**. The editor bar forwards
`editorFindIsRegex` → `findRegex` → JS `regexp: !!msg.regex` straight into CM's `SearchQuery`
(`codemirror.html:1583`), also per keystroke. JSC's RegExp is a backtracking engine; a
`(a+)+$`-class pattern pegs the WebContent process — the editor (and its pending edits, per F1)
becomes unresponsive.
**Impact.** The same attack/foot-gun input is rejected in one lens and freezes the other.
**Fix.** Run `RegexComplexityGuard.reject` on the Swift side before shipping a regex query over the
bridge (treat reject as no-match, matching source behavior).
**Size:** S · **Risk:** safe.

---

### F8 · P2 — Scroll/caret position: three channels, three keyings, two persisted fields, no cross-lens mapping — the codebase's most re-fixed bug family
**Files:** `Sources/ViewerUI/DocumentModel+ScrollPersistence.swift:22-90,160-215`,
`Sources/ViewerUI/Coordinators/SourceViewChannel.swift:49-56`,
`Sources/ViewerUI/Coordinators/EditorCoordinator.swift:573-590`
**Evidence.** Source scroll lives on `SourceViewChannel.sourceScrollState` (per-window channel);
editor scroll in `editorScrollByTab` (tab-id-keyed dict); rendered scroll in `renderedScrollByURL`
(URL-keyed dict). Persistence needed two separate `Tab` fields (`scrollTopLine` +
`renderedScrollY`) and per-channel capture logic (`captureScroll(forTabAt:)` switches on lens,
`DocumentModel+ScrollPersistence.swift:38-77`). The restore side needs a mount-time seed
(`editorMountSelectionSeed`, TSK-1046), a live push for the mounted-pane case
(`pushLiveEditorScroll`, TSK-1047), a session-switch in-flight gate, and two warm caches — five
mechanisms to make "come back where I was" survive the dual stack. The file headers themselves
document four successive loss bugs (TSK-821, 1037, 1041, 1046/1047).
**Impact.** Every new surface or switch path must remember to wire N channels; history shows one is
always missed. Also user-visible today: rendered↔source toggle cannot map pixel-Y↔line, so
`openPath(atLine:)` force-switches the user out of rendered mode (`DocumentModel.swift:927-938`).
**Fix.** Strategic: a single per-tab `ViewportState { lens → position }` owned by the Tab (the
CLAUDE.md root-cause guidance itself prescribes "scroll lives on the Tab, the view reads it
declaratively"). The CH-I migration is the natural moment: CM6 exposes one scroll model for
source+editor+grids, leaving only rendered-Y as a second representation.
**Size:** L · **Risk:** careful.

---

### F9 · P2 — Theming is a per-surface matrix with a user-reachable inconsistency: the legacy Light/Dark override themes native surfaces but not the rendered page
**Files:** `Sources/ViewerUI/DocumentModel+Theming.swift:17-40`,
`Sources/ViewerUI/SettingsView.swift:604-608`,
`Sources/ViewerCore/Highlight/ThemeDefinition.swift:164-183`, `Sources/ViewerUI/ContentView.swift:931-932`
**Evidence.** Three theming pipelines: native `SyntaxTheme`; CM6 `cmPalette` dict over the bridge;
rendered-markdown CSS custom-property overrides (`pageCSS`/`tokCSS`). For **catalog themes** all
three are wired (TSK-602/641/815). But the *legacy* `themeOverride` (Settings appearance picker,
`SettingsView.swift:604-608`) only affects `activeTheme` (`DocumentModel+Theming.swift:19`);
`activeThemeCMPalette` and `themedExtraStylesheet` are keyed on `activeThemeDefinition` **only**
(`:28-30, :35-36`) — with an override but no catalog selection, source/editor render dark while the
rendered markdown page stays system-light (`ThemeDefinition.swift:168-170` documents exactly this
"Dark-Mode gap" as fixed only for catalog themes). Separately, CM6 dark *chrome* is keyed off
`model.activeTheme.name == .xcodeDark` at every call site (`ContentView.swift:931`, `:1279`) — a
stringly proxy that works today only because `SyntaxTheme(from:)` collapses `isDark` onto the two
built-in names (`SyntaxTheme.swift:138`).
**Impact.** User picks Dark in Settings on a light-mode Mac → mixed-appearance app.
**Fix.** Derive one `ResolvedAppearance` + palette at the model level and feed all three pipelines
from it; make `themedExtraStylesheet` honor `themeOverride` (emit `pageCSS` for the built-in
theme). Replace the `.xcodeDark` name checks with `activeTheme.isDark`-style API.
**Size:** M · **Risk:** safe.

---

### F10 · P2 — Print / Export-as-PDF exists only for the WebView lenses; source/editor/hex/CSV cannot print
**Files:** `Sources/ViewerUI/DocumentModel+PrintExport.swift:11-28`
**Evidence.** `canPrintRenderedPage` gates ⌘P and Export-as-PDF to "the selected tab currently
SHOWS a rendered web page"; the comment marks text-view printing "phase 2 … deliberately out of
this gate". No `NSPrintOperation` path exists for the native stack (and none for the CM6 editor
either — printing is implemented once, on the rendered WebView, via its print/pdf nonces).
**Impact.** Table-stakes gap: a code file or CSV cannot be printed/PDF-exported at all; ⌘P
silently no-ops (returns false).
**Fix.** `NSPrintOperation(view:)` over the existing `NSTextView` is the cheap native leg; or defer
to CH-I and print via the CM6 WebView once the source lens migrates (WKWebView printing already
proven by the rendered path).
**Size:** M · **Risk:** safe.

---

### F11 · P2 — Right-click menus diverge: CM6 gets a 4-item hand-built menu; NSTextView gets the full AppKit menu; spelling is editor-only
**Files:** `Sources/ViewerUI/DocumentModel.swift:1724-1790`,
`Sources/ViewerUI/DocumentModel+Spelling.swift:1-40`
**Evidence.** `showEditorContextMenu` builds `NSMenu` with Go-to-Definition + Cut/Copy/Paste. The
native `TextDisplayView` has no menu override (no `NSMenu` hits in the file) — users get the
standard AppKit text menu (Look Up, Translate, Services, Search with Google, spelling
suggestions…). Inversely, the spelling feature (TSK-1505) "land[s] through the CM6 bridge"
(`DocumentModel+Spelling.swift:7-8`) — squiggles/fix-loop exist only in editor mode, and the CM6
context menu doesn't offer the spelling suggestions the native menu would.
**Impact.** The same document offers different right-click affordances per lens; some AppKit
services are unreachable in editor mode.
**Fix.** Enumerate a target context-menu contract per lens (share the builder; add
Look-Up/Services equivalents where the bridge allows); fold spelling suggestions into the CM6 menu.
**Size:** M · **Risk:** safe.

---

### F12 · P2 — Two parallel warm-WebView caches (rendered + editor) duplicate lifecycle/invariant code
**Files:** `Sources/ViewerUI/WarmWebViewCache.swift` (161 LOC),
`Sources/ViewerUI/WarmEditorWebViewCache.swift` (197 LOC)
**Evidence.** The editor cache header says the split exists because "a single cache can't hold both
without erasing the coordinator type" (`WarmEditorWebViewCache.swift:12-21`). Both implement the
same take-once / never-parented / LRU-bounded / path-keyed invariants; the editor adds the
parked-text guard. A generic `WarmWebViewCache<Coordinator>` (or an `AdoptableCoordinator`
protocol) removes the twin.
**Impact.** Invariant fixes must land twice (the "never hand out a parented WebView" guard is
already copy-pasted); a third cache is plausible when Canvas/CSV migrate (CH-I).
**Fix.** Genericize before CH-I adds cache #3.
**Size:** S-M · **Risk:** safe (both caches are host-tested per their headers).

---

### F13 · P2 — Fold regions come from two different engines per lens; fold state doesn't carry across a mode toggle
**Files:** `Sources/ViewerUI/DocumentModel+Folding.swift:1-75`,
`Sources/ViewerUI/CodeMirrorEditorView.swift:69-72`, `Sources/ViewerKit/ViewMode.swift:44-49`
**Evidence.** `.source` folds via TreeSitter `FoldRegion` (native gutter chevrons); `.editor` folds
via CM6 language-default heuristics or LSP `CMFoldRange` overrides
(`CodeMirrorEditorView.swift:69-72`). TSK-948 unified only the *command dispatch*
(`FoldDispatchTarget` records which surface got Fold-All). Nothing maps fold *state* across the
toggle, and the two engines produce different foldable-region sets for the same file.
**Impact.** Fold in source → switch to editor → folds gone/different. Same class as F8.
**Fix.** Rust core already answers fold ranges (per `docs/WASM_WEBUI_DUPLICATION_2026-06-19.md`,
outline/nav); feed both lenses from it and persist folded ranges per tab.
**Size:** M-L · **Risk:** careful.

---

### F14 · P2 — CM6 host JS re-implements logic that exists in Rust core (find, indent, fold answering, edit shaping) — dispositioned by TSK-800 but unimplemented
**Files:** `docs/WASM_WEBUI_DUPLICATION_2026-06-19.md` (spike), `Sources/ViewerUI/Resources/codemirror/codemirror.html`
**Evidence.** The 2026-06-19 spike enumerates the owned duplication precisely:
`Method::FindSearch` ⟷ CM JS find, `Method::IndentDetect` ⟷ CM indent + hand-rolled indent-guide
builder, `Method::CmApply` ⟷ JS edit shaping, core outline/nav ⟷ JS `foldGutter` binary-search
answerer — and recommends a thin `mdvcore-wasm` shim over the existing dispatch registry. The
recommendation was accepted in-doc; the shim is not in-tree (no wasm artifact under
`Sources/ViewerUI/Resources/`).
**Impact.** The JS twins are "untested by our suite" (spike's words) and drift-prone — exactly the
class the Rust migration killed on the Swift side.
**Fix.** Execute the tier-1 slice of TSK-800 as part of CH-I.
**Size:** L · **Risk:** careful (adds a wasm artifact to the bundle; size-cap aware).

---

### F15 · P2 — Compositor-occlusion + CA-commit tax of mixing opaque WebView layers with SwiftUI siblings: a permanent policy layer plus measured 30-366 ms nav stalls
**Files:** `Sources/ViewerUI/PaneCompositingPolicy.swift:1-50`,
`Sources/ViewerUI/Terminal/SideDockCompositing.swift`, `Sources/ViewerUI/ContentView.swift` (12
`compositingGroup` sites)
**Evidence.** The TSK-488 occlusion class (opaque `NSViewRepresentable` composites over
earlier-painted SwiftUI siblings) recurred four times and now requires `compositingGroup().zIndex`
discipline "in EVERY layout branch" (CLAUDE.md; 12 call sites in `ContentView.swift` alone) plus
two named host-testable policy types. The retained-pane ZStack of WebView-hosting panes measurably
costs 30-366 ms main-thread CA-commit stalls per nav action (`PaneCompositingPolicy.swift:17-24`,
citing the perf-explore trace).
**Impact.** Structural tax that grows with every WebView surface CH-I adds; false-green trap for
all in-process visual tests (only VM T5 catches it).
**Fix.** Not directly fixable while the split exists — this is *consolidation pressure*. Fewer
simultaneous heterogeneous panes (one CM6 surface serving source+editor rather than
NSTextView+WebView siblings) shrinks the reconciliation set. Track the stall totals across CH-I
milestones via `scripts/vm-profile.sh`.
**Size:** — (absorbed by CH-I) · **Risk:** —.

---

### F16 · P2 — `.rendered` has no line concept, so line-targeted navigation force-switches the user's chosen lens
**Files:** `Sources/ViewerUI/DocumentModel.swift:927-938`
**Evidence.** `openPath(_:atLine:)`: "If the opener landed us in rendered markdown, switch to
source so the line is actually visible." Outline clicks, cross-search results, bookmarks etc. yank
a rendered-mode reader into source mode; there is no source-line → rendered-anchor mapping
(headings have slugs/anchors in the rendered HTML — `unique_slug` in Rust core — but no line→slug
resolver is wired).
**Impact.** Jarring lens switch on a core navigation flow for markdown users.
**Fix.** For heading-line targets, resolve line→nearest-heading-slug and scroll the rendered view
to the anchor instead of switching modes; fall back to mode-switch otherwise.
**Size:** M · **Risk:** safe.

---

### F17 · P2 — Zoom is two different mechanisms (font-size multiply vs WebView pageZoom) with a third scale knob for rendered content
**Files:** `Sources/ViewerUI/DocumentModel+Zoom.swift:10-19`, `Sources/ViewerUI/DocumentModel.swift:312`,
`Sources/ViewerUI/ContentView.swift:1181-1182`, `Sources/ViewerUI/MarkdownRenderedView.swift:53,132`
**Evidence.** Native + CM6 lenses scale via `effectiveContentFontSize = contentFontSize × zoom`;
rendered/HTML lenses apply `zoom` as WebView page zoom **plus** a separate
`ContentFontSizing.markdownScale(contentFontSize:)` CSS variable (`--mdv-content-scale`). Same ⌘+
gesture, different semantics: text lenses reflow at constant chrome, rendered zooms the whole page
(including images/tables) and layers the content-scale on top. BACKLOG §2 already holds an owner
card "470 zoom-split".
**Impact.** Subtly different zoom feel per lens; two knobs compound on the rendered page.
**Fix.** Owner-gated (card 470) — document the intended matrix; no code change recommended here.
**Size:** M · **Risk:** careful (UX decision).

---

### F18 · P2 — Show-invisibles is two visual implementations (custom Canvas overlay vs CM6 `highlightSpecialChars`) with unpinned visual parity
**Files:** `Sources/ViewerUI/ContentView.swift:1349-1369`, `Sources/ViewerUI/TextDisplayView.swift`
(SourceInvisiblesView), `Sources/ViewerUI/Resources/codemirror/codemirror.html` (invisibles section)
**Evidence.** Native: `SourceInvisiblesView`, a scroll-synced SwiftUI Canvas drawing `·`/`→`
markers in theme colors (TSK-364, deliberately replacing the OS grey). CM6: its own
invisibles rendering toggled by `showInvisibles`. One shared preference, two renderers, no parity
test between their glyph sets/colors (tabs/spaces/newlines/NBSP coverage may differ).
**Impact.** Toggle View↔Edit and the whitespace markers change appearance; minor but visible.
**Fix.** Pin the intended glyph/color set once (theme-level), assert via the WV lane + T5.
**Size:** S · **Risk:** safe.

---

### F19 · P2 — Large-file behavior differs per lens: editor caps at 50 MB with a placeholder; source silently degrades (`isLargeReadOnly` strips features) and still chokes ~1 MB
**Files:** `Sources/ViewerUI/ContentView.swift:881-889`, `Sources/ViewerUI/DocumentModel+ViewModeSwitch.swift:135-146`,
`Sources/ViewerUI/TextDisplayView.swift:780`, `Sources/ViewerCore/WebSourceViewGate.swift:5`
**Evidence.** `.editor` refuses >50 MB (placeholder + mode-flip guard). `.source` has no cap but
flips `isLargeReadOnly` behaviors (invisibles off `ContentView.swift:1357`, degraded selection
`TextDisplayView.swift:780` returning `line: 0, column: 0`) and per the M6 gate rationale is
already painful at 1 MB. Rendered has its own two caps (`markdownRenderMaxBytes`,
`HTMLDocumentPolicy.renderMaxBytes`). Four different large-file contracts.
**Impact.** Users hit four different degradation behaviors depending on lens; the degraded
`SourceSelection(0,0)` also feeds the status bar a nonsense "Ln 0, Col 0" class of readout.
**Fix.** Absorbed by F2/CH-I (virtualized CM6 read-only lens removes the 1 MB pain and can unify
caps). Near-term: document the cap matrix in one place.
**Size:** — · **Risk:** —.

---

### F20 · P3 — `displayedText(for:)` reads the *selected* tab's dirty buffer regardless of which pane's file it's resolving
**Files:** `Sources/ViewerUI/DocumentModel+DisplayText.swift:24-26`, `Sources/ViewerUI/ContentView.swift:1256-1257`
**Evidence.** The dirty-buffer branch keys on `tabs.selected?.id`, but `SourceModeView` calls
`model.displayedText(for: file)` for **its own pane's** file — including mounted-but-inactive
retained panes. If the selected tab has a dirty buffer and an inactive pane (different file)
re-bodies, that pane computes text/find/highlights from the *selected* tab's buffer. Panes are
`opacity(0)` while inactive so it self-corrects on activation (re-body with new selection), and the
split pane avoids the trap explicitly (URL-keyed `splitPaneText`, `SplitPaneView.swift:177-183`) —
which is itself evidence the sharp edge is known.
**Impact.** Latent cross-pane text bleed; becomes real the day inactive panes become visible
(second window, live split of tabs) or anything caches those computations.
**Fix.** Pass the pane's `tabID` into `displayedText` and key the buffer lookup on it.
**Size:** S · **Risk:** safe.

---

### F21 · P3 — Contradictory consolidation designs both live in `docs/`: native-ization of markdown (WEBKIT_MARKDOWN_ELIMINATION) vs web-ization of everything (CH-I)
**Files:** `docs/WEBKIT_MARKDOWN_ELIMINATION.md:1-9`, `BACKLOG.md:108-116` (§CH-I)
**Evidence.** The 2026-06-01 doc designs a native TextKit markdown renderer to *eliminate*
WebViews for the common case ("design only, do not build"). The current BACKLOG direction (CH-I,
parent 1524; item 838 "rendered-MD persistent page + DOM patch") consolidates *toward* the web
stack. The older doc carries no superseded/decision marker and still reads as the plan for "the
biggest durable per-document memory lever".
**Impact.** A future agent/session picking work from `docs/` can drive the two stacks in opposite
directions — the exact failure mode this dimension is about.
**Fix.** Add a status header to `WEBKIT_MARKDOWN_ELIMINATION.md` recording the CH-I decision
context (or fold its memory analysis into the CH-I epic as the counter-argument it partially is —
its WebContent/IOSurface numbers remain the best cost data for *adding* WebViews).
**Size:** S · **Risk:** safe.

---

### F22 · P3 — Two Mermaid WebView hosts with separate lifecycle code
**Files:** `Sources/ViewerUI/MarkdownRenderedView.swift:255-292`,
`Sources/ViewerUI/Walkthrough/WalkthroughMermaidWebView.swift:1-52`
**Evidence.** The rendered view lazily injects/evicts the mermaid runtime; the walkthrough overlay
has its own standalone host (deliberately unwired pending occlusion-safe wiring + T5, per its
header). Both share `MermaidBundle` but duplicate injection/reload logic.
**Impact.** Minor duplication; the standalone host is also dead code until TSK-1333 completes.
**Fix.** When wiring TSK-1333, extract one mermaid-host helper.
**Size:** S · **Risk:** safe.

---

### F23 · P3 — Per-surface nonce/one-shot channel proliferation is the de-facto cross-stack ABI, with per-surface routing rules re-implemented per channel
**Files:** `Sources/ViewerUI/CodeMirrorEditorView.swift:43-120`, `Sources/ViewerUI/CMOneShotRouting.swift`,
`Sources/ViewerUI/Coordinators/FindCoordinator.swift:16-19`
**Evidence.** The model drives WebView surfaces through dozens of `Int`-nonce and one-shot request
channels (goto/insert/select/focus/find-next/prev/replace/print/pdf/scroll-command/flush…), each
with hand-maintained active-pane vs targeted-tab dispatch semantics (TSK-1483 `CMOneShotRouting`
formalized it for three of them). The native stack uses a parallel but different set
(`sourceScrollLineTarget`+nonce, `SourceViewChannel`). Every new verb costs a channel on each stack.
**Impact.** High-friction, error-prone growth surface (the find/scroll bug archaeology in F6/F8 is
largely mis-wired channels).
**Fix.** As CH-I lands, migrate channels onto the versioned CM bridge envelope (one typed command
stream per pane) rather than N SwiftUI properties; `CMOneShotRouting` is the seed.
**Size:** L (incremental) · **Risk:** careful.

---

### F24 · P3 — Editor-only features silently absent in source mode (and vice versa) without a stated capability contract
**Files:** `Sources/ViewerUI/ContentView.swift:940-1019` (editor params) vs `:1290-1400` (source stack)
**Evidence.** Editor-only: LSP hover/completion/definition, diagnostics, vim mode, indent guides,
snippets, spelling (F11), gutter diff/blame markers (`CMGutterMarker`). Source-only: hover line
highlight, markdown overview minimap, bookmark pins in gutter, find-match minimap/list. Some are
inherent (LSP needs an editable buffer — arguably not for hover), most are accidents of which stack
grew the feature. No doc states which lens is *supposed* to have what (the closest is
`ViewMode.hasTextCaret`/`supportsFolding` for two capabilities).
**Impact.** Users learn features exist only in one lens; parity questions get re-litigated per
ticket.
**Fix.** Extend the `ViewMode` capability-property pattern into a small capability matrix doc/type
consumed by menus + the M6 checklist (F2).
**Size:** S (doc/type) · **Risk:** safe.

---

### F25 · P3 — Test burden is structurally doubled: WebView behaviors need a VM-only WV/T4/T5 lane the native stack doesn't, and vice versa
**Files:** `docs/TEST_PYRAMID.md:11,40-49,83`, `Tests/ViewerUITests/Harness/TierBaseCases.swift`
**Evidence.** The pyramid dedicates a 16-suite in-process WebView lane (VM/nightly,
`MDV_RUN_WEBVIEW_TESTS=1`) to CM6/rendered/mermaid behavior, while native SwiftUI needs T5
WindowServer pixels for anything visual (in-process rasterizers false-green, TSK-488). Every
dual-implemented feature (find, scroll restore, invisibles, theming, folding) needs evidence in
*both* lanes per the per-surface matrix mandate (TSK-1539).
**Impact.** Per-feature test cost ×2 and a merge gate that can't see half the product (host gate is
headless-only) — a permanent drag quantified in the pyramid doc itself ("the native
[lane is the gap]" `TEST_PYRAMID.md:83`).
**Fix.** Consolidation (CH-I) is the only real lever; the WV lane notably gets *stronger* as more
surfaces become JS-inspectable (`cmDispatch` beats AX for text assertions).
**Size:** — · **Risk:** —.

---

## Consolidation strategy (proposal — the refactor itself is NEEDS_OWNER)

The codebase has already voted: engines consolidated into Rust (markdown twin deleted,
`HTMLRenderer.swift:110-119`; highlights, find, cm_edit, diff, csv, hex ported), and the BACKLOG's
CH-I epic moves *presentation* onto the CM6/web stack (source M6 → CSV M3 → hex M7 → logs M8 →
git M9, xlsx/docx after). The native candidates that would argue the other way
(WEBKIT_MARKDOWN_ELIMINATION's memory numbers) lose most of their force because the CM6 editor
keeps a WebContent process alive anyway (that doc's own caveat, `:38-45`).

**Recommended sequence:**

1. **Now, independent of the door (pre-launch fixes):** F1 (save flush), F4 (col off-by-one),
   F7 (ReDoS guard on bridge), F3 (split-pane sync render + prefs/theme), F9 (theme override
   matrix), F20 (displayedText keying), F21 (mark the stale doc). All S/M, none one-way.
2. **Contract before code:** turn this report's surface inventory + F24 capability matrix into the
   M6 (TSK-1530) parity checklist with named evidence classes (mandate #4); wire the missing
   channels in the gated branch (F2 list).
3. **Rust-as-single-brain for text services:** highlights over the bridge (F5), fold ranges from
   core (F13), find via `find_engine`/TSK-800 (F6/F14) — these de-risk the flip because behavior
   stops depending on which stack renders.
4. **Flip `MDV_WEB_SOURCE` default** after the VM slice + side-by-side matrix is green —
   **one-way-door #1, NEEDS_OWNER** (park on TSK-1449/1530).
5. **Retire the native text stack** (TextDisplayView + gutter/overlay/scroll-channel family,
   ~3-4k LOC + its test surface) only after a full release cycle behind the flipped default —
   **one-way-door #2, NEEDS_OWNER**. Keep `.preview`/media native permanently (no benefit to
   web-izing).
6. Continue CH-I milestones (CSV/hex/logs/git) using the same checklist discipline; genericize the
   warm cache (F12) before milestone #2 needs a third copy.

**What NOT to do:** don't partially "fix" native-stack quality items on port-targeted surfaces
(the migration policy already forbids it for engines; extend the spirit to the source-view stack —
bugfix-only until the flip decision), and don't start the native-markdown renderer from the 2026-06
doc without an explicit owner reversal of CH-I.

---

## Positive observations

- **Find-bar chrome is already unified**: one generic `FindBar` view with four thin wrappers
  (`MarkdownFindBar.swift:23,381-502`) — the duplication is in the runtimes, not the UI code.
- **Token-palette single source of truth** across stacks: `SyntaxTheme.cmPalette`
  (TSK-602/641, `SyntaxTheme+CMPalette.swift`) killed the "toggling ViewOnly changed every color"
  class, and `HighlightParityHarness` (TSK-962) pins scope-map reachability on the host gate.
- **Markdown→HTML has exactly one engine**: the Swift visitor twin was deleted Stage-B
  (`HTMLRenderer.swift:110-119`); mdv-web/TUI/app all ride rust-core `markdown.rs`.
- **Doc-shadow save integrity** (`docShadow.verifyOnSave`, S3/S4) actively defends the CM6 text
  round-trip — the right paranoia for a bridged editor.
- **Dirty-buffer consistency across lenses was systematically fixed** (TSK-729 `.source` lens,
  TSK-806 split pane) rather than left per-surface.
- **`ViewModeControl`** cleanly decouples the toolbar mental model from the `ViewMode` routing —
  a good template for the capability matrix (F24).
- **The warm-cache twins document their invariants precisely** and carry DEBUG counters +
  host tests; the parked-text guard on the editor cache is exactly the right data-loss defense.
- **The consolidation direction is already owner-visible**: CH-I epic structure + the TSK-1449
  decision card mean this report lands into an existing decision frame, not a vacuum.

## Coverage gaps (not examined)

- **Runtime behavior**: no UI tests were run; all timing/visual claims trace to in-repo
  measurements (TSK-611, PaneCompositingPolicy trace) — not re-measured.
- **Canvas stack** (`CanvasWebViewHost`, canvas.js, M0-M6 epic): parked by owner; only its
  existence was catalogued.
- **Terminal, sidebar, tab bar, panels, Git panel, LSP UI**: native-only, no dual-stack angle;
  skipped beyond confirming no WebView involvement.
- **mdv-tui / mdv-web front-ends**: out of scope (different processes, not the in-app dual stack).
- **Full `codemirror.html` audit**: read targeted sections (~400 of 1,729 lines); the message-case
  inventory (80 inbound / 32 outbound) was counted, not individually reviewed.
- **Accessibility (VoiceOver) parity** between NSTextView and the WKWebView lenses: flagged by the
  AX mandate context but not audited here (AX tier is the one owner-reserved lane).
- **Warm-cache theme-staleness interactions** beyond the `lastHTML` reload gate reasoning
  (spot-checked, not exhaustively traced).
- **Board ticket cross-check** (`tasked` MCP not queried from this subagent): ticket numbers cited
  from in-repo docs/comments only.
