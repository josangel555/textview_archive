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

**Total: 174 swift cases, ~2 s. Plus bundle verify script + manual checklist.**

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
