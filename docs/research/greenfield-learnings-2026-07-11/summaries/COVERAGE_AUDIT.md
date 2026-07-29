# Coverage Audit — CODE-batch summaries (GAPS §4)

Mechanical audit of the 39 reports in `summaries/code/` against every source file on
disk they were supposed to cover.

## Method

1. **Extract covered paths.** All 39 `code/*.md` reports were grepped for filename
   tokens in every observed entry format the batch (author-)reports actually used:
   `**Name.ext**` bold headers, `` **`Name.ext`** `` backtick-in-bold, Markdown table
   cells (with and without extension — `t-ui-root-5of6.md` and one other slice list bare
   test-class names, extension implied by the Tests/ scope), and `+`-joined grouped
   entries (`**a.sh** + **b.py**`). Two extraction passes were unioned: a strict
   `^\*\*path\*\*`-anchored pass and a loose whole-corpus token pass
   (`[A-Za-z0-9_+.-]+\.(swift|rs|sh|py|js|html|css|json)`), plus a table-specific pass
   for the two bare-name slices. Basenames were used for the dedup/diff key for Swift
   (Sources+Tests basenames collide only once — two unrelated `main.swift` — a known,
   accepted blind spot of this method); full relative paths were used for `rust-core/`
   and `scripts/` (basenames collide heavily there — `mod.rs`, `tests.rs`, etc.).
2. **Enumerate on-disk scope.**
   - `find Sources Tests -name '*.swift'` → 2,005 files (2,004 unique basenames + 1
     `main.swift` collision).
   - `find rust-core/crates -name '*.rs' -not -path '*/target/*'` → 85 files.
   - `find scripts -type f` (excluding `.DS_Store`) → 61 files.
   - `find Sources -name '*.html' -o -name '*.js' -o -name '*.css'` (non-min) → 8 web
     assets (CodeMirror/Mermaid/Canvas Resources).
3. **Diff** covered vs. on-disk per corpus (Swift / Rust / scripts / web), by the key
   from step 1.
4. A file counts **"missing"** only if a full-corpus grep of its exact basename across
   all 39 reports returns literally nothing. A file mentioned only inside a **grouped
   wildcard** entry (e.g. `rust-core/crates/core/src/canvas/*.rs` naming eight module
   stems in prose without individual role/notable/carry lines) or only in **incidental
   prose** (a design-decisions bullet, a cross-reference) rather than its own inventory
   line is flagged separately as **shallow coverage** — present in the corpus, but not
   individually profiled the way the batch's own inventory format promises.

## Per-batch / per-corpus counts

| Corpus | On-disk files | Reports covering it | Individually-covered | Zero-mention (missing) | Shallow-only (grouped/prose) |
|---|---|---|---|---|---|
| Swift (`Sources/` + `Tests/`) | 2,005 | 30 reports (`src-core-*`, `src-ui-*`, `t-core-*`, `t-ui-*`, `t-rust-kit-support`) | 1,994 | **11** | 0 |
| Rust (`rust-core/crates/**/*.rs`) | 85 | 3 reports (`src-rust-core-1of2`, `src-rust-core-2of2`, `src-rust-other-crates`) | 75 | **1** | 8 (`canvas/{chart,deck,dsl,io,lint,lower,tokens,vocab}.rs`, named only via a `canvas/*.rs` wildcard bullet) |
| scripts/ | 61 | 1 report (`src-scripts.md`) | 45 | **8** | 1 (`install-app.sh` — mentioned 4× in prose/cross-refs, never gets its own inventory line despite being a core build script) |
| Web assets (`Sources/**/*.{html,js,css}`, non-min) | 8 | 1 report (`src-small-targets-web.md`, cross-cited by others) | 8 | **0** | 0 |
| **Total** | **2,159** | 39 reports (all of `summaries/code/`) | **2,122** | **20** | **9** |

Effective coverage: **2,122 / 2,159 = 98.3%** individually profiled; **2,141 / 2,159 =
99.1%** at least mentioned somewhere (individual + shallow).

## Missing files (20) — zero mentions anywhere in `summaries/code/`

### Swift (11)

**`Sources/RustCore/CanvasCore.swift`** (464 LOC) · Swift wrapper over the canvas M1
Rust engine (`mdvcore_canvas_doc_open/html/apply/free`) — the FFI-facing value types
(`CanvasValue`, `CanvasPosition`, ops) that speak the `canvas::wire` MsgPack shapes.
Replaced an older M0 demo wrapper (numeric ids, mirror ops). · notable: this is the
**Swift-side half of the canvas FFI boundary** — `src-rust-core-1of2.md` documents the
Rust side (`canvas/doc.rs`, `canvas/wire.rs`) in depth but the Swift caller was never
independently profiled, so the FFI contract's Swift-side type mapping is undocumented
in this corpus. · carry: **KEEP** — needed to understand the canvas M1 FFI contract
end-to-end; pair with `src-rust-core-1of2.md`'s canvas section on any rebuild.

**`Sources/ViewerUI/CommandPaletteView.swift`** (813 LOC) · The unified command
palette — file/bookmark fuzzy finder, `>`-prefixed command mode, `?`/`#`/`@`/`:`
operator routing via `SearchRouter` (TSK-677), keyboard nav, hover-vs-keyboard
scroll-follow discipline. · notable: **813 LOC, a major always-visible UI surface,
entirely unprofiled** — likely conflated by the extraction/skim pass with the smaller,
already-covered `TerminalCommandPaletteView.swift` (`src-ui-root-4of4.md:143`), a
distinct file with a similar name. · carry: **KEEP, re-profile** — this is the single
largest true gap in the corpus; the "single front door for every search type" routing
model (operator-prefix dispatch) is a design pattern worth carrying forward regardless.

**`Sources/ViewerUI/ArchiveBrowserView.swift`** (283 LOC) · The `.preview` lens for
zip/jar/tar/tgz/tbz2 archive tabs — read-only entry list + live preview pane +
"Extract & Open" affordance; listing/preview/extraction all run off-main. · notable:
sibling `ArchiveCatalog.swift`/`ArchiveEntryPreview.swift`/`ArchiveFileInfo.swift` are
covered in `src-core-dataapps.md`'s Archive module section — this is the missing
UI-layer file that consumes them. · carry: **KEEP** — off-main archive extraction with
progress/error envelopes is a reusable pattern.

**`Sources/ViewerUI/ShoulderRailView.swift`** (316 LOC) · Panel-toggle button strip
docked to a window edge (v1: all 9 toggles on `.left`). Observes `PanelLayoutStore`/
`SidebarModel`/`DocumentModel` directly (not via `DocumentModel.objectWillChange`) so a
toggle click re-bodies only the rail + sidebar, not the whole content tree. · notable:
explicitly documents a **perf-motivated observation-discipline pattern** (narrow
`@ObservedObject` scoping to avoid a full-tree re-render) that's referenced in
`src-ui-root-4of4.md`'s rollup line but never itself analyzed — the load-bearing
"OBSERVATION DISCIPLINE" comment and its `PanelLayoutRepublishInvariantTests` pin are
invisible to this corpus. · carry: **KEEP** — the narrow-observer-scope pattern
generalizes to any store-backed toggle strip.

**`Sources/ViewerUI/SourceHoverHighlight.swift`** (138 LOC) · Pure geometry for the
source-view line hover highlight (TSK-263); pointer-Y → logical-line mapping mirroring
`SourceGutterView`'s math, wrap-aware (TSK-896). · notable: named 3× in
`src-ui-root-4of4.md` rollup bullets ("Canvas overlays for geometry") as an exemplar of
the compositor-safe-overlay pattern (TSK-488) but never gets a dedicated
role/notable/carry entry — the actual pointer→line geometry algorithm and its
wrap-aware correction are undocumented. · carry: **KEEP** — canonical
compositor-safe-overlay pattern instance; document the geometry formula itself, not
just cite it as an example.

**`Sources/ViewerUI/SourceInvisiblesView.swift`** (120 LOC) · "Show invisibles"
overlay (space/tab/pilcrow markers) for the read-only source view (TSK-364); explicitly
avoids `NSLayoutManager` subclassing (the documented compositor-bug trigger) by using a
clipped SwiftUI `Canvas` tracking `SourceScrollState`, same technique as
`SourceGutterView`. · notable: same situation as `SourceHoverHighlight.swift` — cited
3× in `src-ui-root-4of4.md` rollups as a compositor-safety exemplar, never individually
profiled. Its own test (`SourceInvisiblesViewTests.swift`) IS covered. · carry:
**KEEP** — the "why not `NSLayoutManager`" rationale in its header comment is exactly
the kind of institutional-knowledge trap (LESSONS.md TSK-488 family) this corpus exists
to preserve, and it's currently only preserved in the source file itself.

**`Sources/ViewerCore/Feeds/OPML.swift`** (74 LOC) · OPML (feed-subscription
interchange format) import/export — pure, dependency-free (`Foundation.XMLParser` to
read, string-build to write), fully host-testable. Folder-nesting is flattened on
import (only feed-bearing `<outline>` elements collected). · notable: sibling
`FeedSubscriptionStore.swift` is covered in `src-core-root-2of5.md` and even mentions
"OPML parsing/exporting" in its own notable line, but the actual `OPML.swift` parser
file was never separately profiled. Its test (`OPMLTests.swift`) IS covered. · carry:
**KEEP** — small, clean, dependency-free XML round-trip; reusable as-is.

**`Sources/ViewerCore/Spreadsheet/XLSXSheet.swift`** (81 LOC) · Pure tabular model
for a parsed XLSX worksheet (TSK-682) — dense string-grid output of
`XLSXWorksheet`/`XLSXWorkbook` parsing, deliberately dropping styling/formulae/merged
cells to match the "view, don't edit" epic intent; mirrors the shape `CSVTableView`
already consumes. · notable: only surfaces once, in a terse one-line synthesis bullet
in `src-core-dataapps.md` ("`XLSXSheet` — load + cell access") — no role/notable/carry
of its own, despite the file itself documenting a deliberate scope-narrowing decision
(styling/formulae explicitly out of scope) worth carrying into a rebuild's format
epic. · carry: **KEEP** — the "downgrade to displayed string, reuse the CSV table lens"
design decision is the reusable idea here, not just the code.

**`Tests/RustCoreTests/MsgPackDecoderDepthCapTests.swift`** (132 LOC) · Regression
test for a real, fixed SIGSEGV: `MsgPackReader.decode()` recursed one native stack
frame per array/map nesting level; a sub-16 MiB envelope of ~8M nested single-element
arrays overflowed the stack (signal 139) before a depth cap turned it into a typed
`MsgPackError.tooDeep`. Mirrors a matching Rust-core test
(`deeply_nested_input_is_bounded_not_overflowed`). · notable: **security-relevant
regression test entirely absent from the corpus** — this is exactly the class of
"uncatchable remote DoS, fixed with a depth cap" finding the corpus is meant to surface
so it isn't silently dropped on a rebuild. · carry: **KEEP, HIGH PRIORITY** — the depth
cap itself (not just the test) is a must-carry mitigation for any MessagePack/recursive
wire decoder.

**`Tests/ViewerCoreTests/Sessions/TabSnapshotImageEditStatePersistenceTests.swift`**
(124 LOC) · Serialization-layer coverage for `TabSnapshot.imageEditState` (TSK-1303,
the "image edits lost on session switch" fix's durable half) — additive-optional
Codable field, `nil` omits the JSON key entirely (not literal `null`), legacy
on-disk tabs without the key decode to `nil` (forward-compat downgrade), and
`hasSamePersistedContent` detects a differing edit state so autosave fires. · notable:
this pins the exact **additive-optional Codable discipline** the INDEX.md's
"Most-cited reusable patterns" section already calls out generically ("Forward-compat
Codable discipline... additive-optional fields") — this file is a concrete worked
example of that pattern that the corpus currently doesn't cite. · carry: **KEEP** —
canonical additive-optional-field test shape to replicate for every new persisted
field.

**`Tests/ViewerCoreTests/Walkthrough/WalkthroughHistoryTests.swift`** (149 LOC) ·
Tests for `WalkthroughHistory`, the durable "have I shown the user this before"
completion ledger behind TSK-316 — record/query/cap/persist behavior. · notable: the
Walkthrough module is otherwise covered in `src-core-sessions-review-plugins.md`
(source) and presumably other test batches, but this specific history/ledger test file
has zero mentions; unclear whether `WalkthroughHistory.swift` itself (the source) is
covered — worth a follow-up spot check if the walkthrough-history feature is carried
forward. · carry: **KEEP** — the cap+persist ledger pattern for "don't re-show a
one-time UI element" is generically reusable (onboarding, changelogs, tips).

### Rust (1 zero-mention; 8 shallow-only)

**`rust-core/crates/ffi/src/tests.rs`** (1,715 LOC — the single largest missing
file in this audit) · FFI-boundary test module: exercises the actual `extern "C"`
symbols under the default (`panic = "unwind"`) test profile so `catch_unwind` is
genuinely tested — error codes, panic→error mapping, handle lifecycle, single-writer
concurrency, wire round-trips via `mdvcore_session_open/table` and friends. · notable:
**1,715 LOC of FFI-contract test coverage with zero presence in the corpus** —
`src-rust-other-crates.md` covers the `ffi` crate's `lib.rs`/`handle.rs`/`guard.rs`/etc.
production files but this parallel test module (`#[cfg(test)] mod tests;` style, in its
own file) was skipped entirely, likely because the batch's file enumeration targeted
`src/` production modules and didn't separately walk in-crate test files the way it did
for the `tests/` integration-test directory (which DID get a wildcard mention for
`no_panic_lints_gate_*.rs`). · carry: **KEEP, HIGH PRIORITY** — this is the FFI
boundary's actual regression suite (panic-safety, handle lifecycle, concurrency); for a
Rust-core rebuild this is close to must-read alongside the `lib.rs` it tests.

**Shallow-only (grouped, not individually missing):** `rust-core/crates/core/src/canvas/{chart,deck,dsl,io,lint,lower,tokens,vocab}.rs` — all 8 are named in a single wildcard bullet in `src-rust-core-1of2.md:149` ("`rust-core/crates/core/src/canvas/*.rs` — Other modules (chart, deck, dsl, io, lint, lower, tokens, vocab)") with no per-file LOC/role/notable/carry. These are real gaps in *depth* (no individual analysis exists anywhere in the corpus) even though they're not gaps in *awareness* (the report's author knew they existed and named them). Recommend re-profiling if canvas M1+ (chart/deck rendering, DSL, lint) is in scope for a rebuild — that's 8 modules of unknown size and complexity currently reduced to a parenthetical.

### scripts/ (8 zero-mention; 1 shallow-only)

- `scripts/cc-grammar-wrapper.sh` — tree-sitter grammar C-compile wrapper (paired with `scripts/lib/ccache-env.sh`, which IS covered); likely routes grammar builds through the ccache/sccache wrapper. Not analyzed.
- `scripts/pack-icns.swift` — only referenced in passing ("Invokes scripts/render-icon.swift → iconutil"); `pack-icns.swift` itself (the icon-packing counterpart) has zero mentions, and `render-icon.swift` is mentioned but not analyzed either (both icon-build helpers effectively undocumented beyond one prose clause).
- `scripts/rust-supply-chain-audit.sh` — supply-chain audit script; name suggests it pairs with `scripts/swiftpm-advisory-watch.sh` (covered) for the Rust side. Not analyzed.
- `scripts/stage-frontends.sh` — likely stages CodeMirror/Mermaid/Canvas web frontend build output into `Sources/ViewerUI/Resources/`; not analyzed despite the web-asset build pipeline (`codemirror-build/entry.js`, covered) being otherwise documented.
- `scripts/perf-fixtures/hex-6kb.bin` — binary fixture (6 KB), not code; low-value gap.
- `scripts/vm-uitest/com.markdownviewer.uitest.plist.template` — LaunchAgent template for the VM UI-test harness; sibling `scripts/com.markdownviewer.mdv-serve.plist.template` IS covered.
- `scripts/vm-uitest/README.md`, `scripts/workflows/README.md` — doc files, not code; low-value gaps, mechanically excluded by the batch's own "Swift/code" framing but worth a one-line pointer for a rebuild.

**Shallow-only:** `scripts/install-app.sh` — mentioned 4× across `src-scripts.md` (a "REDO — now subsumed into install-app.sh --with-cli" carry note, and a cross-file bullet on xattr-stripping for iCloud-synced repos) but never given its own File Inventory line despite being one of the ~12 core build/release scripts. Worth a dedicated entry given it's on the critical install path (`build-app.sh` → `install-app.sh` → `/Applications`).

### Web assets

None missing — all 8 files (`canvas.html`/`canvas.js`, `codemirror.{css,html,js}`,
`markdown.css`, `mermaid-shim.{css,js}`) are covered, most by 2–3 reports each.

## Notes on method limits

- Swift basename-matching cannot distinguish two files with the identical basename in
  different directories; the one observed collision (`main.swift` ×2, almost certainly
  the two executable targets' entry points) was not further disambiguated — if one of
  the two is uncovered, this audit would show it as "covered" via the other. Low risk:
  entry-point files are trivial and unlikely to carry unique institutional knowledge.
- This audit checks **presence/absence of a mention**, not **depth or accuracy** of
  the entries that do exist. A file appearing once in a report's inventory with a
  correct one-line role but no `notable`/`carry` guidance would count as "covered"
  here; that's a separate quality question GAPS.md may want addressed elsewhere.
