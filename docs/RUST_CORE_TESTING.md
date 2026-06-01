# Rust Core Testing — the pyramid, paid forward to all three UIs

> **Status: forward-reference, not in flight.** Companion to
> `docs/RUST_CORE_MIGRATION.md` (which links here). Describes how the Rust core
> and every front-end get tested *once the migration happens*. Documentation
> only — no Rust/Core code exists yet beyond the PoC (separate branch, not on
> `main`).
>
> **Grounding:**
> - `docs/POC_STAGE0-2_OUTCOME_2026-05-31.md` — the PoC that *established* the
>   FFI-boundary test patterns this doc generalizes (37 core + 17 FFI Rust tests
>   + 13 Swift cross-language XCTests, all re-verified green).
> - `docs/research/testing-strategy-2026-05-31/TESTING_STRATEGY.md` — the layer
>   models this doc draws on: §1.2 (TUI/ratatui), §1.3 (vanilla-web cliff),
>   §2 (the per-front-end pyramids), §5 step 7 (the reusable-core consequence).
> - `archive/RUST_CORE_PLAYBOOK_2026-05-30.md` §6 — the Rust testing toolchain
>   (proptest, insta, cargo-fuzz, loom/shuttle, llvm-cov, nextest) and the
>   determinism-by-construction rules.

---

## 0. The one idea everything hangs on

**Test each defect at the lowest layer where it is still faithfully produced,
and reserve a real display only for the residue.** (TESTING_STRATEGY §0.) The
Rust core migration makes this *structural*: by moving domain/state logic out of
every UI and into one headless core, the broad base of the pyramid becomes a
single `cargo test` suite **shared by all three front-ends at once** — SwiftUI,
TUI, and vanilla-web. Each front-end is then left with only:

1. a thin **projection** test (does this UI render the core's snapshot
   correctly?), and
2. its own irreducible **real-display residue** (the bug class that only the
   real compositor / real terminal / real browser engine can produce).

That is the payoff: instead of three front-ends each re-testing parse/filter/
diff/history logic against their own UI, the logic is tested *once* in Rust, and
each UI only proves it projects faithfully. **The pyramid paid forward to all
three UIs at once.**

```
                  ┌──────────────────────────────────────────┐
   per-front-end  │  SwiftUI residue │ TUI residue │ web residue │  ← tiny, real-display only
   ──────────────┼──────────────────┼─────────────┼─────────────┤
   projection     │  T1m projection  │ Buffer+vt100│ jsdom-L2 +   │  ← "does this UI render
                  │  (DocumentModel) │  cell-grid  │ headless CSS │     the snapshot right?"
   ──────────────┴────────┬─────────┴──────┬──────┴──────┬──────┘
   FFI boundary           │  panic / handle / threading / wire / x-lang   │  ← the PoC tier
   ──────────────────────┴───────────────────────────────────────────────┘
   shared base            │   L1  cargo test — ALL domain/state logic     │  ← one suite, three UIs
                          └───────────────────────────────────────────────┘
```

---

## 1. The shared base: L1 domain/state logic in `cargo test`

The core is sync + sans-IO by design (migration doc §1) — which makes it **the
easiest possible thing to test deterministically.** The DST literature's
recommended pattern (a state-machine driven by `receive`/`tick`) *is* a sync
design that bans async in the core; the alignment is not a coincidence
(playbook §6).

**This tier is the broad base of the pyramid for every front-end.** It is where
~all the regressions that used to need a Swift `ViewerCoreTests` suite (and would
have needed parallel TUI/web suites) get caught *once*.

- **Put ALL logic behind `lib.rs`**; keep `main`/FFI shims thin. A binary-only
  crate can't be integration-tested; `tests/` + doctests pressure-test the
  public API.
- **Unit tests** in `#[cfg(test)] mod tests` for private logic; `tests/<feature>.rs`
  for public behavior; **doctests** as compile-checked usage examples.
- **Shared helpers** in `tests/common/mod.rs` (the subdir form — `tests/common.rs`
  becomes a phantom "0 tests" crate).

**Determinism by construction** (the rules that keep L1 replayable — playbook §6):

- Inject a `Clock` trait (`fn now(&self) -> Instant`) and a single seeded
  `rand_chacha` RNG. **Forbid `Instant::now()`/`SystemTime::now()`/`thread_rng()`
  in core modules** — enforce with a clippy `disallowed_methods` lint. One stray
  ambient-time/RNG call destroys replayability.
- Never assert on `HashMap` iteration order (per-process randomized) — use
  `BTreeMap` or sort.
- Model the worker-pool / RPC / subscription engine as a state machine driven by
  a single-threaded message bus in tests. Test ordering = message-application
  order. No `thread::sleep`-based sync.
- **Level-triggered, tested on the coalesced snapshot.** Assert on the *converged
  snapshot* after N mutations, not on notification counts. The PoC's
  `snapshot_is_level_triggered_full_state` is the template: a snapshot is the
  full current visible state, and the test proves it, not the deltas.

**Tooling for L1** (playbook §6 — all dev/CI, zero runtime supply-chain surface):

| Layer | Tool | Targets |
|---|---|---|
| Property | `proptest` | wire encode↔decode round-trip, paging-offset math, edit/undo idempotence, `poll_timeout` strictly advances or returns `None` (catches the 100%-CPU busy-loop). Commit `proptest-regressions/`. |
| Snapshot | `insta` (or std golden file to start) | highlight token streams, RPC response shapes, the **converged subscription state**. Commit `.snap`; insta auto-fails in CI. |
| Fuzz | `cargo-fuzz` + `arbitrary` | markdown/tree-sitter feed, the **binary wire decoder** (untrusted remote bytes), large-file paging. Derive `Arbitrary` on op-enums to fuzz operation *sequences*. |
| Concurrency model | `loom`/`shuttle` | ONLY for hand-written lock-free/atomic primitives. **If you stay on std/crossbeam channels + Mutex driven by the message bus, you likely skip these entirely.** |
| Coverage | `cargo-llvm-cov` | Region-level; works on macOS (tarpaulin's ptrace backend is Linux-x86_64 only). A signal, not a 100% obsession. |
| Runner | `cargo-nextest` | Process-per-test isolation (critical for tests spawning git/jq/LSP or touching global state), retries, JUnit. |

`cargo test` runs in parallel threads — tests mutating env/temp-dirs/ports race.
Use `tempfile` per test (never real user dirs) + nextest's process isolation.
Inject subprocess spawning behind a trait so most tests use a *scripted
transcript*, not a live process.

---

## 2. The FFI boundary: the tier the PoC established

The PoC didn't hand-wave the boundary — it proved each mechanic with tests, and
those tests are the template for the real migration. **This tier is the
contract between the shared core and *every* front-end** (each front-end's FFI
or transport adapter is exercised the same way). The PoC's gate: **17 FFI Rust
tests + 13 Swift cross-language XCTests** (headless, host-safe — no
NSApplication).

| Boundary concern | What to test | PoC template |
|---|---|---|
| **Panic safety** | Wrap every extern body (`catch_unwind`/guard macro). A core panic maps to an error code, doesn't unwind into C, doesn't wedge the handle. | All 7 extern bodies wrapped; `dist`/`test` profiles use `panic="unwind"` so the catch is *load-bearing*; poisoned-mutex recovery. **Caveat from PoC §6:** since Rust 1.81 unwind-across-`extern "C"` is *defined* (auto-aborts) — `catch_unwind` is for **host survival**, not soundness. Don't repeat the stale "panic is UB" framing. |
| **Opaque-handle lifecycle** | Open → use → free exactly once; null-free is safe; double-free is caught; long loops don't leak. | `Box::into_raw`/`from_raw` + explicit `*_free`; ordinary calls *borrow* via `as_ref`; cbindgen emits the handle as a forward-declared opaque struct (consumer can't fabricate one). Tested null-free, buf-double-free, **1000-iter** lifecycle loop. |
| **Single-writer threading** | Concurrent calls into one handle are either serialized or loudly rejected — never UB. | `Mutex`-wrapped handle, `try_lock`→`Busy`; justified `unsafe impl Send+Sync`; proven by `concurrent_calls_are_serialized_or_rejected_never_ub` (**8 threads × 200 ops**). *(PoC noted a redundant hollow test, `single_writer_busy_under_contention` — happy-path only; the real proof is the 8×200 test. Don't model new tests on the hollow one.)* |
| **rmp-serde wire round-trip** | Encode→decode is lossless; named maps (not arrays); oversized/truncated/short frames are rejected. | `to_vec_named` asserted via the fixmap marker; DIY `u32`-LE length prefix; oversized/truncated/short frames rejected; Rust→Swift round-trip. **Interop trap to test for:** default `to_vec()` encodes structs as *arrays* (no field names) — Swift/JS `Codable` expect *maps*. Assert maps on every cross-language message. |
| **Cross-language integration (Swift↔Rust)** | The boundary survives a real consumer driving it headlessly: panic-across-FFI maps to `.panic`, bad-UTF8 throws, level-triggered snapshot is full state, handle lifecycle holds, correctness + filter parity vs the Swift baseline. | The 13 Swift XCTests — host-safe, no UI, run in plain `swift test`. This is the single highest-value thing the PoC established: **the bridge is testable in isolation**, before regressions reach the running app. |
| **Error model** | `Result` → `#[repr(C)]` status enum (status in return, payload in out-param — *never mixed*) → host `throws`; rich detail rides the wire `WireError`; a forward-compat `.unknown(code)` default arm. | The PoC's three-layer error model: internal matchable enums → one versioned wire error `{code,message,data}` → FFI integer code + out-param. Don't conflate the three. |

**Miri caveat** (playbook §5): Miri validates the *Rust* side only — green Miri
proves the Rust half, not the cross-language contract. The Swift↔Rust XCTests are
what prove the contract. Run Miri under both Stacked and Tree Borrows; treat a
Stacked-Borrows failure as real even if Tree Borrows passes.

**"Fake the binary-RPC other end" — per front-end.** The repo already ships this
pattern as `Sources/MDVFakeLSPServer` (a deterministic out-of-process server the
host tests drive). Generalize it: to test a front-end's *adapter* without a real
core, stand up a fake core that speaks the rmp-serde wire and replays scripted
snapshots; to test the *core's* transport without a real UI, drive it with a
fake client. Each side is testable headlessly against a faked peer.

---

## 3. Per-front-end projection tiers

Below the FFI boundary the logic is shared; above it each UI tests only its
**projection of core state** plus its real-display residue. The "real screen"
line sits at a different place for each UI — that's the whole reason they need
different residue tiers (TESTING_STRATEGY §1).

### 3.1 SwiftUI — T1m projection (the leverage tier)

The most valuable SwiftUI tests are the headless ones (TESTING_STRATEGY §2).
After the migration, `DocumentModel` is a projection over `CoreClient` (migration
doc §4), so:

- **T1m (the mass tier):** construct `DocumentModel` with a faked/in-proc core,
  dispatch actions, assert the `@Published` projection matches the core's
  snapshot, and count `objectWillChange` fan-out. This is where the
  republish-storm / quadratic-re-render bug class is caught — the
  `RepublishInvariant` suites already prove this is the right floor, and
  "drive the app and look at it" is *structurally blind* to it.
- The projection assertion is the new core-specific test: **given snapshot S,
  the model publishes view-model V.** Pure, host-safe, microsecond.
- **Residue (T4/T5 on the VM, kept minimal):** the one irreducible
  `NSRulerView`-compositor visual-regression class (observable only at the
  WindowServer composite via `screencapture`), one launch-smoke, real
  `NSWindow.frame` clamping, cross-process preference persistence. Everything
  else demotes to T1m. (TESTING_STRATEGY §3.4 names the residue exhaustively.)
- **Do NOT** use same-process raster (`cacheDisplay`/`ImageRenderer`) as evidence
  the window isn't blank — it re-renders views the live compositor *skips*, the
  exact trap that let the ruler bug ship behind a green suite.

### 3.2 TUI (ratatui) — Buffer/cell-grid + a vt100/pty oracle

ratatui's `Backend` is **cell-oriented, not byte-oriented** — which is *why* the
in-memory grid is lossless and style is structured data, not a parsed escape
sequence (TESTING_STRATEGY §1.2). The "real screen" line sits far to the right:
**~90% of TUI correctness is a pure `state → cell grid` function.**

| Layer | Mechanism | Verifies |
|---|---|---|
| **L1 logic** | call `update(msg)` | the reducer / command emission — *shared with the core's L1 where the state lives in the core* |
| **L2 buffer (the mass tier)** | `TestBackend` / render to a raw `Buffer` | layout, glyphs, **style** (`cell.fg`/`modifier`), cursor, scrollback |
| **L2-style oracle** | render to a byte-emitting backend → `Vec<u8>` → `vt100::Parser` → assert `cell.fgcolor()` | **recovers the style fidelity that glyph snapshots silently drop**, without spawning a process — the missing middle |
| **L3 snapshot** | `insta` on the buffer | layout-at-a-glance regression — *belt-and-suspenders only* |
| **L5 PTY+emulator (residue)** | `portable-pty` + `vt100` | `isatty`-gated behavior, termios raw mode, SIGWINCH, mouse/bracketed-paste/kitty handshakes, exit-restore |

- **Gotcha — style-snapshots silently drop style.** `insta` glyph snapshots
  capture *characters*, not `fg`/`bg`/`modifier`. A green `.snap` is **not**
  evidence the colors are right. Always **assert style at L2** (or via the vt100
  oracle) alongside any glyph snapshot. This is the TUI analogue of the SwiftUI
  "cacheDisplay lies" trap.
- **Property-test the reducer** (random key sequences, assert invariants) — it
  composes because L2 render is pure.
- **The one thing no automated layer nails:** per-emulator grapheme width (wezterm
  caps at 2 cells; xterm/kitty use `wcwidth` → 4 for a ZWJ emoji). Cell tests
  verify *intent*, not the user's actual column placement.

### 3.3 Vanilla-web (WASM) — jsdom L2 + a headless computed-style lane

The web layer is **a hard cliff, not a gradient** (TESTING_STRATEGY §1.3):
layers 1–2 run faithfully in a JS-only runtime; layers 3–5 require a real
engine's cascade/layout/raster.

```
  JS   ─▶ [1] logic (any JS engine, no DOM)            ┐ jsdom-faithful
  HTML ─▶ [2] DOM structure (jsdom: real parser, NO layout) ┘
  ──────────────── CLIFF ────────────────
  CSS  ─▶ [3] computed style + geometry  ┐
  evt  ─▶ [4] trusted input + hit-test   ├─ real engine only (headless browser OK)
  px   ─▶ [5] pixels                     ┘
```

- **L1/L2 (the mass):** core logic runs in any JS engine (or as WASM); DOM
  structure tests in **jsdom** (real parser + selectors — fast, many). The
  projection test: **given snapshot S, the `render(root, vm)` produces DOM D.**
- **Gotcha — jsdom does NO layout.** `getBoundingClientRect()` is all zeros;
  `getComputedStyle` returns *declared*, not *resolved*, values. **Any pixel/
  geometry assertion in jsdom is testing a lie.** (happy-dom is *worse* — it
  invents plausible fake numbers.)
- **The layout cliff → a `--headless=new` lane.** Computed-style assertions in a
  real engine (Playwright) *before* any pixel snapshot — real cascade,
  localizable, low-flake. Prefer DOM+computed-style snapshots over pixel
  snapshots for "did output change."
- **Gotcha — "headless" is not one thing.** Pre-2023 headless Chrome was a
  separate code path that rendered differently; **`--headless=new` runs the same
  browser code.** Verify the mode before trusting any headless layout/visual
  result.
- **Gotcha — trusted vs synthetic events.** jsdom `dispatchEvent` is
  `isTrusted:false` — no default actions, no real focus/`:focus-visible`, no
  hit-testing. Layout-coupled interaction bugs (an invisible overlay eating
  clicks, `pointer-events:none`, z-index stacking) are caught **only** by a
  real-browser input doing real hit-testing. That's the argument for a small
  Playwright lane even for a "simple" vanilla UI.
- **Pixel snapshots** only in a pinned-render container (fixed fonts + software
  raster), small regions — the residue of the residue.

---

## 4. The shape of the whole thing

```
   front-end                shared?    where it's tested
   ──────────────────────   ────────   ───────────────────────────────────────
   domain / state logic     SHARED     L1 cargo test (proptest, insta, fuzz)
   FFI / transport adapter  per-FE     boundary tests (panic/handle/thread/wire)
                                        + Swift↔Rust x-lang XCTests (PoC tier)
                                        + "fake the other end" (MDVFakeLSP pattern)
   ─────────────────────────────────── projection ──────────────────────────────
   SwiftUI projection       per-FE     T1m: snapshot S → @Published V
   TUI projection           per-FE     L2 Buffer + vt100 style oracle
   web projection           per-FE     jsdom-L2 + --headless=new computed-style
   ─────────────────────────────────── residue (real display) ──────────────────
   SwiftUI residue          per-FE     T4/T5 VM: ruler-compositor, launch, frame
   TUI residue              per-FE     L5 PTY+vt100: isatty, termios, SIGWINCH
   web residue              per-FE     Playwright trusted events + pinned pixels
```

**Three gotchas to carry into every front-end** — each is the same shape: a
cheap layer that *looks* like it tests the expensive thing but silently drops
the signal.

1. **TUI:** glyph snapshots silently drop style → assert style at L2 / via vt100.
2. **SwiftUI:** `cacheDisplay`/`ImageRenderer` re-render views the compositor
   skips → not evidence the window isn't blank.
3. **Web:** jsdom does no layout + synthetic events aren't trusted → no px/geometry
   assertions in jsdom; hit-testing needs a real engine.

The migration's gift to testing is that it forces the *cheap* layer (shared L1)
to carry the bulk, leaving each UI a small, honestly-scoped projection test and
a named, irreducible real-display residue.

---

## 5. Cross-references

- **`docs/RUST_CORE_MIGRATION.md`** — the migration this testing strategy
  supports: locked decisions, phasing, the thin-projection end-state, transport
  tiers, per-front-end roadmap. **Read it first.**
- **`docs/POC_STAGE0-2_OUTCOME_2026-05-31.md`** — the PoC that established the
  FFI-boundary tests (§3 scorecard, §6 the panic-UB correction + the hollow-test
  caveat).
- **`docs/research/testing-strategy-2026-05-31/TESTING_STRATEGY.md`** — the layer
  models (§1.2 TUI, §1.3 web cliff), the per-front-end pyramids (§2), and the
  reusable-core consequence (§2 "reusable-core" + §5 step 7).
- **`archive/RUST_CORE_PLAYBOOK_2026-05-30.md`** §6 — the Rust testing toolchain
  and determinism-by-construction rules.
- **`Sources/MDVFakeLSPServer/`** — the in-tree "fake the other end" template.
