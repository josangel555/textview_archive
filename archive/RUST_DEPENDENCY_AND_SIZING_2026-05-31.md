# Rust Dependency Blast-Radius + Bundle Sizing (2026-05-31)

> Empirical study for the deferred Rust-core PoC. All numbers MEASURED with
> `cargo 1.92.0` in throwaway scratch projects (release, `opt-level="z"` +
> fat-LTO + `panic=abort` + `strip`), or measured off the shipped Swift app.
> Estimated values marked `~`. Lives in `archive/` because the Rust core is
> deferred (PoC-first); see the handoff.

## 1. Dependency blast radius (transitive, `cargo tree`, default features)

| crate | runtime deps | +build | lean (no-default / minimal) | bloat source | verdict |
|---|--:|--:|--:|---|---|
| serde (+derive) | **0** | ~4 | 0 runtime | core is dependency-free; derive = build-time proc-macros | **keep** — free at runtime, not DIY-able |
| comrak | **67** | 75 | **13** (`default-features=false`) | `clap` (its CLI) + `syntect`→**`onig` (C regex)** + `bon` | **keep w/ no-default**, or pulldown-cmark |
| pulldown-cmark | 7 | — | **4** (no-default) | — | lighter MD alt; you build the HTML |
| notify | 8 | 8 | 8 | one per-OS backend (unavoidable) | **keep** — DIY = 1000+ LOC × 4 backends |
| tracing | 9 | 9 | ~5 | — | **keep** (facade, core only) |
| tracing-subscriber | 11 | 11 | fewer w/o env-filter/ansi | regex, nu-ansi-term | **app binaries only**, trim features |
| postcard | **15** | 17 | 11 | **`heapless` + `cobs`** (embedded-oriented) | **DROP** — not lean for a non-embedded host |
| rmp-serde | **5** | 6 | 5 | — | **keep** — leanest + cross-language (Swift/JS) |
| thiserror | 6 | 6 | (all build-time) | syn family | keep when needed — **~0 runtime** |
| crossbeam-channel | 2 | 2 | 2 | — | keep when `select!` needed |
| ropey | 3 | 3 | 3 | — | keep (deferred — GB editing) |
| memmap2 | 2 | 2 | 2 | — | keep if mmap (deferred) |
| encoding_rs | 2 | 2 | 2 | big binary data tables | keep only if non-UTF-8 needed |
| cbindgen | 42 | 42 | — | it's a C-header *generator* | **build/dev-only — doesn't ship**; or hand-write header (0 deps) |
| tree-sitter *(agreed)* | 8 | 18 | — | — | keep |
| rustls *(agreed)* | 10 | 18 | — | ring/aws-lc crypto | keep (remote tier only) |

### Three findings that changed decisions
1. **comrak's 67 is a default-features illusion.** It bundles its own CLI
   (`clap`) + `syntect` highlighting (→ `onig`, a **C** regex via `onig_sys`).
   `default-features = false` → **13 pure-Rust crates, zero C**. And we don't
   need syntect — tree-sitter does our highlighting. `pulldown-cmark` (4
   no-default) is even leaner. Markdown parsing is a DIY tarpit (CommonMark
   spec) → adopt, but never the default feature set.
2. **postcard is NOT lean for us — dropped.** Its "tiny" reputation is for
   `no_std`/embedded; on a host it drags `heapless` + `cobs` (15 deps).
   `rmp-serde` (MessagePack) is **5 deps** AND cross-language → use it for the
   wire, DIY the framing. postcard buys nothing on a desktop/server.
3. **serde is genuinely free** (0 runtime deps). `derive` is a build-time
   proc-macro; doesn't ship.

### Build-time vs runtime, and why union ≪ sum
`syn` / `quote` / `proc-macro2` / `unicode-ident` sit under almost everything
(serde_derive, thiserror-impl, clap_derive, bon, darling) but are **build-time
only** (never ship) and **shared** (counted once, not per crate). The *binary*
blast radius is the "runtime" column; the *supply-chain-trust* surface is
runtime+build with the syn family amortized.

**Still owed:** `cargo deny` + `cargo audit` (RUSTSEC advisories, license
compatibility, duplicate-version detection) against the final set — the
programmatic catch for the "bincode-is-unmaintained (RUSTSEC-2025-0141)" class.

## 2. Bundle sizing

### Measured anchors
| Artifact | Size | how |
|---|--:|---|
| Rust core `.dylib` (pulldown-cmark + rmp-serde + tree-sitter-rt + notify + memmap2 + tracing + serde) | **441 KB** | release, opt-z + fat-LTO + panic=abort + strip, dead-stripped (probe-level) |
| Rust core `.a` (pre-link archive) | 5.7 MB | unlinked — NOT shippable size |
| ratatui + crossterm bin | **330 KB** | same release profile |
| Shipped Swift app | **36 MB** | 16 MB exec + 16 MB grammars (11 dylibs) + 4.2 MB JS/icon |

**Headline: the Rust code is tiny** (441 KB probe; ~1–3 MB for a full core).
Size is dominated by two UI-asset layers: **tree-sitter grammars (16 MB)** and
**CM6/mermaid JS (4.2 MB)**, each shared or shed per front-end.

### Per-target (✓ measured · ~ estimated)
| Target | Rust core | framework | grammars 16MB? | JS 4.2MB? | Total |
|---|--:|--:|:--:|:--:|--:|
| macOS app (SwiftUI+FFI) | ~1–3 MB | SwiftUI/AppKit = $0 (system) | yes | yes | **~36 MB** (≈ unchanged) |
| ratatui TUI (no highlight) | ~1–3 MB | +0.3 MB | no | no | **~1.5–4 MB** |
| ratatui TUI (highlight) | ~1–3 MB | +0.3 MB | yes | no | **~17–20 MB** |
| Browser WASM | ~0.2–0.8 MB (post `wasm-opt -Oz`) | wasm-bindgen glue | tree-sitter.wasm ~150KB + lazy per-lang grammar wasm | yes (4.2 MB, reused) | **~1–2 MB wasm + 4.2 MB JS**, lazy |
| Headless Linux server | ~1–3 MB | +rustls ~1–3 MB + tungstenite | yes (server-side) | no | **~5–20 MB** static binary |
| Remote-Mac-UI (thin) | 0 (core remote) | Mac UI shell | local or server | yes | **~10–20 MB** |

### Takeaways
- **macOS app ≈ stays ~36 MB.** Swift-core→Rust-core is a size wash (Swift exec
  shrinks ≈ what the Rust dylib adds; grammars + JS — the real 20 MB — don't
  move). SwiftUI/AppKit cost **0** bundle bytes (system frameworks).
- **Non-Mac targets are far smaller**: TUI sheds the 4.2 MB JS (no WKWebView);
  WASM ships sub-MB core code (native-only deps — notify/memmap2/rustls/
  subprocess — don't cross to wasm; they live server-side).
- **Grammars (16 MB) are the universal swing factor.** The existing
  lazy-grammar split is the lever to keep them out of the initial footprint —
  especially for WASM.
- **rustls adds a few MB** only on the remote/server path.

## 3. Rust empirical gotchas confirmed this session
- **Edition 2024 requires `#[unsafe(no_mangle)]`** (not `#[no_mangle]`) — a hard
  compile error otherwise. (Also `#[unsafe(export_name)]`, `unsafe extern`.)
- **`opt-z` + fat-LTO + strip + `panic=abort` is load-bearing** — the
  5.7 MB `.a` → 441 KB `.dylib` gap is dead-code-elimination. Shippable size
  scales with how much of each dep's API the real core touches.
- **WASM has per-crate friction.** Raw `wasm32-unknown-unknown` lib builds
  tripped on `memchr` (a pulldown-cmark transitive). The web target needs the
  **wasm-pack / wasm-bindgen** toolchain + verifying each crate's wasm support
  (+ `getrandom`'s `js` feature, etc.). An effort *and* sizing signal for the
  browser front-end.

> The dep verdicts here REFINE the locked decisions in the memory note
> `project_rust_core_decision.md` (wire = rmp-serde, postcard dropped; comrak
> no-default). Full crate rationale: `archive/RUST_CORE_PLAYBOOK_2026-05-30.md`.
