# Recent Swift & Rust additions — adoption survey (TSK-793)

**Date:** 2026-06-19 · **Type:** spike (survey + adoption shortlist) ·
**Status:** survey complete; one foundation slice landed (see §5).

## 0. TL;DR

This is the deliverable for TSK-793 ("look at Swift and Rust recent
additions"): a survey of language/stdlib features that shipped in our
**Swift 6.0–6.3** toolchain and **Rust edition 2024 / MSRV 1.88** window,
mapped onto patterns that *actually exist* in `Sources/` and `rust-core/`,
ranked by value-vs-risk, with concrete candidate refactor tickets.

Baseline (verified 2026-06-19):

| Knob | Value | Source |
|---|---|---|
| Swift tools version | `6.0` | `Package.swift:1` |
| Swift toolchain (CI/VM) | `6.3` | `CLAUDE.md` (TSK-439) |
| Swift language mode | default (6) | no `swiftLanguageMode` override in `Package.swift` |
| Rust edition | `2024` | `rust-core/Cargo.toml:26` |
| Rust MSRV (`rust-version`) | `1.88` | `rust-core/Cargo.toml:30` |
| Cargo resolver | `3` | `rust-core/Cargo.toml:15` |
| Edition-2024 compat lint | `rust_2024_compatibility = warn` | `rust-core/Cargo.toml:70` |

**Adoption shortlist** (detail in §3/§4, tickets in §6):

1. **[LANDED] `Sequence.count(where:)`** (Swift 6.0) — replace allocating
   `xs.filter { … }.count` roll-ups. 11 `ViewerCore` sites converted in this
   change; 4 `ViewerUI` sites remain (TSK-793a).
2. **Typed throws `throws(E)`** (Swift 6.0) — narrow, high-value at the
   RustCore FFI boundary and small pure-logic engines (155 throwing funcs
   in `Sources/`, **zero** typed). Selective, not blanket. (TSK-793b)
3. **`std::sync::LazyLock` / `LazyCell`** (Rust 1.80) — replaces any
   `once_cell` / `lazy_static` usage with zero deps. *Currently a no-op:
   the audit found neither crate in use* — keep as a guard/convention note.
4. **`if let` shorthand / `let … else`** — already idiomatic; no action.
5. **Noncopyable types / `~Copyable` / `consuming`** (Swift) and Rust
   edition-2024 closure-capture & `gen` blocks — **defer**; high churn,
   low payoff for our shapes today.

The owner asked a question, not for a big refactor: this doc answers it and
lands the single cleanest, fully-host-tested win so the spike produces code,
not just prose. The rest is filed, not force-shipped.

---

## 1. Scope & method

- **Versions:** Swift 6.0 → 6.3 (our toolchain ceiling); Rust 1.80 → 1.88
  (MSRV) plus edition-2024 semantics. Language + stdlib only — **no new
  third-party crates / SwiftPM packages** are recommended (owner dep policy).
- **Method:** for each candidate feature, grep the tree for the *pattern it
  replaces*, count real sites, and judge value (safety / perf / clarity) vs
  risk (churn, MSRV, ABI, review cost). Features with no matching pattern
  are recorded as "no-op / convention note" rather than invented work.
- **Bias guard:** the shortlist is driven by what the code *does*, not by
  what's shiny. `InlineArray`, `Span`, `gen` blocks etc. are surveyed and
  explicitly **deferred** because our shapes don't benefit yet.

---

## 2. Swift 6.x — what shipped, and does it map onto us?

| Feature (ver) | Pattern it improves | Sites in tree | Verdict |
|---|---|---|---|
| `Sequence.count(where:)` (6.0, SE-0220) | `xs.filter{…}.count` (extra alloc + full pass) | 18 total (11 `ViewerCore`, 4 `ViewerUI`, 3 misc) | **ADOPT** — done for `ViewerCore` (§5); `ViewerUI` → TSK-793a |
| Typed throws `throws(E)` (6.0, SE-0413) | `throws` funcs over a single concrete error enum | 155 throwing funcs, **0** typed | **ADOPT selectively** — FFI boundary + small engines (TSK-793b) |
| `@retroactive` conformance (6.0) | retroactive conformance warning suppression | already used (`SyntaxTheme.swift:114`) | already adopted |
| Full data-race safety / `Sendable` (6.0 mode) | actor isolation | extensively used (actors, `@MainActor`, `Sendable`) | already on it; default mode in effect |
| `package` access level (5.9) | cross-module-within-package `public` leakage | many gratuitously-`public` symbols | **NICE-TO-HAVE** — large surface, low urgency (TSK-793c) |
| Noncopyable `~Copyable` / `consuming`/`borrowing` (5.9–6.0) | move-only resources (fd/handle wrappers) | a few handle wrappers; mostly class-based | **DEFER** — ownership churn outweighs payoff for ARC types |
| `InlineArray` / `Span` (6.1/6.2) | fixed-size buffers, zero-copy slices | parsers mostly already lean on `Array`/`ArraySlice` | **DEFER** — measure first; no profiled hotspot points here |
| `count(where:)`-style stdlib (`trimmingPrefix`, `chunks(ofCount:)`) | hand-rolled prefix-trim / chunking | scattered | **OPPORTUNISTIC** — fold into TSK-793a sweep |

### 2.1 Why `count(where:)` is the right first slice

`xs.filter { p($0) }.count` allocates an intermediate `Array` and walks the
sequence once to *build* it, then again to count. `xs.count(where: p)` is a
single pass with **no allocation** (`Sequence.count(where:)`, SE-0220). It's
behaviourally identical, so the diff is risk-free and the existing tests
already pin every count — making this the textbook "lands code, can't
regress silently" adoption to demonstrate the survey's recommendation.

Converted sites (all host-testable computed properties / initializers):

- `LSPDiagnosticsStore.{errorCount,warningCount,informationCount,hintCount}`
- `LSPProblemsViewModel.FileGroup.{errorCount,warningCount}`
- `LSPProblemsViewModel.{liveServerCount,deadServerCount}`
- `ReviewStore` summary `unresolvedCount`
- `CrossFileReplace.Summary.filesChanged`

### 2.2 Typed throws — where it pays, where it doesn't

`throws(E)` lets a function declare it throws exactly one concrete error
type, which (a) makes `catch` exhaustive without a `default`, (b) avoids
existential `any Error` boxing on hot paths, and (c) documents the failure
contract in the signature. **Do not blanket-convert** — value concentrates
where:

- the function already throws *one* enum (`RustCore.CoreError`, LSP framing
  errors, the small pure-logic parsers), and
- callers actually switch on the cases.

Avoid it on functions that legitimately propagate heterogeneous errors
(file I/O + decode + network), where `throws` (untyped) stays correct and
typed throws would force a lossy wrapper enum. This is a *selective*,
per-engine adoption — filed as TSK-793b with the FFI boundary as slice 1.

---

## 3. Rust edition 2024 / 1.80–1.88 — what shipped, and does it map onto us?

| Feature (ver) | Pattern it improves | Sites in tree | Verdict |
|---|---|---|---|
| `std::sync::LazyLock` / `std::cell::LazyCell` (1.80) | `once_cell::sync::Lazy` / `lazy_static!` | **0** (audit found neither crate) | **NO-OP / convention note** — if a `Lazy` is ever wanted, use std, not a dep |
| `unsafe_op_in_unsafe_fn` default-deny (edition 2024) | implicit-unsafe inside `unsafe fn` | FFI crate has unsafe blocks (`crates/ffi/`) | already on edition 2024; **verify lint is satisfied** (TSK-793d) |
| RPIT lifetime capture rules / `use<>` (edition 2024) | over-capturing `-> impl Trait` | ~few `impl Trait` returns | **OPPORTUNISTIC** — only if a capture warning appears |
| `gen` blocks / `Iterator` from generators (nightly→1.x) | hand-rolled iterators | a few | **DEFER** — not stable on 1.88 in the form we'd want |
| `Option::is_none_or`, `[T]::split_off`, slice `chunk_by` (1.77–1.81) | manual predicate/slice plumbing | scattered | **OPPORTUNISTIC** — fold into the next rust-core touch |
| Edition-2024 closure capture (disjoint, `let` in `if let` temp scope) | subtle borrow-scope bugs | covered by edition 2024 already | already in effect; `rust_2024_compatibility = warn` is the guard |

### 3.1 The honest finding for Rust

`rust-core/` is **already on edition 2024 with the migration-compat lint
on**, so most "recent Rust" wins are *already structurally adopted*. The
remaining concrete action is small and verification-shaped (confirm the
`unsafe_op_in_unsafe_fn` lint is clean in the FFI crate) rather than a
feature backfill. We deliberately did **not** invent refactors here — that
would be churn for its own sake against the owner's frugality directive.

---

## 4. Risk / value matrix

```
 value ^
       |  count(where:) [DONE]      typed-throws (FFI)
  high |  *                         *
       |
       |  package-access            unsafe_op lint verify
  med  |  *                         *
       |
       |  ~Copyable/consuming       InlineArray/Span      gen blocks
  low  |  *  (DEFER)                *  (DEFER)            *  (DEFER)
       +-----------------------------------------------> risk/churn
          low                med                 high
```

Top-left (high value, low churn) is where we act: `count(where:)` (landed)
and typed throws at the FFI boundary (filed). Bottom-right is surveyed and
explicitly deferred.

---

## 5. Foundation slice landed in this change

- **Source:** 11 `filter{…}.count` → `count(where:)` conversions across
  `LSPDiagnosticsStore`, `LSPProblemsViewModel`, `ReviewStore`,
  `CrossFileReplace`, `ReviewExporter`.
- **Tests:** `Tests/ViewerCoreTests/CountWhereAdoptionTests.swift` — 12
  host tests pinning every converted roll-up incl. boundary cases (empty /
  all-match / none-match). `swift test --filter CountWhereAdoptionTests`
  green (12/12).
- **Risk:** nil — behaviour-identical stdlib substitution; pre-existing
  suites also still pin these counts.

## 6. Candidate follow-up tickets (file from this doc)

| Ticket | What | Effort | Risk |
|---|---|---|---|
| TSK-793a | `count(where:)` sweep for the 4 `ViewerUI` sites + `trimmingPrefix`/`chunks` opportunistic folds | S | low |
| TSK-793b | Typed throws `throws(E)` at the RustCore FFI boundary (slice 1), then per-engine | M | med (signature changes ripple to callers) |
| TSK-793c | `public` → `package` access-level tightening for intra-package-only symbols | M | low (mechanical, large surface) |
| TSK-793d | Verify `unsafe_op_in_unsafe_fn` lint is clean across `crates/ffi/`; add explicit `unsafe {}` where implicit | S | low |

None of these require new dependencies. TSK-793b is the only one with real
review cost and should ship per-engine, not as one mega-PR.
