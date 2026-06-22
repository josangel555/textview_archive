# TextView

A native macOS file viewer + minimal editor — plaintext and markdown, code (TreeSitter
highlighting + a CodeMirror 6 editor), hex/CSV/SQLite/diff viewers, a git inspector, and
a Claude Code activity timeline.

> **Naming.** The shipped app bundle is `TextView.app` (CFBundleName `TextView`). The
> SwiftPM executable target is still named `MarkdownViewer` (`swift run MarkdownViewer`),
> and the bundle identifier stays `com.markdownviewer.MarkdownViewer` — both are
> TCC/Launch-Services-stable and deliberately left unchanged. See `scripts/build-app.sh`.

See [`DESIGN.md`](./DESIGN.md) for the full plan.

## Status

Well past the early phases: tabs + sidebar + split view, WKWebView markdown render
(CommonMark + GFM) with light/dark CSS, a CodeMirror 6 source editor, TreeSitter syntax
highlighting (lazy-loaded grammar dylibs), hex/CSV/SQLite/diff viewers, a tabbed git
inspector, LSP-backed hover/outline, a plugin host, an MCP automation surface, and a
walkthrough/code-review system. `⇧⌘R` toggles Source / Rendered.

See [`DESIGN.md` §10](./DESIGN.md) and `BACKLOG.md` for the up-to-date roadmap.

## Requirements

- macOS 15 (Sequoia) or later (`Package.swift` targets `.macOS(.v15)`)
- Swift 6.0+ / Xcode 16+

## Build & run

Two paths — the SPM executable (dev loop) or the assembled `.app` bundle
(closer to shipped).

```sh
# Dev loop — fastest iteration
swift run MarkdownViewer DESIGN.md

# Assemble a real macOS .app bundle
bash scripts/build-app.sh        # debug
bash scripts/build-app.sh release

# Open files with it like any Mac app:
open -a TextView DESIGN.md                 # name lookup (after build-app.sh registers)
open -a "$PWD/dist/TextView.app" DESIGN.md # path lookup, no registration needed
open DESIGN.md                             # use the system default app
```

> `open -a` resolves a relative path through Launch Services' name lookup, not as
> a filesystem path. Use either an **absolute path** or the **app name** (`TextView`;
> the build script registers the bundle automatically).

`⌘O` opens the file picker. Pass a path on the command line / Finder to
open it directly.

## Test

```sh
# Host-safe (no window / NSApplication): pure-logic suites.
swift test --filter ViewerCoreTests
swift test --filter ViewerKitTests

# Full suite — VM only. Unfiltered `swift test` sweeps live-app +
# visual UI tests that must run on the macOS VM (see CLAUDE.md).
ssh macOS15 'cd markdown_viewer && swift test'

bash scripts/verify-app.sh  # validates the assembled bundle (run after build-app.sh)
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

- macOS 15 deployment target
- SPM-only, no Xcode project — text-editable everywhere
- XCTest for now (swift-testing later)
- Non-sandboxed dev builds
- Distribution: DMG direct, no Mac App Store (sandbox cost too high for early phases)

### Dependency commitments (see DESIGN.md §2)

Phase 1: `swift-markdown` (Apple). Phase 5b: `SwiftTreeSitter` + per-language grammars
for unified syntax highlighting (§11). Git: shell out to `/usr/bin/git`, no libgit2.
No JS in WKWebView (TreeSitter pre-renders to HTML spans).

## Scripts reference

All in `scripts/`, all `bash` (no zsh-isms):

| Script | What it does |
|---|---|
| `build-app.sh [debug\|release]` | Build SPM, assemble `dist/TextView.app`, sign locally, run bundle-size check |
| `install-app.sh` | Copy `dist/TextView.app` to `/Applications` and re-register with LaunchServices |
| `verify-app.sh` | 17 checks on the assembled bundle (signing, plist keys, executable arch, icon) |
| `check-bundle-size.sh` | Fails if bundle > `BUDGET_MB` (default 80) or exec > `EXEC_BUDGET_MB` (default 60). Wired into `build-app.sh` |
| `gen-third-party-notices.sh` | Regenerate `THIRD_PARTY_NOTICES.md` from `.build/checkouts/*` + vendored JS bundles. `--check` fails if stale |
| `visual-smoke.sh` | Headless launch, capture screenshot, assert TabBar/ModeBar/Sidebar/StatusBar rendered |
| `pack-icns.swift` | Hand-pack `.icns` preserving oxipng compression (iconutil re-encodes) |

After any change to `scripts/Info.plist`, `scripts/build-app.sh`, or
the app's main bundle assembly, run **`bash scripts/verify-app.sh`**
before declaring done. Bundle issues fail late and look like other bugs.

## Environment variables

See `MANUAL_TESTING.md` for the full list. Quick reference:

- `MDV_BACKGROUND=1` — force dark theme
- `MDV_SKIP_WORKSPACE_RESTORE=1` — clean-room launch
- `MDV_NO_RULER=1` — disable line-number gutter
- `MDV_SKIP_VISUAL=1` — skip visual regression tests locally
- `BUDGET_MB=<N>` / `EXEC_BUDGET_MB=<N>` — override the 80 MB total / 60 MB exec bundle caps

## Distribution & signing

The build uses a self-signed cert `MarkdownViewer Local Dev` from the
login keychain. **Do not** change `CFBundleIdentifier` — TCC (Files &
Folders, Accessibility) grants are keyed on
`(com.markdownviewer.MarkdownViewer, cert-leaf-hash)`. Changing either
invalidates every user's existing grant.

For VM/CI testing, sync excluding `.build/`, `.swiftpm/`, `dist/` (host
artifacts won't relocate cleanly). See `MANUAL_TESTING.md` →
"VM smoke testing".
