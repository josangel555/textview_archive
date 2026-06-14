# Disk & `.build` — why it's 4.4 GB and what's reclaimable

## Measured breakdown (`du`, today)

```
4.4G  .build
├── 1.7G  index-build/                ← SourceKit-LSP background-index build tree (SEPARATE)
│   ├── 814M  repositories/           ← DUPLICATE of .build/repositories (same grammar mirrors)
│   ├── 722M  arm64-apple-macosx/     ← second compiled tree, just for the index
│   └── 212M  checkouts/              ← DUPLICATE of .build/checkouts
├── 1.7G  arm64-apple-macosx/
│   ├── 1.1G  debug/                  ← the tree the gate + app actually use
│   │   ├── 244M  index/store         ← index-while-building output (--auto-index-store)
│   │   ├── 225M  ModuleCache         ← precompiled system .swiftmodules
│   │   ├── 175M  MarkdownViewerPackageTests.xctest
│   │   ├── 75M   ViewerUITests.build  +  73M ViewerCoreTests.build
│   │   ├── 69M   MarkdownViewer (exec)  +  49M MarkdownViewer.dSYM
│   │   └── 68M ViewerUI.build  46M ViewerCore.build  …
│   └── 601M  release/                ← STALE leftover (last touched Jun 12; gate uses debug)
│       ├── 225M ModuleCache (2nd copy)  32M index  41M dSYM …
├── 798M  repositories/               ← FULL git mirrors of tree-sitter SwiftPM deps
└── 210M  checkouts/                  ← working-tree checkouts of those deps
```

## The three duplications (this is the whole story)

### 1. `index-build/` is a second, complete `swift build` tree (1.7 GB)

SourceKit-LSP's **background indexing is default-on in Swift 6.1+** and "the index build is
currently **completely separate** from the command-line build generated using `swift build`"
(swiftlang/sourcekit-lsp docs). So while you edit, the LSP runs its own `swift build
--experimental-prepare-for-indexing` into `.build/index-build/`, which:
- re-clones **every** tree-sitter git mirror → `index-build/repositories` = **814 MB**, a near
  byte-for-byte duplicate of `.build/repositories` (798 MB). Same `tree-sitter-c-sharp-*`,
  `tree-sitter-typescript-*`, etc.
- maintains a second compiled tree (`index-build/arm64-apple-macosx`, 722 MB).

`index-build/build.db` was last written **today** (Jun 14) — confirming it's the live indexer,
not a stale artifact.

**Reclaim:** delete `.build/index-build` (regenerates) and/or set `swift.backgroundIndexing:
false` in the editor (VS Code `settings.json` / Xcode). Cost of disabling: cross-file
jump-to-definition / find-references degrade until the next explicit build. For an
agent-driven repo where the editor index is rarely the bottleneck, turning it off is a clean
−1.7 GB. (Recommendation **F1**.)

### 2. Stale `release/` tree coexists with `debug/` (601 MB)

The headless gate and `build-app.sh debug` use the **debug** tree. The 601 MB `release/` tree
(225 MB ModuleCache + 32 MB index + 41 MB dSYM + compiled `.build` dirs) is a leftover from
some `-c release` invocation (Jun 12). Nothing in the daily loop needs it.

**Reclaim:** `rm -rf .build/arm64-apple-macosx/release` → **−601 MB**, regenerates only if you
explicitly build release. (Recommendation **F4**.)

### 3. Index-while-building emits 244 MB the gate never reads

`swift build` defaults to `--auto-index-store`, writing `debug/index/store` (244 MB). This is
*distinct* from the LSP's index above. The CLI **gate** (`test-headless-gate.sh`) builds tests
and runs them; it never consumes the index store. Passing `--disable-index-store` to the gate's
`swift build --build-tests` drops the write entirely.

**Reclaim:** −244 MB + a measurable cut to the build phase (index-store generation is reported
to add 10–30%+ to swift compile across many sources; on this tree treat as ~5–15% conservative).
(Recommendation **F2**.)

## Secondary disk facts

- **ModuleCache is duplicated** debug (225 MB) + release (225 MB). It's precompiled system
  `.swiftmodule`s (AVKit, Concurrency, SwiftUI, …). Shareable in principle (`-module-cache-path`)
  but SwiftPM doesn't expose it cleanly and cross-config sharing has had foot-guns — low
  priority (T5).
- **`repositories/` (798 MB) + `checkouts/` (210 MB)** are the tree-sitter SwiftPM deps. These
  are *full* git clones, not shallow — see `git-deps.md`. The grammar repos are enormous because
  they vendor generated parser tables AND full history (c-sharp pack = 191 MB / 1081 commits).

## One-shot reclaim estimate (zero behavioural risk)

| Action | Reclaimed |
|---|---|
| `rm -rf .build/index-build` + disable bg-indexing | 1.7 GB |
| `rm -rf .build/arm64-apple-macosx/release` | 0.6 GB |
| `--disable-index-store` on next gate build (after wiping `debug/index`) | 0.24 GB |
| **Total `.build`** | **~2.5 GB → `.build` shrinks 4.4 GB to ~1.9 GB** |

(Rust `/private/tmp` target-dir reclaim of ~6 GB is separate — see `rust.md`.)
