# Text Editor Architecture Options — macOS / Swift / SwiftUI / AppKit

Research dated **2026-05-23**. Read-only survey. No recommendation is made; instead, a decision tree (§5) lets the reader pick based on their own constraints.

Scope: how to evolve a SwiftUI + AppKit *viewer* into a *viewer-and-editor* without painting ourselves into a corner. Covers `NSTextView` (TextKit 1 and 2), SwiftUI `TextEditor`, embedded CodeMirror / Monaco, a custom CoreText view, third-party Swift packages, and reference apps.

---

## 1. TL;DR

Three paths are realistically viable for this project's situation (small team, SwiftUI/AppKit Mac-native shell, markdown-focused, eventual code-edit ambitions):

1. **`NSTextView` on TextKit 2 + Neon + tree-sitter** — maximum Mac-native fidelity (IMEs, Services, spell check, Force Touch lookup, Find UI), low bundle cost (~0 MB), low risk of vendor lock-in. Trade-off: TextKit 2 still has well-documented layout / viewport bugs in macOS 15 (Marcin Krzyżanowski, MarkEdit team, Riley Testut, Simon Støvring have all called out concrete pain). You will hit them.
2. **A maintained `NSTextView` replacement (e.g. `STTextView`, `CodeEditTextView`)** — same Mac-native surface, but someone else has eaten the TextKit 2 papercuts. Trade-off: dependency on a small-maintainer package (1 person bus factor for `STTextView`; CodeEdit ecosystem is broader but younger). `STTextView` is GPL-3 with paid commercial licence.
3. **Embed CodeMirror 6 in `WKWebView`** — battle-tested editor used by Replit, CodeSandbox, GitHub, and explicitly the path MarkEdit chose after rejecting TextKit. Trade-off: ~1–4 MB bundle, JS bridge for every command, Mac-native quirks (Services, Force Touch lookup, system Find UI) need bespoke shimming. For markdown specifically this is the path with the most "this already works" precedent.

Dominant trade-off across all three: **Mac-nativeness vs. battle-testedness**. The further left on that axis (raw `NSTextView`), the better the system integration but the more bugs you eat. The further right (CodeMirror in WKWebView), the more polished the editor primitive but the more "this isn't quite a Mac app" friction.

Monaco, Zed-style custom Metal, and roll-your-own CoreText are not viable for this project's resourcing — listed for completeness.

---

## 2. Options Matrix

### 2.1 `NSTextView` (TextKit 1) — the legacy default

| Dimension | Notes |
|---|---|
| What it is | The Cocoa text view, backed by `NSLayoutManager` + `NSTextStorage` + `NSTextContainer`. ~30 years of bug-fixes. |
| Mac-native | All system features (IMEs, spell check, Services menu, Force Touch lookup, undo manager, drag-drop, Find UI via `NSTextFinder`) work out-of-box. The gold standard. |
| Performance ceiling | Plain text scrolls fine up to multi-MB files. **Editing** near the start of a large doc is "dog-slow" — bottleneck is `glyphRangeForCharacterRange:` and `deleteGlyphsInRange:` [3]. Disabling `usesFontPanel` recovers a lot on large plain-text files [3]. Realistic ceiling: ~50–100k lines before edit-latency becomes noticeable. |
| Syntax highlighting hook | Yes via `NSTextStorage` attributes; pair with `Neon` + `SwiftTreeSitter` [13]. Flicker-free on-keypress highlighting requires an `NSTextStorage` subclass [13]. |
| Find / Replace | Built-in via `NSTextFinder` — system-standard UI. |
| Multi-cursor | Not natively supported. |
| Memory | Cheap. `NSTextStorage` is a single backing string + attribute runs. |
| Bundle hit | Zero. |
| License / maintenance | Apple system framework. Layout-manager APIs were officially soft-deprecated in macOS 12 (still functional in macOS 15/26) [1][6]. |
| Risk | Apple's direction is TextKit 2; betting on TK1 long-term means betting on Apple keeping it alive indefinitely. Historically they do — but new features land in TK2 only (printing got TK2 support only in macOS 15) [1]. |

### 2.2 `NSTextView` (TextKit 2) — the modern default since macOS 12

| Dimension | Notes |
|---|---|
| What it is | Same `NSTextView` class, new model layer: `NSTextContentStorage` + `NSTextLayoutManager` + `NSTextViewportLayoutController`. Viewport-based incremental layout — only visible fragments are laid out [6][11]. Default since macOS 12. |
| Mac-native | Inherits everything from `NSTextView` — IMEs, Services, Force Touch, Find UI all work. Caveat: touching the legacy `.layoutManager` property on macOS 26 silently downgrades the view to TextKit 1 [1]. |
| Performance ceiling | Architecturally much better than TK1 — viewport layout means *scrolling* a 1M-line file is cheap. `TextViewBenchmark` reports TK2 is "a small amount faster" than TK1 in their tests [5]. Real-world editing reports are mixed — Riley Testut: "switching to TextKit 2 introduced a bunch of bugs with no tangible benefits" [10]; CPU spikes seen during text streaming in 2026 [1]. |
| Syntax highlighting hook | Same `NSTextStorage` attribute mechanism, but `Neon`'s author notes: *"I have not yet figured out a way to do this with TextKit 2, and it may not be possible without new API"* [13]. Tree-sitter integration is harder than under TK1 today. |
| Find / Replace | Built-in via `NSTextFinder`. |
| Multi-cursor | Not natively. |
| Memory | Lower than TK1 for large docs (only viewport laid out). |
| Bundle hit | Zero. |
| License / maintenance | Apple. Soft-deprecated APIs are TK1, not TK2 — TK2 is the forward path. |
| Risk | **Significant.** Marcin Krzyżanowski (4 years of TextKit 2 work): *"TextKit 2 API and its implementation are lacking and unexpectedly difficult to use correctly"* [9][10]. Known bugs: unstable document-height estimation causing scrollbar "jiggery" (visible even in Apple's own TextEdit) [9]; broken "extra line fragment" layout [9]; only `NSTextContentStorage` actually works despite the abstract API suggesting alternatives [9]; `NSTextElement` must subclass `NSTextParagraph` or crash at runtime [9]; no multi-container / pagination / table support, forcing TextEdit to fall back to TK1 for printing [10]. Keith Blount (Scrivener), Simon Støvring (Runestone) have also publicly bailed [10]. |

### 2.3 SwiftUI `TextEditor`

| Dimension | Notes |
|---|---|
| What it is | The SwiftUI primitive (`TextEditor($text)`). Thin wrapper over `NSTextView` / `UITextView`. |
| Mac-native | Inherits underlying `NSTextView` features but exposes almost nothing — no API for attributed strings, no syntax-highlight hook, no find UI binding, no scroll position control [12][14]. |
| Performance ceiling | Reported terrible at scale — multiple writers note ~60–80k word documents become unusable, typing latency multiple seconds per keypress [12]. Scrolling reliability issues with trackpad/mouse [12]. |
| Syntax highlighting | None. Plain text only. No attributed-string binding. |
| Find / Replace | None built-in. |
| Multi-cursor | No. |
| Memory | Same as underlying NS/UITextView. |
| Bundle hit | Zero. |
| License | Apple. |
| Risk | Not production-viable as a code editor today. Useful for chat-message-style single-paragraph editing only. The escape hatch every serious project uses: wrap `NSTextView` in `NSViewRepresentable`. |

### 2.4 CodeMirror 6 in `WKWebView`

| Dimension | Notes |
|---|---|
| What it is | A modern (v6) browser-native code editor; loaded into a `WKWebView` and driven via JS bridge. The path `MarkEdit` took after explicitly rejecting TextKit [15]. |
| Mac-native | Mixed. `WKWebView` itself integrates well: spell check works, IMEs work (Apple WebKit handles them), Force Touch / lookup works in selected text, basic drag/drop works. But: system Find UI (`NSTextFinder`), Services menu integration, and `NSUndoManager` integration all require shimming — you bridge the editor's find/undo/etc. to AppKit yourself. MarkEdit demonstrates this is doable and produces a "delightful" result [15]. |
| Performance ceiling | High. MarkEdit reports opening a 10 MB markdown file is "eye-blinking" on an 8-year-old MBP, and editing megabytes feels like kilobytes [15]. CodeMirror 6 was designed for this. |
| Syntax highlighting | First-class. Native CodeMirror grammars (Lezer) for ~150 languages; tree-sitter integration available too. |
| Find / Replace | Built-in CodeMirror UI; or you can hide it and bridge to a SwiftUI/AppKit find bar. |
| Multi-cursor | Yes, first-class. |
| Memory | Higher than native — WebView process plus JS heap. |
| Bundle hit | CodeMirror 6 alone is small (~200–400 KB minified+gz for a typical config). MarkEdit ships as a 4 MB app total [15] (vs ~100 MB for Electron equivalents). |
| License | MIT for CodeMirror. |
| Risk | JS bridge latency for every host-driven command (open file, save, format). Async-by-default. Browser-style focus/blur quirks vs Mac conventions. Long-term: depends on CodeMirror upstream. |

### 2.5 Embedded Monaco in `WKWebView`

| Dimension | Notes |
|---|---|
| What it is | VS Code's editor as a library, loaded into a WebView. `SwiftyMonaco` is one Swift wrapper [4]. |
| Mac-native | Same caveats as CodeMirror — but Monaco was explicitly designed for browser-with-keyboard, not iOS/Catalyst (so don't ship via Catalyst) [4]. |
| Performance ceiling | High at runtime; heavy at load. |
| Syntax highlighting | First-class. ~80 languages out of the box via Monarch + TextMate grammars. |
| Find / Replace | Built-in VS Code style. |
| Multi-cursor | Yes. |
| Memory | The heaviest of all options — full VS Code editor JS heap. |
| Bundle hit | **Large.** The `min/` directory of `monaco-editor` is ~6 MB; full package is ~29 MB; typical bundled application chunks: main ~3.9 MB + TS worker ~6.7 MB [16]. Approximately 5–10× the bundle cost of CodeMirror for similar features. |
| License | MIT. |
| Risk | Bundle cost (vs the project's 25 MB cap) is the dominant blocker. Maintainer notes from `SwiftyMonaco` and similar wrappers: not Catalyst-compatible due to custom focus handling [4]. |

### 2.6 Roll-your-own CoreText + custom `NSView`

| Dimension | Notes |
|---|---|
| What it is | What Nova, Sublime Text, and (effectively) Zed do. Direct `CTFramesetter`/`CTLine` drawing in `drawRect:`, custom text storage, custom selection / cursor / IME glue. |
| Mac-native | Nothing free — you re-implement Services menu, Force Touch lookup, drag-drop, accessibility, undo, find UI, IME composition, spell check (NSSpellChecker is reachable), system colour pickers, etc. Nova spent years to get this right [7]. |
| Performance ceiling | Whatever you build. Nova ships a custom text layout manager precisely because Apple's was too slow and buggy for them [7]. Sublime Text built their own buffer + regex + rendering pipeline and achieves 16ms-budget rendering at 8K [17]. |
| Syntax highlighting | DIY. Pair with tree-sitter. |
| Find / Replace | DIY. |
| Multi-cursor | DIY (Nova has it [7]). |
| Memory | Whatever you build. |
| Bundle hit | Zero. |
| License | N/A. |
| Risk | **Massive effort.** Real engineer-years. The list of system features you'll re-implement and get subtly wrong (and the bug reports about it) is long. Justifiable for a product whose differentiation *is* the editor. Not justifiable for "we want a viewer-that-also-edits". |

### 2.7 Wrapper libraries (enumerated; no recommendation)

These are third-party Swift packages aimed at filling the `NSTextView` / SwiftUI gap. Listed alphabetically — health metrics as of 2026-05.

| Package | What it adds | TK version | Platforms | Licence | Maintenance |
|---|---|---|---|---|---|
| `CodeEditTextView` ([CodeEditApp](https://github.com/CodeEditApp/CodeEditTextView)) | `NSView` subclass (not `NSTextView`); custom line layout for fast initial render and large docs. Plain text view; semantics added by parent package `CodeEditSourceEditor`. | Custom (CoreText-based, not TK2) | macOS only | MIT | Active. ~83 commits, ~6 contributors, ~2 yrs old. Backs the open-source `CodeEdit` app [18]. |
| `CodeEditSourceEditor` ([CodeEditApp](https://github.com/CodeEditApp/CodeEditSourceEditor)) | Tree-sitter syntax highlighting, find/replace, minimap, bracket matching, inline messages, current-line highlight — on top of `CodeEditTextView`. SwiftUI + AppKit APIs. | Custom (via CET) | macOS only | MIT | Active. Used in production by `CodeEdit`. |
| `CodeEditorView` ([mchakravarty](https://github.com/mchakravarty/CodeEditorView)) | SwiftUI code editor view; syntax highlighting, themes, bracket matching, current-line highlight, minimap, inline messages. | TextKit 2 | iOS / macOS / visionOS | Apache-2.0 | ~343 commits, 899 stars. Maintainer explicitly notes "pre-release quality" with known bugs blocking 1.0. |
| `CodeMirror-Swift` ([ProxymanApp](https://github.com/ProxymanApp/CodeMirror-Swift)) | WKWebView wrapper around CodeMirror **5** (not 6). | N/A (WebView) | macOS / iOS | MIT | Stale. Last release Nov 2020 (~5.5 yrs). |
| `CodeMirror-SwiftUI` ([Pictarine](https://github.com/Pictarine/CodeMirror-SwiftUI)) | SwiftUI wrapper around CodeMirror 5. | N/A (WebView) | macOS / iOS | MIT | Lower activity; CM5-era. |
| `CodeView` ([eonil](https://github.com/eonil/CodeView)) | Experimental high-perf code editor view written from scratch (no `NSTextView`). | Custom | macOS | (check repo) | Experimental / low activity. |
| `CodeEditor` ([ZeeZide](https://github.com/ZeeZide/CodeEditor)) | SwiftUI `TextEditor` + Highlight.js. | TK1/2 via wrapping | macOS / iOS | Apache-2.0 | Modest activity. |
| `Neon` ([ChimeHQ](https://github.com/ChimeHQ/Neon)) | Not a view — a styling pipeline. `TextViewHighlighter` glues `TreeSitterClient` to `NSTextView` / `UITextView`. Three-phase styler combines primary + fallback + secondary token sources. | TK1 well-supported; **TK2 support incomplete** (maintainer's own caveat) [13] | macOS / iOS | BSD-3-Clause | Active. ~256 commits. v0.6.0 Jan 2024 (newer maintenance commits since). |
| `Runestone` ([simonbs](https://github.com/simonbs/Runestone)) | Performant code editor view; tree-sitter, line numbers, themes. Built on the AvalonEdit line-management model. | Neither — uses **Core Text** directly | **iOS only** (maintainer dropped Mac port partly due to TK2 frustration) [10] | MIT | Active for iOS. Powers the App Store Runestone app. |
| `Sourceful` ([twostraws](https://github.com/twostraws/Sourceful)) | Older syntax-highlighting source editor wrapping `NSTextView` / `UITextView`. | TK1 | macOS / iOS | MIT | Lower activity. |
| `SourceView` ([ChimeHQ](https://github.com/ChimeHQ/SourceView)) | TextKit 2 `NSTextView` subclass tuned for source code. | TK2 | macOS | (check repo) | Active under ChimeHQ. |
| `STTextView` ([krzyzanowskim](https://github.com/krzyzanowskim/STTextView)) | Full `NSTextView`/`UITextView` replacement using TK2. Multi-cursor, search/replace, completion, plugin system. Plugins: `Plugin-Neon` (tree-sitter highlight), `Plugin-TextFormation`, `Plugin-Annotations`. README enumerates **22+ TextKit 2 bugs** it works around. | TK2 | macOS 14+ / iOS 16+ / Mac Catalyst | **GPL-3.0**, commercial licence available from author | Very active. v2.3.10 Apr 2026; ~1,173 commits; 116 releases; ~4 yrs. Effectively a 1-person project. |
| `SwiftyMonaco` ([ICToolkit](https://github.com/ICToolkit/SwiftyMonaco)) | SwiftUI wrapper around Monaco editor in WKWebView. | N/A | macOS / iOS (not Catalyst) | (check repo) | Lower activity. |
| `SwiftTreeSitter` ([tree-sitter](https://github.com/tree-sitter/swift-tree-sitter)) | Low-level Swift bindings to the tree-sitter C runtime. | N/A | macOS / iOS | MIT | Active. Upstream `tree-sitter` org. |

---

## 3. Reference Apps

| App | Editor stack (where publicly known) | Notes |
|---|---|---|
| **Xcode** | `NSTextView` (long history). Source editor uses Apple's text frameworks; SourceKit (`sourcekitd` XPC) handles syntax, completion, semantics [11]. As of macOS 14+, observers report TextKit 2 paths becoming usable for source — but exact mix in Xcode itself is not publicly documented. |
| **VSCode (macOS)** | Electron + CodeMirror-derived Monaco editor in a browser context. Not Mac-native; Chromium + V8. |
| **Cursor** | Fork of VSCode → same stack, same Electron overhead [21]. |
| **Zed** | Custom Rust GPUI framework drawing directly via **Metal** on macOS. Glyph atlas on GPU with 16 sub-pixel variants per glyph, bin-packed; ~120 FPS [19][20]. Does **not** use `NSTextView`. Implements IME, find, etc. itself; recent release notes mention fixing IME composition + predictions interplay [19]. |
| **Sublime Text** | Custom buffer, custom regex, custom rendering pipeline. ST4 added GPU rendering (OpenGL) cross-platform, 16ms budget at 8K [17]. |
| **BBEdit** | Originally classic-Mac TextEdit control, then THINK Technologies "PE" engine; modern BBEdit is heavily customised AppKit. BBEdit 15 added VoiceOver / Full Keyboard Access overhauls — implies deep custom accessibility work [22]. Public details on rendering layer are sparse. |
| **Nova (Panic)** | AppKit / Swift app with **custom text layout manager** built from scratch — Panic explicitly rejected Apple's text layout for both bugs and performance reasons [7]. JS-based extension API. Built-in LSP support. |
| **TextMate (2.x)** | Objective-C++ on AppKit, but its own text engine; not raw `NSTextView`. Published source on GitHub under GPL-3 in 2012 [23]. Build uses Ninja, depends on Boost/Cap'n Proto/Ragel. |
| **MacDown** | Native Cocoa, `NSTextView` for editing pane, WebView for preview. Hoedown markdown renderer. |
| **Typora** | Cross-platform Electron-style; hides markdown syntax in a single-pane WYSIWYG-ish view. Not Mac-native in the AppKit sense. |
| **MarkEdit** | **CodeMirror 6 in `WKWebView`**, with AppKit chrome around it. Explicitly chose this after dismissing TextKit 1 and TK2: *"TextKit is not better than contentEditable"* [15]. Ships as a 4 MB app; opens 10 MB markdown files instantly. The closest existing precedent for "markdown-focused, Mac-native chrome, CodeMirror inside". |

---

## 4. Scoring Table

Axes: 1 = poor, 5 = excellent. **For the use case of a SwiftUI + AppKit Mac-native viewer evolving into an editor.** These are calibrated *for this project's situation* — not absolute quality.

| Option | Native­ness | Perf | Ease (impl effort, ↑ = less work) | Flexi­bility | Future-proof | Bundle cost (↑ = smaller) | Notes |
|---|---|---|---|---|---|---|---|
| `NSTextView` (TextKit 1) | 5 | 3 | 5 | 3 | 2 | 5 | Soft-deprecated APIs; works today, but Apple's not investing here. |
| `NSTextView` (TextKit 2) | 5 | 4 | 3 | 3 | 4 | 5 | Forward path on paper; you eat the bugs. |
| SwiftUI `TextEditor` | 4 | 1 | 5 | 1 | 3 | 5 | Not production-viable as an editor. |
| CodeMirror 6 in WKWebView | 3 | 5 | 4 | 5 | 4 | 4 | MarkEdit precedent. JS bridge friction. |
| Monaco in WKWebView | 3 | 5 | 3 | 5 | 4 | 1 | Bundle cost blows the 25 MB cap. |
| Custom CoreText + NSView | 3 | 5 | 1 | 5 | 4 | 5 | Engineer-years. Justifiable only if editor *is* the product. |
| `STTextView` (TK2 wrapper) | 5 | 4 | 4 | 4 | 3 | 5 | 1-person bus factor; GPL-3 licence implications. |
| `CodeEditTextView` + `SourceEditor` | 5 | 4 | 4 | 4 | 4 | 5 | Custom non-TK rendering; MIT; backed by CodeEdit app community. |
| `CodeEditorView` (mchakravarty) | 4 | 3 | 5 | 3 | 3 | 5 | SwiftUI-first; pre-1.0 self-described. |
| `Neon` + raw `NSTextView` | 5 | 4 | 4 | 4 | 3 | 5 | Pipeline only; you supply the view. TK2 support incomplete. |

---

## 5. Decision Framework

Not a single recommendation — a decision tree based on which constraint dominates.

```
START: how important is "this feels exactly like a Mac app" (Services, Force Touch
       lookup, system Find UI, IME, spell check, undo, drag/drop — all out of box)?

├─ Critical (must be indistinguishable from TextEdit / Xcode)
│   │
│   └─ How much engineering bandwidth for TextKit 2 papercuts?
│       │
│       ├─ Lots (can afford to file & work around Apple bugs):
│       │   └─►  NSTextView + TextKit 2 + Neon (TK2 path, but accept Neon's
│       │        TK2 support is incomplete — may need to stay on TK1 for highlight)
│       │        OR  NSTextView + TextKit 1 + Neon (older but battle-tested)
│       │
│       └─ Limited (want someone else to have eaten the bugs):
│           ├─ MIT-licence requirement → CodeEditTextView + CodeEditSourceEditor
│           └─ GPL-3 acceptable, or commercial licence is fine → STTextView + Plugin-Neon
│
├─ Important but not critical (markdown editor — users tolerate some non-native quirks)
│   │
│   └─ Is editor quality (multi-cursor, large-file perf, language support breadth)
│      the bigger product differentiator?
│       │
│       ├─ Yes  → CodeMirror 6 in WKWebView (MarkEdit precedent; ~4 MB bundle)
│       └─ No   → STTextView or CodeEditTextView (native path, lower-risk perf)
│
└─ Not important (developer tool where users live in the editor, not the chrome)
    │
    └─ Bundle / installer size sensitivity?
        ├─ Tight (≤ 25 MB cap, as here)         → CodeMirror in WKWebView
        ├─ Loose (50+ MB OK)                    → Monaco in WKWebView
        └─ Editor is the product, multi-year R&D → Custom Metal / CoreText (Zed / Nova path)
```

### Secondary axes

- **Licence risk** — `STTextView` is GPL-3 by default; in a closed-source product you must pay for the commercial licence (or vendor a fork pre-relicensing, which is risky). `CodeEditTextView`, `Neon`, CodeMirror, Monaco, `Runestone` are all MIT/BSD/Apache.
- **Bus-factor risk** — `STTextView` is essentially Marcin alone; `CodeEditTextView` has the `CodeEdit` app community backing it; `Neon`/`SourceView` have ChimeHQ; CodeMirror is widely used by many companies; Monaco is Microsoft.
- **iOS / Catalyst future** — `STTextView` works on iOS/Catalyst; `CodeEditTextView` is macOS-only; `Runestone` is iOS-only; CodeMirror works everywhere a WebView does; Monaco explicitly does NOT work on Catalyst [4]; SwiftUI `TextEditor` works everywhere but is too thin.
- **Markdown-specific wins** — for a markdown viewer/editor, CodeMirror 6 has the richest ecosystem (live preview, GFM grammar, math, embedded code-block syntax). MarkEdit's 4 MB outcome is the existence proof.

### Anti-patterns to flag

- **Touching `.layoutManager` on a TK2 `NSTextView`** — silently downgrades the whole view to TK1 [1]. Easy to do accidentally.
- **Relying on `SwiftUI.TextEditor` for the editor surface** — replace with `NSViewRepresentable<NSTextView>` from the start; the migration cost later is non-trivial.
- **Going to Monaco with a 25 MB bundle cap** — won't fit. The min directory alone is 6 MB and you need workers on top [16].
- **Picking `Runestone`** — it is iOS-only; the maintainer has publicly stated the Mac port is stalled in part due to TextKit 2 [10].
- **Mixing TK1 and TK2 in the same view** — see point 1.

---

## 6. References

1. Marcin Krzyżanowski, *TextKit 2: the promised land* (2025) — `https://blog.krzyzanowskim.com/2025/08/14/textkit-2-the-promised-land/`
2. ChimeHQ, *TextViewBenchmark* — `https://github.com/ChimeHQ/TextViewBenchmark`
3. Christian Tietze, *NSTextView Performance May Degrade for Large Plain Text Documents When usesFontPanel Is Active* (2021) — `https://christiantietze.de/posts/2021/09/nstextview-fontpanel-slowness/`
4. Pavel Kasila, *Monaco Editor and SwiftUI* — `https://pkasila.medium.com/monaco-editor-and-swiftui-4b188a2f4d0f`; SwiftyMonaco — `https://github.com/ICToolkit/SwiftyMonaco`
5. ChimeHQ, *TextViewBenchmark README* — `https://github.com/ChimeHQ/TextViewBenchmark/blob/main/README.md`
6. Apple, *Meet TextKit 2* (WWDC21) — `https://developer.apple.com/videos/play/wwdc2021/10061/`
7. Panic, *Nova* — `https://nova.app/`; MacStories, *Nova Review* — `https://www.macstories.net/reviews/nova-review-panics-code-editor-demonstrates-why-mac-like-design-matters/`
8. Apple, *TextEditor (SwiftUI)* — `https://developer.apple.com/documentation/swiftui/texteditor`
9. Marcin Krzyżanowski (same as [1]) on extra-line-fragment, viewport-height instability, `NSTextElement` runtime crash, NSTextContentStorage-only reality.
10. Michael Tsai, *TextKit 2: The Promised Land* aggregation (2025) — `https://mjtsai.com/blog/2025/08/15/textkit-2-the-promised-land/` (collects Krzyżanowski, Riley Testut, Keith Blount/Scrivener, Simon Støvring/Runestone, MarkEdit team).
11. NSHipster, *XcodeKit and Xcode Source Editor Extensions* — `https://nshipster.com/xcode-source-extensions/`; JP Simard, *Uncovering SourceKit* — `https://www.jpsim.com/uncovering-sourcekit/`
12. Cephalopod Studio, *Modest Improvements on the TextEditor in SwiftUI* — `https://www.cephalopod.studio/blog/improving-on-texteditor-in-swiftui`; Medium, *SwiftUI 2.0/macOS — TextEditor capabilities, limitations, and wishlist* — `https://medium.com/macoclock/swiftui-2-0-macos-texteditor-capabilities-limitations-and-wishlist-d43eaa8930b1`; Artem Novichkov, *Mastering TextEditor in SwiftUI* — `https://artemnovichkov.com/blog/mastering-text-editor-in-swiftui`
13. ChimeHQ, *Neon* — `https://github.com/ChimeHQ/Neon`; tree-sitter, *swift-tree-sitter* — `https://github.com/tree-sitter/swift-tree-sitter`
14. Apple Developer Forums on TextKit — `https://developer.apple.com/forums/tags/textkit`
15. MarkEdit, *Why MarkEdit* — `https://github.com/MarkEdit-app/MarkEdit/wiki/Why-MarkEdit`; main repo — `https://github.com/MarkEdit-app/MarkEdit`
16. Bundlephobia, *monaco-editor* — `https://bundlephobia.com/package/monaco-editor`; Microsoft issue *Reducing size of monaco-editor dependency* — `https://github.com/Microsoft/monaco-editor/issues/463`; Microsoft issue *Monaco-editor 0.55 generated bundle file larger than 6MB* — `https://github.com/microsoft/monaco-editor/issues/5154`
17. Sublime HQ, *Sublime Text 4* — `https://www.sublimetext.com/`; Medium, *Text rendering in Sublime Text* — `https://medium.com/abhnv/text-rendering-in-sublime-text-38ee28acd4a3`
18. CodeEdit, *Why We're Building CodeEdit* — `https://www.codeedit.app/blog/2024/01/why-were-building-codeedit`; `CodeEditApp/CodeEditTextView` — `https://github.com/CodeEditApp/CodeEditTextView`; `CodeEditApp/CodeEditSourceEditor` — `https://github.com/CodeEditApp/CodeEditSourceEditor`
19. Zed Industries, *Leveraging Rust and the GPU to render user interfaces at 120 FPS* — `https://zed.dev/blog/videogame`; *GPUI README* — `https://github.com/zed-industries/zed/blob/main/crates/gpui/README.md`
20. Beck Moulton, *GPUI: A Technical Overview* — `https://beckmoulton.medium.com/gpui-a-technical-overview-of-the-high-performance-rust-ui-framework-powering-zed-ac65975cda9f`
21. DataCamp, *Cursor vs. VS Code* — `https://www.datacamp.com/blog/cursor-vs-vs-code`
22. Bare Bones, *BBEdit 15 Release Notes* — `https://www.barebones.com/support/bbedit/notes-15.0.html`; *BBEdit 11 Release Notes* (PE engine history) — `https://www.barebones.com/support/bbedit/arch_bbedit11.html`; Wikipedia, *BBEdit* — `https://en.wikipedia.org/wiki/BBEdit`
23. TextMate, *GitHub* — `https://github.com/textmate/textmate`; Wikipedia — `https://en.wikipedia.org/wiki/TextMate`
24. CocoaDev, *NSTextViewPerformanceEnhancement* — `https://cocoadev.github.io/NSTextViewPerformanceEnhancement/`
25. Simon Støvring, *Runestone* — `https://github.com/simonbs/Runestone`; docs — `https://docs.runestone.app/`
26. Manuel M T Chakravarty, *CodeEditorView* — `https://github.com/mchakravarty/CodeEditorView`
27. ProxymanApp, *CodeMirror-Swift* — `https://github.com/ProxymanApp/CodeMirror-Swift`; Pictarine, *CodeMirror-SwiftUI* — `https://github.com/Pictarine/CodeMirror-SwiftUI`
28. eonil, *CodeView* — `https://github.com/eonil/CodeView`
29. twostraws, *Sourceful* — `https://github.com/twostraws/Sourceful`
30. ChimeHQ, *SourceView* — `https://github.com/ChimeHQ/SourceView`
31. CodeMirror — `https://codemirror.net/`
32. Microsoft, *Monaco Editor* — `https://microsoft.github.io/monaco-editor/`; repo — `https://github.com/microsoft/monaco-editor`

---

*End of document.*
