# Pre-Launch Product Review — Code Quality

**Dimension:** Code quality (duplication, oversized functions/files, unclear naming, error-prone idioms, missing abstractions, layering violations)
**Date:** 2026-07-10
**Reviewer:** automated code-quality lens (static analysis, read-only)
**Repo:** `/Users/me/Documents/workspaces/claude/markdown_viewer`

---

## Executive summary

The codebase is, on the whole, **structurally healthier than its size suggests**. Module
layering is clean and enforced in practice (no `ViewerCore → ViewerUI` back-edges; `ViewerKit`
depends on nothing above it). The Rust FFI seam is disciplined: every `extern "C"` entry point is
wrapped in a panic guard, and shipping Rust paths are essentially free of `unwrap()`/`expect()`
(those live in `#[cfg(test)]`). Swift force-unwrap idioms are rare (3 `try!`, 1 `as!`, 5
`fatalError` across ~170K LOC of source).

The quality debt is concentrated in a **small number of god-objects and mega-functions in the
presentation/app-shell layer**, plus a **deliberate-but-costly dual-maintenance surface** from the
in-flight Swift→Rust engine migration. None of these are ship-blockers on their own — they are
maintainability and regression-risk liabilities, not user-facing crashes. The two that most
deserve attention before scaling the team or the feature set are:

1. `AppDelegate` in `main.swift` — a **4,435-line single class with ~150 methods** that owns menu
   construction, window management, every menu action, LSP dispatch, export, and reset. Inside it
   `buildMenu()` is a **~1,300-line single function**.
2. `DocumentModel` — a **god-model** (3,586-line core file + 73 extension files = ~10.7K LOC on
   one type; 90 `@Published` properties). Every feature routes through it.

No P0 findings. Findings are P1 (structural risk) and below.

---

## Methodology

**What I examined (static analysis; no UI/window tests run):**

- **File-size census** — `wc -l` over all `Sources/**/*.swift` (~170K LOC) and
  `rust-core/**/*.rs` (~53K LOC); ranked the top ~30 of each.
- **Function-size probing** — structural `grep`/`awk` over the largest files to locate mega-methods
  (`main.swift`, `DocumentModel.swift`, `formula.rs`, `CoreClient.swift`).
- **Error-prone idiom sweep** — counts of `try!`, `as!`, `fatalError`, `unwrap()`/`expect()`,
  `panic!`/`unreachable!`/`todo!`, `DispatchQueue.*.asyncAfter`, `print(`, `TODO/FIXME/HACK`.
- **Layering audit** — cross-module import edges (`ViewerCore`↛`ViewerUI`, model-layer
  `import AppKit/SwiftUI` leaks, `ViewerKit` independence).
- **FFI panic-safety** — read `rust-core/crates/ffi/src/lib.rs` header + `ffi_guard!` usage and
  entry-point count.
- **Duplication** — Swift/Rust engine twins (migration surface), `Rust*Adapter` boilerplate,
  duplicate file basenames, MCP tool-catalog vs verb-dispatch surfaces.
- **Targeted reads** — `main.swift` (menu/validate/dispatch), `DocumentModel.swift` (MARK map),
  `CoreClient.swift` (FFI marshalling), `MCPToolCatalog.swift`, `validateMenuItem`, `SourceInvisibles.swift`.

**Coverage depth:** file/function metrics are comprehensive across both source trees; deep
line-by-line reads were spot sampled on the highest-risk files. See *Coverage gaps* for what I did
not open.

---

## Findings

### F1 — `AppDelegate` is a 4,435-line god-object in the executable shell
- **Severity:** P1
- **File:** `Sources/MarkdownViewer/main.swift:12` (class), spanning to ~`:4392`
- **Evidence:** A single `final class AppDelegate` implements ~150 methods: it builds the entire
  menu tree, manages windows, and hosts a menu-action handler for essentially every command in the
  app (`openDocument`, `saveActiveEditor`, `exportActiveAsDocx`, `lspGotoDefinition`,
  `applyJQFilter`, `minifyJSON`, `sortLinesAsc/Desc`, `installCLITool`, `openClaudeMonitor`, …).
  The "executable shell" (`Sources/MarkdownViewer/`) is meant to be thin per the layering doc, yet
  `main.swift` is the single largest Swift file in the repo.
- **Impact:** Every menu/command change touches one 4.4K-line file → high merge-conflict surface,
  hard to test in isolation, hard to reason about `AppDelegate`'s state. Action handlers that are
  one-liners forwarding to `model.*` (e.g. `promoteHeadings`, `makeUpperCase`) mix trivially with
  200-line handlers, obscuring the real complexity.
- **Suggested fix:** Extract cohesive command groups into focused `NSResponder`/coordinator types
  or `AppDelegate+<Area>.swift` extensions (Text ops, LSP, Export, Session, Terminal, Debug menus),
  mirroring the pattern already used for `DocumentModel+*.swift`. Menu *construction* should move to
  a declarative builder (see F2).
- **Fix size:** L · **Fix risk:** careful (menu-item `#selector` wiring + `validateMenuItem` are
  tightly coupled; mechanical but must preserve every selector).

### F2 — `buildMenu()` is a single ~1,300-line function
- **Severity:** P1
- **File:** `Sources/MarkdownViewer/main.swift:1639` (`private func buildMenu()`) → `:2936`
- **Evidence:** One function imperatively constructs the whole menu bar (~1,300 lines of
  `NSMenuItem(...)`, `addItem`, submenu wiring). Related builders (`buildDebugMenu`,
  `buildPluginsMenu`, `buildSessionMenu`, `rebuildWindowMenu`, `rebuildRecentsMenu`, …) sit
  alongside it, and `applicationDidFinishLaunching` (`:127`→`:614`) is itself ~487 lines.
- **Impact:** A single function far past any reviewable/testable threshold. Menu structure cannot
  be unit-tested (it's inline construction), and adding/reordering an item means editing deep
  inside a 1,300-line body. This is the same imperative-menu class that already required the
  parallel 203-line `validateMenuItem` switch (`:3575`→`:3778`) to stay in sync by hand.
- **Suggested fix:** Model the menu as data (an array of `MenuSection`/`MenuItemSpec` with
  title/selector/shortcut/validation-closure) and render it in a small generic builder. This
  collapses `buildMenu` + `validateMenuItem` + `applyShortcut` into one source of truth and makes
  the menu unit-testable (there is already a `MenuContributionRegistry` — extend that model rather
  than the imperative path).
- **Fix size:** L · **Fix risk:** careful (must preserve every shortcut, tag, and validation rule).

### F3 — `DocumentModel` is a god-model spread across 74 files
- **Severity:** P1
- **File:** `Sources/ViewerUI/DocumentModel.swift` (3,586 lines) + 73 `DocumentModel+*.swift`
  extensions (~7,135 additional lines) = **~10.7K LOC on a single type**
- **Evidence:** The core file declares **90 `@Published` properties**, ~242 stored properties, and
  ~266 methods; the MARK map spans ~35 distinct responsibilities (Find, Bookmarks, Git gutter,
  Split view, Focus shortcuts, File history, Code folding, LSP bridge, HTML/JS opt-in, Print/PDF,
  Sessions, Tabs, Recents, …). Decomposing the *logic* into 73 extension files is good hygiene, but
  every one of them extends the **same type**, so `DocumentModel` remains the single aggregate every
  view observes and every feature mutates.
- **Impact:** With 90 `@Published` fields on one `ObservableObject`, any published mutation can
  invalidate every observing SwiftUI view (over-invalidation / render churn), and the type is a
  perpetual merge hotspot. It also makes the documented recurring bug class — "imperative state
  populated *around* a switch, raced by the declarative render that reads it" (CLAUDE.md root-cause
  section) — structurally likely, because so much cross-cutting state lives on one object.
- **Suggested fix:** Split into feature sub-models (`FindModel`, `GitGutterModel`, `FoldingModel`,
  `LSPBridgeModel`, …) each its own `ObservableObject`, composed into `DocumentModel`, so a mutation
  in one feature only invalidates views that observe *that* sub-model. This is a large, incremental
  refactor — do it feature-by-feature, not big-bang.
- **Fix size:** XL · **Fix risk:** careful (SwiftUI observation semantics change; needs the VM
  render lane to validate no view stops updating).

### F4 — Dual-maintenance Swift/Rust engine twins (migration debt)
- **Severity:** P2
- **Files:** e.g. `Sources/ViewerCore/LineDiff.swift` (595), `Sources/ViewerCore/FindEngine.swift`
  (213), `Sources/ViewerCore/FormulaEngine.swift` (161) — full Swift engines that coexist with
  their Rust ports (`rust-core/crates/core/src/{diff,find,formula}.rs`) reached through
  `Rust{Diff,Find,Formula}Adapter.swift`.
- **Evidence:** Migration is **partial**: some engines are now thin shims (`CSVParser.swift` = 45
  lines, `FuzzyMatcher.swift` = 20 lines over the Rust adapter) while others still carry a complete
  second implementation in Swift. Per the migration policy these Swift twins are frozen to
  "bugfix-only", but they are still compiled, shipped, and must be kept behaviourally in sync with
  the Rust engine that is the real path.
- **Impact:** Two implementations of the same logic = drift risk (a fix landed in Rust but not the
  Swift twin, or vice-versa, produces mode-dependent behaviour), doubled test surface, and reader
  confusion about which path is live. It also inflates the binary.
- **Suggested fix:** Finish the migration for the still-full twins (diff, find, formula) — reduce
  each to a shim over its `Rust*Adapter` like CSV/fuzzy already are — and delete the dead Swift
  logic once the Rust path is the sole caller. Where a twin must remain (fallback), add a
  differential test that runs both against shared inputs and asserts parity, so drift fails a gate.
- **Fix size:** L · **Fix risk:** careful (need parity confidence before deleting the Swift twin).

### F5 — Monolithic single-file Rust front-end binaries
- **Severity:** P2
- **Files:** `rust-core/crates/tui/src/main.rs` (4,888 lines, ~207 fns),
  `rust-core/crates/web/src/main.rs` (4,728 lines, ~208 fns)
- **Evidence:** Each secondary front-end packs ~200 functions and ~4.8K lines into a single
  `main.rs` module. (For contrast, the shared `core` crate is cleanly split — markdown, csv,
  formula, diff, nav, hex, json, find, canvas/ are separate modules.)
- **Impact:** These are not the shipping macOS app, so blast radius is lower, but a 4.8K-line
  `main.rs` is hard to navigate/test and concentrates all of a binary's logic in one translation
  unit. If the `tui`/`web`/`serve` front-ends are part of the launch surface, they carry the same
  reviewability cost as F1/F2.
- **Suggested fix:** Break each `main.rs` into modules by concern (input/event loop, rendering,
  command handlers, state) — the `core` crate already demonstrates the target structure.
- **Fix size:** M · **Fix risk:** safe (module extraction within a binary crate is low-risk).

### F6 — `asyncAfter` timing-coordination idiom across 11 files
- **Severity:** P2
- **Files:** `Sources/ViewerUI/TextDisplayView.swift`,
  `Sources/ViewerUI/Sessions/SessionsAppCoordinator.swift`, `Sources/MarkdownViewer/main.swift`,
  `Sources/ViewerCore/{ProcessRunner,JSTransform,FolderWatcher,FileWatcher,DiagnoseSchedule}.swift`,
  `Sources/ViewerUI/UISceneApplier.swift`, and others (18 call sites in 11 files).
- **Evidence:** `DispatchQueue.main.asyncAfter` is used as a coordination/settle mechanism. The
  project's own CLAUDE.md root-cause section documents a *recurring* bug class of "imperative state
  populated around a switch, raced by the declarative render" (scroll reset, footer blank,
  loading-flashes) — delay-based sequencing is exactly the fragile idiom that produces it.
- **Impact:** Fixed-delay coordination is inherently race-prone: too short and it fires before the
  dependency is ready, too long and it lags. Some uses are legitimate debounce (`FileWatcher`,
  `FolderWatcher`); others substitute for a proper "when-ready" signal.
- **Suggested fix:** Audit each site; where the delay is standing in for "after X is ready", replace
  with an explicit completion/`await`/publisher. Keep `asyncAfter` only for genuine debounce, and
  centralize debounce in one helper so the intent is greppable.
- **Fix size:** M · **Fix risk:** careful (timing bugs must be validated on the real render lane,
  not inferred — per the codebase's own root-cause directive).

### F7 — Model layer (`ViewerCore`) imports AppKit/SwiftUI in 9 files
- **Severity:** P2
- **Files:** `Sources/ViewerCore/{FileTreeRecency,TextToolRunner,SpellCheckEngine,SourceInvisibles,FontPreference}.swift`,
  `Sources/ViewerCore/Highlight/{SyntaxTheme,ThemeDefinition,VSCodeThemeImporter,SyntaxTheme+CMPalette}.swift`
- **Evidence:** The intended dependency direction is `ViewerKit ← ViewerCore ← ViewerUI`, with
  `ViewerCore` as the platform-agnostic model/engine layer. These 9 files `import AppKit`/`SwiftUI`
  to produce `NSColor`/`NSFont`/`NSAttributedString` (e.g. `SourceInvisibles.markerColor(for:) ->
  NSColor`). The back-edge `ViewerCore → ViewerUI` does **not** exist (verified 0), so this is a
  platform-coupling leak, not a module-graph cycle.
- **Impact:** Ties the "portable" model layer to AppKit, which undercuts the stated remote-core /
  sans-IO goal (the Rust core is deliberately sans-IO; the Swift model layer is not held to the same
  bar). It also means theme/color logic can't be reused headless or on another platform without
  AppKit.
- **Suggested fix:** Have `ViewerCore` emit platform-neutral color/font descriptors (RGBA structs,
  font specs) and let `ViewerUI` map them to `NSColor`/`NSFont`. Low urgency, but it's the seam that
  keeps the model layer honest.
- **Fix size:** M · **Fix risk:** safe (mechanical; produces a value type instead of an AppKit type).

### F8 — Repeated FFI marshalling boilerplate in `CoreClient`
- **Severity:** P3
- **File:** `Sources/RustCore/CoreClient.swift` (1,523 lines) — e.g. `setFilter` (`:296`),
  `snapshotWindow` (`:318`), `open` (`:269`)
- **Evidence:** A `callBuf(...)` helper exists and is used for the no-arg calls, but arg-carrying
  entry points each re-inline the same shape: `bytes.withUnsafeBufferPointer { … mdvcore_*(…, &buf)
  }` → status check → `defer { mdvcore_buf_free(&buf) }` → decode. The pattern recurs for each new
  method.
- **Impact:** Minor duplication; each new FFI method copies the ceremony, and a forgotten
  `buf_free` defer would leak. Not a correctness bug today.
- **Suggested fix:** Generalize `callBuf` into a single `call(_ fn, encoding: [UInt8]…)` helper that
  owns the `withUnsafeBufferPointer` + status + `buf_free` lifecycle, so method bodies shrink to
  encode/decode only. (The `mdvcore_call` single-dispatch path already shows the target shape.)
- **Fix size:** S · **Fix risk:** safe.

### F9 — `validateMenuItem`: 203-line hand-synced switch mirroring the menu
- **Severity:** P3
- **File:** `Sources/MarkdownViewer/main.swift:3575` → `:3778`
- **Evidence:** A single `switch item.action { case #selector(...) … }` of ~200 lines both sets item
  titles/state and returns enablement, in parallel to the menu built by `buildMenu()`. The two must
  be kept in sync by hand (a selector added in one must be handled in the other).
- **Impact:** Sub-symptom of F1/F2 — dual sources of truth for menu behaviour. Idiomatic AppKit, but
  the size + hand-sync is where "menu item enabled but does nothing" / "wrong title" bugs breed.
- **Suggested fix:** Fold validation into the declarative menu spec from F2 (each `MenuItemSpec`
  carries its own `isEnabled`/`title`/`state` closure), eliminating the parallel switch.
- **Fix size:** M · **Fix risk:** careful (part of the F2 refactor).

---

## Positive observations

- **FFI panic safety is disciplined.** Every `extern "C"` entry point in
  `rust-core/crates/ffi/src/lib.rs` runs inside `ffi_guard!` / `std::panic::catch_unwind`, mapping a
  panic to `MdvStatus::Panic` instead of unwinding across the C boundary (UB). There's even a
  committed `mdvcore_force_panic` test hook proving the mapping. This is exactly right for an FFI seam.
- **Shipping Rust paths are unwrap-clean.** The ~497 `unwrap()`/`expect()` in the `core` crate are
  concentrated in `#[cfg(test)]` modules — hot files like `markdown.rs`/`csv.rs`/`formula.rs` have
  effectively zero shipping-path unwraps. `ffi` and `pm` crates: 0.
- **Module layering holds in practice.** No `ViewerCore → ViewerUI` back-edge (0), `ViewerKit`
  imports nothing above it (0). The strict `ViewerKit ← ViewerCore ← ViewerUI ← MarkdownViewer`
  direction is real, not aspirational.
- **Swift force-idioms are rare.** Across ~170K LOC: 3 `try!`, 1 `as!`, 5 `fatalError`. No wall of
  force-unwraps. Debug `print()` leftovers are effectively nil (the apparent hits are sample-content
  strings, not logging).
- **`DocumentModel` logic *is* decomposed.** Despite F3, the team pushed feature logic into 73
  `DocumentModel+*.swift` extensions with a clear MARK map — the problem is the shared *type*, not
  undisciplined dumping.
- **The `core` Rust crate is well-modularized** — each engine (markdown/csv/formula/diff/nav/hex/
  json/find/canvas) is its own module; the monolith smell (F5) is confined to the `tui`/`web`
  binaries, not the shared library.

---

## Coverage gaps (not examined, or examined only shallowly)

- **Deep line-by-line reads** were limited to the highest-risk files. Mid-size files (500–1,000 LOC)
  — `Formatter.swift`, `CoreClient.swift` beyond the FFI shape, `GitClient.swift`, `LSPClient.swift`,
  `CodeMirrorEditorView.swift`, `HexView.swift`, `CSVTableView.swift` — were not read in full for
  internal duplication/naming.
- **Naming quality** was assessed opportunistically (I found no egregious offenders in what I read),
  not via a systematic identifier audit.
- **Intra-function duplication / copy-paste blocks** were probed via file/basename heuristics, not a
  token-level clone detector (no `jscpd`/`cargo` clone tooling was run). There may be smaller
  copy-paste clusters I did not surface.
- **The web `Resources/` assets** (bundled CodeMirror/Mermaid/Canvas JS/CSS) were not reviewed for
  quality — a different lens.
- **`serve` daemon unwraps (134)** were counted but not classified by whether they sit in
  request-handling paths (a panic there could drop a connection). Worth a follow-up if `serve` is in
  the launch surface.
- **Test code** (~178K LOC) was excluded per the quality lens on *product* code.
- No tests were run (constraint honored); all findings are from static reading + structural metrics
  and are independently verifiable at the cited paths/lines.
