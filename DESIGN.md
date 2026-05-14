# Markdown Viewer for macOS — Design Plan

A native macOS viewer (not editor) that opens as a markdown viewer first and expands into a
general-purpose file viewer (plaintext, code, HTML, hex), with git awareness and a Claude Code
activity inspector. Minimum third-party dependencies; prefer Apple-shipped frameworks.

---

## 1. Goals & Non-goals

### Goals
- Native macOS feel: NSWindow tabs, sidebar, toolbar, Quick Look-style snappiness.
- Markdown rendering with code blocks, tables, GFM extensions.
- Tabs, recent-files history, folder picker / file browser (sidebar).
- Right-click "Open in Markdown Viewer" Quick Action on folders and files.
- Live file watching with visible "flash" on changes (tail-like).
- Extensible viewer architecture (plaintext, code with syntax highlighting, HTML, hex later).
- Git awareness: diff overlays, log, status — built incrementally.
- Visualize what Claude Code is doing in a repo (transcript-driven activity timeline).
- Comprehensive testing: unit, headless view, snapshot, full E2E in a VM.

### Non-goals (for now)
- Editing. View-only.
- Cross-platform. macOS 13+ only (clean APIs, native tabs).
- Cloud sync, plugins, marketplace.

---

## 2. Tech Stack — Native Options Compared

| Stack | Native | Deps | Strengths | Weaknesses |
|---|---|---|---|---|
| **Swift + AppKit + SwiftUI (recommended)** | Full | ~0 | Native tabs, NSDocument gives history free, SwiftUI for views | Two paradigms |
| Swift + pure SwiftUI | Full | ~0 | Less code | Tab/document story weaker, less window control |
| Swift + pure AppKit | Full | ~0 | Maximum control | Verbose, dated for new views |
| Catalyst (iOS UIKit on Mac) | Sort of | ~0 | Reuse iOS | Doesn't feel Mac-native; rules out NSDocument |
| Objective-C + AppKit | Full | ~0 | Same as AppKit | No reason to choose over Swift today |
| Electron / Tauri | No | 100s MB | Web ecosystem | Violates "minimize deps" |

**Pick: Swift + AppKit shell + SwiftUI content.** Apple-recommended modern approach.
Use `NSHostingView` to embed SwiftUI in AppKit, and `NSViewRepresentable` for AppKit in SwiftUI.

### Frameworks (all Apple-shipped, $0 deps)
- **Foundation / AppKit / SwiftUI** — shell & UI.
- **WebKit (`WKWebView`)** — render generated HTML for markdown and HTML files.
- **UniformTypeIdentifiers (UTType)** — file-type detection / Quick Actions.
- **CoreServices (FSEvents)** — recursive directory watching.
- **DispatchSource** — single-file fd-level watching.
- **NSDocument / NSDocumentController** — "Open Recent" for free, document state.
- **NSTextView** — plaintext + code viewer (with Attributed strings).
- **NSServices** — Finder right-click Quick Action.
- **XCTest / XCUITest** — testing.

### Small Swift packages (Apple-maintained → counts as "native")
- **`swift-markdown`** (apple/swift-markdown) — CommonMark + GFM AST parser. Phase 1. We walk
  the AST and emit our own HTML for `WKWebView`. ~10k LoC, no transitive deps.
- **`swift-cmark`** is a dep of swift-markdown (also Apple-vendored).

### Third-party committed (Phase 5b)
- **`SwiftTreeSitter`** (ChimeHQ) — Swift wrapper around TreeSitter C library.
- **`tree-sitter-markdown`** + **`tree-sitter-markdown-inline`** — for source-mode highlighting
  of `.md` files and for code-fence **language injection**.
- **Per-language grammars** (added as we expand coverage): `tree-sitter-swift`,
  `tree-sitter-python`, `tree-sitter-rust`, `tree-sitter-go`, `tree-sitter-typescript`,
  `tree-sitter-json`, `tree-sitter-yaml`, `tree-sitter-bash`, `tree-sitter-html`,
  `tree-sitter-c`. Each is a small Swift package wrapping a C grammar (~100 KB–2 MB).

### Third-party committed (testing only — dev deps)
- **swift-snapshot-testing** (pointfreeco) — snapshot tests. Test target only.
- **ViewInspector** — SwiftUI view introspection in tests. Test target only.

### Rejected / deferred
- **libgit2 / SwiftGit2** — **rejected**. Shell out to `/usr/bin/git`; revisit only if a perf
  regression demands.
- **JS markdown libs** (marked, markdown-it) — rejected; pull in `swift-markdown` instead.
- **Highlight.js / Prism / Shiki in WKWebView** — rejected; TreeSitter pre-renders to HTML
  spans at parse time (see §11).
- **Sparkle** — deferred to Phase 9; consider DIY updater first.

---

## 3. High-Level Architecture

```
+---------------------------------------------------------------+
|                    MarkdownViewerApp (target)                 |
|  AppDelegate, NSDocumentController, services registration     |
+----------------------------+----------------------------------+
                             |
        +--------------------+--------------------+
        |                                         |
+----------------+                       +------------------+
| ViewerCore     |  Swift package        | UI Layer         |
|  (logic, pure) |                       |  AppKit+SwiftUI  |
|----------------|                       |------------------|
| FileType       |                       | MainWindow       |
| ViewerRegistry |                       | TabBar           |
| HistoryStore   |                       | Sidebar          |
| FileWatcher    |                       | ViewerPane       |
| MarkdownToHTML |                       | StatusBar        |
| GitService     |                       | ClaudeTimeline   |
| ClaudeLogParser|                       |                  |
+----------------+                       +------------------+
        |                                         |
        +--------------------+--------------------+
                             |
                     +---------------+
                     | ViewerKit pkg |  (protocols, models)
                     +---------------+
```

### Module boundaries (3 Swift packages + 1 app target)
1. **`ViewerKit`** — protocols, models, types. Zero UI imports. Easy to unit-test.
2. **`ViewerCore`** — pure logic: markdown→HTML, file watcher, history, git, Claude parser.
   Depends on `ViewerKit`. No AppKit/SwiftUI. Fully unit-testable.
3. **`ViewerUI`** — SwiftUI views and AppKit glue. Depends on both.
4. **`MarkdownViewerApp`** — the `.app` target. Tiny: just wiring and `@main`.

This split is the single most important decision for testability. ~80% of behavior lives in
`ViewerCore` and runs without a display.

### Core protocols
```swift
protocol Viewer: AnyObject {
    static var supportedTypes: [UTType] { get }
    static var displayName: String { get }
    func load(url: URL) async throws
    func makeView() -> AnyView
}
```
`ViewerRegistry` picks the highest-priority viewer per UTType. Multiple viewers can claim a type;
user can switch from a toolbar segmented control ("Rendered | Source | Hex").

---

## 4. Wireframes

### 4.1 Main window (markdown rendered, folder open)
```
+-------------------------------------------------------------------------------+
|  [<] [>]  [📂] [⟳]    README.md                    [Rendered|Source|Hex] [⚙] |
+------------+------------+---------------------------------------------------+-+
|            | tabs ▶                                                       | |
|  Sidebar   |  README.md ×  | api.md ×  | + new                            | |
|            +--------------------------------------------------------------+ |
| 📁 my-repo |                                                              | |
|  📁 src    |   # Project Title                                            | |
|   📄 a.swift|                                                              | |
|  📁 docs   |   Hello world — *italic* and **bold**.                       | |
|   📄 README.md ◀ open                                                     | |
|   📄 api.md|   ```swift                                                   | |
|  📄 .gitig |   let x = 1                                                  | |
|            |   ```                                                        | |
|            |                                                              | |
|            |   | col | col |                                              | |
|            |   |-----|-----|                                              | |
|            |   |  a  |  b  |                                              | |
|            |                                                              | |
+------------+--------------------------------------------------------------+
|  ● docs/README.md · 4.2 KB · UTF-8 · md  ·  git: 2 changes  ·  watched ●     |
+-------------------------------------------------------------------------------+
```

### 4.2 Sidebar collapsed (single file mode)
```
+-------------------------------------------------------------------------------+
|  [<] [>]   README.md                                  [Rendered|Source]      |
+-------------------------------------------------------------------------------+
|   # Project Title                                                             |
|   ...                                                                         |
+-------------------------------------------------------------------------------+
```

### 4.3 Hex viewer
```
+-------------------------------------------------------------------------------+
| binary.dat                                       [Rendered|Source|Hex] ◀ Hex |
+-------------------------------------------------------------------------------+
|  00000000  7f 45 4c 46 02 01 01 00  00 00 00 00 00 00 00 00  .ELF............|
|  00000010  02 00 3e 00 01 00 00 00  d0 4a 40 00 00 00 00 00  ..>......J@.....|
|  00000020  40 00 00 00 00 00 00 00  78 41 02 00 00 00 00 00  @.......xA......|
|                                                                               |
|  goto: [          ]   find: [          ]   group: [8] cols: [16]              |
+-------------------------------------------------------------------------------+
```

### 4.4 Diff overlay (git)
```
+-------------------------------------------------------------------------------+
| README.md  ●  unstaged                                  [Diff|Rendered]      |
+-------------------------------------------------------------------------------+
|   1   1   # Project Title                                                    |
|   2   2                                                                       |
|   3   -   Old line removed                                                    |
|       3 + New line added                                                      |
|   4   4                                                                       |
+-------------------------------------------------------------------------------+
```

### 4.5 Claude Code activity timeline
```
+-------------------------------------------------------------------------------+
|  Claude Activity · session 2026-05-14 09:12                  [live ●]        |
+-------------------------------------------------------------------------------+
|  09:12  ▶ user prompt           "refactor the auth module"                   |
|  09:12  ⚙ Read  src/auth.swift                                               |
|  09:13  ⚙ Edit  src/auth.swift  +12 -4  ◀ click → open with diff overlay     |
|  09:13  ⚙ Bash  swift test                                                   |
|  09:14  ⚙ Write src/auth_session.swift  +84 -0                               |
|  09:14  ▶ assistant: "Refactored. Tests pass."                               |
|                                                                               |
|  [filter: ⌗file ⌗tool ⌗text]   [scrub ◀━━━●━━━▶]                            |
+-------------------------------------------------------------------------------+
```
The timeline reads JSONL transcripts under `~/.claude/projects/<encoded-path>/`. Clicking a
file-touching event opens that file in the viewer at the diff produced by that edit.

### 4.6 Recent / history palette (⌘O extension)
```
+--------------------------------------------------+
|  Open                                            |
+--------------------------------------------------+
|  🔍 search:  __                                  |
+--------------------------------------------------+
|  Recent files                                    |
|    📄 ~/work/repo/README.md         2 min ago    |
|    📄 ~/notes/2026-05-14.md         today        |
|    📄 ~/work/repo/api.md            yesterday    |
|  Recent folders                                  |
|    📁 ~/work/repo                                |
|    📁 ~/notes                                    |
+--------------------------------------------------+
```

---

## 5. Quick Action — How "Open this folder in app" works

Three complementary mechanisms, all native:

1. **UTI registration** — `Info.plist` declares the app handles `public.folder` and common text
   UTIs. Finder's "Open With…" then shows the app for folders and `.md`/`.txt` files.

2. **NSServices** — `Info.plist` declares a Service named "Open in Markdown Viewer" with
   `NSSendTypes = NSFilenamesPboardType`. Right-click in Finder → Services → Open in Markdown
   Viewer. Free, zero install steps for the user.

3. **CLI helper `mdv`** — small Swift executable in the bundle's `Resources/`. First run offers
   to symlink to `/usr/local/bin/mdv`. `mdv .` becomes the muscle-memory invocation; under the
   hood it uses `NSWorkspace.open(_:configuration:)` to send the URL to the running app.

4. (Optional) **Shortcuts app action** — register an App Intent `OpenInMarkdownViewerIntent` so
   the system Shortcuts app exposes it. Power users wire it to a global hotkey or Stream Deck.

For **App Sandbox + folder access**: capture a security-scoped bookmark on first open, persist
in history store so subsequent launches reopen the folder without re-prompting.

---

## 6. Feature Roadmap (phased)

Each phase = a shippable beta. Stop, dogfood, move on.

### Phase 0 — Skeleton (1–2 days)
- Xcode project, 4 targets (app + 3 packages).
- Empty NSWindow, "Hello".
- CI: GitHub Actions macOS runner builds and runs `swift test`.

### Phase 1 — Markdown MVP (3–5 days)
- Open single `.md` via menu/CLI/Finder.
- Parse with `swift-markdown`, render to HTML, load in `WKWebView`.
- Theming: light/dark following system; CSS in app bundle.
- "Source" toggle (raw `NSTextView`).

### Phase 2 — Tabs, sidebar, history (3–5 days)
- Custom in-app tab bar (more flexible than NSWindow tabs).
- Sidebar = SwiftUI `OutlineGroup` over filesystem; lazy children.
- `HistoryStore` writes JSON to `~/Library/Application Support/MarkdownViewer/history.json`.
- ⌘O command palette.

### Phase 3 — Quick Actions & folder open (2–3 days)
- UTI handlers, NSServices, `mdv` CLI bridge, security-scoped bookmarks.
- App Intents (Shortcuts).

### Phase 4 — File watcher + change flash (2 days)
- `FSEvents` for trees, `DispatchSource` for open files.
- On change: re-render diff against last-rendered snapshot; flash new lines with a yellow→clear
  CSS animation; auto-scroll if user was at bottom (tail mode).

### Phase 4.5 — UnifiedFinder (3 days)
- Replace native find with `FindEngine` + `FinderBar`; unified UI across NSTextView and WKWebView.
- Regex, case/word toggles, match count, prev/next. See §12.

### Phase 4.6 — Cross-file search (3 days)
- `FolderSearchEngine` streams matches across the open folder; side panel groups by file.
- Honors `.gitignore`. See §12.

### Phase 5 — Plaintext / code / HTML viewers
Split into two sub-phases so the engine swap doesn't gate basic functionality.

**5a — Plaintext + minimal code highlighting (2–3 days)**
- Plaintext: `NSTextView` non-editable, monospace, line numbers gutter.
- Code: same view, highlighted via Apple's **`SwiftSyntax`** for `.swift` and a tiny
  regex highlighter for ~8 common languages (Python, JS/TS, JSON, YAML, Bash, Go, Rust,
  Markdown source). Throwaway code; deleted in 5b.
- HTML: `WKWebView` with `file://` base URL, JS disabled by default (opt-in per-tab).

**5b — TreeSitter as the unified highlighter (~1 week)**
- Adopt `SwiftTreeSitter` + grammars (see §2 commitment list).
- Replace 5a's highlighter behind the same `Highlighter` protocol — no view-side changes.
- Pulls three wins at once (see §11):
  1. High-quality highlighting in code files.
  2. Source-mode highlighting for markdown.
  3. Code-fence highlighting **inside the rendered markdown HTML** via language injection
     — `HTMLRenderer` emits `<span class="hl-X">` from spans at parse time.
- Incremental reparse used by the file watcher (Phase 4) for cheap updates.

### Phase 6 — Hex viewer (1–2 days)
- Custom `NSView` (Core Text). Memory-map files; show offset, hex, ASCII columns.
- Goto, find (bytes or text), grouping/cols controls.
- Should easily handle multi-GB files via mmap.

### Phase 7 — Git module (incremental, weeks)
- Step 7a: shell-out `git status` to badge sidebar entries (M/A/D/?).
- Step 7b: `git diff` → render in Diff viewer mode.
- Step 7c: `git log` panel (graph optional).
- Step 7d: staged/unstaged/stash listing.
- Step 7e: maybe swap shell-out for libgit2 if perf matters. Likely not needed.

### Phase 8 — Claude Code activity (3–5 days)
- Watch `~/.claude/projects/` for transcript JSONL.
- Parse messages, identify tool uses (`Read`, `Edit`, `Write`, `Bash`).
- Timeline panel with filters; click an `Edit` event → open file with that diff selected.
- "Repo heatmap": small grid showing which files Claude touched today; click → open.

### Phase 9 — Polish & distribution
- Codesigning, notarization, Sparkle (or self-hosted updater — defer Sparkle if possible).
- DMG via `create-dmg`.
- Crash reporting: built-in `os_log` + maybe `MetricKit`.

---

## 7. Testing Strategy — Four Tiers

| Tier | Tool | Speed | What it tests | Where it runs |
|---|---|---|---|---|
| **1. Unit** | XCTest on `ViewerCore`/`ViewerKit` | ms | Pure logic — parsing, history, watcher state machine, git output parsing, Claude JSONL parsing | `swift test`, CI, local |
| **2. View snapshot** | swift-snapshot-testing | ~100 ms | SwiftUI views rendered offscreen, PNG diffed against golden | CI macOS runner |
| **3. Headless UI behavior** | XCTest + `NSHostingView` + ViewInspector | ~s | SwiftUI views constructed, interactions simulated, no display server | CI macOS runner |
| **4. End-to-end on real macOS** | XCUITest in **tart VM** | ~min | Full app: open file from Finder, click sidebar, see render | Nightly CI / pre-release |

### Tier 1: Unit (target 80% of test value)
Because `ViewerCore` has no UI imports, every behavior is straightforwardly testable:
```swift
func test_markdownTable_rendersAsHTMLTable() throws {
    let html = try MarkdownToHTML().render("| a | b |\n|---|---|\n| 1 | 2 |")
    XCTAssert(html.contains("<table>"))
}
func test_fileWatcher_emitsChangeOnAppend() throws { ... }
func test_history_dedupesAndOrdersByRecency() { ... }
func test_claudeLogParser_extractsEditTool() throws { ... }
```

### Tier 2: Snapshot
```swift
func test_sidebar_emptyState_snapshot() {
    let view = Sidebar(items: [])
    assertSnapshot(matching: view, as: .image(layout: .fixed(width: 200, height: 400)))
}
```
Run on CI's macOS runner — same OS version critical to avoid AA-rendering drift. Pin via runner
version label.

### Tier 3: Headless SwiftUI behavior
ViewInspector lets us do:
```swift
let sut = try Sidebar(items: [.file("a.md")]).inspect()
try sut.list().forEach(0).button().tap()
XCTAssertEqual(model.selected, "a.md")
```
No display required; runs in `swift test`.

### Tier 4: Real-macOS E2E via VM

#### Why a VM at all
Some behavior is only real when the OS is real: Finder right-click Services, drag-from-Finder,
notarization gating, full-screen tab merging, Quick Look integration. Even XCUITest on a CI host
can be flaky if shared.

#### Tool comparison
| Tool | Apple Silicon | CLI snapshots | CI friendliness |
|---|---|---|---|
| **tart** (Cirrus Labs) | Native | Yes | Excellent — designed for CI |
| **UTM** | Native | Manual | OK for local; CLI exists but rough |
| **VirtualBuddy** | Native | Limited | Local-only, GUI-oriented |
| Anka | Native | Yes | Commercial |
| VMware Fusion | Native | Yes | Commercial-ish |

**Pick tart for CI; UTM for ad-hoc exploration.** Both use Apple's `Virtualization.framework`.

#### Workflow
1. **Build golden image once**: a clean macOS, autologin enabled, SSH on, no Spotlight indexing,
   Accessibility prompts pre-approved. Saved as `tart` image `mdv-test-base`.
2. **Per-run**:
   ```
   tart clone mdv-test-base run-$RUN_ID
   tart run --no-graphics run-$RUN_ID &
   wait_for_ssh
   scp MarkdownViewer.app vm:~/
   ssh vm 'open MarkdownViewer.app'
   ssh vm '/path/to/xctestrun ...'         # or AppleScript drivers
   scp vm:~/screenshots/ ./out/
   tart stop run-$RUN_ID
   tart delete run-$RUN_ID
   ```
3. **Drivers**: prefer **XCUITest .xctestrun** bundles copied into VM and run with
   `xcodebuild test-without-building`. Fallback for "Finder right-click" type tests: AppleScript
   via `osascript` — flaky but the only way to drive Finder programmatically.
4. **Visual diffs**: `screencapture -x` on the VM; pixel-diff against goldens. Allow small
   tolerance per OS version.
5. **Speed**: tart snapshot restore ≈ 5 s on M-series. A full smoke suite of ~10 cases ≈ 3 min.

#### What lives in Tier 4 (and what doesn't)
Tier 4 is for **integration with the OS**, not feature coverage. Aim for ≤20 cases:
- Cold launch + open file via `open` command.
- Right-click folder → Services → Open in Markdown Viewer.
- Drag a file from Finder onto the dock icon.
- Reopen after restart, history restored, sandbox bookmarks still valid.
- Notarization gatekeeper accepts the bundle.
- Hex viewer opens a 2 GB file without OOM.
- Quick Look preview extension (if we ship one) renders.

Anything you can test in Tier 1–3, do not test in Tier 4. Treat it as the smoke layer.

### Local UTM workflow
For day-to-day macOS-feature exploration without CI:
- Keep a UTM VM with the same base config.
- Mount the host's build folder into the VM (UTM virtiofs); rebuild on host, run in VM.
- Snapshot before each manual session; revert when done.

### CI shape (proposed)
- **PR**: Tier 1 + Tier 2 + Tier 3 on `macos-14` runner. ~3 min.
- **Main merge**: above + Tier 4 in tart on a self-hosted Apple Silicon Mac mini (or Cirrus
  hosted runners). ~10 min.
- **Nightly**: Tier 4 long-suite (drag-drop, Quick Look ext, full-screen tab merge, gatekeeper).

---

## 8. Risks & Open Questions

| Risk | Mitigation |
|---|---|
| App Sandbox friction with folder access | Security-scoped bookmarks; document if we need to ship un-sandboxed first |
| WKWebView memory on huge markdown | Stream-render in pages; consider NSTextView+custom layout for `.md > 5 MB` |
| Syntax highlighting quality vs. dep weight | Phase 5 decision deferred; start simple |
| Tart on CI requires self-hosted Mac or paid runner | Acceptable; CI minutes for macOS are pricey regardless |
| Claude JSONL format changes | Parser is best-effort; fail-soft; pin format version in tests |
| Quick Action discoverability | Onboarding screen explains all 4 entry points |

### Decisions to make before Phase 1 code
1. macOS minimum version — propose **macOS 14 Sonoma** (clean SwiftUI APIs).
2. App ID & dev team for codesigning.
3. Sandboxed from day one, or escape hatch first? Propose **non-sandboxed dev builds, sandboxed
   release**.
4. Telemetry: none, or opt-in `os_log` aggregation? Propose **none until v1.0**.
5. Distribution: DMG direct, Mac App Store, or both? Propose **DMG direct** to avoid sandbox
   restrictions during early phases.

---

## 9. Repo Layout (target)

```
markdown_viewer/
├── DESIGN.md                       ← this file
├── README.md
├── Package.swift                   ← workspace root for SPM packages
├── App/
│   ├── MarkdownViewer.xcodeproj
│   └── MarkdownViewer/             ← app target, Info.plist, assets
├── Packages/
│   ├── ViewerKit/                  ← models, protocols
│   ├── ViewerCore/                 ← logic
│   └── ViewerUI/                   ← views
├── Tools/
│   └── mdv/                        ← CLI helper, Swift Package executable
├── Tests/
│   ├── ViewerCoreTests/
│   ├── ViewerUITests/              ← snapshot + ViewInspector
│   └── E2E/
│       ├── XCUITests/
│       └── tart/                   ← VM image build scripts, smoke runner
├── .github/workflows/
│   ├── pr.yml                      ← tiers 1–3
│   └── nightly.yml                 ← tier 4
└── docs/
    ├── architecture.md
    ├── testing.md
    └── quick-actions.md
```

---

## 10. Recommended Next Steps

Done:
1. ✅ Locked decisions from §8 (macOS 14, SPM-only, non-sandboxed dev, no telemetry, DMG distribution).
2. ✅ Phase 0.1–0.3 — packages, NSTextView shows a text file, CI workflow in place.

Up next (in order):
3. **Phase 0.4** — `.app` bundle + `Info.plist` so `open -a MarkdownViewer file.md` works. Foundation for Phase 3 quick actions.
4. **Phase 1** — `swift-markdown` → HTML → `WKWebView`, with Source/Rendered toggle.
5. **Phase 2** — tabs, sidebar, history, `⌘O` palette. Pause + dogfood after this.
6. **Phase 3** — UTI handlers, NSServices, `mdv` CLI, App Intents.
7. **Phase 4** + **4.5** — file watcher with change-flash, then UnifiedFinder.
8. **Phase 5a → 5b** — viewers with SwiftSyntax+regex, then TreeSitter wholesale (§11).
9. **Phase 6** hex viewer, **Phase 7** git incrementally, **Phase 8** Claude activity timeline.
10. **Phase 9** distribution.

In parallel: stand up tart base image (it's slow to build, doesn't block any phase but is needed before Tier-4 CI gets useful).

---

## 11. Highlighting Architecture — One Producer, Two Render Surfaces

Once TreeSitter lands (Phase 5b), the project has **two display surfaces** that both
need syntax-highlighted output, and they consume the same span data in different ways.

```
                          ┌────────────────────────┐
                          │  TreeSitter (producer) │
                          │   text → spans         │
                          │   [(range, capture)]   │
                          └──────────┬─────────────┘
                                     │ HighlightSpan[]   (pure data, Sendable)
                ┌────────────────────┴────────────────────┐
                ▼                                         ▼
   ┌────────────────────────┐              ┌─────────────────────────────┐
   │ HighlightedTextView    │              │ HTMLRenderer                │
   │ (ViewerUI)             │              │ (ViewerCore)                │
   │  NSTextStorage         │              │  emits <span class="hl-X">  │
   │  .setAttributes(_,_)   │              │  inside <pre><code>         │
   └──────────┬─────────────┘              └──────────────┬──────────────┘
              ▼                                           ▼
        NSTextView                                    WKWebView
   (code files, source-mode markdown)          (rendered markdown)
```

### Why two paths

Markdown's killer view is the rendered one — headings styled, tables drawn, prose
flowing in a proportional font. That lives in `WKWebView` as HTML+CSS. **Code blocks
inside that page are also HTML**, so their highlighting must be HTML `<span>`s with CSS
classes; you can't drop in an `NSTextView` mid-page.

Code files (`.swift`, `.py`, etc.) and the **Source** toggle on a markdown file are
monospaced views in `NSTextView`. Same TreeSitter spans, applied as
`NSAttributedString` attribute runs.

### Component responsibilities

| Component | Package | Role |
|---|---|---|
| `HighlightSpan` | ViewerKit | `{range: NSRange, capture: String}` — pure data |
| `HighlightTheme` | ViewerKit | Codable mapping `capture → traits` (color, weight, italic). No `NSColor`; abstract trait names so it's testable. |
| `Highlighter` protocol | ViewerCore | `func highlight(_ text: String, lang: Language) -> [HighlightSpan]` |
| `TreeSitterHighlighter` | ViewerCore | Impl. Owns parser, runs queries, returns spans. Supports injections (markdown→rust etc.) |
| `HTMLRenderer` | ViewerCore | Walks `swift-markdown` AST → HTML. On code fences, asks `Highlighter` for spans and wraps text in `<span class="hl-{capture}">`. |
| `HighlightedTextView` | ViewerUI | NSViewRepresentable around NSTextView. Takes text + spans + theme; resolves theme to AppKit attributes; applies to `textStorage`. |
| `markdown.css` | ViewerUI/Resources | Maps `.hl-keyword`, `.hl-string`, … to colors. Light + dark. |

### Why the theme is split (capture → traits → AppKit colors)

Keeps `HighlightTheme` testable without importing AppKit — Tier 1 can assert "this Rust
snippet's `fn` keyword maps to capture `keyword.function`, which the theme says should
be `bold + accentColor`." The conversion to `NSColor` / `NSFont` happens at the view
boundary, where it always would.

### Incremental updates (the real reason TreeSitter)

When the file watcher (Phase 4) sees a change:
1. `TreeSitterHighlighter` does an **incremental reparse** — μs even on huge files.
2. New spans are diffed against the previous set.
3. `HighlightedTextView` calls `textStorage.setAttributes(_:range:)` only on the
   changed ranges; for `WKWebView` we re-render the affected block's HTML.

Any non-incremental highlighter (regex, even SwiftSyntax full-reparse) loses this.

### Migration path from today

`TextDisplayView` (Phase 0.2, in place) is the seed. In 5b it becomes
`HighlightedTextView` by:
- accepting an optional `[HighlightSpan]` param (empty = plain monospaced, today's behavior),
- accepting an optional `HighlightTheme`,
- applying attributes in `updateNSView`.

`ContentView` keeps picking the right viewer per file category; only the parameters change.

---

## 12. Find & Search

### Today (Phase 0.2)
We set `NSTextView.usesFindBar = true`. That gives the native macOS find bar (`⌘F`), with a
gear menu for case-sensitive, whole-word, and **regex** matching. Free, polished, fine.

### Why we'll replace it eventually
Native `NSTextView` find only works inside a single text view. It does not help with:
- **Cross-file search** ("find `TODO` across the open folder").
- **Sidebar filter-as-you-type** ("show only files whose name matches `*.md`").
- **Unified UX between NSTextView and WKWebView** — they have different built-in finders;
  the rendered-markdown view uses `WKWebView.find(_:configuration:)` which doesn't do regex.
- **Result list** — built-in find jumps one match at a time; many users want a side panel
  with all matches.

### Phased plan

**Phase 0–4: stay native.** `usesFindBar` is enough.

**Phase 4.5 (new) — UnifiedFinder (~3 days), lands after the file watcher**
- New component `ViewerCore/FindEngine`:
  - Pure logic. Input: text + query (`literal` / `regex` / `glob`) + flags (case, word).
  - Output: `[FindMatch]` with byte ranges and line/column for display.
  - Uses `NSRegularExpression`; literal/glob paths short-circuit for speed.
  - Fully Tier 1 testable.
- New component `ViewerUI/FinderBar`:
  - SwiftUI overlay at top of the viewer pane.
  - One UI that drives both NSTextView (via `textStorage` attribute runs to mark hits) and
    WKWebView (via injected `<mark>` tags or scroll-to-line on the source).
  - Match count, prev/next, "X of N", current-match highlight.
- Same UI usable from sidebar to filter file list.

**Phase 4.6 — Cross-file search (ripgrep-style, ~3 days)**
- Walks the open folder using FSEvents-cached file list.
- Streams matches into a side panel grouped by file.
- Click → opens file with that match selected.
- Excludes via `.gitignore` parsed by shelling out to `git check-ignore` (already on disk
  for any git repo) or a simple gitignore parser if outside a repo.

### Why split the phases
4.5 is in-file polish — small, low-risk, deletable. 4.6 is a real feature with a UI panel.
We get value from each independently.

### What lives where

| Component | Package | Role |
|---|---|---|
| `FindQuery` (literal/regex/glob + flags) | ViewerKit | Pure data |
| `FindMatch` (range + line/col + matchedText) | ViewerKit | Pure data |
| `FindEngine` | ViewerCore | Runs queries against `String` (single file) |
| `FolderSearchEngine` | ViewerCore | Async stream of matches across a directory |
| `FinderBar` | ViewerUI | The bar UI |
| `SearchResultsPanel` | ViewerUI | Side panel for cross-file results |
| Bridge to `WKWebView` | ViewerUI | Maps source-byte ranges → DOM via line numbers |

### Out of scope
- Find-and-replace (we don't edit).
- Saved searches / search history (defer to v1.1).
- Semantic / fuzzy file finder (`⌘P`-style) — easy to add later but not Phase 4.5.
