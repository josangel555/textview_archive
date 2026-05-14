# MarkdownViewer

A native macOS file viewer — starting with plaintext and markdown, growing into a code
viewer, hex viewer, git inspector, and Claude Code activity timeline.

See [`DESIGN.md`](./DESIGN.md) for the full plan.

## Status

Phase 0 — skeleton. Opens and displays a text file.

## Requirements

- macOS 14 (Sonoma) or later
- Swift 6.0+ / Xcode 16+

## Build & run

```sh
swift build
swift run MarkdownViewer DESIGN.md
```

`⌘O` opens the file picker. Pass a path on the command line to open it directly.

## Test

```sh
swift test
```

## Project layout

```
Sources/
  ViewerKit/        models, file type detection — no UI, no IO
  ViewerCore/       file loading, parsers, watchers — no UI
  ViewerUI/         SwiftUI views, AppKit glue
  MarkdownViewer/   the app target (@main)
Tests/
  ViewerKitTests/
  ViewerCoreTests/
```

## Working decisions (locked in for Phase 0)

- macOS 14 deployment target
- SPM-only, no Xcode project — text-editable everywhere
- XCTest for now (swift-testing later)
- Non-sandboxed dev builds
- No external dependencies until Phase 1 (then `swift-markdown`)
