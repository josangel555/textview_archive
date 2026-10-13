# Testing

The full multi-tier strategy is in [`DESIGN.md` §7](./DESIGN.md). This file is
the **running view**: what exists today, how to run it, what to add next.
The manual smoke checklist for things tools can't see is
[`MANUAL_TESTING.md`](./MANUAL_TESTING.md).

## Tiers (current state)

| Tier | Tool | Status | Runs in CI? |
|---|---|---|---|
| **0. Manual smoke** | [`MANUAL_TESTING.md`](./MANUAL_TESTING.md) checklist | ✅ documented; ~5 min/run | No — pre-release only |
| **1. Pure unit** | XCTest on `ViewerCore` / `ViewerKit` | ✅ ~200 cases | Yes (every push) |
| **1m. Main-actor unit** | XCTest on `ViewerUI` (`DocumentModel`, `SidebarModel`) | ✅ ~40 cases | Yes (every push) |
| **1m+. Hosted view (structural)** | XCTest + `NSHostingView`, walk NSView subtree | ✅ `ContentViewHostingTests` | Yes |
| **1m+. Hosted view (pixel)** | XCTest + `SwiftUI.ImageRenderer`, sample pixels | ✅ `ContentViewPixelTests` | Yes |
| **4. Live-app launch** | XCTest + `Process` + `osascript` AX queries on running `.app` | ✅ `LiveAppLaunchTests`; auto-skips without Accessibility permission | Local + nightly with Accessibility |
| **2. SwiftUI snapshot (PNG golden)** | swift-snapshot-testing | ⏸ deferred (see DESIGN.md §7) | — |
| **3. Headless ViewInspector** | ViewInspector | ⏸ deferred | — |
| **Tier 4 VM** | XCUITest in tart VM | ⏸ Phase 17 infra task, nightly only | Nightly only |

### What each tier catches

| Bug class | Tier that catches it |
|---|---|
| Pure logic regression (parsing, history, fuzzy, find, git output) | **1** |
| `@MainActor` state-machine drift (e.g. "vanishing tabs") | **1m** |
| SwiftUI view fails to construct, misses a state | **1m** |
| NSView hierarchy missing or zero-sized after `model.open(...)` | **1m+ structural** |
| Views structurally present but visually empty/transparent | **1m+ pixel** |
| Real-app window off-screen / wrong size after launch | **4 live-app** |
| AppDelegate sequencing bugs (argv, application(_:open:)) | **4 live-app** |
| Visual pixel regression on a specific layout | **2 snapshot** (deferred) |
| Gesture / focus / responder chain | **3 ViewInspector** (deferred) |
| OS-integration smoke (Finder Services, Quick Look) | **4 VM** (deferred) |

The pixel + live-app tiers were added after the "source view shows only line numbers" regression — they're the layers that would have caught it before the user did.

## How to run

```sh
swift test                                      # whole suite (~2s)
swift test --filter ViewerKitTests              # one target
swift test --filter ViewerUITests.SidebarModelTests   # one suite
swift test --filter ViewerCoreTests.DocumentControllerTests/test_oversizedFile_reportsSizeInMB
swift test --parallel                           # what CI runs
bash scripts/verify-app.sh                      # bundle structural checks
# Manual: open MANUAL_TESTING.md and walk through pre-release
```

## Current coverage (post-bug-sweep)

**Tier 1 (`ViewerCoreTests` + `ViewerKitTests`) — 151 cases**

| Suite | Cases | What's asserted |
|---|---|---|
| FileTypeDetectorTests | 7 | extension → FileCategory, UTType fallback, extensionless treatment |
| InfoPlistTests | 8 | bundle schema (required keys, doc types incl. folder, version shape) |
| TextFileLoaderTests | 5 | UTF-8 + Latin-1 fallback, size cap, missing file, empty file |
| DocumentControllerTests | 4 | URL → DocumentState mapping + human messages |
| HTMLRendererTests | 20 | every CommonMark + GFM construct, escaping, page wrapper |
| HistoryStoreTests | 13 | record/dedupe/normalize/cap/persistence/corrupt recovery |
| TabsStateTests | 19 | every TabsState mutation + selection edge case |
| FileTreeServiceTests | 9 | sort + hidden + error paths |
| FuzzyMatcherTests | 12 | match scoring (boundary, consecutive, prefix), filter() |
| PreferencesStoreTests | 7 | sidebar width clamp + folder URL persistence |
| FileWatcherTests | 4 | write fires, atomic-write re-attach, stop prevents further fires |
| FindEngineTests | 16 | literal / regex / case / whole-word / line-col / next-match wrap |
| GitServiceTests | 14 | isGitRepo, repoRoot walk, status parsing, live repo round-trip |
| ClaudeLogParserTests | 13 | string + array content, tool_use, tool_result, multi-line, malformed |

**Tier 1m (`ViewerUITests`) — 23 cases**

| Suite | Cases | What's asserted |
|---|---|---|
| DocumentModelTests | 15 | open/reuse/duplicate, missing-file regression, tab selection edges, view-mode per-tab, reload, openFolder, sidebar-width clamp + persistence |
| SidebarModelTests | 8 | cache-only `children(of:)` contract, ensureLoaded, hidden-toggle refresh, root rotation clearing |

**Tier 0 (manual)**

[`MANUAL_TESTING.md`](./MANUAL_TESTING.md) — 10 sections, ~5 min total. Run pre-release.

**Build-system tests**

`scripts/verify-app.sh` — 17 structural assertions on the assembled `.app`
(executable bit, plist lint, required keys, doc type UTIs incl. folder,
SPM resource bundle + `markdown.css`).

**Total: 509 swift cases, ~85 s. Plus bundle verify script + manual checklist.**

**Test catch-up (Batches A / B / C) — added after the autonomous-batch
series shipped without tests:**

| Suite | Cases | Covers |
|---|---|---|
| TextSearchTests | 16 | literal + regex paths in `SourceTextController.findRanges`: empty, case-insens default, regex invalid pattern, anchors-match-lines, zero-width match, unicode `\w`, summarize n/N format |
| PreferencesStoreTests (+10) | — | `uiScale` clamp on read + write, default, bounds; `showInvisibleChars` + `sourceWordWrap` round-trip |
| DocumentModelTests (+11) | — | windowTitle default = "TextView", `uiScale` seed + persist, `uiSize(base)`, `showInvisibleChars` seed + toggle, `sourceFindIsRegex`, HEX state routing from `.loaded`, HEX→Source back-conversion, HEX persists across file switch (regression), `bookmarkTargetURL` precedence |
| GitClientTests (+4) | — | `diff(forPath:)` unified format, color stripping, missing path, paths with spaces |
| FileIconClassifierTests (+2) | — | folder-state precedence: gitRoot beats locked/hidden/expanded; symlink beats gitRoot |
| RecentChangesDiscoveryTests | 5 | `discoverRepo(sidebarRoot:currentURL:)` — fallback to current file's parent when sidebar root nil; sidebar wins when both set |
| MetadataPanelTests | 10 | `filesystemRows(url:attrs:)` pure builder — size formatting, dyn UTI for unknowns, date row presence, label ordering |
| SQLiteWidthTests | 8 | `ResultTableView.computeWidths(...)` — 80pt floor, 320pt cap, ragged rows, sample-size bound, header-only width, nil cells |
| FolderStateSymbolTests | 3 | every `FolderState.symbol` resolves to a valid SF Symbol; states are visually distinct |
| BookmarksStoreTests (+1) | — | folder URLs round-trip through `contains` |
| InfoPlistTests (+3) | — | `CFBundleName=TextView`, `CFBundleIdentifier` stays stable, `AppIcon` declared, TCC strings mention TextView, NSServices entry has `openInTextView` + accepts `public.file-url` |


## What each tier *won't* find — and the workaround

Read this before adding a Tier 2/3 dep "just in case":

| Bug type | Caught by | Example |
|---|---|---|
| Pure logic error | Tier 1 | Wrong fuzzy score formula |
| @MainActor state-machine drift | Tier 1m | "Vanishing tabs" — actually caught by `test_open_missingFile_keepsExistingTabAndAppendsError` |
| Side-effect inside SwiftUI body | Tier 1m on the model (contract pivot) | Sidebar `children(of:)` was writing to cache from `body` |
| Visual regression (layout broke) | Tier 2 once adopted; Tier 0 today | Tab bar height accidentally doubled |
| Gesture handler order / surface | Tier 3 once adopted; Tier 0 today | Duplicate `.onTapGesture` swallowing taps |
| NSViewRepresentable lifecycle | Tier 0 (or careful code review) | WKWebView reloading on every body re-render |
| OS integration (drag, Services, launch) | Tier 0 + future Tier 4 | Native window-tabs menu leaking |

## What is *not* yet tested

| Surface | Why deferred |
|---|---|
| `TextDisplayView` `NSTextView` configuration | Need ViewInspector or snapshot tier — Phase 2 |
| `DocumentModel` state transitions | Trivially correct now; revisit when it owns more (history, tabs) |
| `AppDelegate` menu + window wiring | Needs Tier 4 VM E2E — Phase 3+ |
| File argument handling at launch | Tier 4 |
| Markdown AST → HTML rendering | Lands with Phase 1; Tier 1 (compare emitted HTML to fixture strings) |
| `HighlightSpan` production (TreeSitter) | Phase 5b; Tier 1 (input source → expected `[span]`) |
| `HTMLRenderer` span injection | Phase 5b; Tier 1 (input MD with fence → output HTML contains expected `<span class="hl-…">`) |
| `FindEngine` regex / literal / glob | Phase 4.5; Tier 1 with golden inputs |
| `FolderSearchEngine` async stream | Phase 4.6; Tier 1 using a temp directory tree |

## Conventions

- **`ViewerCore` and `ViewerKit` must stay UI-free.** No `import AppKit` /
  `SwiftUI` there. This is what keeps Tier 1 cheap.
- **Tests own their temp dirs.** Each test creates a fresh
  `MarkdownViewerTests-<UUID>` directory and removes it in tearDown. Never
  write to a fixed path.
- **Tests own their UserDefaults.** Use `UserDefaults(suiteName: UUID().uuidString)` and clean up in tearDown — never read/write `.standard` from a test.
- **No mocks in Tier 1.** Inject real `TextFileLoader` / `FileTreeService` / `GitService` instances; they're fast and the file system is the integration we want to exercise. The two existing injectable seams (`HistoryStore.clock`, `PreferencesStore.defaults`) exist where genuine non-determinism would otherwise bleed in.
- **Tests with `@MainActor` objects mark the class `@MainActor`.** All `ViewerUITests` cases are main-actor.
- **One file per type.** Tests mirror source layout
  (`Sources/Foo/Bar.swift` → `Tests/FooTests/BarTests.swift`).
- **Regression tests cite their bug.** When a fix lands, the test that would have caught it gets a comment referencing the symptom — see e.g. `DocumentModelTests.test_open_missingFile_keepsExistingTabAndAppendsError`.

## CI

`.github/workflows/pr.yml` runs `swift build` + `swift test --parallel` on
`macos-14` on every push to `main` and every PR.

## Test file inventory (by coverage area)

When picking up a test, use this map to find adjacent prior art
rather than rediscovering test patterns.

### ViewerKitTests
| File | Covers |
|---|---|
| `InfoPlistTests.swift` | Bundle schema, required keys, doc types, **NSServices entry** (Open in TextView), TCC usage strings reference TextView, AppIcon declared. Stale-anchor protection: if you rename the display name, this test catches it. |
| `FileCategoryMediaTests.swift` | Smoke: extension → FileCategory for image/audio/video/PDF/sqlite |
| `FileTypeDetectorTests.swift` | Extension table + UTType fallback + extensionless handling |

### ViewerCoreTests (pure, instant)
| File | Covers |
|---|---|
| `BinaryFileLoaderTests.swift` | Byte read, size cap |
| `BookmarksStoreTests.swift` | File + folder bookmarks (line bookmarks in separate file) |
| `LineBookmarksTests.swift` | `(URL, line)` semantics, legacy on-disk JSON decode (no `line` field → nil) |
| `ClaudeLogParserTests.swift` | All Claude transcript JSONL shapes |
| `CrossFileSearchTests.swift` | Async stream, symlink loop guard, cancel race |
| `CSVParserTests.swift` | Delimiter detection (tab/comma/semi/pipe), quoting, embedded commas/newlines, CRLF, ragged rows |
| `DocumentControllerTests.swift` | URL → DocumentState routing |
| `DocumentControllerMediaTests.swift` | Image/audio/video/PDF/sqlite → .preview state |
| `FileIconClassifierTests.swift` | Two-system chips + glyphs; folder-state precedence (symlink > root > locked > hidden > expanded) |
| `FileTreeServiceTests.swift` | Sort + hidden + errors |
| `FileWatcherTests.swift` | Write fires; atomic-write re-attach; stop prevents further fires |
| `FindEngineTests.swift` | Literal / regex / case / whole-word / next-match wrap |
| `FormatterTests.swift` | Pretty-print per format |
| `FuzzyMatcherTests.swift` | Scoring rules + filter() |
| `GitClientTests.swift` | discoverRoot, status, **diff (unified format, color-stripped, paths with spaces)** |
| `GitServiceTests.swift` | Porcelain v1 parsing, repoRoot walk |
| `HexViewSizingTests.swift` | Address column digits + row-count math |
| `HistoryStoreTests.swift` | Record / dedupe / normalize / cap / persistence / corrupt recovery |
| `HTMLRendererTests.swift` | Every CommonMark + GFM construct + escaping + page wrapper |
| `IndentDetectorTests.swift` | Tabs / spaces(N) / mixed |
| `PreferencesStoreTests.swift` | All prefs: sidebar width / zoom / lastFolder / sourceWordWrap / showInvisibleChars / uiScale (clamp on read **and** on write) |
| `SQLiteReaderTests.swift` | Read-only open, schema introspection, query bounds |
| `TabsStateTests.swift` | Every TabsState mutation + selection edge |
| `TextFileLoaderTests.swift` | UTF-8 / Latin-1 / UTF-16 (with and without BOM) / size cap / empty / missing |
| `TreeSitterEngineGoldenTests.swift` | Per-language token golden output + ABI smoke |
| `TreeSitterEngineSmokeTests.swift` | Engine boots, all v1 grammars tokenize |
| `WorkspaceStoreTests.swift` | JSON snapshot round-trip |
| `DiffHunkParserTests.swift` | `git diff` text → `[Int: DiffMark]`; multi-hunk; no-newline marker; malformed-header tolerance |
| `DiffHighlighterTests.swift` | Diff text → `[HighlightRun]`; `+++`/`---` distinguished from `+`/`-`; CRLF |

### ViewerUITests (main-actor, in-process)
| File | Covers |
|---|---|
| `AppLauncher.swift` | Helper for Tier 4 launches |
| `BookmarkIntegrationTests.swift` | Bookmark UX state transitions |
| `BookmarkLineCacheTests.swift` | `bookmarkedLines(for:)` memoization + invalidation |
| `ComponentVisualTests.swift` | Tier 1m+ pixel — sample RGB at specific coords |
| `ContentViewHostingTests.swift` | Walks `NSHostingView` subtree to verify structure |
| `CrossSearchIntegrationTests.swift` | End-to-end cross-search behavior |
| `DiagnosticDumpTests.swift` | `--diagnose` JSON dump shape |
| `DocumentModelTests.swift` | Open / reuse / duplicate, tab management, HEX state routing, UI scale, view-mode persistence, regex flag, bookmark target precedence |
| `DragDropTests.swift` | Multi-file drag order, error tabs |
| `FileWatcherIntegrationTests.swift` | Reload-on-change via the model |
| `FindBarTests.swift` | Source find: count, no-results, focus, persist |
| `FolderStateSymbolTests.swift` | Every `FolderState` → valid SF Symbol; symbols distinct enough |
| `FormatToggleTests.swift` | View mode availability per file type |
| `InteractionDeepTests.swift` | Multi-step scenario chains. **Contains the known-failing `test_zoom_persistsAcrossNewTab`** (guarded against crash; not investigated yet) |
| `InteractionScriptTests.swift` | Step-driven scenario runner |
| `LongFlowTests.swift` | Long user-flow regressions |
| `MarkdownRenderedViewTests.swift` | WKWebView wrapper |
| `MetadataPanelTests.swift` | Filesystem-row builder (pure helper) |
| `RecentChangesDiscoveryTests.swift` | `discoverRepo(sidebarRoot:currentURL:)` fallback rule |
| `RegexCacheTests.swift` | Compiled-regex LRU cache hit / invalidation / negative caching |
| `RenderedFindBarTests.swift` | Rendered find: query → JS injection round-trip |
| `ScenarioTests.swift` | Long-form interaction scenarios |
| `SidebarModelTests.swift` | children-of, ensureLoaded, hidden toggle, root rotation |
| `SourceViewVisualRegressionTests.swift` | Real-window screencap; **the compositor-bug regression guard** |
| `SQLiteWidthTests.swift` | Column width auto-compute (used by both SQLite + CSV) |
| `TextSearchTests.swift` | Find-ranges literal + regex; invalid pattern; zero-width matches |

## Recently elevated for tests (don't make private again)

Documented at each call site with a "Exposed internal so
`@testable import` can exercise it" comment.

- `SourceTextController.findRanges(in:query:caseSensitive:isRegex:)`
- `SourceTextController.cachedRegex(pattern:caseSensitive:)`
- `RecentChangesSection.discoverRepo(sidebarRoot:currentURL:)`
- `MetadataPanel.filesystemRows(url:attrs:)`
- `MetadataPanel.dateFmt`
- `ResultTableView` (whole struct in `SQLiteBrowserView.swift`)
- `ResultTableView.computeWidths(columns:rows:sampleRows:)`
- `ResultTableView.approxTextWidth(_:)`
- `DiffHighlighter.highlight(_:)`

When refactoring, preserve these signatures unless updating tests
in lockstep.

## Test-relevant environment variables

| Var | Effect | Usually set by |
|---|---|---|
| `MDV_BACKGROUND=1` | Accessory mode (no focus theft) | Tests + visual-smoke |
| `MDV_SKIP_WORKSPACE_RESTORE=1` | Start clean, no last-session restore | Tests |
| `MDV_ENABLE_BROKEN_RULER=1` | Reproduces the compositor bug | Meta-test for visual regression |
| `MDV_NO_RULER=1` | Deprecated synonym (old diagnostic path) | n/a |
| `MDV_SKIP_VISUAL=1` | Skip the visual regression test entirely | CI environments without WindowServer |
| `BUDGET_MB=N` | Override 25 MB bundle-size guard for one run | `scripts/build-app.sh` invocation |

## Patterns for new test files

A new test file should look like:

```swift
import XCTest
@testable import ViewerCore           // or ViewerKit / ViewerUI
// import ViewerCore                 // if you only need public surface

final class ThingTests: XCTestCase {
    // For tests touching the filesystem:
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // For tests touching UserDefaults:
    private var suiteName: String!
    private var defaults: UserDefaults!
    override func setUp() {
        suiteName = "ThingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // Main-actor tests (anything that touches DocumentModel):
    // mark the class @MainActor, use async setUp.

    // Cite the bug in regression tests:
    /// Regression: commit ea89818 (HEX picker lied after file switch).
    func test_regression_ea89818_hex_persists_across_switch() { ... }
}
```

## Test commands (everyday)

```sh
# Whole suite — ~85 s on a 4-core, 562 cases
swift test

# Single suite
swift test --filter ViewerCoreTests
swift test --filter CSVParserTests

# Single case
swift test --filter "ViewerCoreTests.CSVParserTests/test_quoted_field_with_embedded_comma"

# Parallel — what CI uses
swift test --parallel

# Bundle integrity (post-build)
bash scripts/verify-app.sh

# Inside a VM — see VM-SETUP.md
bash scripts/test-in-vm.sh smoke     # ~1 s, tier-1 only
bash scripts/test-in-vm.sh all       # full
```
