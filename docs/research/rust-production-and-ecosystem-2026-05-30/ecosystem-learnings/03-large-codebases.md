# Learnings from Large Rust Codebases: Architecture, Compile Times, and Scaling

## Learnings from Large Rust Codebases

Synthesis of documented lessons from rust-analyzer (matklad), rustc, ripgrep, Servo, tokio/Firezone, and cargo on how to organize, scale, and evolve a large Rust project — weighted toward primary sources and toward what teams *regret* or wish they'd done from day one. Several findings directly reinforce TextView's stated preferences (sans-IO core, minimal deps); a few cut against intuition.

### 1. The dominant cost is navigation, not authorship

matklad's most-cited lesson: *"it takes 2x more time to write a patch if you are unfamiliar with the project, but it takes 10x more time to figure out where you should change the code"* (ARCHITECTURE.md, 2021). The thing that separates core devs from drive-by contributors is a mental *codemap* — the physical layout of the code. His prescription, cheap now and expensive to retrofit:

- Write an **`ARCHITECTURE.md`** once the project clears ~10k LOC. Keep it brief (every recurring contributor reads it), describe only things unlikely to change, and give a "country-level" codemap answering *"where's the thing that does X?"* — not implementation detail.
- **Name files/modules/types in prose, but avoid hyperlinks** (they rot); tell readers to use symbol search.
- **Document invariants explicitly — especially the absence of something** ("body type inference never invalidates global data", "only the server crate does I/O"). Invariants that live only in people's heads are the first thing lost as a team grows.

### 2. Sans-IO / functional core is a *vindicated* pattern at scale

This is the strongest external validation of TextView's chosen architecture. rust-analyzer's `hir`/`ide` layers do **no I/O and cannot fail** — they return `(T, Vec<Error>)` rather than `Result`, so a broken build never blocks IDE features (graceful degradation). Firezone's `connlib` rebuilt its networking core sans-IO and documented the production payoff:

- Core state machines expose `handle_input()`, `poll_transmit()`, `handle_timeout(now: Instant)`, `poll_timeout()`. **Time is passed in as a parameter**, never read via `Instant::now()` inside the core — this is what makes "advance time 5 minutes in one tick" tests possible.
- Synchronous `&mut self` cores **avoid the `Arc<Mutex>`/channel tax** of async Rust entirely — no lock contention, no nondeterministic task ordering.
- Enabled **property/simulation testing**: a reference state machine as ground truth + `proptest` running thousands of scenarios per CI run, deterministically.

**Documented downsides to budget for:** `poll_timeout` bugs cause hard-to-debug busy-loops; multi-step sequential workflows are verbose without `.await`; few ecosystem crates are sans-IO, so you'll wrap async/blocking libs at the edge yourself.

### 3. Incremental computation: salsa vs. hand-rolled

Both rust-analyzer (salsa) and rustc (the red-green query DAG) converged on **demand-driven, memoized pure queries** as the spine of a responsive tool. Key invariant from rustc: queries must be **pure functions of their inputs**, forming an acyclic graph. rust-analyzer cancels stale work via `catch_unwind` panics caught at the `ide` boundary and converted to `Result<T, Cancelled>`. *Gotcha:* this is heavy machinery — don't adopt salsa preemptively. For a viewer/editor, a simpler dirty-flag + recompute may suffice until interactive latency on large docs forces fine-grained incrementality.

### 4. Workspace structure: flat, not nested

matklad's "Large Rust Workspaces" (2021), validated by Servo (~600 modules / 20 crates) and ripgrep:

| Decision | Recommendation | Why |
|---|---|---|
| Layout | **Flat** `crates/*`, no nesting | "even large lists are easier to grok than small trees"; trees rot as people guess where new crates go |
| Root manifest | **Virtual** (no root crate) | a root crate pollutes root with `src/` and forces `--workspace` on every command |
| Crate name = folder name | exact match | makes navigation and renames mechanical |
| Internal crate versions | `version = "0.0.0"` | signals "not published"; isolate publishable crates under `libs/` |
| Automation | **`cargo xtask`** crate in Rust | replaces Makefiles/shell; one toolchain, cross-platform |

ripgrep's facade pattern is worth copying: `grep` orchestrates `grep-matcher` (trait abstraction), `grep-regex`/`grep-pcre2` (pluggable engines), `grep-searcher`, `grep-printer`. The **trait boundary made the regex engine swappable** — exactly the seam TextView wants between core and the Swift/WASM/TUI frontends.

### 5. Compile time is an architectural concern, and the crate graph is the lever

Servo's lesson: a Rust crate is **whole-program-compiled as one unit**, so monolithic crates kill build parallelism (45 min clean, 3–5 min incremental even at 20 crates). Splitting into crates is the primary compile-time lever — only changed crates and their dependents rebuild. Concrete tactics from the corpus:

- **One integration-test crate, not many** (matklad, "Delete Cargo Integration Tests"): each `tests/*.rs` file is a separately-linked binary; consolidating cut one suite 20s→13s. For internal libs, prefer unit tests (`#[cfg(test)]`) over integration tests to skip the relink entirely.
- **Feature unification across a workspace** silently bloats builds (a dep gets compiled with the union of features any crate wants). `cargo-hakari` generates a `workspace-hack` crate to make this consistent — 1.4–1.7x cumulative speedups on real workspaces (Omicron). Only worth it past ~dozens of crates.
- **Gate heavy deps behind cargo features** (tokio's model) so frontends pull only what they need — directly relevant to a WASM target where binary size and absent threads matter.

### 6. Compiler-style data layout: indices over references

rustc/rust-analyzer pervasively use the **newtype-index + arena pattern** (matklad, 2018): allocate AST/IR nodes in a `Vec`, hand out `Idx<T>` newtypes instead of `&` or `Rc`. This sidesteps Rust's single-owner constraint for graph/cyclic data (which forced Servo into `unsafe` for doubly-linked lists), enables data-oriented SoA layouts, and makes nodes trivially `Copy`/serializable. *Gotcha:* indices can be used against the wrong arena — `typed-index-collections` (`TiVec`) or a branding lifetime restores compile-time safety.

### 7. API evolution: decide stability boundaries *before* you have users

rust-analyzer's stated regret: `rust-project.json` became de-facto stable before they meant it to. *"When designing an API which could become a stability boundary, don't wait for the first users until you stabilize it."* For TextView, the **FFI surface and any on-disk/workspace formats are your real semver boundaries.** Build in from day one: `#[non_exhaustive]` on public enums/structs (lets you add variants/fields non-breakingly), **sealed traits** for any trait you don't want downstreams implementing (lets you add methods later), and treat Hyrum's Law as given (1-in-6 of the top-1000 crates has shipped an accidental semver break). `cargo-semver-checks` in CI catches the mechanical breaks.

### 8. Testing: data-driven snapshots, fast suites as a feature

rust-analyzer's suite runs in <30s vs. cargo's ~7min — and matklad treats that as a *contributor-attraction* feature, not a nicety. The pattern: a single `check(input, expected)` driver where **all variation lives in data**, using `expect-test` (inline, auto-updatable snapshots) or `insta`. Snapshot review becomes "eyeball a diff, accept" rather than hand-editing assertions. Combine with the sans-IO simulation testing from §2.

### 9. Social architecture: design for the contributor distribution

matklad's 2026 framing — a system is simultaneously **deep** (the compiler core: few experts, high quality bar) and **wide** (many IDE features: part-time contributors, "happy path works" bar). rust-analyzer guards each wide feature with `catch_unwind` so a crash in one is isolated and *attracts* a fix rather than scaring contributors off. Deliberate accessibility choices — builds on stable, no C deps, no rustc dependency, fast tests — were made to lower the contribution barrier. For a multi-frontend project, the analogue: keep the core spine pristine and let frontend adapters fail in isolation.


## Key takeaways
- Navigation dominates cost: write a brief ARCHITECTURE.md (country-level codemap) once past ~10k LOC and document invariants — ESPECIALLY 'the absence of something' (e.g. 'core does no I/O'). matklad: figuring out WHERE to change code is 10x the cost of writing the patch.
- Sans-IO is externally vindicated at scale (rust-analyzer hir/ide, Firezone connlib): pass `now: Instant` into the core instead of calling Instant::now(); expose handle_input/poll_transmit/handle_timeout/poll_timeout; reify I/O as data at the edge. Payoff is deterministic property/simulation testing and no Arc<Mutex> tax.
- Make the functional core infallible where possible: rust-analyzer returns (T, Vec<Error>) not Result so a broken input never blocks features — graceful degradation as a design invariant.
- Flat workspace (crates/* , virtual root manifest, crate-name == folder-name, internal crates at version 0.0.0), automation as a `cargo xtask` Rust crate. Trees rot; flat lists scale.
- Compile time is architectural: crates are whole-program-compiled, so the crate split is THE parallelism/incrementality lever. Use ONE integration-test crate (each tests/*.rs relinks separately), prefer unit tests for internal libs, gate heavy deps behind cargo features.
- Copy ripgrep's trait-facade seam (grep-matcher Matcher trait → swappable engines) for TextView's core↔frontend boundary; copy rustc's newtype-index + arena pattern for graph/AST data to avoid the unsafe that Servo needed for cyclic structures.
- Lock in stability-boundary hygiene NOW on the FFI surface and on-disk formats: #[non_exhaustive], sealed traits, cargo-semver-checks in CI. rust-analyzer's documented regret: a format went de-facto stable before they intended.
- Fast tests are a feature, not a nicety (rust-analyzer <30s vs cargo ~7min). Use data-driven snapshot testing (expect-test inline / insta) where all variation is in the input data; review diffs instead of editing assertions.

## Gotchas
- Don't adopt salsa or a full red-green query engine preemptively — it's heavy. rustc/rust-analyzer earned it via interactive-latency pressure; a viewer can start with dirty-flag recompute and add fine-grained incrementality only when large-doc latency forces it.
- Sans-IO has real downsides: bugs in poll_timeout cause hard-to-debug busy-loops; multi-step sequential workflows are verbose without async/.await; almost no ecosystem crates are sans-IO so you wrap blocking/async libs yourself at the edge.
- Newtype indices can silently index the WRONG arena (a classic bug source). Restore safety with typed-index-collections (TiVec) or a branding/invariant-lifetime wrapper, or accept the risk consciously.
- Many cargo integration test files = many separately-linked binaries = slow test builds. Consolidate into one integration-test crate; for internal-only libs skip integration tests entirely in favor of #[cfg(test)] units.
- Workspace feature unification silently rebuilds shared deps under the union of features any crate requests — invisible compile-time bloat. cargo-hakari fixes it (1.4–1.7x) but only earns its keep past dozens of crates; not worth the complexity early.
- FFI defeats inlining (Servo): C/C++ wrapper shims block the inlining the native side relied on, degrading perf. Cross-language LTO helps but is fiddly. Keep the FFI surface narrow and coarse-grained, not chatty.
- Hyrum's Law is empirical, not theoretical: 1 in 6 of the top-1000 crates has shipped an accidental semver break. Anything observable about your FFI/format will be depended on; #[non_exhaustive] and sealed traits buy back evolution room cheaply if added from day one (expensive to retrofit).
- An ARCHITECTURE.md with hyperlinks rots fast — name symbols in prose and rely on symbol search instead; review the doc a few times a year rather than trying to keep it line-accurate.

## Crates
- cargo-hakari — generates a workspace-hack crate to unify dependency feature sets across a large workspace; 1.4–1.7x cumulative build speedups (verdict: well-maintained, guppy-rs; adopt only past dozens of crates, overkill early)
- cargo-semver-checks — lints public-API changes for accidental semver breaks in CI; pairs with #[non_exhaustive]/sealed traits (verdict: actively maintained, low-cost CI gate, recommended once a public/FFI surface stabilizes)
- expect-test — minimalist inline snapshot testing (matklad/rust-analyzer); single check() driver, auto-updatable, all variation in input data (verdict: tiny, battle-tested in rust-analyzer; ideal for a data-driven functional core)
- insta — fuller-featured snapshot testing with .snap files, redactions, cargo-insta review tool, JSON/YAML/etc formats (verdict: most widely used; heavier than expect-test, good when outputs are large structured values)
- typed-index-collections — TiVec/TiSlice indexable only by a specified newtype index, making the arena+index pattern compile-time safe (verdict: small, optional; or hand-roll a newtype Idx<T> per matklad's 2018 post)
- proptest — property-based testing; the engine behind Firezone's sans-IO simulation tests (reference-model + thousands of scenarios/CI run) (verdict: mature, the standard choice; high leverage for a deterministic sans-IO core)
- salsa — generic incremental/demand-driven computation framework (the engine under rust-analyzer) (verdict: powerful but heavy; do NOT adopt preemptively — earn it via interactive latency pressure)
- cargo xtask — convention (not a crate): a workspace member that holds all build/dev automation in Rust instead of Makefiles/shell (verdict: recommended from day one; one toolchain, cross-platform, no shell-portability headaches)

## Sources
- https://matklad.github.io/2021/02/06/ARCHITECTURE.md.html — matklad, 'ARCHITECTURE.md' (Feb 2021) — codemap, invariants, navigation-cost lesson
- https://rust-analyzer.github.io/book/contributing/architecture.html — rust-analyzer Architecture (current) — crate layering, sans-IO core, salsa, testing boundaries, rust-project.json stability regret
- https://matklad.github.io/2026/05/12/software-architecture.html — matklad, 'Learning Software Architecture' (May 2026) — deep-vs-wide, social architecture, catch_unwind feature isolation
- https://matklad.github.io/2021/08/22/large-rust-workspaces.html — matklad, 'Large Rust Workspaces' (Aug 2021) — flat layout, virtual manifest, naming, xtask
- https://matklad.github.io/2021/02/27/delete-cargo-integration-tests.html — matklad, 'Delete Cargo Integration Tests' (Feb 2021) — relink cost, single integration-test crate
- https://matklad.github.io/2018/06/04/newtype-index-pattern.html — matklad, 'Newtype Index Pattern' (Jun 2018) — arena + typed index data layout
- https://www.firezone.dev/blog/sans-io — Firezone, 'sans-IO: The secret to effective Rust for network services' (2024) — production sans-IO APIs, time-as-parameter, proptest simulation, downsides
- https://rustc-dev-guide.rust-lang.org/queries/incremental-compilation-in-detail.html — Rustc Dev Guide, 'Incremental compilation in detail' (current) — red-green query DAG, pure-query invariant
- https://ar5iv.labs.arxiv.org/html/1505.07383 — Anderson et al., 'Experience Report: Developing the Servo Web Browser Engine using Rust' (2015) — whole-program compile cost, 600 modules/20 crates, unsafe for cyclic data, FFI inlining loss, message-passing reasoning
- https://github.com/BurntSushi/ripgrep/tree/master/crates/grep — ripgrep grep crate family (current) — facade + pluggable Matcher trait, library/binary separation
- https://docs.rs/cargo-hakari/latest/cargo_hakari/about/index.html — cargo-hakari docs (current) — workspace-hack feature unification mechanism and speedups
- https://effective-rust.com/semver.html — Effective Rust Item 21, 'Understand what semantic versioning promises' (current) — Hyrum's Law, non_exhaustive, sealed traits, 1-in-6 breakage stat
- https://rust-lang.github.io/rfcs/1105-api-evolution.html — RFC 1105 'API evolution' — which changes are breaking; foundation for non_exhaustive/sealed-trait guidance
- https://lib.rs/crates/expect-test — expect-test (current) — data-driven inline snapshot testing as used in rust-analyzer
- https://github.com/mitsuhiko/insta — insta snapshot testing (current) — snapshot workflow, redactions, CI behavior