# MarkdownViewer

A native macOS file viewer — starting with plaintext and markdown, growing into a code
viewer, hex viewer, git inspector, and Claude Code activity timeline.

See [`DESIGN.md`](./DESIGN.md) for the full plan.

## Status

Phase 0 complete — skeleton, AppKit window, NSTextView display, CI workflow.
Next: Phase 0.4 (`.app` bundle), Phase 1 (markdown rendering via WKWebView).

See [`DESIGN.md` §10](./DESIGN.md) for the up-to-date roadmap.

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

## Working decisions

- macOS 14 deployment target
- SPM-only, no Xcode project — text-editable everywhere
- XCTest for now (swift-testing later)
- Non-sandboxed dev builds
- Distribution: DMG direct, no Mac App Store (sandbox cost too high for early phases)

### Dependency commitments (see DESIGN.md §2)

Phase 1: `swift-markdown` (Apple). Phase 5b: `SwiftTreeSitter` + per-language grammars
for unified syntax highlighting (§11). Git: shell out to `/usr/bin/git`, no libgit2.
No JS in WKWebView (TreeSitter pre-renders to HTML spans).
