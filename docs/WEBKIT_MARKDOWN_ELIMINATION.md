# WebKit-for-markdown elimination — DESIGN (scope only, do not build)

**Status:** design only. This documents a native `NSAttributedString`/TextKit
markdown renderer to replace the `WKWebView`-backed rendered-markdown pane for
the common case, keeping a *lazy* `WKWebView` only for mermaid / raw-HTML / CM6.
It is the biggest durable per-document memory lever (P3e). The big refactor is
**not** in this run — this is the plan + the file:line index a future
implementer needs.

Date: 2026-06-01. Author context: P3 memory investigation.

---

## Why (the memory premise, corrected)

The earlier "renderedHTML cache 15-20 MB" / "70 MB IOSurface per window"
framing was a misattribution (see `DocumentModel.renderedHTMLCacheMax`
comment + the P3a vmmap analysis): the in-heap String cache is KB-scale, and
the host process charges ~1.6 MB of compositing regions, not 70 MB. The real
MB-scale rendered-markdown cost lives in the **WebKit `WebContent` XPC
process** (parsed DOM + render tree + IOSurface layer backing, `SM=SHM`
shared-memory surfaces charged to the GPU helper + WindowServer, not to the
app's `phys_footprint`) — documented at 30-80 MB while rendering + a ~35 MB
persistent GPU/Networking helper floor (`LESSONS.md` WebKit XPC attribution).

So the lever is **not** a Swift cache to shrink — it's eliminating the
`WKWebView` for basic markdown so no WebContent process + IOSurface backing is
spun up for the common "open a markdown file" case.

### What the win actually is (bounded)

| Saving | When realized |
|---|---|
| ~30-80 MB WebContent process for the rendered doc | every markdown tab shown natively instead of in a WebView |
| ~70-150 MB IOSurface/window compositing backing attributable to the WebView's layer | every natively-rendered markdown tab |
| ~35 MB persistent WebKit helper floor (GPU + Networking) | **only** in a pure read-only-markdown session — see caveat |

**Caveat that bounds the floor saving:** the CM6 editor is *also* a
`WKWebView` (`CodeMirrorEditorView`). The moment the user enters edit mode, or
opens any raw `.html`, or any mermaid doc, the ~35 MB persistent WebKit floor
is paid anyway and stays for the app lifetime. So the *floor* saving is fully
realized only for pure-read-only-markdown sessions. The *per-doc* WebContent +
IOSurface saving (the ~70-150 MB chunk) is realized **whenever** a markdown tab
renders natively — that is the durable win and it applies even in mixed
sessions.

---

## Feasibility: HIGH — the pieces already exist in-tree

- **AST**: `swift-markdown` is already a dependency (`Package.swift`) and
  already fully walked by `HTMLVisitor` (`Sources/ViewerCore/HTMLRenderer.swift`).
  A native renderer is a **parallel visitor** emitting `NSAttributedString`
  runs instead of HTML — same traversal, same depth-guarding, same TreeSitter
  fence highlighting (`TreeSitterEngine.shared.tokenize`), same URL-safety logic.
- **NSTextView host**: `SourceTextController` (`Sources/ViewerUI/TextDisplayView.swift`)
  is a production `NSScrollView + NSTextView` controller with
  `allowsNonContiguousLayout`, theming, scroll-sync, find/highlight,
  selection-highlight, and republish-loop dedupe guards. The renderer reuses
  this shape (or this class directly with an attributed-string apply path).
- **Precedent + the team's own verdict**: `LSPMarkdownRenderer`
  (`Sources/ViewerUI/LSP/LSPMarkdownRenderer.swift`) already renders markdown
  to `NSAttributedString` for LSP hovers; its doc-comment states the conclusion
  — Foundation's `AttributedString(markdown:)` is **inline-only** (insufficient
  for block structure), so we use the `Markdown` AST for the file viewer. The
  native renderer follows that: AST walk, **not** the Foundation initializer.

---

## Element mapping (markdown → NSAttributedString / TextKit)

| Element | Native mechanism | Difficulty |
|---|---|---|
| Headings h1-h6 | font size/weight + paragraph spacing | trivial |
| Para / emphasis / strong / del / inline code | font traits + `.backgroundColor` (already in `LSPMarkdownRenderer.applyInlineTraits`) | trivial |
| Links | `.link` attribute → `NSTextView` delegate opens via the existing `Coordinator.decide` allowlist | easy |
| Code fences + TreeSitter spans | reuse `TreeSitterEngine.shared.tokenize` → per-run `.foregroundColor` + monospaced font + paragraph background | easy (logic exists) |
| Blockquote | `firstLineHeadIndent`/`headIndent` + custom left-border via a layout-fragment / `NSLayoutManager` draw override | medium |
| Lists (ul/ol, nested) | `NSTextList` + `NSParagraphStyle.textLists` | medium |
| HR | full-width rule via attachment or layout draw | easy-medium |
| Images | `NSTextAttachment` (async-load local/remote, respect the existing `safeURL` image allowlist) | medium |
| Tables | `NSTextTable` (TextKit 1) — **the hardest piece**; brittle layout, no `overflow-x:auto` per-cell scroll like CSS | **hard** |
| Mermaid / raw HTML / CM6 | **stay on lazy WKWebView** (per brief) | n/a |
| Find bar | reuse `SourceTextController`'s native find (NSRange match set) — *better* than WKWebView find (which "can't regex", see `MarkdownFindBar`); also drops the injected `findScript` JS | win |
| Zoom | scale base font size (replaces `webView.pageZoom`) | easy |
| dark/light scheme | `SyntaxTheme` already wired in `SourceTextController` | done |

---

## Effort & risk

- **Core renderer** (inline + headings + code fences + lists + blockquote +
  links + images + HR): ~1-2 weeks. Mostly a re-skin of the existing
  `HTMLVisitor` traversal + reuse of `SourceTextController`. Low risk —
  pure-logic, host-testable (T1).
- **Tables via `NSTextTable`**: +0.5-1 week and the **main risk**. TextKit
  table layout is finicky and won't match CSS `display:block; overflow-x:auto`
  for wide tables. Pragmatic fallback: render tables as a monospaced
  fixed-column block, OR keep a *lazy* per-doc WebView only when the doc
  contains a table (content-sniff like the existing `htmlNeedsMermaid` in
  `MarkdownRenderedView`). This preserves most of the memory win (table-heavy
  docs are rare).
- **Integration**: swap `MarkdownRenderedView` for a native `MarkdownNativeView`
  in `ContentView` (the rendered-markdown branch) and `SplitPaneView`; rewire
  the rendered find path (`FindCoordinator`) to the NSTextView match-set API;
  zoom; the rendered find-bar's regex toggle can now be *enabled*.
- **Behavioral parity risks to flag for review**:
  - text selection/copy fidelity (HTML→clipboard rich text vs NSAttributedString),
  - `prefers-color-scheme` live-flip without reload,
  - anchor-link (`#heading`) intra-doc scroll (needs a heading→range map,
    replacing the slug anchors),
  - exact typographic match to the current `markdown.css` (users will notice
    spacing diffs).
- **Security bonus**: removes the entire markdown-path JS/CSP attack surface
  (`MarkdownRenderedView` injects `findScript` + the mermaid runtime via
  `addUserScript`, which bypasses CSP per the WV-7 notes). Native render has no
  JS at all for basic markdown.

---

## Recommended scope split (phased; do NOT build now)

1. **Phase 1** — native renderer for the inline + block subset *excluding
   tables*; content-sniff to keep a lazy WebView for docs containing tables,
   mermaid, or raw HTML. Captures the bulk of the memory win at the lowest risk.
2. **Phase 2** — `NSTextList`/`NSTextTable` to drop the table-WebView fallback,
   if the table layout quality proves acceptable.

---

## File:line index (for the future implementer)

- `Sources/ViewerCore/HTMLRenderer.swift` — `renderPage` + `HTMLVisitor` (the
  AST-walk to mirror in a native visitor).
- `Sources/ViewerUI/MarkdownRenderedView.swift` — the WebView to replace;
  `lastHTML` (2nd HTML copy per tab), mermaid lazy-inject, find JS, nav allowlist.
- `Sources/ViewerUI/SplitPaneView.swift` — the split-pane rendered-markdown
  branch (also calls `HTMLRenderer().renderPage` inline; route it to the native
  renderer too). Note: it currently does a synchronous `TextFileLoader().load`
  in `body` (P2-overlap; guarded for large files but re-renders per body eval).
- `Sources/ViewerUI/TextDisplayView.swift` — `SourceTextController` (NSTextView
  host to reuse).
- `Sources/ViewerUI/LSP/LSPMarkdownRenderer.swift` — existing
  markdown→NSAttributedString precedent + the "use swift-markdown AST for the
  viewer" rationale.
- `Sources/ViewerUI/Resources/markdown.css` — styling to replicate (~5 KB;
  tables are the hard part).
- `Sources/ViewerUI/CodeMirrorEditorView.swift`, `Sources/ViewerUI/HTMLRenderedView.swift`
  — the two WebViews that **stay** (and bound the floor-saving caveat above).
- `LESSONS.md` (WebKit XPC memory attribution) — the 35 MB floor / 30-80 MB
  WebContent the rendered pane spins up; the real target of this work.
- `scripts/mem-profile.sh`, `scripts/heap-dump.sh` — measurement; remember
  WebContent is a SEPARATE process so the saving shows as fewer/no
  `com.apple.WebKit.*` helpers + lower IOSurface, not in `phys_footprint` alone.
