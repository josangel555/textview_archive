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

## 7. Testing Strategy — Five Tiers (incl. manual)

| Tier | Tool | Speed | What it catches well | What it can't see |
|---|---|---|---|---|
| **0. Manual smoke** | A checklist + a built `.app` | ~5 min | Drag-and-drop from Finder, native window-tab leakage, Launch Services discovery, accessibility issues, "feels wrong" perception bugs | Slow, can't run in CI, no regression history |
| **1. Unit (pure)** | XCTest on `ViewerCore`/`ViewerKit` | ms | All pure logic: parsing, history, fuzzy matching, git output, Claude JSONL, find engine, file watcher behavior | Anything that depends on `@MainActor` / SwiftUI render loop |
| **1m. Main-actor unit** | XCTest on `ViewerUI` models | ms | `DocumentModel` & `SidebarModel` state transitions, `@Published` correctness, view-mode persistence across tab selection, sidebar cache contract | Pixel layout, gesture order, NSView lifecycle |
| **2. View snapshot** | swift-snapshot-testing | ~300–600 ms each (realistic; ignore "100 ms" iOS-Sim figures) | Visual regressions in SwiftUI views (TabBar empty/loaded/many, palette, sidebar, mode bar) | Behavior over time, gestures, OS-version rendering drift (must pin runner) |
| **3. Headless behavior** | XCTest + ViewInspector | ~s | "Tap the close button → onClose fires" style behavioral assertions on SwiftUI views without a display | Anything that needs a real responder chain (find bar, focus, key events) |
| **4. Real-macOS E2E** | XCUITest in **tart VM** | ~min | Finder right-click → Open With, drag from Finder onto dock, gatekeeper notarization, Quick Look, full app launch | Cost & flake; reserve for OS-integration smoke |

### What's actually wired today (Phases 0–4)
- **Tier 0** — informal so far; this commit lands the formal checklist in `MANUAL_TESTING.md`.
- **Tier 1** — `ViewerCoreTests`, `ViewerKitTests` — ~138 cases; covers all of `ViewerCore`'s production code paths.
- **Tier 1m** — `ViewerUITests` (new) — covers `DocumentModel` open/close/select/reload flows and the `SidebarModel` cache contract (the two places where the most recent bugs hid).
- **Tier 2/3/4** — **not yet wired**; deferred until they pay off (see decision matrix below).

### Why Tier 2/3 are deferred, not yet adopted

We've seen which bugs *actually* slipped past Tier 1 — and almost all of them were either:
1. **SwiftUI side-effect-in-body** patterns (sidebar cache write during render) → caught by **Tier 1m**.
2. **NSViewRepresentable lifecycle quirks** (WKWebView reloading on every body tick) → no tier catches this cheaply except **Tier 0**, because the bug is "blank flash followed by recovery" and a snapshot test wouldn't see it unless we time-skewed.
3. **macOS integration** (Launch Services name lookup, native window tabbing, drag receivers) → only **Tier 0** + **Tier 4** can see these.

Snapshot tests (Tier 2) would have caught zero of the bugs reported so far. ViewInspector (Tier 3) would have caught maybe one (the duplicate `.onTapGesture` in `FileRowView`). Both add a runtime dep and recording/replay infrastructure for marginal ROI right now.

**Decision**: defer Tier 2 and Tier 3 to **after Phase 5b** (TreeSitter), when the UI surface becomes branchier and visual regressions become the dominant failure mode. Until then, double down on Tier 0 + Tier 1m.

### Tier 0 — Manual smoke checklist
Lives in [`MANUAL_TESTING.md`](./MANUAL_TESTING.md). Run before every release-candidate tag. ≤5 min. Catches what tools can't: drag-and-drop, window tabbing, palette focus, native menus.

### Tier 1: Unit (target 80% of test value)
Because `ViewerCore` has no UI imports, every behavior is straightforwardly testable:
```swift
func test_markdownTable_rendersAsHTMLTable() throws {
    let html = HTMLRenderer().render("| a | b |\n|---|---|\n| 1 | 2 |")
    XCTAssert(html.contains("<table>"))
}
func test_fileWatcher_emitsChangeOnAppend() throws { ... }
func test_history_dedupesAndOrdersByRecency() { ... }
func test_claudeLogParser_extractsEditTool() throws { ... }
```

### Tier 1m: Main-actor unit (new, where the *@MainActor* objects live)
```swift
@MainActor
final class DocumentModelTests: XCTestCase {
    func test_open_missingFile_keepsExistingTabAndAppendsError() throws {
        let model = makeModel()
        model.open(url: existingFile)
        model.open(url: ghostFile)
        XCTAssertEqual(model.tabs.tabs.count, 2)   // ← was 0 in the bug
    }
}
```

These run in `swift test` without a display server. The trick: use a fresh
`UserDefaults(suiteName:)` and a temp `HistoryStore` per test so persistence
doesn't bleed across tests.

### Tier 2: Snapshot (when adopted)
```swift
func test_tabBar_threeTabs_snapshot() {
    let model = DocumentModel(...)
    model.open(url: aFile)
    model.open(url: bFile)
    model.open(url: cFile)
    let view = TabBar(model: model).frame(width: 700, height: 30)
    assertSnapshot(matching: view, as: .image)
}
```
Run on CI's macOS runner — pin the runner OS version to avoid AA-rendering drift.

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

---

## 13. Usability Backlog

Captured from a working-session brainstorm. Each item tagged with where it
slots into the phased plan (or is already implicit). Sizes are coarse:
S ≤ ½ day, M = 1–2 days, L = ≥ 3 days.

### Already in place — document, don't re-implement
| Item | Where it lives now |
|---|---|
| **Read-only file reads** | `TextFileLoader` opens with `Data(contentsOf:)` (read-only); `NSTextView` is `isEditable = false`. We never write to opened files. |
| **Window size memory** | `NSWindow.setFrameAutosaveName("MainWindow")` — window position/size already persists per user. |

### Folds into existing phases
| Item | Phase | Size | Notes |
|---|---|---|---|
| **"Open in MarkdownViewer"** (Finder right-click) | 3 | M | Already specified in §5 — NSServices + UTI handlers + `mdv` CLI. |
| **Default-anything Viewer** (be the default app for many text types) | 3 + 9 | M | Phase 3 declares `LSItemContentTypes` for the common text UTIs; Phase 9 considers whether to register with `LSHandlerRank = Default` for select types. **Policy call**: probably *not* default for code files — most users have IDEs. Default for `.md` and binary text logs makes sense. |
| **Drag-and-drop onto window** | 3 | S | `NSWindow.registerForDraggedTypes([.fileURL])`; route to `DocumentModel.open(url:)` from `NSDraggingDestination`. Easy add-on alongside UTI work. |
| **Full Disk Access prompt** | 3 / 9 | S | Add a Settings pane that links to `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFilesAccess`. Only needed if user wants to view files outside sandbox-permitted paths; non-sandboxed dev builds bypass entirely. |
| **Remember sidebar width** | 2.4 | S | Bind `@AppStorage("sidebarWidth")` to the split view's width — couple of lines. |
| **Remember last-open folder / tabs** | 2.4 → Workspaces | M | Persist current `TabsState.tabs[].url` + sidebar root in user defaults; restore on launch. Stub for full Workspaces (below). |

### New phases to schedule

| Phase | Item | Size | Sketch |
|---|---|---|---|
| **2.5 — Split view** | Two viewer panes side-by-side (or stacked) | L | New `PaneSplit` model: either single pane or split (`PaneSplit.split(left, right)` recursive). Each pane has its own `TabsState`. Drag-tab-to-edge gesture opens a split. ⌘D duplicates current tab into a new pane. Window remembers split layout. |
| **5.5 — Format viewer (pretty-print)** | JSON, XML, JS/CSS beautify | M | `Formatter` protocol; viewer toolbar gains a "Format" button when supported. JSON via `JSONSerialization`. XML via `XMLParser` re-emit. JS minified — `JSContext` runs `prettier` (vendored) headlessly **or** simpler `js-beautify` (~30 KB JS). HTML pretty-print via swift-html-formatter or a small re-emit. **Decision**: keep JS-format JS-free if possible; investigate native pure-Swift formatters first. |
| **6.5 — Bookmarks** | Pin files/folders into a Bookmarks sidebar section | S–M | Extend `HistoryStore` → split `recents` from `pinned`. Sidebar gets a "Bookmarks" header above the tree. ⌘D bookmarks current file. Drag to reorder. Persist alongside history JSON. |
| **8.5 — Workspaces** | Save & restore named sessions | L | A workspace = `{ sidebarRoot, tabs[(url, viewMode)], sidebarWidth, splitLayout, activeTab }`. Stored as JSON. UI: ⌘⇧S "Save Workspace As…", File ▸ Workspaces ▸ submenu. Builds on every prior phase — schedule after tabs/sidebar/split/git all settle. |

### Smaller polish items (no dedicated phase; queue as side tasks)

- **Show full path** in title strip — **done** today (this commit).
- **Quick Look space-preview** of selected sidebar file.
- **Reveal in Finder** menu item on a tab/sidebar entry (`NSWorkspace.activateFileViewerSelecting`).
- **Copy path** / **Copy contents** context menu on tab and sidebar rows.
- **Print** rendered markdown via `WKWebView.printOperation`.
- **Export Rendered to PDF** via `WKWebView.createPDF`.
- **Goto line / column** for source mode (`⌘L`).
- **Reload** current file from disk (`⌘R`) — separate from view-mode toggle (which is `⇧⌘R`).

### Priority ordering for what should slot in soon

After Phase 2.4 (palette), the next "value per hour" wins are likely:
1. **Drag-and-drop + UTI** (Phase 3) — biggest UX uplift; people will drag files onto the dock icon almost immediately.
2. **Reveal in Finder + Copy path** — 30 minutes of work, removes daily friction.
3. **Reload from disk** — 30 minutes, needed before/while watcher is built.
4. **Remember sidebar width + last-open folder** — 1 hour.

Workspaces, Split view, Format are all great but should wait until the core is dogfooded for a few sessions.

---

## DocumentModel coordinator pattern (2026-05-25 split)

`DocumentModel` was a 2377-LOC, 71-`@Published`, 107-method god
object. Split into three child `@MainActor ObservableObject`
coordinators, each owning one cohesive domain. DocumentModel
stays as the aggregate ObservableObject + the home of cross-cutting
state that doesn't fit a single coordinator (sidebar reference,
LSP pool, bookmarks, zoom, theme, walkthrough bridge, history).

### `FindCoordinator`

Owns the three find-mode bags — rendered (WKWebView markdown find),
source (NSTextView find), editor (CM6 find). Each bag exposes
`query`, `caseSensitive`, `isRegex` (where applicable), `matched`,
`matchSummary`, `nextRequest`/`prevRequest`/`focusRequest` request-
nonce counters, plus `matchLines` + `currentMatchIndex` for the
source bag.

`commit` from request-nonces happens through methods on the
coordinator; views observing the request-nonce see one bump per
user-pressed Next/Previous. `setMatchSummary(_:)` dedupes on equal
value to avoid spurious republishes.

### `TabCoordinator`

Owns `tabs` (`TabsState`), the open/openInNewTab/openInSplit/
closeTab/closeOtherTabs/closeTabsToRight family, `openTabURLs`,
`splitURL`, and 6 per-tab dicts (`csvFilterStates`,
`hexBytesPerRow`, `languageOverrides`, `formattedTabIDs`,
`formattedTextCache`+`Order`, `editorBuffers`). The
`materializeTasks` slot is also per-tab.

**`addCloseHook(_:)`** is the canonical extension point for any
new per-tab subsystem. Register a hook in `init`; the hook runs
inside `cleanupAfterClose(id:)` which is called by every close path.
Don't enumerate per-tab dicts per-path; subscribe to the hook.

### `EditorCoordinator`

Owns CM6 editor-mode state: `editorGotoLine`, `editorIndentation`,
`saveEditorOnBlur`, `editorCursorByTab`, `editorScrollByTab`,
`pendingEditorDiagnostics`. Owns `saveActiveEditor()` / `saveEditor(forTabID:)`
plus close-prompt routing (`confirmCloseIfDirty(at:)`) and
external-edit conflict (`presentExternalEditConflict(...)`).

Test seams: `dirtyClosePromptOverride`, `externalEditPromptOverride`
let tests bypass the NSAlert calls. Injected effect closures
(`onPauseFileWatcher`, `onResumeFileWatcherIfApplicable`,
`onReloadFromDisk`, etc.) keep the coordinator headless-testable
without dragging FileWatcher state into the coordinator.

`editorBuffers` lives on `TabCoordinator` (single cleanup fan-out);
EditorCoordinator references it via `tabsSnapshot` / etc.

### Forwarder discipline

Every public DocumentModel API moved to a coordinator gets a thin
forwarder kept on DocumentModel. Existing call sites don't change;
new code can call through either surface. The forwarders are
plain getters/setters into the coordinator — no caching, no extra
state.

When you grep "where is X mutated," you'll see both the coordinator
mutation and the DocumentModel forwarder. The forwarder is
authoritative for the public API; the coordinator is the home of
the state. Tests cover both paths.

### Republish-invariant test pattern

For each coordinator, a `*RepublishInvariantTests.swift` pins the
contract: mutating a field on the coordinator fires `objectWillChange`
on the coordinator only, **never** on DocumentModel.

```swift
let count = countDocumentRepublishes(while: {
    coord.someField = newValue
})
XCTAssertEqual(count, 0)
```

`countDocumentRepublishes(while:)` is in
`Tests/ViewerUITests/TabRepublishInvariantTests.swift`. Each
invariant suite also has at least one **negative-control** test
that asserts a real DocumentModel mutation still does fire
`objectWillChange` — guards against "publisher silently disabled."

This pattern caught two regressions during the original splits and
one during the recent EditorCoordinator extraction; mirror it for
any future coordinator.

### Why this matters

Before: a keystroke in cross-search field re-evaluated every TabBar
row body; a tab rename re-rendered the editor; CrossSearchPanel
re-rendered on tab close. After: each domain's republishes are
scoped to that domain's observers. Quantifiable per-domain wins are
pinned by the invariant tests.

## CM6 editor architecture

CodeMirror 6 hosted in a `WKWebView`. The bundle is vendored under
`Sources/ViewerUI/Resources/codemirror/` (HTML/JS/CSS); the build
recipe lives in `scripts/codemirror-build/` (npm + esbuild;
no `node_modules` in the runtime app).

### Bridge protocol — versioned envelope

`{v: 1|2, type: "…", replyId?: int, …}`. All messages encoded by
`CMBridgeCodec` (`Sources/ViewerCore/CodeMirrorBridgeV1.swift`).

- `v=1` baseline: every JS→Swift / Swift→JS message goes through
  one shape: `webView.evaluateJavaScript("window.cmDispatch(\(JSON))")`
  for outbound, `WKScriptMessageHandler("mdvEditor")` for inbound.
- `v=2` adds `incrementalChange` (inbound, edit batches) +
  `applyEdits` / `setFoldingRanges` / `setGutterMarkers` /
  `setIndentGuides` (outbound).
- Unknown types decode to `.unknown` (forward-compat); the receiver
  ignores the message instead of crashing.

### JS-safe JSON

`Sources/ViewerCore/JSStringEmbedding.sanitize` is the single source
of truth for embedding JSON in `evaluateJavaScript`. Escapes
U+2028 / U+2029 (LINE/PARAGRAPH SEPARATOR) since `JSONSerialization`
doesn't. **Don't `evaluateJavaScript` JSON without going through this.**

### Incremental change applier

`Sources/ViewerCore/CMEditApplier.swift` replays JS-batched
ChangeSet edits Swift-side. UTF-16 indexed, rejects overlap/OOB.
On length drift Swift requests `flushChanges` → falls back to v1
full-text `setText`.

### Editor-mode lifecycle

Owned by `EditorCoordinator`. ⌘S routes through both the macOS menu
item AND the CM6 JS-bridge `saveRequested` message (the in-WebView
keystroke). Dirty state shows as a dot on the tab title. External
edits while dirty trigger `presentExternalEditConflict` (NSAlert).

50 MB hard cap on Editor mode — larger files render
`LargeEditorPlaceholderView` instead. Cap pinned by tests.

## Process-running pattern

`Sources/ViewerCore/ProcessRunner.swift` is the canonical
`Process + Pipe + drain` helper. Used by `GitClient`, `JQRunner`,
`PluginSubprocessHost`, `LSPDiscovery`. Don't reimplement; if you
need a new shape, extend the helper.

`PluginSubprocessHost` additionally applies env-scrub +
`setrlimit`-style discipline. LSP / git / jq don't yet — see
BACKLOG.

## Security model

Documented in detail in `docs/code-review/SECURITY_CONCURRENCY_2026-05-25.md`.
Key invariants now enforced:

- **URL scheme containment** (`URLSchemePolicy`): `markdownviewer://open?path=…`
  rejects paths outside `$HOME ∪ $TMPDIR`.
- **Walkthrough drop transport** requires `TV_WALKTHROUGH_DROP=1`
  env var. Defaults off.
- **HTML sanitizer** (`HTMLSanitizer`): allowlist for user-supplied
  HTML rendered to WKWebView. CSP becomes defense-in-depth.
- **Regex complexity guard** (`RegexComplexityGuard`): nested-quant
  + overlapping-alt detection on `FindEngine` + MCP `find` input.
- **EditorWriter symlink refuse**: `Data.write(.atomic)` would
  follow symlinks (TOCTOU). Default-deny; `allowSymlink:` opt-in.
- **LSP binary ownership**: refuse group/world-writable lookup
  dirs (`~/.npm-global/bin` was unfiltered).
- **Audit dir perms 0o700**: plugin grant store + walkthrough drop.

## Multi-agent dispatch workflow

Worktree-isolated parallel agents are the standard for any
multi-file change exceeding ~200 LOC.

- `isolation: "worktree"` for code-changing agents. Each lands on
  its own branch.
- Orchestrator merges with `git fetch ./.claude/worktrees/agent-XXXX
  <branch>` + `git merge --no-ff FETCH_HEAD`.
- **Agents must commit incrementally**, not at the end. Worktrees
  can be pruned on agent completion; uncommitted work has been
  lost more than once.
- **Coexistence via marker comments**: when two agents touch
  overlapping files, brief them with `// MARK: - feature-X
  (agent-name)` conventions so merges are mechanical.

## Subagent prompt discipline

Per `/Users/me/.claude/CLAUDE.md`: research / exploration agent
prompts must be **generic** — goal + constraints + coexistence
context. Don't pre-bake a hypothesis or a numbered scenario list;
let the agent surface unknowns. Prescriptive prompts are reserved
for focused mechanical fixes where the cause is already known.

The exception is *executing an already-decided plan* — those
agents get the plan + constraints, but still don't get pre-baked
file paths or sub-decision trees (those belong to the agent's
own choices). Example: the FindCoordinator / TabCoordinator /
EditorCoordinator extractions each got the user-locked scope (E2
+ J), constraints, and pattern references — they chose their own
file layout, test grouping, and per-feature ordering.

