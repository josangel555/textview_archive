# Homework: Are we using modern language/test features? (TSK-792) — 2026-06-19

**Question (owner):** Are we using modern language and test features across the
codebase (Swift + Rust)? Investigate and recommend.

**TL;DR.** **Rust core: yes, near state-of-the-art** — edition 2024, MSRV 1.88
(let-chains), `unsafe_code = forbid` on the pure crate, clippy `pedantic` +
hand-picked no-panic denies. Little to add. **Swift app: a split picture** —
we are *fully* on the **Swift 6 language mode** with deep, correct concurrency
adoption (92 actors, `Sendable` pervasive, 163 `nonisolated`/`isolated`
annotations, 286 `@MainActor`), but we lag on three *post-6.0* ergonomic
features that are now low-risk and worth incremental adoption:
1. **Swift Testing** — 0 of ~797 test files use it (covered in depth by the
   sibling TSK-787 doc; recommendation echoed here).
2. **`@Observable` (Observation framework)** — 0 sites; **573**
   `ObservableObject`/`@Published`/`@StateObject`/`@ObservedObject`/
   `@EnvironmentObject` sites still on the Combine-era pattern.
3. **`if`/`switch` expressions** and **typed throws** — 0 sites each; both are
   pure-ergonomic, mechanically adoptable in new code.

Recommendation: **adopt-in-new-code, no big-bang migration.** Add a short
`CLAUDE.md` convention; let the three Swift gaps accrete on the natural edit
path. Nothing here is a correctness or perf defect — it's idiom drift.

This doc is the language/test-feature *usage census*. The narrower
**"migrate the test suite to Swift Testing?"** decision lives in
`docs/TEST_FRAMEWORK_SWIFT_TESTING_VS_XCTEST_2026-06-19.md` (TSK-787) — not
re-litigated here, only cross-referenced.

---

## Method

All figures are `grep`/`find` counts over `Sources/`, `Tests/`, and
`rust-core/crates/` at HEAD on 2026-06-19 (host Swift 6.3.2, workspace Rust
edition 2024, MSRV 1.88). Counts are *indicative density*, not exhaustive
semantic analysis — a few will double-count or miss edge syntax, but the
order-of-magnitude signal (0 vs hundreds) is what drives the recommendations.

---

## Swift — language feature census

| Feature | Sites | Status | Note |
|---|---:|---|---|
| `swift-tools-version` | `6.0` | current-1 | 6.0 manifest → **Swift 6 language mode** is the default (no `swiftLanguageMode` override needed). Bumping the manifest to 6.1/6.2 buys nothing unless we adopt a 6.1+ stdlib type. |
| **Strict concurrency** | — | **fully adopted** | This is the strongest area. |
| ⤷ `actor` declarations | 92 | ✅ | Real isolation, not `DispatchQueue` lock-shims. |
| ⤷ `Sendable` references | 796 | ✅ | Pervasive — conformances + constraints. |
| ⤷ `@MainActor` | 286 | ✅ | UI isolation done properly. |
| ⤷ `nonisolated` / `isolated` params | 163 | ✅ | Fine-grained isolation control. |
| ⤷ `@unchecked Sendable` | 42 | ⚠️ minor | Each is a hand-audited escape hatch; not wrong, but each is a small standing risk. Worth a periodic re-audit (own ticket if it grows). |
| ⤷ `withTaskGroup` / structured concurrency | 1 | note | Low — most async is request/response, not fan-out. Not a gap; the workload rarely needs task groups. |
| ⤷ `AsyncStream` / `AsyncSequence` | 0 | note | None. Event streams currently flow through Combine/delegate callbacks. Candidate where we bridge callback APIs to async, but not urgent. |
| `guard let` / `if let` shorthand | 187 | ✅ | Modern shorthand in active use. |
| `@resultBuilder` / `@ViewBuilder` | 110 | ✅ | Idiomatic SwiftUI. |
| `some` / `any` existentials | 374 | ✅ | Opaque + boxed existentials used correctly. |
| `package` access level | 28 | ✅ | The 5.9 access level, used for cross-module-within-package surface. |
| Regex (`Regex`, `try Regex`, `#/…/#`) | 23 | ✅ | Typed regex in use (6 `Regex { }` builder DSL sites). |
| `Duration` / `ContinuousClock` | 4 | partial | Some adoption; most timing still `Date`/`DispatchTime`. Low-value to chase. |
| **`@Observable` (Observation)** | **0** | ❌ **GAP** | **573** legacy `ObservableObject`-family sites. macOS 14+ feature; we target macOS 15 → fully available. See below. |
| **`if` / `switch` as expressions** | **0** | ❌ gap (cosmetic) | Zero `= if`/`= switch`. Pure ergonomics; adopt in new code. |
| **Typed throws (`throws(E)`)** | **0** | ❌ gap (cosmetic) | None. The Rust FFI boundary (`CoreError`) is the natural first candidate — a typed-throws Swift wrapper would make the error set exhaustive at call sites. |
| Macros (`@freestanding`/`@attached`) | 0 | n/a | We author none and consume none beyond the compiler-builtin `#expect`-style. No need to author macros for this app. |
| Noncopyable (`~Copyable`, `consuming`) | 6 / 4 | minimal | Niche. Used where it matters (resource handles); no need to spread. |
| `InlineArray` / `Span` / `RawSpan` (6.1+) | 0 | n/a | Would require a 6.1 manifest bump *and* a hot path that benefits. The Rust core owns the perf-critical buffer work; Swift-side `Span` is not currently justified. |

### The `@Observable` gap (the one with teeth)

573 sites across the SwiftUI layer still use the **Combine-era**
`ObservableObject` + `@Published` + `@StateObject`/`@ObservedObject`/
`@EnvironmentObject` pattern. The modern replacement is the **Observation
framework** (`@Observable` macro + plain `@State`/`@Bindable`), available on
**macOS 14+** — and we target **macOS 15**, so it is fully usable today.

Why it matters (not just idiom):
- **Fewer invalidations / better SwiftUI perf.** `@Observable` tracks
  *field-level* reads — a view re-renders only when a property it actually read
  changed. `@Published` invalidates on *any* published change the view observes.
  For a document app with large model objects driving many views, this is a real
  (if modest) latency win and dovetails with the perf lane (TSK-791 family).
- **Less boilerplate.** No `@Published` per field; no `objectWillChange`
  plumbing; `@StateObject`/`@ObservedObject` collapse to `@State`/`@Bindable`.

Why **not** a big-bang migration:
- 573 sites is a large, view-coupled surface. Each conversion changes view
  invalidation semantics → must be re-validated **on the VM** (render path has
  no host coverage — per `CLAUDE.md` testing rules, `@Observable`-driven view
  updates are exactly the "rendered behavior" class that host tests can't prove).
- Mixed `ObservableObject` + `@Observable` coexists fine, so there's no
  forced cutover.

Recommendation: **opportunistic migration.** When a model object is already
being edited for another reason *and* its views are easy to re-validate, convert
it to `@Observable`. Prioritize hot, frequently-invalidated models flagged by
the perf lane. Do **not** open a 573-site sweep ticket.

---

## Rust — language feature census

| Feature | Status | Evidence |
|---|---|---|
| **Edition** | **2024** ✅ (latest) | `rust-core/Cargo.toml` `edition = "2024"` |
| **MSRV** | **1.88** ✅ | Real floor — core uses **let-chains** (stabilized 1.88). Understating it would die on E0658 instead of a clean "toolchain too old" (audit TSK-553). |
| `rust_2024_compatibility` lint | **warn** ✅ | Workspace lint actively keeps us 2024-clean. |
| `unsafe_code = "forbid"` | ✅ | On the pure `mdvcore-core` crate; `unsafe` is confined to `mdvcore-ffi` (the only place symbol exports + the C boundary live). Exactly the right boundary. |
| clippy `all = deny`, `pedantic = warn` | ✅ | Strong static posture. |
| No-panic denies | ✅ (notably strict) | `unwrap_used`/`expect_used`/`indexing_slicing`/`string_slice`/`panic` = **deny** in non-test code; `cast_possible_truncation`/`cast_sign_loss` = deny with reasoned `#[allow]`s. This is *stricter than most production Rust*. |
| `unsafe extern` / edition-2024 unsafe-attr forms | 37 sites | ✅ | The FFI crate uses the edition-2024 `unsafe extern` block form. |
| let-chains (`if let … && …`) | present | ✅ | The reason MSRV is 1.88. |
| GATs / `impl Trait` in return | 3 / 1 | ✅ minimal | Used where needed; not over-applied. |
| `async fn` | 0 | n/a (correct) | The core is **sans-IO** by design — no async runtime, no tokio. This is a deliberate architecture choice (transport-agnostic core), not a gap. |
| Dep hygiene | ✅ | Every dep pinned exactly (`=x.y.z`), `default-features = false` + explicit minimal feature lists (owner rider TSK-629). |

**Verdict for Rust: effectively no gap.** The only feature *not* used that a
"modern Rust" checklist might flag is async — and that's an intentional
sans-IO architecture decision, not drift. The one thing worth noting is that
there is **no `rust-toolchain.toml` pin** in `rust-core/` — MSRV is documented
in `Cargo.toml` but not enforced via a pinned toolchain file. Minor; the gate
catches drift via the lints.

---

## Test-framework feature census

| Stack | Modern feature | Adopted? | Detail |
|---|---|---|---|
| **Swift** | Swift Testing (`import Testing`, `@Test`, `#expect`, `@Suite`, parameterized `@Test(arguments:)`) | **0 / 797 files** | Full XCTest. The migrate-or-not decision is **TSK-787** — recommendation there is **hybrid** (new pure-logic tests in Swift Testing; keep XCTest as the tier/UI/VM backbone). |
| Swift | XCTest async (`XCTestExpectation`, `fulfillment(of:)`) | 49 sites | Modern async-XCTest forms in use. |
| Swift | `measure {}` / `XCTMetric` perf tests | 0 | Perf is measured via the bespoke `PerfSignpost`/xctrace harness (`docs/PERFORMANCE_PROFILING.md`) + bench tests, not `XCTMetric`. Deliberate — the signpost harness is richer for this app. |
| Swift | Table-driven loops that would map to `@Test(arguments:)` | 117 files | This is the **single biggest concrete win** if/when Swift Testing lands: parser golden corpora, capture maps, parity tables, fuzz tables all loop manually today. Parameterized tests would give per-case failure isolation + names for free. |
| **Rust** | `#[test]` / `#[cfg(test)]` | 678 / 43 | Standard built-in test harness, broadly used. |
| Rust | `cargo nextest` | not wired | Gate uses `cargo test`. nextest = faster + better isolation, but a **new tool dependency** → owner-gated; not adopted. |
| Rust | property testing (`proptest`/`quickcheck`) | 0 | None. Would be a **new dependency** (owner-gated). The parser/CSV/markdown engines are *exactly* the workload where property tests pay off (round-trip + invariant checks). Worth a future dep-approval spike — flagged, not added. |
| Rust | `criterion` benches | 0 | Benches are custom (`*Bench` tests). criterion = new dep, owner-gated. |

---

## Recommendations (ranked, each independently shippable)

1. **Swift Testing — hybrid adoption (per TSK-787).** Add a one-line
   `CLAUDE.md` convention: *new pure-logic `ViewerCoreTests`/`RustCoreTests`
   may use `import Testing`*. Zero migration cost; biggest ergonomic win is the
   **117 table-driven test files** → `@Test(arguments:)`. **No dep, no risk.**
2. **`@Observable` — opportunistic, perf-driven.** Convert hot,
   frequently-invalidated models on the natural edit path; re-validate on the
   VM. Tie to the perf lane. **No dep. No big-bang ticket.**
3. **`if`/`switch` expressions + typed throws — new-code idiom.** Cosmetic;
   adopt going forward. Typed throws' best first home is the `CoreError` FFI
   boundary wrapper (exhaustive error sets at call sites). **No dep, no risk.**
4. **Property testing for Rust engines (proptest)** — **owner dep-approval
   needed.** Highest *correctness* upside of anything here (round-trip/invariant
   fuzzing of CSV/markdown/find). Run a dep-approval spike before adopting.
5. **`cargo nextest`** — **owner tool-approval needed.** Test speed/isolation
   win; weigh against the minimal-deps posture. Not urgent.
6. **`AsyncStream` bridging + `Duration`/`Clock` consistency** — minor; adopt
   where a callback→async bridge or a timing site is already being touched.

**Do NOT do:** a 573-site `@Observable` sweep, a 7.5k-func Swift Testing
migration, authoring Swift macros, or adding `Span`/`InlineArray` without a
measured hot path. None clears the cost/risk bar.

---

## Items needing owner input (dep/tool gates)

- **proptest** (Rust dev-dependency) — for engine property testing (rec #4).
- **cargo nextest** (Rust test runner tool) — faster/isolated test runs (rec #5).
- **criterion** (Rust bench dependency) — only if we want standardized benches.

All three are *new dependencies/tools* → gated per the minimal-deps policy. This
doc files them as candidates; it does not adopt them.
