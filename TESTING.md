# Testing

The full multi-tier strategy is in [`DESIGN.md` §7](./DESIGN.md). This file is the
**running view**: what exists today, how to run it, what to add next.

## Tiers (target shape)

| Tier | Tool | Phase first lands | Runs in CI? |
|---|---|---|---|
| 1. Unit (`ViewerCore` / `ViewerKit`) | XCTest | 0.1 ✅ | yes |
| 2. SwiftUI snapshot | swift-snapshot-testing | 2 (tabs/sidebar) | yes |
| 3. Headless SwiftUI behavior | ViewInspector | 2 | yes |
| 4. Real-macOS E2E in tart VM | XCUITest in VM | 3+ | nightly only |

## How to run

```sh
swift test                   # whole suite
swift test --filter ViewerKitTests
swift test --filter ViewerCoreTests.DocumentControllerTests/test_oversizedFile_reportsSizeInMB
```

## Current coverage (Phase 1)

- **ViewerKitTests/FileTypeDetectorTests** — 7 cases.
- **ViewerKitTests/InfoPlistTests** — 7 cases.
- **ViewerCoreTests/TextFileLoaderTests** — 5 cases.
- **ViewerCoreTests/DocumentControllerTests** — 4 cases.
- **ViewerCoreTests/HTMLRendererTests** — 20 cases. Blocks (headings, lists,
  blockquote, code fences w/ + w/o language, table, hr), inline (em, strong,
  strikethrough, inline code, link incl. href escaping, image), text-escape
  table, GFM strikethrough, page wrapper with stylesheet, complex round-trip.
- **ViewerCoreTests/HistoryStoreTests** — 13 cases. Record, dedupe + bump,
  URL normalization, cap limit, remove, clear, persistence round-trip,
  corrupt-file recovery, cap applied on load, folder kind, recent limit.
- **ViewerCoreTests/TabsStateTests** — 19 cases. Empty state, init with
  out-of-bounds selection clamps, append-selects, close-at-selected /
  before / after / only-tab / out-of-bounds, move (rearranges + carries
  selection + invalid args no-op), `openOrReveal` (existing → switch, new →
  append, reuse blank tab), replace, select out-of-bounds.
- **scripts/verify-app.sh** — 17 structural assertions on the built bundle
  (executable bit, plist lint, required keys, document type UTIs, ViewerUI
  resource bundle + markdown.css presence).

Total: **75 swift cases, ~80 ms** + bundle verify script.

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
- **No mocks in Tier 1.** Inject real `TextFileLoader` instances; they're
  fast and the file system is the integration we want to exercise.
- **One file per type.** Tests mirror source layout
  (`Sources/Foo/Bar.swift` → `Tests/FooTests/BarTests.swift`).

## CI

`.github/workflows/pr.yml` runs `swift build` + `swift test --parallel` on
`macos-14` on every push to `main` and every PR.
