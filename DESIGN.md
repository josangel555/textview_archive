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
- **`swift-markdown`** (apple/swift-markdown) — CommonMark + GFM AST parser. Use this rather than
  shipping JS. We walk the AST and emit our own HTML for `WKWebView`. ~10k LoC, no transitive deps.
- **`swift-cmark`** is a dep of swift-markdown (also Apple-vendored).

### Optional third-party (defer; only if needed)
- **swift-snapshot-testing** (pointfreeco) — for snapshot tests only, dev dependency.
- **ViewInspector** — SwiftUI view introspection in tests, dev dependency.
- **libgit2 via SwiftGit2** — only if shelling out to `git` proves too slow.

### Things to deliberately avoid
- JS-based markdown libs (marked, markdown-it) — adds web baggage.
- Syntax-highlighting via Highlight.js — pull in TreeSitter Swift bindings or hand-roll instead.
  (Decision deferred to Phase 4.)

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

### Phase 5 — Plaintext / code / HTML viewers (3 days)
- Plaintext: `NSTextView` non-editable, monospace, line numbers gutter.
- Code: same view + a syntax highlighter. **Decision deferred**:
  - Option A: ship pre-built grammars for ~12 languages via simple regex highlighter (good
    enough, zero deps, ugly for tricky langs).
  - Option B: TreeSitter Swift bindings — high quality, adds C deps.
  - Option C: Highlight.js inside WKWebView — defeats purpose.
  - Tentatively A → B if quality bites.
- HTML: `WKWebView` with `file://` base URL, JS disabled by default (opt-in per-tab).

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

1. Confirm decisions in §8 (macOS version, sandbox stance, distribution).
2. Spike Phase 0 — empty app + 3 packages + CI green.
3. Spike Phase 1 — `swift-markdown` → HTML → WKWebView, side-by-side with source pane.
4. Stand up tart base image in parallel (it takes a while to build a clean macOS image).
5. After Phase 2 (tabs/history), pause: dogfood for a week before adding more.
