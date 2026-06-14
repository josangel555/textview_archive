# SwiftPM build performance

## Current state

- Clean Swift build (fresh `.build`, all modules): **64 s**. Warm no-op: 1 s. Incremental
  (1-file edit): 3 s. App build (`build-app.sh debug`) warm: 16 s.
- Module graph: `ViewerKit → ViewerCore → RustCore → ViewerUI → MarkdownViewer`, plus 11
  `TreeSitter*Lazy` dynamic-library products built one-at-a-time by `build-app.sh`, plus 3
  C-patch targets and `MDVFakeLSPServer`.
- Sources: ~93 k LOC Swift. Largest modules: ViewerUI 45 k LOC, ViewerCore 41 k LOC. Largest
  single file `DocumentModel.swift` 5.5 k LOC.

## Findings

### Index-while-building is on by default and the gate doesn't need it
`swift build` defaults to `--auto-index-store` (verified: `swift build --help`). This writes
`debug/index/store` (244 MB) on every build. The headless gate never reads it. **Pass
`--disable-index-store`** to the gate's `swift build --build-tests` (in
`scripts/test-headless-gate.sh`). Free wall-clock + disk. Keep it ON for the interactive
`swift build` developers use so live indexing stays warm. (Rec **F2**.)

### SourceKit-LSP background indexing is a *separate* build (the big one)
Default-on in Swift 6.1+. It maintains `.build/index-build/` — a whole second `swift build`
tree (1.7 GB) including duplicate git mirrors. See `disk-build-dir.md` §1. For a CLI/agent
loop where editor cross-references aren't the bottleneck, disabling it (`swift.backgroundIndexing:
false`) reclaims 1.7 GB and stops a background `swift build` competing for cores during edits.
(Rec **F1**.)

### Module structure is already reasonable; WMO is the wrong lever for debug
- The web's headline advice (WMO / cross-module-optimization) is a **release-only** lever: it
  *increases* clean compile time and *destroys* incremental compilation (any 1-file change →
  full-module rebuild). Debug builds must stay `-Onone` / incremental. Do **not** enable WMO
  for the dev/gate loop. (Swift.org WMO blog; SwiftLab.)
- The genuine structural lever is **target granularity**: a change to ViewerCore (41 k LOC,
  single module) recompiles the whole module + everything downstream (ViewerUI 45 k LOC, the
  exec, the tests). The 64 s clean and the fact that ViewerUI.build/ViewerCore.build are the
  two biggest `.build` dirs both reflect this. *If* incremental edit time becomes painful,
  splitting ViewerCore along a real seam (e.g. Git / LSP / parsing subsystems into sub-modules)
  would shrink the recompile blast radius. This is a real refactor — file it, don't do it blind.

### SwiftPM compilation caching is NOT available
Despite the buzz, explicit-module / compilation caching "is not yet functional for SwiftPM
projects" (it needs explicit module support not wired for SPM). The cache wins cited online are
Xcode or Bazel. Nothing to enable here.

### `--enable-experimental-prebuilts` only covers swift-syntax macros
SwiftPM's prebuilt feature (default-on) prebuilds swift-syntax for macros. This package uses no
swift-macros in the hot path, so it's a no-op here. Not a lever.

### Lazy-grammar products are built serially in `build-app.sh`
`build-app.sh` loops `swift build --product TreeSitter<X>Lazy` over 11 grammars sequentially
(lines 82–98). Each invocation re-enters SwiftPM. These are independent dynamic libraries — they
*could* be requested in one `swift build` invocation with repeated `--product` flags (SwiftPM
accepts multiple `--product`), letting SwiftPM schedule them in one build graph instead of 11
cold re-entries. Likely a few seconds on the app build. Low risk, low effort — secondary to the
gate wins (the app build isn't on the merge gate). Worth a follow-up ticket.

## Non-levers (recorded so they're not re-investigated)

- **WMO/CMO for debug** — wrong, see above.
- **`-enable-batch-mode`** — already the SwiftPM default for non-WMO debug builds; not a manual win.
- **Explicit source-file lists in targets** — a known SwiftPM perf *foot-gun*
  (swiftlang/swift-package-manager #9304); this package uses directory-glob targets, which is
  the fast path. Leave it.

## Sources
- https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html
- https://www.swift.org/blog/whole-module-optimizations/
- https://github.com/swiftlang/sourcekit-lsp (Background Indexing docs)
- https://forums.swift.org/t/what-are-the-tradeoffs-of-cross-module-optimization/45585
- https://github.com/swiftlang/swift-package-manager/issues/9304
- https://actondon.com/blog/swift-build-time-improvement-research
