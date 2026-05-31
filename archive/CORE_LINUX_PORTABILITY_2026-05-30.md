# Core Linux Portability

> Status: 2026-05-30 — read-only investigation. No code changed. Conclusions from import-surface analysis, **not** a green Linux build.

## 1. Verdict

ViewerKit + ViewerCore are **mostly portable Foundation and close to a Linux-buildable subset** — the hard coupling is narrow and well-localized. No `#if os(...)` / `#if canImport(...)` guards exist anywhere in either module today (zero grep hits), and `Package.swift:6` hard-pins `platforms: [.macOS(.v15)]` — there is no cross-platform scaffolding yet. The blocker count is small (8 import/API files) but the validator surfaced **3 Combine-coupled `ObservableObject` Core types** (not 1), which are additional hard blockers on swift-corelibs-foundation. ViewerKit has exactly **one** blocker (`FileCategory`).

## 2. Blockers (compile-hard on Linux as-is)

| # | File:line | What | Severity | Approach / cost |
|---|---|---|---|---|
| 1 | `Highlight/SyntaxTheme.swift:1,15-114` | `import AppKit`; stores `NSColor` bg/text/gutter + `[TokenKind:NSColor]`; `resolved(forAppearance: NSAppearance?)`; `extension NSColor: @retroactive @unchecked Sendable` (`:114`) | **Hard** | Swap `NSColor`→`struct RGBA8`. Values already hardcoded `srgbRed:` hex — trivial. `forAppearance:`→`enum Appearance{light,dark}`. UI bridges RGBA→NSColor at edge. ~1 file. |
| 2 | `FileTreeRecency.swift:1,94-124` | `import AppKit`; `color(for:)->NSColor` via `NSColor(name:dynamicProvider:)` | **Hard** | Same RGBA treatment. Tier logic (`tier(forAge:):67`) + cache (`:160-209`) already portable — split, move only color mapping up. |
| 3 | `FolderWatcher.swift:2,31,73-141` | `import CoreServices`; `FSEventStreamRef`, `FSEventStreamCreate/Start/Stop`, `kFSEventStream*` | **Hard** | Protocol `FolderWatching{init(url:onChange:);stop()}`; macOS=FSEvents, Linux=inotify (per-subdir, not recursive). Debounce/dedup (`:147-192`) portable, lift out. **Largest single effort.** Rust `notify` crate solves natively. |
| 4 | `Walkthrough/WalkthroughDropTransport.swift:2,84,148-196` | `import CoreServices`; duplicate FSEvents surface | **Hard** | Same fix as #3, reuse `FolderWatching`. Env-gated off by default (`:43,107`), low priority, but must still compile. |
| 5 | `LSP/LSPClient.swift:160-165` | `fcntl(fd, F_SETNOSIGPIPE, 1)` — Darwin/BSD-only `fcntl` cmd | **Shimmable** | `#if canImport(Darwin)` around it + one-time `signal(SIGPIPE, SIG_IGN)` on Linux (code self-documents this at `:162-163`). ~5 lines. Rest of `LSPClient` (POSIX `write`, `Pipe`, `Process`, `Thread`) portable. |
| 6 | `Mermaid/MermaidSourceParser.swift:2,105` | `import CryptoKit`; `SHA256.hash` | **Shimmable** | swift-crypto (`import Crypto`, drop-in) — needs dep approval. Or hand-roll (hash is only an 8-hex diagram id, non-cryptographic). |
| 7 | `LSP/LSPDiscovery.swift:2,274` | `import CryptoKit`; `SHA256.hash` (cache key) | **Shimmable** | Same swift-crypto swap as #6. |
| 8 | `SQLite/SQLiteReader.swift:2` | `import SQLite3` — macOS system modulemap; Linux has none by default | **Shimmable** | Add a `CSQLite` system-library target + modulemap linking `-lsqlite3`, `#if canImport(SQLite3)` swap. API is identical C. Mid-low cost. |
| 9 | `FileCategory.swift:2,77-85` (**ViewerKit — only Kit blocker**) | `import UniformTypeIdentifiers`; `UTType(filenameExtension:).conforms(to:)` | **Shimmable** | UTType block is a *fallback* after pure extension-set lookups (`:62-71`). `#if canImport(UniformTypeIdentifiers)`, else fall through to `.unknown`. ~5 lines. |
| 10 | `Sessions/SessionsCoordinator.swift:32,44-50` | `ObservableObject` + 3×`@Published` (Combine) | **Hard** | `@Published`/`ObservableObject` are Combine — Apple-only, absent on swift-corelibs-foundation. Swap to `AsyncStream`/callbacks. (Orig agent hedged "uncertain"; body confirms load-bearing — definite blocker.) |
| 11 | `LSP/LSPNavigationStore.swift:12,45-54` | `ObservableObject` + `@Published` | **Hard** | **Missed by orig agents** (LSP layer wrongly called "fully portable"). `import Foundation` only — resolves via Foundation's Combine re-export *on Apple only*; absent on Linux. Same fix as #10. |
| 12 | `LSP/LSPDiagnosticsStore.swift:16,18` | `ObservableObject` + `@Published` | **Hard** | **Missed by orig agents.** Same as #11. |

**Combine-in-Core tally: 3 types** (#10/#11/#12), not 1. Note: OpenCombine (3rd-party) exists, so "no Linux Combine implementation" is too strong — but the bundled toolchain ships none, so without a new dep these remain hard blockers.

## 3. Already-portable subsystems (verified by import surface)

| Subsystem | Notes |
|---|---|
| **MCP/Automation boundary** (`Automation/*`) | Ports **clean, zero changes** — Foundation only (`FileHandle.standardInput/Output`, `NSLock`, `Thread`, `JSONEncoder`, manual framing). `(path as NSString).expandingTildeInPath`+`NSHomeDirectory()` work on swift-corelibs-foundation. Strongest existing keystone for the remote vision. |
| **Subprocess** (`ProcessRunner`, `GitClient`, `JQRunner`, `PluginSubprocessHost`, `LSPClient`) | Foundation `Process`/`Pipe`/`FileHandle` portable. rlimits via `/bin/sh -c 'ulimit'` wrapper (`ProcessRunner:297-317`), not syscalls. **Runtime caveat (not compile):** hardcoded `/usr/bin/git` (`GitClient.swift:493`), `/usr/bin/jq`+`/opt/homebrew/bin/jq` (`JQRunner:34`), `/usr/bin/xcrun`, Homebrew dirs (`LSPDiscovery:151-154`) — compile fine, resolve nothing on Linux; need PATH locator. |
| **Persistence** (`BookmarksStore`, `HistoryStore`, `SessionStore`, `ReviewStore`, `PluginGrantStore`, `JSONFileStore`, `PreferencesStore`) | `FileManager.url(.applicationSupportDirectory)`→XDG on Linux; `UserDefaults` works; Codable portable. App-support→XDG is behavioral, not compile. |
| **Text/parse/search** (`CSVParser`, `CSVFilter`, `FindEngine`, `CrossFileSearch`, `FuzzyMatcher`, `Formatter`, `EditorBuffer`, `Tab`, `TabsState`, `DocumentController`, `HexDumpBuilder`/`HexLayout`/`HexSearchEngine`, `Fold*`, `DiffHighlighter`, `HighlightRun`) | Foundation-only. `NSRegularExpression` (`FindEngine:141`) is ICU-backed on Linux — portable, watch ICU drift. `HexDumpBuilder` `NSAttributedString` is doc-comment only (`:7`); emits `String`. |
| **Git diff/graph** (`DiffParser`, `DiffHunkParser`, `DiffGutterFeeder`, `GraphLayout`) | Pure string/struct. Portable. |
| **HTML/md render** (`HTMLRenderer`, `HTMLSanitizer`, `CodeMirrorBridgeV1`, `CMEditApplier`) | `swift-markdown` builds on Linux. `HTMLRenderer:179` `as NSString` portable. comrak swap is a Rust concern, not a Linux-Swift blocker. |
| **TreeSitter** (`TreeSitterEngine`, `GrammarLoader`) | SwiftTreeSitter + C grammars build on Linux; `GrammarLoader` `dlopen`/`dlsym` is POSIX. **Caveat:** dylib *search paths* (`Bundle.main.privateFrameworksPath`, `Contents/Frameworks/`, `GrammarLoader:186-266`) are `.app`-shaped — compile but find nothing on Linux; need Linux lib-dir + `.so`. Mid cost (path logic, not API). **Unverified risk:** SwiftTreeSitter wrapper on Linux not build-tested here. |
| **LSP (most)** (`LSPProtocol`, `LSPFraming`, `LSPPositionConverter`, `LSPPool`, `LSPLanguage`, `CMDiagnosticMapping`) | Pure JSON-RPC/Foundation. Portable. (But `LSPNavigationStore`/`LSPDiagnosticsStore` are NOT — see #11/#12.) |
| **Sidebar/sessions/walkthrough/plugins/security logic** (`SidebarPanel*`, `Walkthrough/{Engine,Loader,Script}`, `Plugins/*`, `Security/*`, `FileTreeService`, `FileIconClassifier`, `HighlightLanguage`, `ViewMode`) | Foundation-only. `SidebarPanelKind/Heights` `import CoreGraphics` only for `CGFloat` (available on Linux via Foundation — **not** a blocker; the import may be droppable). `systemImage` returns SF-Symbol *strings* — portable. |
| **Single-file watch** `FileWatcher.swift:86` | `DispatchSourceFileSystemObject` — libdispatch, **portable on Linux** (unlike `FolderWatcher`'s FSEvents). |

## 4. Smallest path to a Linux-buildable core subset
1. Add `#if canImport(...)` scaffolding (none exists today) and a Linux `Package.swift` platform entry.
2. **De-NSColor** #1/#2 → RGBA value types (unblocks the highlight theme).
3. **De-Combine** the 3 `ObservableObject`s #10/#11/#12 → `AsyncStream`/callbacks (or accept an OpenCombine dep — needs approval).
4. **Shim the cheap ones:** #5 (`F_SETNOSIGPIPE`), #6/#7 (swift-crypto or hand-roll), #9 (`UTType` fallback guard).
5. **`FolderWatching` protocol** #3/#4 with an inotify Linux impl — the largest item; lift the portable debounce/dedup out first.
6. `CSQLite` modulemap target #8 (or defer SQLite from the Linux subset entirely).
7. Runtime: PATH-based locator for git/jq/xcrun; Linux lib-dir + `.so` search for `GrammarLoader`.
8. **Verify the two unproven risks with an actual Linux `swift build`:** SwiftTreeSitter wrapper, swift-markdown/swift-cmark.

A useful first milestone: build only the **MCP/Automation + text/parse/persistence** subset (all clean) headless on Linux, deferring TreeSitter/LSP/SQLite/watchers.

## 5. Intersection with the Rust-core question

| Blocker | Under Rust core | Must solve either way |
|---|---|---|
| #1/#2 NSColor theme | Vanishes (Rust emits RGBA natively) | — |
| #3/#4 FSEvents watchers | Vanishes (`notify` crate is cross-platform) | — |
| #6/#7 CryptoKit | Vanishes (`sha2` crate) | — |
| #8 SQLite3 modulemap | Vanishes (`rusqlite`) | — |
| #5 `F_SETNOSIGPIPE` | Vanishes (Rust handles SIGPIPE differently) | — |
| #10/#11/#12 Combine `ObservableObject` | Vanishes (no Combine in Rust) — **but** the reactive-state design problem reappears as: how does the FFI surface a state/event stream | The *event-stream design* must be solved either way |
| #9 UTType fallback | Vanishes (Rust mime/ext logic) | — |
| Render correctness (swift-markdown, TreeSitter on Linux — unverified) | Vanishes / changes (comrak + tree-sitter Rust crates, build-proven cross-platform) | The unverified-build risk is itself an argument for Rust |
| The Core↔UI **boundary shape** (Command/Query/Event protocol) | **Does NOT vanish** | Must be designed regardless — it's the keystone for *both* Swift-portable and Rust paths; the uniffi FFI surface = the same protocol |

**Net:** nearly every *compile* blocker vanishes under Rust, which is a genuine point in its favor (and sidesteps the two unverified Linux-Swift build risks). But the two *hardest* items — the event/reactive-state boundary and the protocol that drives remote/browser UIs — are language-agnostic and must be solved either way. Sequencing the boundary work first (per the boundary doc's Option C) de-risks both the Swift-portable and the Rust migration paths.