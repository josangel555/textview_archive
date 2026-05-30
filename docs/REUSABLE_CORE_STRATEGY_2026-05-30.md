# Reusable Core Strategy — Rust core / multi-front-end

**Date:** 2026-05-30 · **Status:** direction agreed, decision pending · **Owner:** Jos

## Goal

One reusable core runnable across: **macOS SwiftUI · WebUI (browser) · macOS terminal (ratatui) · Linux terminal** — plus the explicit vision:

> Run the **core headless on a Linux box** and do everything the Mac UI can do via a **browser**; and/or run the **same Mac UI in "remote mode"** against that core.

Both halves of that vision reduce to one requirement: a **clean, serializable, transport-agnostic core protocol**. That is the keystone (see "De-risking insight").

## The deciding question

Is the **macOS app the product** (other UIs are nice-to-haves) — or is the **reusable core the product** (the Mac app is one client among several)? This single answer determines whether a core rewrite is worth it. The remote/browser vision implies the latter.

## Reframe (two of three options collapse)

- ❌ **Rewrite the whole app to Rust (incl. the Mac GUI).** No. Throws away native macOS integration — SwiftUI/AppKit, WKWebView, NSTextView, TCC + signing, NSServices, the CM6 WebView host — for a less-native Rust GUI. Strictly a loss for the Mac target.
- ✅ **Move `ViewerKit` + `ViewerCore` to a portable language (Rust).** Keep Swift/SwiftUI for the Mac UI; add ratatui (TUI) + WASM (WebUI) front-ends. This is the real question.

## Target matrix (the decisive factor)

| Front-end | Swift core | Rust core |
|---|---|---|
| **Mac SwiftUI** | native, in-process, zero tax | FFI boundary (mitigated by `uniffi`/`swift-bridge`) |
| **Mac terminal** (ratatui) | FFI/IPC bridge, or a Swift TUI | **native, zero FFI** |
| **Linux terminal** | Swift-on-Linux exists but FSEvents/AppKit/NSColor don't port — **weak** | **native, clean** |
| **WebUI** | ~no production Swift→WASM; only as a backend server | **WASM-native**, runs client-side |

**Bottom line:** a Swift core is fine for *"Mac + maybe a Mac TUI."* It **fails Linux + Web** (no production Swift→WASM; macOS-isms don't port). Linux + browser are exactly the stated targets → **favors a portable (Rust) core.**

## Gains (Rust core)

- **True cross-platform** — one core → macOS, Linux, WASM. Per-platform Swift caveats (FSEvents-only watching, `NSColor` in theme, macOS-26 Foundation bugs) vanish.
- **The large-file win** — the deferred mmap + zero-copy line-index pager (bounded RAM for GB files) is Rust's home turf (`memmap2` + `&[u8]`). Directly fixes the "file too large" pain.
- **Strong crate parity** — `comrak`/`pulldown-cmark` (markdown), official `tree-sitter` crate (better than the Swift wrapper dance), `notify` (cross-platform watch), `rusqlite`, `std::process` (cleaner rlimit/timeout). LSP is already JSON-RPC/stdio — trivial in Rust.
- **Perf/memory** on the byte-pushing work (parsers, search, highlight spans).
- **Zero-FFI for non-Swift front-ends** — ratatui + WASM call Rust directly.

## Losses / costs

- **The rewrite** — `ViewerCore` is large and battle-tested (~1359 ViewerCoreTests + dozens of LESSONS.md fixes). Months to parity. macOS-platform bug fixes vanish (good); domain bug fixes (CSV ragged rows, diff, regex-DoS, symlink TOCTOU) must be re-ported + re-tested. **The tests are the spec.**
- **FFI tax on the *primary* (Mac) UI** — every UI→core call crosses a boundary. **Mitigated**: `uniffi` (Mozilla, used in Firefox) + `swift-bridge` generate idiomatic Swift bindings from Rust incl. records, **enums-with-payloads**, async, errors. A generated, typed boundary — not raw-C hand-marshalling. Still a tax (serialize at the edges, design the interface), but viable.
- **`swift-markdown` → `comrak`** lib swap (equivalent cmark-gfm; rewrites `HTMLRenderer`'s AST walk). Upside: comrak HTML is directly reusable by the WebUI.
- **Second-system / divergence trap** — the biggest *risk* (distinct from cost): rewrite stalls at 80%, Swift keeps getting patched, the two diverge.

## De-risking insight (most important)

**The boundary matters more than the language.** Highest-leverage move *regardless of whether we ever rewrite*: harden **one stable, serializable, transport-agnostic core API** (the MCP/JSON-RPC stdio server is a start). Once that boundary is crisp:

1. A TUI/WebUI can be driven with the **Swift core today** (no rewrite for a first non-Mac client).
2. The core can be swapped to Rust **behind the boundary, one subsystem at a time**, with the Swift tests as the oracle — no big bang.
3. **It directly enables the remote/browser vision**: a serializable boundary = the core runs headless/remote and any UI (browser, remote Mac UI) drives it over the wire.

## Recommendation — phased, ROI-gated

0. **Harden the boundary.** Define the core protocol. Large-file engine is the ideal first thing behind it.
1. **One Rust pilot behind `uniffi`** — reimplement just the large-file mmap pager; expose to the Swift Mac UI; reuse from a ratatui spike. Proves boundary + FFI + cross-platform reuse, and ships the bounded-RAM viewer.
2. **Migrate perf/portable-critical subsystems** behind the boundary (parsers, search, highlight-span producer, file-watch via `notify`); leave LSP/git/sessions in Swift until there's a reason.
3. **Full Rust core only if the multi-platform product justifies it** (Linux/Web committed, not hypothetical).
4. **Never rewrite the Mac GUI.**

## Open questions / decisions

- **Mac-app-as-product vs core-as-product** — the deciding question.
- Are **Linux + Web committed** targets or aspirational?
- Remote protocol transport: stdio / WebSocket / HTTP / gRPC — ties to the boundary audit.
- "Same UI in remote mode": does the Swift Mac UI talk the same protocol as the browser UI? (Argues for one transport-agnostic protocol, not two.)
- FFI tooling: `uniffi` vs `swift-bridge`.

## Companion investigations (in progress, read-only)

- `docs/CORE_UI_BOUNDARY_AUDIT_2026-05-30.md` — current UI↔Core boundary, what can move to Core, interface critique + a proposed elegant/serializable interface.
- `docs/CORE_LINUX_PORTABILITY_2026-05-30.md` — what blocks `ViewerCore`/`ViewerKit` from running on Linux, and what each blocker would take.
