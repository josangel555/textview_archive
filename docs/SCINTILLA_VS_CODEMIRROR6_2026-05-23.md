# Scintilla (ScintillaCocoa) vs. CodeMirror 6 (WKWebView) — Head-to-Head

Research dated **2026-05-23**. Sanity check against the prior choice of **CodeMirror 6 in WKWebView** (see `/Users/me/Documents/workspaces/claude/markdown_viewer/docs/TEXT_EDITOR_OPTIONS_2026-05-23.md`). Read-only; no code. Scoped to the user's stated criteria: **MIT/permissive license, small, performant, runtime-lean, Mac-native feel not required**.

---

## 1. TL;DR

**No, do not reconsider — stay with CodeMirror 6.** Scintilla is technically permissively licensed, smaller on disk for what it does, and battle-tested on three desktop platforms — but the path from a SwiftUI/Swift app to a working `ScintillaCocoa` view is a **Swift ↔ C++ via Obj-C++ wrapper** problem that the Scintilla project has not solved for you (its own author confirms there is no first-class Swift story [1]). On the markdown / source-editor axes the user actually cares about — multi-cursor, modular language packs that include Swift/TS/Markdown, an active LSP client maintained by the editor's own author, and a 4 MB precedent (MarkEdit) — CM6 wins clearly. Scintilla would beat CM6 only on two dimensions: native IME / Services / Force Touch integration (which the user already said they don't need) and possibly absolute editing latency at the very-large-file end (1 GB+ plain text). Continue the CM6 implementation already in flight.

---

## 2. Side-by-side table

| Dimension | **Scintilla / ScintillaCocoa** | **CodeMirror 6 in WKWebView** |
|---|---|---|
| **License** | Custom HPND-style: "Permission to use, copy, modify, and distribute… provided that the above copyright notice appear in all copies" [2]. OSI-recognised, MIT-compatible in practice. `ScintillaCocoa.mm` specifically is **dual LGPL-2.1 + Scintilla** [3] — meaning if you modify *that file* the LGPL terms can apply. Lexilla: same Scintilla license [4]. | MIT [5]. |
| **Bundle cost (runtime)** | Scintilla static lib on macOS: roughly **1.5–3 MB** of compiled C++ per arch slice (no published official number; Lexilla shared lib `liblexilla.dylib` adds ~1–2 MB more). Universal binary doubles it. No JS runtime — uses the WebKit-free AppKit text rendering. | CM6 minimal core: **~124 KB min+gz** [6]; typical config with a few languages: **~250–400 KB min+gz**, ~700 KB minified [6][7]. WKWebView itself is system-provided, zero bundle cost. MarkEdit ships at **4 MB total app size** [8]. |
| **Memory per editor + per MB of file** | Gap-buffer-style document (Scintilla's `SplitVector` / `CellBuffer`) [9]. **Notepad++ rule of thumb: ~4× file size in RAM** — a 300 MB file uses ~1.2 GB; a 2 GB file needs 8 GB [10]. Per-instance overhead modest (single C++ object graph). | Persistent tree-based document (Marijn's data-structure post Sep 2025) [11]. Viewport rendering — only visible lines in the DOM. Per-MB overhead lower than Scintilla in practice, but **each editor lives in a WebView process** — an extra ~30–80 MB just for the WebContent process even when empty. |
| **Big-file ceiling** | Hard ceiling **2 GB** (32-bit `int` positions; `SCI_FINDTEXTFULL` exists for 64-bit search but core position type still bites) [10][12]. **Lines longer than `INT_MAX` chars hang or crash** — single-line minified JS / one-line JSON pathological [10]. Loading 30 MB takes ~25 s historical baseline [13]. Notepad++ users report editing comfort up to ~100 MB. | "Avoids performance cliffs"; designed to be sub-linear in doc size and line length [14]. Million-line demo runs in-browser [15]. **MarkEdit: 10 MB markdown opens "eye-blinking" on an 8-year-old MBP** [8]. No hard byte ceiling; JS heap (4 GB default) is the practical limit. Long single lines handled better than Scintilla. |
| **Find / Replace** | Built-in `SCI_SEARCHINTARGET` with `MATCHCASE`, `WHOLEWORD`, regex [12]. **You build the UI.** No `NSTextFinder` integration out of box. | Built-in CodeMirror search panel; or hide it and bridge to AppKit chrome (MarkEdit does this). |
| **Multi-cursor** | Yes — Ctrl-drag for additional selections [12]. Less polished than CM6's; primary/secondary distinction. | First-class. Alt-click, Ctrl-D word-expand, column selection — exactly the modern affordances users expect. |
| **Bracket matching** | Built-in (`SCI_BRACEHIGHLIGHT`, `SCI_BRACEBADLIGHT`). | Built-in via `@codemirror/language` matchBrackets extension. |
| **Folding** | Built-in (lexer-driven); folding margin support [12]. | Built-in via `@codemirror/language` foldGutter + per-language folding service. |
| **Syntax highlighting** | **Lexilla** ships **~100+ lexers** as a `.dylib` [4][16]. Compile once, get C/C++/JS/Python/Java/Go/Rust/Markdown/JSON/XML/HTML/CSS/PHP/SQL/YAML/Bash/PowerShell/Lua/Ruby/Perl/Swift (basic) for free. New language ≈ write a C++ lexer or a Lua/LPeg lexer via Scintillua. **Lexers are line-based regex-style state machines — accurate enough but not AST-aware** (no semantic awareness). | Lezer parser-based; tree-aware. Official `@codemirror/lang-*` packages for **JS, TS-via-JS, Python, Java, Markdown, JSON, XML, HTML, CSS, Rust, C++, PHP, SQL, YAML, JSON, Vue, Angular** [17][18]. **Swift / Go: no official package** — community packages exist (`codemirror-lang-go`, custom Swift via Lezer) [19]. Per-language onboarding: `npm i @codemirror/lang-X`, add to extensions array. |
| **Per-language coverage for the asked set** | JS (good), TS (use JS lexer), Python (good), Java (good), **Swift (basic only)**, Markdown (good), JSON (good), XML (good), HTML (good), CSS (good), Go (good), Rust (good). | JS (excellent), TS (via lang-javascript with `typescript: true`), Python (excellent), Java (excellent), **Swift (community only)**, Markdown (excellent — GFM, embedded code-block parsing), JSON (excellent), XML (excellent), HTML (excellent), CSS (excellent), **Go (community only)**, Rust (excellent). |
| **macOS native: IME** | `ScintillaView` implements `NSTextInputClient` — `setMarkedText` / `unmarkText` / `validAttributesForMarkedText` [20]. **Has historical bugs**: malloc-fail crashes with certain IMEs on 10.12+ [21]; ranges near `NSNotFound` issues reported [20]. Workable but not pristine. | Browser IME path via WebKit. Apple's `WKWebView` handles Japanese/Chinese/Korean composition correctly out of box. Markedly more polished than Scintilla's. |
| **macOS native: spell check** | DIY — must wire `NSSpellChecker` yourself. | WebKit-provided automatically. Works. |
| **macOS native: Services menu / Force Touch lookup** | Inherits `NSView` Services; lookup requires custom `quickLookWithEvent:` handling. | WebKit handles Force Touch lookup in selected text automatically; Services partial. |
| **macOS native: NSUndoManager** | Not bridged — Scintilla has its own undo stack. You'd write a forwarding adapter. | Not bridged — CM6 has `history()` extension. Same forwarding-adapter cost. |
| **macOS native: drag/drop** | Implemented in `ScintillaView`. | WebKit-provided. |
| **macOS native: system Find UI** | DIY — Scintilla has no `NSTextFinder` glue. | DIY — MarkEdit shows the pattern (hide CM find, bridge to AppKit find bar). |
| **Bridge complexity** | **Swift cannot import C++ directly** [1]. Required: (a) build Scintilla + Lexilla as C++ static libs, (b) wrap `ScintillaCocoa` behind `ScintillaView.h` Objective-C interface, (c) write a module map to expose Obj-C symbols, (d) call `SCNotification`/`Sci_*` C structs from Swift. Per-message latency: **direct C function call (~ns)**. Code shape: bidirectional — Swift posts `SCI_*` messages via `[scintillaView setGeneralProperty:value:]`, listens via `SCEN_*` notification callbacks. | **`WKScriptMessageHandler` async messaging**. Per-message latency: **~3.6 ms round-trip on iPad** [22] (Mac is typically faster but same order of magnitude — milliseconds, not nanoseconds). Code shape: Swift `evaluateJavaScript()` + JS `webkit.messageHandlers.X.postMessage()`. Async-by-default; every call needs marshalling through JSON. Higher overhead but conceptually simpler — no C++ build system in the Xcode project. |
| **Maintenance / bus factor** | **Neil Hodgson (single primary maintainer, @nyamatongwe)** for 27 years. v5.5.8 Nov 2025; v5.6.x dropping mid-2026 [23][24]. Active mailing list. Lexilla: 8.5k commits, ~256 stars, but core contributor list short [25]. **Hard 1-person bus factor.** | **Marijn Haverbeke (single primary maintainer)** — also CodeMirror 5, ProseMirror, Eloquent JS. Blog posts Sep 2025 + Jan 2026 [26]. Wide corporate user base (Replit, CodeSandbox, GitHub Gists, Observable, MarkEdit). **Also 1-person bus factor at the top**, but a much larger contributor ecosystem and many companies that would fork if Marijn stopped. |
| **Reference apps using it** | **Notepad++** (Windows; the canonical Scintilla showcase), **Nextpad++ for Mac** (Apr 2026, native Cocoa port of Notepad++ using ScintillaCocoa + Lexilla + Obj-C++ Cocoa UI) [27][28], **SciTE** (Hodgson's own demo IDE, Mac App Store version exists) [29], **Code::Blocks**, **Geany**, **MySQL Workbench**, **Komodo IDE**, **Eric Python IDE** [30]. **None of these are SwiftUI apps.** | **MarkEdit** (4 MB Mac markdown app, the closest precedent) [8], **Replit** (web IDE, switched from CM5 → CM6 and reported +70% weekly mobile retention) [31], **CodeSandbox**, **Observable**, **GitHub Gists / Codespaces UI**, **Jupyter** (in places). |
| **Build / vendor story** | (a) Clone Scintilla + Lexilla source; (b) add as C++ targets in Xcode or via a SwiftPM C-target wrapper around the cocoa/ sources; (c) compile `liblexilla.dylib` + Scintilla static lib; (d) ship `liblexilla.dylib` inside the .app bundle (signed); (e) maintain an Obj-C++ shim target. **No official SwiftPM package exists.** [1] | (a) `npm i @codemirror/state @codemirror/view @codemirror/lang-markdown ...`; (b) bundle with esbuild/rollup; (c) vendor the produced `.js` + `.css` into the Xcode `Resources/`; (d) `WKWebView.loadHTMLString` or `loadFileURL`. Build is part of the JS toolchain, fully separate from Xcode. |
| **LSP future-fit** | **Weak.** `@codemirror/lsp-client` equivalent does not exist. Third-party: `gitlab.com/marcolazzarotto/scintilla-lsp` — single-developer experimental fork focused on autocompletion + signature help [32]. Scintilla's own feature-request tracker has had an LSP issue open since the early Microsoft LSP era with no native plan [33]. You'd write your own LSP client and feed results into Scintilla via indicators/annotations/autocompletion APIs. | **Strong.** Official `@codemirror/lsp-client` published by the CodeMirror org [34] (note: the user-facing repo was reorganized in Apr 2026 — package is alive, not abandoned). Plus three mature community alternatives: `FurqanSoftware/codemirror-languageserver`, `@marimo-team/codemirror-languageserver`, `JeanJPNM/codemirror-lsp-client` — all support hover, diagnostics, completion, go-to-def, rename, references [34]. |

---

## 3. Where **Scintilla** genuinely beats CM6

- **Memory ceiling per editor when no file is loaded** — a C++ widget is grams; a WebView process is hundreds of MB cold. If you'll have many editor panes open, this matters.
- **Predictable native event loop integration** — synchronous C calls vs. async JS messages. If you ever want every keystroke to deterministically round-trip Swift code without `async`/`await`, Scintilla is the only choice.
- **Lexer breadth out of the box** — ~100 languages in one `.dylib` with no `npm install` per language. For a "we want to support every language a junior dev throws at it" use case, Scintilla onboards languages cheaper.
- **License is unambiguously permissive** — HPND is simpler than MIT; no GPL contamination risk anywhere in the core (the dual-licensed `ScintillaCocoa.mm` is the only subtle gotcha).
- **Long horizon** — 27 years of continuous releases. CM6 itself is 4 years old (post-stable, 2022).
- **Doesn't depend on WebKit's behaviour** — WKWebView quirks (focus, scrolling rubber-band, contextual menu suppression) are not your problem.
- **Better story for "absolute" plain-text performance** on 100+ MB log files (within its line-length limits).

## 4. Where **CodeMirror 6** beats Scintilla

- **Existence of a credible Swift-app precedent** (MarkEdit), shipping at 4 MB, with screenshots / source you can copy. Scintilla on macOS has Nextpad++ — Obj-C++, not SwiftUI.
- **Modern multi-cursor / column-select polish**. Scintilla's multi-selection is functional; CM6's is industry-standard.
- **Lezer-based syntax highlighting is AST-aware** — better for hover, references, rainbow brackets, semantic actions. Scintilla lexers are regex state machines.
- **First-class LSP** — official `@codemirror/lsp-client` plus three vetted community libs. Scintilla has one experimental third-party fork.
- **Markdown ecosystem is unmatched** — `@codemirror/lang-markdown` parses GFM, embedded code-block syntax (so `js` block inside markdown gets JS highlighting). Scintilla's markdown lexer is basic.
- **Build pipeline is decoupled from Xcode** — `npm run build` produces a vendored `.js`; no C++ toolchain to maintain in the iOS/Mac project. Xcode-side, you ship one resource file.
- **No C++ ↔ Swift bridge pain**. Module maps, Obj-C++ shims, namespace `Scintilla::` exposure issues [1] all go away.
- **Async by default matches Swift concurrency** — `await webView.evaluateJavaScript()` is idiomatic; sync C callbacks fight `@MainActor`.
- **Tree-shaking** — you pay only for what you import.
- **Community velocity** — extensions land weekly across the CM6 ecosystem; Scintilla is more glacial.

## 5. Six-month risk per option

- **Scintilla risk:** You'll have built a working `ScintillaCocoa` view in 2–4 weeks, then spend the next 5 months bridging modern Mac affordances (LSP, semantic highlight, multi-cursor that matches Xcode, search UI that matches `NSTextFinder`) that the CM6 ecosystem hands you free. The bridge maintenance — Obj-C++ shim, lexer rebuilds, signing the `.dylib` separately, `SCNotification` plumbing for every editor feature — accumulates. *Most likely thing that bites you: a CJK IME composition bug or a tree-sitter-equivalent semantic highlighting requirement, with no upstream path to fix.*
- **CodeMirror 6 risk:** WKWebView focus / IME / drag-drop / system Find UI edge cases — exactly the ones MarkEdit has documented patches for. *Most likely thing that bites you: an IME bug on a specific macOS minor version, or a `WKScriptMessageHandler` latency spike under heavy load, or the JS bridge serialisation cost becoming visible on multi-megabyte paste/format operations.* Mitigations are well-known and well-Googled.

## 6. Recommendation

**Stay with CodeMirror 6. Do not interrupt the in-flight implementation.**

Conditions under which you should reconsider Scintilla:
- You drop SwiftUI/Swift and rewrite the shell in Objective-C++ (you won't).
- You commit to opening 1 GB+ plain-text log files as a flagship feature (you haven't).
- You need to render 50+ simultaneous editor panes in one window (memory pressure flips the equation).
- You decide LSP integration doesn't matter for the next 18 months (it does — see project's `docs/LSP_*`).

Conditions under which CM6 stays the right call (all currently true):
- MIT license is mandatory. (CM6: yes; Scintilla: HPND is permissive but with the dual-licensed `ScintillaCocoa.mm` caveat.)
- Bundle ≤ 25 MB. (CM6 < 1 MB JS + assets; Scintilla ~3–5 MB native libs — both fit, CM6 with more headroom.)
- Mac-native feel not required. (CM6's WebKit-based IME/spell-check is actually *better* than ScintillaCocoa's documented IME bugs.)
- Markdown is the primary target. (CM6's `@codemirror/lang-markdown` + MarkEdit precedent are decisive.)
- LSP-aware future. (CM6 has it; Scintilla doesn't.)

**Caveat for the in-flight CodeMirror agent:** No course correction needed based on this research. The single thing to keep an eye on, independent of editor choice, is **per-message bridge cost**. Batch state mutations across the `WKScriptMessageHandler` boundary instead of one-message-per-keystroke; pre-bundle the JS rather than loading from disk per-editor; consider a single shared WebView with multiple CM6 instances if multiple editor panes are needed (one WebContent process can host many editors).

---

## 7. References

1. Neil Hodgson on `scintilla-interest` re: Swift bridging — `https://groups.google.com/g/scintilla-interest/c/5kVw7Vizgns`
2. Scintilla License (HPND-style) — `https://www.scintilla.org/License.txt`
3. `ScintillaCocoa.mm` dual LGPL-2.1 + Scintilla — header comment in `cocoa/ScintillaCocoa.mm` (e.g. `https://github.com/LuaDist/scintilla/blob/master/cocoa/ScintillaCocoa.mm`)
4. Lexilla — `https://www.scintilla.org/Lexilla.html`; `https://github.com/ScintillaOrg/lexilla`
5. CodeMirror license — `https://github.com/codemirror/dev/blob/main/LICENSE`
6. CodeMirror bundle size discussion — `https://github.com/codemirror/dev/issues/760`; `https://discuss.codemirror.net/t/minimal-setup-because-by-default-v6-is-50kb-compared-to-v5/4514`
7. CodeMirror bundling example — `https://codemirror.net/examples/bundle/`
8. MarkEdit — `https://github.com/MarkEdit-app/MarkEdit/wiki/Why-MarkEdit`; size + 10 MB MD claim same source
9. Scintilla `SplitVector` / `CellBuffer` (split-buffer) — `https://scintilla.org/ScintillaDoc.html`
10. Notepad++ large-file behaviour — `https://10scopes.com/fix-notepad-cannot-open-large-files/`; `https://community.notepad-plus-plus.org/topic/16960/text-limit`
11. Marijn Haverbeke, *CodeMirror data structures* (Sep 2025) — `https://marijnhaverbeke.nl/blog/`
12. Scintilla documentation (search, multi-selection, brace highlight, folding, `SCI_FINDTEXTFULL`) — `https://scintilla.org/ScintillaDoc.html`
13. Scintilla SinkWorld performance notes — `https://www.scintilla.org/SWPerformance.html`
14. CM6 perf philosophy thread — `https://discuss.codemirror.net/t/cm6-performance-benchmarks/2471`
15. CM6 million-line demo — `https://codemirror.net/examples/million/`
16. Scintillua (Lua/LPeg lexers for Scintilla) — `https://orbitalquark.github.io/scintillua/`
17. CodeMirror language packages npm — `https://www.npmjs.com/package/@codemirror/lang-javascript` etc.
18. CodeMirror `language` infra — `https://github.com/codemirror/language`
19. CodeMirror community packages list (gap analysis: Swift / Go not in official list) — `https://codemirror.net/docs/community/`
20. Scintilla `NSTextInputClient` impl + IME issues — `https://fossies.org/linux/scintilla/cocoa/ScintillaView.mm`
21. Scintilla bug #1881 IME malloc fail — `https://sourceforge.net/p/scintilla/bugs/1881/`
22. WKWebView `WKScriptMessageHandler` latency — `https://blog.persistent.info/2015/01/wkwebview-communication-latency.html`
23. Neil Hodgson GitHub profile (@nyamatongwe) — `https://github.com/nyamatongwe`
24. Scintilla 5.5.8 release Nov 2025 + 5.6.x plans 2026 — `https://groups.google.com/g/scintilla-interest`
25. Lexilla repo stats — `https://github.com/ScintillaOrg/lexilla`
26. Marijn Haverbeke blog (2025–2026 activity) — `https://marijnhaverbeke.nl/blog/`
27. Notepad++ for Mac (community port) — `https://www.macrumors.com/2026/04/29/notepad-plus-plus-editor-comes-to-mac/`
28. Nextpad++ technical details — `https://nextpad.org/about/`
29. SciTE for OS X — `https://www.scintilla.org/SciTE-OSX.html`
30. Scintilla Wikipedia (app list) — `https://en.wikipedia.org/wiki/Scintilla_(software)`
31. Replit code-editor comparison (CM perf) — `https://blog.replit.com/code-editors`
32. Scintilla-LSP experimental — `https://gitlab.com/marcolazzarotto/scintilla-lsp`
33. Scintilla LSP feature request — `https://sourceforge.net/p/scintilla/feature-requests/1330/`
34. CodeMirror LSP clients: official `@codemirror/lsp-client` — `https://github.com/codemirror/lsp-client`; FurqanSoftware — `https://github.com/FurqanSoftware/codemirror-languageserver`; Marimo — `https://github.com/marimo-team/codemirror-languageserver`; JeanJPNM — `https://github.com/JeanJPNM/codemirror-lsp-client`

---

*End of document.*
