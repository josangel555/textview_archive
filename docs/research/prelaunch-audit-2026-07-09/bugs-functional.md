# Pre-launch audit — Functional bugs (logic errors, ranges, offset units, state machines)

**Dimension:** Logic errors — inverted conditions, wrong ranges, bad math, wrong string/offset
handling (UTF-16 vs Character vs bytes), state machines with unreachable/absorbing states.
**Date:** 2026-07-10 · **Repo @** `main` (working tree; last commit `304a8290`)

## Executive summary

The engine tier of this codebase is in unusually good shape for this lens: the rust-core
engines (hex, find, cm_edit, formula, diff, nav, transcript) carry differential property
tests, fuzz loops, and explicit unit documentation ("UTF-16 semantics are load-bearing"),
and most Swift pure-logic modules are defensively clamped and host-tested. A broad sample
of ~30 modules across all four strata surfaced **no P0** and **one P1**: the shared
`LSPPositionConverter` splits lines only on the `"\n"` Character, and in Swift a CRLF
(`\r\n`) pair is a *single* grapheme cluster that does **not** equal `"\n"` — so every
CRLF (and CR-only) document is treated as one giant line by the entire LSP position seam
*and* the editor scroll-restore seed. This was confirmed empirically (a compiled repro
shows zero line starts for a CRLF document). Everything else found is P2/P3: a
whole-word+regex grouping bug present identically in both the Swift and Rust find engines
(so the A/B parity test pins the wrong behavior), an LSP text-edit tie-ordering bug, and
two minor comparator/rounding nits.

Findings: **1 × P1, 2 × P2, 2 × P3.**

## Methodology

- Targeted static review driven by the lens, not a line-by-line sweep (the codebase is
  ~380K LOC). Sampled all four strata:
  - **Rust core:** `hex.rs` (full read), `find_engine.rs`, `cm_edit.rs` (reducer kernel),
    `formula.rs` (criteria/glob/date/format sections), `diff.rs` (outline), `nav.rs`
    (NavHistory full read), `transcript.rs` (timestamp/date math).
  - **ViewerCore:** `LSPPositionConverter`, `CMDiagnosticMapping`, `CMFoldRangeMapping`,
    `SyntaxFoldRangeMapping`, `LSPTextEditApplier`, `LSPFraming`, `LSPDefinitionPreview`,
    `FindEngine`, `CSVFind`, `CsvSort`, `CSVViewportPager`, `CellReference`,
    `SpellNavigation`, `HexHighlightPlan`, `DocumentStats`, `ByteSize`,
    `EditLocationHistory`, `ThreeWayMerge` (full read, diff3 walk traced by hand),
    `MCPFraming` (reader buffer math), `ImageEditing/PaintCoordinateMapping`,
    `ImageEditing/ImageResizeMath`, `FlameInteraction`, `TreeSitterEngine` (unit seams),
    `LSPVSCodeExtensions` (version parse).
  - **ViewerUI:** `SelectionHighlightEngine`, `TextDisplayView` find-cycling,
    `ConflictResolutionModel`, `DocumentModel+EditorState` (mount-selection seed),
    `FontPreference`, spot checks of gutter/invisibles row math.
  - **FFI seam:** `CoreClient.swift` find/highlight decoders vs `find_engine.rs` UTF-16
    emission (units verified consistent end-to-end).
- Pattern greps across `Sources/` + `rust-core/` for classic bug shapes: negative-modulo
  cycling, unclamped `String.index(offsetBy:)`, `Int()` float truncation, slice+
  `enumerated()` misuse, integer-division-before-float-conversion, `len()-1` underflow,
  unsigned subtraction, `Data` slice index-space traps.
- **Empirical verification** of the P1 (compiled Swift repro, output shown below). No
  UI/VM tests were run; no repo files modified other than this report.

## Findings

---

### F1 · P1 — CRLF/CR documents collapse to a single line in `LSPPositionConverter`; whole LSP position seam + editor scroll-restore mis-map

- **File:** `Sources/ViewerCore/LSP/LSPPositionConverter.swift:55` (root), also the
  break condition at `:126`.
- **Fix size:** S · **Fix risk:** careful (core seam; needs CRLF/CR tests across all
  three encodings)

**Evidence.** The init records a line start only when `ch == "\n"`:

```swift
// LSPPositionConverter.swift:50-61
while idx < text.endIndex {
    let ch = text[idx]
    ...
    if ch == "\n" {          // ← "\r\n" is ONE Character; this is FALSE for it
        starts.append(codeUnits)
        ...
```

In Swift, `\r\n` is a single grapheme cluster (`Character`), and
`Character("\r\n") == Character("\n")` is **false**. Bare `\r` (classic-Mac) never
matches either. Compiled repro (simulating the init loop exactly):

```
input: "let a = 1\r\nlet b = 2\r\nlet c = 3"
chars equal to \n: 0
lineStartUTF16:    [0]        // should be [0, 11, 22]
```

So for any CRLF or CR file the converter believes the document has exactly one line.
`stringIndex(for:)` (line 119) returns `text.endIndex` for every `position.line >= 1`,
and `utf16Offset(for:)` clamps to the full document length. The same `ch == "\n"` break
condition at line 126 also means a line-0 walk runs past what the server considers line 0.

LSP servers (3.17 §"Text Documents") treat `\r\n`, `\n`, **and** `\r` as line
terminators, so a server working on the same CRLF file reports positions on lines ≥ 1
that this converter cannot resolve.

**Blast radius (all direct constructors/users of the converter):**

| Consumer | Effect on a CRLF file |
|---|---|
| `Sources/ViewerCore/LSP/CMDiagnosticMapping.swift:29` | every diagnostic on line ≥ 1 squiggles at the document end |
| `Sources/ViewerCore/LSP/CMFoldRangeMapping.swift:28` / `Sources/ViewerCore/SyntaxFoldRangeMapping.swift:36` | all fold ranges degenerate (`to <= from`) and are dropped — folding silently disappears |
| `Sources/ViewerCore/LSP/LSPTextEditApplier.swift:23` | **formatting corrupts the document**: every edit on line ≥ 1 resolves to the empty range at doc end, so the formatter's replacement texts are *appended* at EOF instead of replacing their spans (⌘Z is the only recovery) |
| `Sources/ViewerUI/DocumentModel+EditorState.swift:78` | session-restore scroll seed: a saved top line > 1 converts to the document END, so reopening a CRLF file jumps the editor to EOF instead of the saved position — **not an LSP-only bug** |
| `Sources/ViewerUI/LSP/LSPHoverAttachment.swift:448` | hover/goto ranges mis-anchored |

**Why this is the outlier, not the convention:** the rest of the codebase explicitly
handles CRLF/CR — `FindEngine.swift:103-134` (S2-E fix: CR and CRLF line accounting),
`DocumentStats.swift:30-52` (CRLF-aware line count), `LSPDefinitionPreview.splitLines`
(`:114-152`, hand-rolled to tolerate `\r\n` and bare `\r`). There is no CRLF
normalization at load (`TextFileLoader` has none), so raw CRLF text reaches the
converter. `Tests/ViewerCoreTests/LSPPositionConverterTests.swift` /
`...UTF16Tests.swift` contain **no** `\r` coverage (grep-verified) — which is how it
survived.

**Suggested fix.** In the init loop treat `"\r\n"` and `"\r"` as terminators
(`if ch == "\n" || ch == "\r\n" || ch == "\r"`), and mirror the same set in the
`stringIndex(for:)` break (`if ch.isNewline`-style, but pin the exact set — Swift's
`isNewline` also includes U+0085/U+2028/U+2029, which LSP does *not* count; the
conservative fix is the explicit three-case check). Note `codeUnitCount(of:)` already
returns 2 for the `"\r\n"` Character in utf8/utf16, so the accumulated line-start
offsets come out correct once the terminator check is fixed. Add CRLF + CR fixtures to
all three converter test files and one CRLF end-to-end case each for
`CMDiagnosticMapping`, `LSPTextEditApplier`, and `editorMountSelectionSeed`.

---

### F2 · P2 — Whole-word + regex alternation: `\b` wrapped without grouping, in BOTH engines (parity test pins the wrong behavior)

- **Files:** `Sources/ViewerCore/FindEngine.swift:189-191` and
  `rust-core/crates/core/src/find_engine.rs:99-101`
- **Fix size:** S · **Fix risk:** safe

**Evidence.**

```swift
// FindEngine.swift:189-191
if query.wholeWord {
    pattern = "\\b" + pattern + "\\b"
}
```

```rust
// find_engine.rs:99-101
if whole_word {
    pat = format!("\\b{pat}\\b");
}
```

For a regex query with a top-level alternation, e.g. `cat|dog` with Whole Word on, the
compiled pattern is `\bcat|dog\b` — i.e. `(\bcat)|(dog\b)`. `"catapult"` then matches
`cat` (leading boundary only) and `"hotdog"` matches `dog` (trailing boundary only),
both of which the Whole Word toggle explicitly promises to exclude. The literal branch is
safe (escaped, no alternation possible); only `kind == .regex` + `wholeWord` is affected.
Because the Swift and Rust engines share the identical construction, the Rust-vs-Swift
A/B parity harness cannot catch it — both agree on the wrong answer.

**Failure scenario.** Find bar (or the MCP `find` tool with `regex:true`) with query
`cat|dog`, Whole Word enabled, document `"catapult hotdog"` → 2 matches reported;
correct answer is 0.

**Suggested fix.** Wrap in a non-capturing group on both sides:
`"\\b(?:" + pattern + ")\\b"` / `format!("\\b(?:{pat})\\b")`. (`regex-lite` supports
`(?:…)`.) Add a shared test vector (alternation + whole-word) to both engines' suites
and to the A/B parity set.

---

### F3 · P2 — `LSPTextEditApplier`: same-position insertions apply in wrong / nondeterministic order

- **File:** `Sources/ViewerCore/LSP/LSPTextEditApplier.swift:38-52`
- **Fix size:** S · **Fix risk:** safe

**Evidence.**

```swift
// LSPTextEditApplier.swift:38-43
// Reverse document order; ties (same start: pure insertions at one
// point) keep their response order by using a stable sort key.
resolved.sort { a, b in
    if a.from != b.from { return a.from > b.from }
    return a.to > b.to
}
```

Two problems, both for multiple edits at the same position (LSP 3.17 explicitly allows
"multiple inserts at the same position; the order in the array defines the order of the
inserted strings"):

1. **Swift's `sort(by:)` is not guaranteed stable**, so for two pure insertions at the
   same offset (`from == to` equal for both) the comparator returns `false` both ways and
   their relative order is unspecified — the comment's "stable sort key" claim is wrong.
2. Even *if* the sort were stable, preserving response order is the wrong direction:
   the edits are applied back-to-front, so an insert applied *later* ends up *earlier*
   in the document. Inserting `X` then `Y` at the same position must yield `…XY…`
   (spec); stable-descending + reverse application yields `…YX…`. The correct tie-break
   for reverse application is **descending original array index**.

`Tests/ViewerCoreTests/LSP/LSPTextEditApplierTests.swift` has a single zero-length-range
case (`test_insertion_zeroLengthRange`, line 30) and no same-position-pair case
(grep-verified).

**Failure scenario.** A formatter/rename response containing two inserts at one position
(e.g. an import line + a leading comment, both at `(0,0)`) lands in reversed or
run-to-run-varying order.

**Suggested fix.** Capture the array index in `Resolved` and sort
`(from, to, index)` all descending; applying descending-index ties last-first restores
spec order. One new test: two inserts at the same position must appear in response order.

---

### F4 · P3 — `CsvSort` comparator violates strict weak ordering when a "numeric" column contains `nan`

- **File:** `Sources/ViewerCore/CsvSort.swift:22-42`
- **Fix size:** S · **Fix risk:** safe

**Evidence.** The numeric-column detector accepts anything `Double.init` parses —
which includes `"nan"`, `"inf"`, and hex-float forms:

```swift
let numeric = rows.allSatisfy { ... c.isEmpty || Double(c) != nil }
...
if numeric, let na = Double(ca), let nb = Double(cb) {
    if na == nb { return a.offset < b.offset }   // NaN == NaN is FALSE
    ascendingOrder = na < nb                     // NaN < x is FALSE
}
```

For two rows whose cells are `nan`, `na == nb` and `na < nb` are both false, so with
`ascending == false` the comparator returns `true` for `(x, y)` **and** `(y, x)` — an
inconsistent (non-strict-weak) ordering. `sorted(by:)`'s result is then unspecified, the
documented stability guarantee breaks, and NaN rows interleave arbitrarily with numbers
(comparisons involving NaN are non-transitive).

**Failure scenario.** A CSV with a column containing `nan` (a common export artifact of
pandas/NumPy) sorted descending: row order is arbitrary and can differ between runs.

**Suggested fix.** Either treat non-finite parses as text (change the detector to
`Double(c).map(\.isFinite) == true`) or order non-finite values consistently (e.g. NaN
sorts last like empties). Add a `nan`-column test.

---

### F5 · P3 — `CMDiagnosticMapping` widens a zero-length diagnostic by one UTF-16 code unit, which can split a surrogate pair

- **File:** `Sources/ViewerCore/LSP/CMDiagnosticMapping.swift:57-61`
- **Fix size:** S · **Fix risk:** safe

**Evidence.**

```swift
if clampedTo == clampedFrom {
    // Widen to one code unit so the squiggle is visible.
    clampedTo = min(docUTF16Count, clampedFrom + 1)
}
```

If the zero-length diagnostic lands immediately before an astral-plane character
(emoji, many CJK-B ideographs), `clampedFrom + 1` points between the high and low
surrogate. JS/CM6 tolerates mid-surrogate offsets without throwing, so this is cosmetic
(the squiggle covers half a character's code units, and any downstream slice of the
range yields a lone surrogate), but it is still an offset-unit correctness nit in a file
whose whole purpose is offset-unit correctness.

**Suggested fix.** Widen by the UTF-16 length of the character at `clampedFrom`
(1 or 2), e.g. via the already-built converter, or accept-and-document. One test with a
diagnostic at an emoji boundary.

---

## Positive observations

- **`rust-core` engines are exemplary for this lens.** `hex.rs` guards the width-0
  underflow and the `u32::MAX`-width allocation abort, and carries a differential
  property test against a naive reference plus a deterministic fuzz loop asserting
  in-bounds, non-overlapping hits (`hex.rs:338-435`). `cm_edit.rs` operates on
  `Vec<u16>` precisely because CM6 indexes UTF-16, validates ranges up front, and
  rejects (rather than U+FFFD-substitutes) split surrogates (`cm_edit.rs:47-57`).
- **The Rust find engine emits UTF-16 units with proptest bounds checks**
  (`find_engine.rs:153-215, 519-536`), and `CoreClient.swift` documents the `Int(UInt64)`
  trap it avoids (`CoreClient.swift:1337`). The FFI seam's unit contract (UTF-16 both
  sides) held everywhere I checked.
- **`ThreeWayMerge.swift` (fresh TSK-1171 code) traced clean**: the diff3 stable/unstable
  walk, `nextStable` anchor search, classification, and coalescing all behaved correctly
  on hand-traced reorder/tail-insert cases; `resolved(_:)` refuses partial resolution.
- **Negative-modulo cycling is done right everywhere it appears** (14 sites checked:
  `(i - 1 + count) % count` or the double-mod in `SpellNavigation.step`).
- **`CellReference` implements bijective base-26 correctly** (the `Z`→`AA` off-by-one is
  explicitly handled, with overflow guards).
- **`MCPFraming` documents and defends against the macOS-26 `Data` slice index-space
  trap** everywhere it buffers (`MCPFraming.swift:228-238, 280-307`); the one
  `suffix(from:)` outside it (`MDVFakeLSPServer/main.swift:442`) operates on `[UInt8]`
  (always 0-based) and is fine.
- **CRLF/CR are handled correctly in every text engine except the one flagged in F1**
  (`FindEngine` S2-E, `DocumentStats`, `LSPDefinitionPreview.splitLines`).

## Coverage gaps (not examined under this lens)

- **Canvas subsystem** (`rust-core/crates/core/src/canvas/*` ~10 modules, `canvas.js`,
  `CanvasDocAdapter`) — large DSL/lowering surface, unexamined.
- **ImageEditing renderer internals** (`Renderer.swift`, `RasterCanvas`,
  `VectorOverlay`, `ImageDocument` — only the two pure-math helpers were read).
- **Terminal, Git graph layout (`GitGraphColumn` lane math), Sessions persistence,
  Plugins, Walkthrough, Review, Audio** feature clusters.
- **`DocumentModel.swift` god-model bulk** (3.6K LOC; only the editor-state extension
  was read) and most Coordinators.
- **`ClaudeLogParser` / transcript Swift twin, `markdown.rs` AST emission, `json.rs`,
  `editor_session.rs`, `history.rs`, `pm`/`serve`/`tui`/`web` crates.**
- **Bundled JS** (CodeMirror/Mermaid/canvas web assets) — vendored, out of scope.
- Anything requiring runtime/VM observation (render, AX, timing) — static review only.
