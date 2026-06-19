# Spike/Decision: WASM to reduce WebUI duplication? (TSK-800) — 2026-06-19

**Question (owner):** Can we use WASM to share the Rust core with the in-app
WebUI tiers and cut duplication?

**Recommendation: Yes — but scoped tightly. Land the cheap, high-leverage piece
now (a thin `mdvcore-wasm` shim that exposes the EXISTING `dispatch::Method`
registry to the in-app WebViews' JS, replacing the few JS reimplementations of
logic we already own in Rust). Do NOT WASM-ify CodeMirror, Mermaid, or the
markdown→HTML render path — those are not "our duplication," they are
third-party engines or already-Rust-sourced. Keep the separately-tracked
"4th front-end / hosted demo" WASM idea (RUST_FRONTENDS_BACKLOG item 8) as a
distinct, lower-priority thing — it answers a different question.**

This is the right thing because it deletes real, owned duplication at the one
place it exists (JS logic that has a Rust twin), reuses the thin-waist envelope
the architecture was already built around, adds **zero new dependencies** for
tier-1, and does not pick a doomed fight against CodeMirror / Mermaid.

---

## The two questions hiding inside "use WASM to reduce WebUI duplication"

These get conflated. They have different answers.

| | (A) Dedupe the **in-app** WebViews' JS | (B) WASM as a **hosted demo / 4th front-end** |
|---|---|---|
| Goal | Stop reimplementing Rust-core logic in JS inside the macOS app's WebViews | Run the whole viewer in a browser with no local server |
| Duplication it removes | JS twins of `find_engine`, `indent`, `cm_edit`, etc. | None (it's a NEW surface, not a dedupe) |
| Tracked as | **TSK-800 (this doc)** | RUST_FRONTENDS_BACKLOG.md item 8 |
| Verdict | **Do the scoped slice now** | Defer; separate spike; not a dedup play |

The owner's framing ("reduce **WebUI duplication**") is question (A). The rest of
this doc is about (A); (B) is addressed briefly at the end so the two stop
getting muddled.

## The homework — what actually duplicates, and what does NOT

The macOS app hosts three `WKWebView` surfaces (`Sources/ViewerUI/Resources/`):
markdown render (`markdown.css` + injected HTML), the CodeMirror editor
(`codemirror/`), and Mermaid (`mermaid/`). Auditing each for "JS that
reimplements logic we already have in Rust core":

### Real, owned duplication (WASM can delete this)

The Rust core's `dispatch::Method` registry (`crates/core/src/dispatch.rs`)
already exposes — over ONE safe-Rust entry point reused by FFI/TUI/web — exactly
the algorithmic surface the editor WebView reimplements in JS:

- `Method::FindSearch` (`find_engine`) ⟷ CodeMirror's JS `findNext` /
  `findPrevious` / `replaceAll` / `highlightSelectionMatches` (`codemirror.html`).
- `Method::IndentDetect` (`indent`) ⟷ CM's `indentUnit` / `indentOnInput` /
  `indentWithTab` + the hand-rolled indent-guide builder (`codemirror.html` Phase 4).
- `Method::CmApply` (`cm_edit`) ⟷ the edit-batch reducer the editor already
  round-trips to Swift→Rust for; the JS side still owns selection/edit shaping.
- Fold-range answering (`outline` / `nav` in core) ⟷ CM's JS `foldGutter` +
  the binary-searched fold-range answerer (`codemirror.html`).

This is genuine duplication: the SAME algorithm exists in Rust (gated, tested,
the system of record) AND in JS (in the page, untested by our suite, free to
drift). It is the "stop the drift before it starts" class the front-end backlog
already flags for TUI/web — the in-app WebView is just a fourth drift surface.

### NOT duplication (leave it alone — WASM-ifying it is a net loss)

- **CodeMirror itself.** It is a third-party editor engine (~660 KB bundle). We
  do not own its rendering, virtual scroll, selection model, or keymap, and we
  will not reimplement it in Rust. The dedupe target is the *thin algorithmic
  glue around* it (search/indent/fold answers), not the engine.
- **Mermaid.** Third-party diagram engine; the only "ours" is `mermaid-shim.js`
  (theme resolution + step-manifest sort/apply for walkthroughs). Small, and its
  step-sort twin could *optionally* move to core later, but it is not worth a
  WASM boundary on its own.
- **Markdown → HTML.** Already sourced from Rust (`Method::MarkdownRender`,
  `markdown::render_wire`); the WebView just displays injected HTML. No JS
  markdown parser to dedupe — this is the model we want the others to follow.

So the surgical target is **the editor WebView's algorithmic JS that has a Rust
twin**, reached through the registry that already exists.

## Why WASM is the right mechanism (not "call Swift")

The editor WebView ALREADY round-trips some work to Swift via
`window.webkit.messageHandlers.mdvEditor.postMessage` (`codemirror.html`). Three
ways to dedupe; WASM wins on the latency-sensitive, per-keystroke surface:

| Mechanism | Latency | Offline / hosted reuse | New deps |
|---|---|---|---|
| postMessage → Swift → Rust FFI → back | async hop per call; janks per-keystroke find/indent | macOS-only (no Swift in a browser) | none |
| WASM core in the page | synchronous, in-process linear memory | works in ANY WebView incl. a future hosted (B) | **none for tier-1** |
| Keep JS twins | zero hop | n/a | none, but the drift cost we are trying to kill |

The async Swift hop is fine for batch/coarse ops but wrong for the per-keystroke
ones (incremental find-as-you-type, indent-on-input, fold recompute). WASM gives
the JS a **synchronous, in-process** call into the *same* Rust functions Swift
calls — one algorithm, two host bindings (FFI for Swift, linear-memory envelope
for JS), zero JS reimplementation. And the artifact is portable to (B) for free.

## Feasibility — verified, not assumed

The core is already WASM-shaped, so tier-1 is genuinely cheap:

- `mdvcore-core` is `#![forbid(unsafe_code)]` + sans-IO (`crates/core/src/lib.rs`).
  Zero `std::fs` / `std::net` / `std::thread` / `std::process` / `std::env`
  usage in production code (verified by grep AND now pinned by the regression
  guard `crates/core/src/wasm_shape.rs` — see Tests below). Deps are
  `serde` + `rmp-serde` + `regex-lite` + `pulldown-cmark`, all pure-Rust and
  `wasm32`-compatible (the 2026-06-09 audit verified the transitive set).
- The thin-waist envelope already exists: `dispatch::call(method, req, aux) ->
  bytes`. A WASM shim is the SAME `(ptr,len)→(ptr,len)` contract over linear
  memory — the audit estimates **~100 lines of glue, no wasm-bindgen, no new
  crate deps** for tier-1.
- The JS contract for the shim mirrors the FFI one with ONE wasm-specific
  caveat the audit flagged: **wasm has no unwinding — a panic traps the whole
  instance.** The JS wrapper must `catch (RuntimeError)` → discard the instance
  → re-instantiate (the wasm analog of the FFI drop-&-recreate-on-poison rule).

What tier-1 deliberately EXCLUDES (matches the audit): tree-sitter / the
`mdvcore-highlight` crate stays out of WASM permanently (unsafe C grammar FFI;
syntax highlighting in the editor stays CM's job or the FFI highlight path).

## Cost / dependency gate

- **Tier-1 shim (compile + the JS glue): no new dependencies.** Pure Rust + the
  existing crates. Loads as a `.wasm` asset in the WebView bundle (size budget:
  measure against the 48 MB bundle cap / 26 MB exec sub-cap — a core-only wasm
  is small, but confirm with `check-bundle-size.sh`).
- **`wasm32-unknown-unknown` target** is a `rustup` toolchain COMPONENT, not a
  crate dep — but it is **not installed** in the current host/sandbox
  (`rustup target list --installed` shows no wasm). Adding it to host + CI is an
  **owner-gated toolchain change** (cheap, free, but per project policy the
  owner approves it). The audit already recommended "approve now (free)."
- **A wasm execution test** needs a runtime (`wasmtime-cli` or node) so a real
  round-trip can be asserted, not just `cargo check`. That is a second
  owner-gated dev/CI tool, deferrable to when the shim actually ships (the audit
  put it at Phase 3). Until then, the host source-scan guard (below) protects
  the feasibility premise.

Both gates are toolchain/CI provisioning, **not** application dependencies — no
supply-chain surface added to the shipped app.

## Decision options

1. **(Recommended) Scoped dedupe via a tier-1 `mdvcore-wasm` shim.** Expose the
   existing `dispatch` registry to the editor WebView's JS; migrate the JS twins
   of `find_engine` / `indent` / `cm_edit` / fold-answers to call into the WASM
   core; leave CodeMirror/Mermaid/markdown engines alone. Requires owner OK on
   the `wasm32` target (toolchain, free). One algorithm, two host bindings.
2. **Dedupe via the existing postMessage→Swift→FFI hop instead of WASM.** No new
   toolchain, but adds an async hop to per-keystroke paths (jank) and is
   macOS-only (no reuse for a hosted tier). Acceptable ONLY for coarse/batch ops.
3. **Status quo (keep the JS twins).** Cheapest today, but pays the drift tax
   forever — the exact "feature parity drift" the front-end backlog warns about,
   now on a fourth surface with no test coverage in our suite.
4. **Full WASM 4th front-end / hosted demo (RUST_FRONTENDS_BACKLOG item 8).**
   Worthwhile but a DIFFERENT goal (new surface, not a dedupe); bigger spike;
   defer. The tier-1 shim from option 1 is a prerequisite of it anyway — do the
   dedupe first, get the demo as a downstream bonus.

**Why option 1 is the right thing:** it removes the only duplication we actually
own, at the latency-correct layer (synchronous in-page), reusing the thin-waist
the architecture was deliberately built around, with no app dependencies and a
portable artifact. It is frugal (delete code, don't add engines), future-proof
(unblocks the hosted tier), and refuses the two wrong fights (reimplementing
CodeMirror in Rust; or accepting permanent JS↔Rust drift).

## Sequencing (if/when option 1 is approved)

1. Owner approves the `wasm32-unknown-unknown` target (toolchain component, free).
2. Add a non-blocking CI canary: `cargo check --target wasm32-unknown-unknown -p
   mdvcore-core` (compile-only; the source-scan guard already protects the
   property in the always-on lane).
3. Land `crates/wasm` (`mdvcore-wasm`): the ~100-line linear-memory envelope over
   `dispatch::call`, + the JS wrapper (alloc/free, call, the catch-trap→
   re-instantiate contract). Out of `default-members` like tui/web.
4. Approve a wasm execution-test runtime; add a round-trip test (the tests
   mandate — `cargo check` alone is not an execution test).
5. Migrate ONE editor JS twin first (incremental find is the highest-leverage,
   most-janky candidate) end-to-end, validate, then the rest.
6. Track each migration as its own `TSK` so parity is asserted per-twin.

## Tests shipped with this spike

A doc-only spike still must guard its load-bearing claim. The recommendation
rests entirely on **"the core is wasm-shaped"**; if that silently regresses, the
WASM path silently dies. So this lands a regression guard:

- `rust-core/crates/core/src/wasm_shape.rs` — a host, dependency-free test that
  source-scans the production core for the std IO surface
  (`std::fs`/`net`/`thread`/`process`/`env`) that would break
  `wasm32-unknown-unknown`, and fails `cargo test --workspace` if any creeps in.
  It also asserts the core src tree stays flat (so the scan can't miss a file).
- Teeth demonstrated: injecting `std::fs::metadata(...)` into a production core
  module makes the guard FAIL red; removing it returns it green (run + restored
  during this spike). A second test (`guard_detects_an_injected_violation`)
  pins both the needle scan and the test-module stripper so the guard's own
  logic is covered.

This is the host-testable proxy for the canonical `cargo check --target
wasm32-unknown-unknown`, which is owner-gated on the toolchain component and not
installed here. The two are complementary: the guard runs always and pins the
*property*; the compile-check confirms the *exact build* once the target lands.

## Pointers

- `rust-core/crates/core/src/dispatch.rs` — the thin-waist `Method` registry a
  WASM shim would expose (the dedupe vehicle).
- `Sources/ViewerUI/Resources/codemirror/codemirror.html` — the editor WebView
  JS holding the find/indent/fold twins.
- `docs/research/rust-core-audit-2026-06-09/synthesis.md` (§"WASM path") +
  `architecture.md` — the verified feasibility analysis this builds on.
- `docs/RUST_FRONTENDS_BACKLOG.md` item 8 — the separate "hosted demo / 4th
  front-end" idea (question B), explicitly NOT this dedupe.
