# Hex / HexSearch carve-out — Stage B fallback-model decision (TSK-810)

**Status:** DESIGN SPIKE — owner decision required. No code change.
**Date:** 2026-06-19
**Scope:** Stage B deletion order #2 (`hexSearch`) and #3 (`hex`) — the two
engines whose Swift twins **cannot fully delete** the way `indent` (#1) and
`diff` (#4) did.

---

## TL;DR

`indent`/`diff` deleted cleanly because **every** live caller routed through the
adapter, so removing the twin left zero Swift references. Hex is different: a
handful of Swift call sites consume the Swift engines **directly, by design**,
because the Rust FFI doesn't expose an API shape that fits them. Those call sites
are real, small, and structural — not laziness.

**Recommendation: Option A** — collapse each adapter to *rust-first for the
routed path*, **keep** the Swift code for the carved-out paths, and retire only
the gate case / env var / Settings toggle. The Swift code stays alive anyway for
the carve-out; the fail-safe fallback is therefore *free safety with zero extra
dead-weight*, and it keeps the migration honest (no silent-failure risk, no
twin-deletion payoff to chase). File a follow-up to do the **real** clean
deletion (Option C) once Phase-1 windowing + a byte-pattern search FFI land — at
which point hex re-joins the uniform rust-only model.

---

## 1. What concretely keeps the Swift engine alive

Stage A (`RustCoreGates`) already routes the two *string-driven* operations
through Rust by default (`hex`, `hexSearch` both `defaultEnabled = true`):

| Op | Adapter | Rust FFI | Swift fallback |
|----|---------|----------|----------------|
| Full-dump render | `RustHexAdapter.buildAll` | `mdvCoreHexRender` → `hex::render_all` | `HexDumpBuilder.buildAll` |
| Query search (parse+find) | `RustHexSearchAdapter.search` | `mdvCoreHexSearch` → `hex::hex_search` | `HexSearchEngine.search` |

But four **live, non-fallback** Swift consumers remain after Stage A
(`grep` over `Sources/`, 2026-06-19):

1. **`HexView.swift:217` — `HexSearchEngine.parse(query, mode:)`**
   UI-side query validation on **every keystroke**. Drives the red "invalid"
   field background + the disabled prev/next buttons (`queryIsInvalid`). The
   pattern is then handed to the Rust `search`; parse runs Swift-side because it
   is a per-keystroke UI affordance, not a search execution. (`STAGE_B_DELETION_PLAN.md`
   row #2: *"parse() helper stays (query→pattern is UI-side)"*.)

2. **`HexView.swift:256` — `HexSearchEngine.find(pattern:, in:)`**
   **Click-to-highlight.** A click/drag produces a `[UInt8]` byte pattern
   directly (`reportClickPattern`), so there is **no query string to parse** —
   the existing `mdvCoreHexSearch` FFI takes `(data, query: String, mode)`, which
   doesn't fit a raw-bytes pattern. `RustHexSearchAdapter`'s own doc comment
   carves this out explicitly: *"the cheap single-byte click-highlight
   (`offsets(ofByte:)`) stays Swift-only."*

3. **`HexView.swift:650 / :744` — `HexDumpBuilder.plan(...)` + `.build(...onChunk:)`**
   The **windowed / streaming chunk build** that fills `NSTextView` incrementally
   for multi-MB files. `RustHexAdapter` only routes the *all-at-once* `buildAll`
   (used on the small-file sync path, `≤256 KiB`). The chunked path's
   `onChunk: (Int, String) -> Bool` callback is a **synchronous closure that
   cannot cross the C ABI** — the adapter doc says so directly: *"the
   chunked/streaming `build(...onChunk:)` ... stays in Swift (its callback can't
   cross the C boundary)."* `hex.rs` agrees: *"the chunked/streaming drive ...
   stays in Swift."*

So the residual coupling is **two structural API-shape gaps**, not a porting
oversight:

- **hexSearch:** the FFI is string-query-only; click-highlight needs a
  **raw `[UInt8]` pattern** entry point. Plus `parse()` is a UI validation
  affordance that belongs UI-side regardless.
- **hex:** the FFI is full-buffer-only; the streaming view needs a **windowed /
  range-render** entry point (the Phase-1 windowed-snapshot contract, not yet
  landed) before the chunk loop can move Rust-side.

> Corroborating signal: `CoreCapabilities.requiredByShippingAdapters`
> (`CoreClient.swift:205`) lists `.hex` but **not** `.hexSearch` — i.e. render
> already hard-requires the core, but search deliberately still has a live
> fallback. Hex render's *small-file* path is rust-required; its *streaming*
> path is not yet portable.

---

## 2. Fallback-model options

| | **A — rust-first, keep Swift fallback, retire gate** (RECOMMENDED) | **B — rust-only, degraded-on-fault, no fallback** | **C — finish the port first, then delete like indent** |
|---|---|---|---|
| Adapter | Collapses to direct Rust call for the routed path; `RustCoreFallback` Swift arm **stays** | Direct Rust call; on fault returns `[]` / placeholder dump | Adapter deleted; consumers call Rust directly |
| Gate/env/toggle | **Retired** (no dual-engine choice left to toggle) | Retired | Retired |
| Swift twin code | **Stays** (needed for click-highlight, parse, chunk build) | Stays (same carve-outs) — but now *also* a fallback that's never reached | **Deleted** entirely |
| New Rust work | None | None | New `hex_search_find(pattern:[u8])` FFI **+** windowed/range hex-render FFI (Phase-1 windowing) |
| Bundle size | No change (twin already shipping) | No change | ~tiny reclaim (HexDumpBuilder ~280 LoC, HexSearchEngine ~110 LoC) — negligible vs the 16 MB grammar item (TSK-854) |
| Parity-drift risk | **Lowest** — A/B parity suites stay live as long as both arms exist; or convert routed paths to golden | Medium — twin can silently drift from Rust since it's never exercised on the routed path | None (one engine) |
| Silent-failure risk | **None** — fault falls back to a working Swift path | **New risk** — a Rust regression shows the user an empty dump / no matches, *with the twin sitting right there unused* | None |
| Migration-policy fit | Good — Swift twin is **bugfix-only** (carve-out paths only); routed paths are rust-first | Poor — pays the *risk* of deletion without the *reward* (twin stays) | **Best** — uniform rust-only end state |
| Effort | **Lowest** (delete gate plumbing only) | Low | **Highest** |

### Why B is the trap
B is the "uniform model for its own sake" option. It removes the fallback to
*look* consistent with indent/diff — but the Swift engine **does not leave the
bundle** (the carve-outs keep it), so there is **no twin-deletion payoff**. You
pay the full silent-failure risk of fallback removal and get none of the
size/maintenance reward. Strictly dominated by A.

### Why not C *now*
C is the genuinely correct long-term end state and is consistent with the
highest-standard reading of the migration policy. But it is blocked on two real
pieces of infrastructure:

- **Windowed hex render** depends on the **Phase-1 windowed-snapshot contract**
  (the same contract `cmEdit`/large-doc rendering needs) — that's an epic, not a
  hex-local change. `RustHexAdapter` and `hex.rs` both explicitly defer the
  chunk path to *"until the Phase-1 windowed snapshot lands."* `hex.rs` already
  prototypes the bulk-output plumbing (`render_wire_aux`, the `aux` side-channel)
  — the rails exist, but the windowed *drive* doesn't.
- **Byte-pattern search FFI** is small (a `hex_search_find(&[u8], &[u8])`
  already exists in `hex.rs:189` as `pub(crate)` — it just needs an FFI symbol
  + adapter), but doing it in isolation strands it behind the windowing work
  that gates full deletion anyway.

Shipping C piecemeal would mean a half-deleted twin (search ported, render not),
which is worse than a clean carve-out boundary. So C becomes a **fast-follow
once Phase-1 windowing lands**, not a now-task.

---

## 3. Recommendation — Option A, with a tracked path to C

**Adopt Option A for both `hex` and `hexSearch`:**

1. **Retire the gate plumbing** for `hex` and `hexSearch`:
   - Drop the `RustCoreCapability.hex` / `.hexSearch` cases, their `defaultsKey`,
     `envVar`, and the Settings toggles. There is no longer a dual-engine choice
     to expose.
2. **Collapse the adapter routed path to a direct Rust call**, but **keep the
   Swift functions** (`HexDumpBuilder.buildAll`, `HexSearchEngine.search/find/
   parse`) — they are still the implementation for the carved-out paths AND the
   safety fallback for the routed path. The fallback is *free*: the code ships
   regardless.
   - Practically: `RustHexAdapter.buildAll` and `RustHexSearchAdapter.search`
     keep their `RustCoreFallback.run(rust:swift:)` shape but lose the gate
     argument (always rust-first, swift-on-fault).
3. **Keep `.hex` in `requiredByShippingAdapters`? Decide per engine.** With the
   fallback retained, render does *not* strictly need to be required — but
   keeping it documents intent. (Owner micro-call; default: leave as-is.)
4. **A/B parity suites:** keep them live (both arms still exist), OR convert the
   routed paths to golden suites per `STAGE_B_DELETION_PLAN.md`. Keeping them
   live is cheaper and the oracle is still real.
5. **File the Option-C fast-follow** (two tickets, blocked on Phase-1 windowing):
   - `hexSearch` rust-only: add `hex_search_find(pattern:[u8])` FFI + route
     click-highlight; move `parse()` validation to a thin rust call or accept it
     stays UI-side (it's a UI affordance, arguably *should* stay Swift).
   - `hex` rust-only: windowed/range render FFI riding the Phase-1 snapshot
     contract; move the chunk loop's per-chunk render Rust-side (the `onChunk`
     *drive* stays Swift — that's NSTextView orchestration, correctly host-side).

### Implementation surface (Option A)
- `Sources/ViewerCore/RustCoreGates.swift` — remove `hex` / `hexSearch` cases
  (and the round-2 `defaultEnabled` note).
- `Sources/ViewerCore/RustHexAdapter.swift`, `RustHexSearchAdapter.swift` —
  drop the gate read; keep the rust-first / swift-fallback body.
- `Sources/ViewerUI/SettingsView.swift` — remove the two experimental toggles.
- Tests: A/B suites stay green (or golden-convert); add a probe-test update for
  the retired capability cases (`RustCoreCapability.allCases` count).
- **No `Sources/` deletions** — `HexDumpBuilder`, `HexSearchEngine`,
  `HexLayout`, `HexCaretMap`, `HexHighlightPlan`, `HexGridGeometry` all stay.

### Why A is the highest-standard *available* choice
The migration policy says ported engines are *bugfix-only* on the Swift side.
Under A that holds exactly: the Swift hex code receives no new features/perf —
it serves the carve-out paths (which have no Rust equivalent yet) and a free
fallback. It does **not** create the "permanent invisible fallback masks Rust
regressions" failure mode the deletion plan warns about, because the **audit-log
core-call failure events (TSK-636)** still make any Rust fault loud — we get the
visibility of B without its silent-empty-result risk. And it leaves a clean,
documented runway to C (the true uniform end state) the moment Phase-1 windowing
unblocks it. It is strictly better than B and strictly cheaper/safer than a
premature, piecemeal C.

---

## 4. What needs the OWNER's decision

**Pick the Stage-B end-state for `hex` + `hexSearch`:**

- **[ ] A (recommended)** — rust-first routed path, **keep** Swift fallback,
  retire only the gate/env/toggle. Free safety, no dead-weight, honest. File
  the C fast-follow as blocked-on-Phase-1-windowing.
- **[ ] B** — rust-only, degraded/empty on fault, no fallback. (Not advised:
  pays deletion's risk, keeps the twin anyway.)
- **[ ] C now** — fund the new FFIs (byte-pattern search + windowed render)
  *before* Stage B so the twins fully delete like indent/diff. Cleanest end
  state, but pulls Phase-1 windowing forward and is the most work.

**Secondary (only if A):** keep `.hex` in `requiredByShippingAdapters`, or drop
it now that a fallback is retained? Default: leave as-is.

Everything in §3 is implementable autonomously once the A/B/C choice is made;
the *only* true gate is which end-state model you want.
